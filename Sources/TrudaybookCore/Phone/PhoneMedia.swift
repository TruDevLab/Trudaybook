import CommonCrypto
import CryptoKit
import Foundation

// MARK: - SDP

/// Описание звука в звонке (SDP, RFC 4566): куда слать и чем кодировать.
///
/// Кодеки — только G.711 (PCMA, PCMU): их понимает любая АТС, и для них
/// не нужна сторонняя библиотека. Тоновый набор — telephone-event (RFC 4733).
public struct SDPDescription: Equatable, Sendable {
    public enum Direction: String, Sendable { case sendrecv, sendonly, recvonly, inactive }

    public var address: String
    public var port: Int
    /// `RTP/AVP` или `RTP/SAVP` (шифрованный звук).
    public var profile: String
    /// Номера форматов в порядке предпочтения.
    public var payloads: [Int]
    /// Номер → имя кодека в верхнем регистре: `8 → PCMA`, `101 → TELEPHONE-EVENT`.
    public var codecs: [Int: String]
    /// Ключи SRTP: `тег → (набор, ключ inline)`.
    public var crypto: [(tag: Int, suite: String, key: String)]
    public var direction: Direction

    public static func == (lhs: SDPDescription, rhs: SDPDescription) -> Bool {
        lhs.address == rhs.address && lhs.port == rhs.port && lhs.profile == rhs.profile
            && lhs.payloads == rhs.payloads && lhs.codecs == rhs.codecs && lhs.direction == rhs.direction
            && lhs.crypto.map(\.key) == rhs.crypto.map(\.key)
    }

    public init(address: String, port: Int, profile: String = "RTP/AVP", payloads: [Int], codecs: [Int: String],
                crypto: [(tag: Int, suite: String, key: String)] = [], direction: Direction = .sendrecv) {
        self.address = address
        self.port = port
        self.profile = profile
        self.payloads = payloads
        self.codecs = codecs
        self.crypto = crypto
        self.direction = direction
    }

    /// Наш набор форматов: A-закон первым — так у большинства АТС в России и Европе.
    public static let supported: [(Int, String)] = [(8, "PCMA"), (0, "PCMU")]
    public static let dtmfPayload = 101
    public static let srtpSuite = "AES_CM_128_HMAC_SHA1_80"

    /// Предложение для нового звонка.
    public static func offer(address: String, port: Int, srtpKey: String?) -> SDPDescription {
        var codecs = Dictionary(uniqueKeysWithValues: supported)
        codecs[dtmfPayload] = "TELEPHONE-EVENT"
        return SDPDescription(
            address: address, port: port, profile: srtpKey == nil ? "RTP/AVP" : "RTP/SAVP",
            payloads: supported.map(\.0) + [dtmfPayload], codecs: codecs,
            crypto: srtpKey.map { [(1, srtpSuite, $0)] } ?? [])
    }

    /// Ответ на чужое предложение: первый общий кодек, тоновый набор —
    /// под чужим номером. `nil` — договориться нельзя (ответим 488).
    public static func answer(to offer: SDPDescription, address: String, port: Int, srtpKey: String?) -> SDPDescription? {
        guard let codec = offer.audioPayload else { return nil }
        var payloads = [codec]
        var codecs: [Int: String] = [codec: offer.codec(for: codec) ?? "PCMA"]
        if let dtmf = offer.dtmfPayload {
            payloads.append(dtmf)
            codecs[dtmf] = "TELEPHONE-EVENT"
        }
        let direction: Direction = switch offer.direction {
        case .sendonly: .recvonly
        case .recvonly: .sendonly
        case .inactive: .inactive
        case .sendrecv: .sendrecv
        }
        var crypto: [(tag: Int, suite: String, key: String)] = []
        if offer.isSecure {
            guard let srtpKey, let theirs = offer.crypto.first(where: { $0.suite == srtpSuite }) else { return nil }
            crypto = [(theirs.tag, srtpSuite, srtpKey)]
        }
        return SDPDescription(address: address, port: port, profile: offer.profile, payloads: payloads,
                              codecs: codecs, crypto: crypto, direction: direction)
    }

    static func isSupported(_ name: String) -> Bool {
        supported.contains { $0.1 == name }
    }

    public var isSecure: Bool { profile.uppercased().contains("SAVP") }

    /// Имя кодека: из rtpmap, а для статических номеров — по таблице RFC 3551.
    public func codec(for payload: Int) -> String? {
        codecs[payload] ?? [0: "PCMU", 8: "PCMA"][payload]
    }

    /// Кодек звука — первый, который мы умеем.
    public var audioPayload: Int? {
        payloads.first { codec(for: $0).map(Self.isSupported) == true }
    }

    public var dtmfPayload: Int? {
        payloads.first { codec(for: $0) == "TELEPHONE-EVENT" }
    }

    /// Ключ SRTP той стороны (inline без `inline:` и без срока).
    public var srtpKey: String? {
        crypto.first { $0.suite == Self.srtpSuite }.map(\.key)
    }

    public func serialized(sessionID: UInt64, version: UInt64) -> String {
        var lines = [
            "v=0",
            "o=- \(sessionID) \(version) IN IP4 \(address)",
            "s=Trudaybook",
            "c=IN IP4 \(address)",
            "t=0 0",
            "m=audio \(port) \(profile) " + payloads.map(String.init).joined(separator: " "),
        ]
        for payload in payloads {
            guard let name = codec(for: payload) else { continue }
            lines.append("a=rtpmap:\(payload) \(name == "TELEPHONE-EVENT" ? "telephone-event" : name)/8000")
            if name == "TELEPHONE-EVENT" { lines.append("a=fmtp:\(payload) 0-16") }
        }
        lines.append("a=ptime:20")
        for item in crypto {
            lines.append("a=crypto:\(item.tag) \(item.suite) inline:\(item.key)")
        }
        lines.append("a=\(direction.rawValue)")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Разбор: берётся первая звуковая строка `m=audio`.
    public static func parse(_ text: String) -> SDPDescription? {
        var sessionAddress: String?
        var mediaAddress: String?
        var port: Int?
        var profile = "RTP/AVP"
        var payloads: [Int] = []
        var codecs: [Int: String] = [:]
        var crypto: [(tag: Int, suite: String, key: String)] = []
        var sessionDirection = Direction.sendrecv
        var mediaDirection: Direction?
        var inAudio = false
        var seenAudio = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count > 2, line.dropFirst().first == "=", let type = line.first else { continue }
            let value = String(line.dropFirst(2))
            if type == "m" {
                inAudio = false
                let parts = value.split(separator: " ").map(String.init)
                guard !seenAudio, parts.count >= 4, parts[0] == "audio", let found = Int(parts[1]) else { continue }
                inAudio = true
                seenAudio = true
                port = found
                profile = parts[2]
                payloads = parts.dropFirst(3).compactMap { Int($0) }
                continue
            }
            // Строки чужих потоков (видео) не наши.
            guard inAudio || !seenAudio else { continue }
            switch type {
            case "c":
                let parts = value.split(separator: " ")
                guard parts.count >= 3 else { continue }
                let address = String(parts[2].split(separator: "/").first ?? "")
                if inAudio { mediaAddress = address } else { sessionAddress = address }
            case "a":
                if value.hasPrefix("rtpmap:") {
                    let parts = value.dropFirst(7).split(separator: " ", maxSplits: 1)
                    guard parts.count == 2, let number = Int(parts[0]) else { continue }
                    codecs[number] = String(parts[1].split(separator: "/").first ?? "").uppercased()
                } else if value.hasPrefix("crypto:") {
                    let parts = value.dropFirst(7).split(separator: " ")
                    guard parts.count >= 3, let tag = Int(parts[0]), parts[2].hasPrefix("inline:") else { continue }
                    let key = String(parts[2].dropFirst(7).split(separator: "|").first ?? "")
                    crypto.append((tag, String(parts[1]), key))
                } else if let found = Direction(rawValue: value) {
                    if inAudio { mediaDirection = found } else { sessionDirection = found }
                }
            default: continue
            }
        }
        guard let port, let address = mediaAddress ?? sessionAddress else { return nil }
        return SDPDescription(address: address, port: port, profile: profile, payloads: payloads,
                              codecs: codecs, crypto: crypto, direction: mediaDirection ?? sessionDirection)
    }
}

// MARK: - G.711

/// G.711: A-закон и μ-закон, 8 кГц, байт на отсчёт (ITU-T G.711).
public enum G711 {
    public static func encodeMuLaw(_ sample: Int16) -> UInt8 {
        let bias = 0x84
        let clip = 32635
        var value = Int(sample)
        let sign = value < 0 ? 0x80 : 0
        if value < 0 { value = -value }
        value = min(value, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, value & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    public static func decodeMuLaw(_ byte: UInt8) -> Int16 {
        let value = Int(~byte & 0xFF)
        let sign = value & 0x80
        let exponent = (value >> 4) & 0x07
        let mantissa = value & 0x0F
        let magnitude = (((mantissa << 3) + 0x84) << exponent) - 0x84
        return Int16(sign != 0 ? -magnitude : magnitude)
    }

    public static func encodeALaw(_ sample: Int16) -> UInt8 {
        var value = Int(sample)
        let mask: Int
        if value >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            value = -value - 1
        }
        value = min(value, 32767)
        let compressed: Int
        if value < 256 {
            compressed = value >> 4
        } else {
            var exponent = 1
            var shifted = value >> 8
            while shifted > 1, exponent < 7 {
                shifted >>= 1
                exponent += 1
            }
            compressed = (exponent << 4) | ((value >> (exponent + 3)) & 0x0F)
        }
        return UInt8((compressed ^ mask) & 0xFF)
    }

    public static func decodeALaw(_ byte: UInt8) -> Int16 {
        let value = Int(byte ^ 0x55)
        let exponent = (value & 0x70) >> 4
        var magnitude = (value & 0x0F) << 4
        switch exponent {
        case 0: magnitude += 8
        case 1: magnitude += 0x108
        default: magnitude = (magnitude + 0x108) << (exponent - 1)
        }
        return Int16((value & 0x80) != 0 ? magnitude : -magnitude)
    }

    public static func encode(_ samples: [Int16], payload: Int) -> Data {
        Data(samples.map { payload == 0 ? encodeMuLaw($0) : encodeALaw($0) })
    }

    public static func decode(_ data: Data, payload: Int) -> [Int16] {
        data.map { payload == 0 ? decodeMuLaw($0) : decodeALaw($0) }
    }
}

// MARK: - RTP

/// Пакет RTP (RFC 3550) — заголовок и полезная нагрузка.
public struct RTPPacket: Equatable, Sendable {
    public var payloadType: Int
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: Data

    public init(payloadType: Int, marker: Bool = false, sequence: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data) {
        self.payloadType = payloadType
        self.marker = marker
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    public static let headerSize = 12

    public var data: Data {
        var bytes = [UInt8](repeating: 0, count: Self.headerSize)
        bytes[0] = 0x80
        bytes[1] = UInt8(payloadType & 0x7F) | (marker ? 0x80 : 0)
        bytes[2] = UInt8(sequence >> 8)
        bytes[3] = UInt8(sequence & 0xFF)
        for index in 0..<4 {
            bytes[4 + index] = UInt8((timestamp >> (24 - 8 * UInt32(index))) & 0xFF)
            bytes[8 + index] = UInt8((ssrc >> (24 - 8 * UInt32(index))) & 0xFF)
        }
        return Data(bytes) + payload
    }

    /// Длина заголовка с CSRC и расширением — по первым байтам.
    static func headerLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= headerSize, bytes[0] >> 6 == 2 else { return nil }
        var length = headerSize + Int(bytes[0] & 0x0F) * 4
        if bytes[0] & 0x10 != 0 {
            guard bytes.count >= length + 4 else { return nil }
            length += 4 + (Int(bytes[length + 2]) << 8 | Int(bytes[length + 3])) * 4
        }
        return bytes.count >= length ? length : nil
    }

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard let length = Self.headerLength(bytes) else { return nil }
        var end = bytes.count
        // Набивка в конце: её длина — последним байтом.
        if bytes[0] & 0x20 != 0, let pad = bytes.last, Int(pad) <= end - length { end -= Int(pad) }
        payloadType = Int(bytes[1] & 0x7F)
        marker = bytes[1] & 0x80 != 0
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        ssrc = bytes[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
        payload = Data(bytes[length..<end])
    }

    /// RTCP на том же порту (rtcp-mux): типы 200–204 во втором байте,
    /// где у RTP были бы маркер и номер формата.
    public static func isRTCP(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return (192...223).contains(Int(data[data.startIndex + 1]))
    }
}

/// Событие тонового набора (RFC 4733): цифра, конец, длительность.
public enum DTMF {
    public static func event(for digit: Character) -> UInt8? {
        switch digit {
        case "0"..."9": UInt8(String(digit))
        case "*": 10
        case "#": 11
        case "A", "B", "C", "D": UInt8(12 + Int(digit.asciiValue! - Character("A").asciiValue!))
        default: nil
        }
    }

    public static func payload(event: UInt8, end: Bool, duration: UInt16, volume: UInt8 = 10) -> Data {
        Data([event, (end ? 0x80 : 0) | (volume & 0x3F), UInt8(duration >> 8), UInt8(duration & 0xFF)])
    }
}

// MARK: - SRTP

/// SRTP (RFC 3711) с набором AES_CM_128_HMAC_SHA1_80 и ключами из SDP
/// (SDES, RFC 4568). Ключи передаются в SIP — поэтому шифрованный звук
/// имеет смысл только вместе с TLS: по открытому UDP ключ прочтут вместе
/// со звонком.
public final class SRTPContext: @unchecked Sendable {
    private let cipher: AESBlock
    private let authKey: SymmetricKey
    private let salt: [UInt8]
    /// Отправитель: счётчик переполнений номера (ROC).
    private var sendROC: UInt32 = 0
    private var lastSentSequence: UInt16?
    /// Получатель: наибольший номер и его ROC.
    private var receiveROC: UInt32 = 0
    private var highestSequence: UInt16?

    public static let tagLength = 10

    /// `inline` — base64 из 16 байт ключа и 14 байт соли.
    public convenience init?(inline: String) {
        guard let data = Data(base64Encoded: inline), data.count == 30 else { return nil }
        self.init(masterKey: [UInt8](data.prefix(16)), masterSalt: [UInt8](data.suffix(14)))
    }

    public init?(masterKey: [UInt8], masterSalt: [UInt8]) {
        guard masterKey.count == 16, masterSalt.count == 14, let master = AESBlock(key: masterKey) else { return nil }
        let keys = Self.deriveKeys(master: master, salt: masterSalt)
        guard let cipher = AESBlock(key: keys.cipher) else { return nil }
        self.cipher = cipher
        authKey = SymmetricKey(data: keys.auth)
        salt = keys.salt
    }

    /// Новый случайный ключ для SDP.
    public static func newInlineKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 30)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Ключи сеанса из главного ключа (RFC 3711 §4.3), шаг выработки — 0.
    static func deriveKeys(master: AESBlock, salt: [UInt8]) -> (cipher: [UInt8], auth: [UInt8], salt: [UInt8]) {
        func derive(_ label: UInt8, _ length: Int) -> [UInt8] {
            var x = salt
            x[7] ^= label
            return keystream(master, iv: x + [0, 0], length: length)
        }
        return (derive(0, 16), derive(1, 20), derive(2, 14))
    }

    /// Поток AES-CM: шифруется счётчик, младшие 16 бит — номер блока.
    static func keystream(_ cipher: AESBlock, iv: [UInt8], length: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length + 16)
        var block = iv
        var counter: UInt16 = 0
        while result.count < length {
            block[14] = iv[14] ^ UInt8(counter >> 8)
            block[15] = iv[15] ^ UInt8(counter & 0xFF)
            result += cipher.encrypt(block)
            counter &+= 1
        }
        return Array(result.prefix(length))
    }

    private func packetIV(ssrc: UInt32, index: UInt64) -> [UInt8] {
        var iv = salt + [0, 0]
        for byte in 0..<4 { iv[4 + byte] ^= UInt8((ssrc >> (24 - 8 * UInt32(byte))) & 0xFF) }
        for byte in 0..<6 { iv[8 + byte] ^= UInt8((index >> (40 - 8 * UInt64(byte))) & 0xFF) }
        return iv
    }

    private func tag(_ bytes: [UInt8], roc: UInt32) -> [UInt8] {
        let rocBytes = (0..<4).map { UInt8((roc >> (24 - 8 * UInt32($0))) & 0xFF) }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: bytes + rocBytes, using: authKey)
        return Array(Array(mac).prefix(Self.tagLength))
    }

    /// Зашифровать готовый пакет RTP.
    public func protect(_ packet: Data) -> Data? {
        var bytes = [UInt8](packet)
        guard let header = RTPPacket.headerLength(bytes) else { return nil }
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if let last = lastSentSequence, sequence < last, last - sequence > 0x8000 { sendROC &+= 1 }
        lastSentSequence = sequence
        let ssrc = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let index = UInt64(sendROC) << 16 | UInt64(sequence)
        let stream = Self.keystream(cipher, iv: packetIV(ssrc: ssrc, index: index), length: bytes.count - header)
        for offset in header..<bytes.count { bytes[offset] ^= stream[offset - header] }
        return Data(bytes + tag(bytes, roc: sendROC))
    }

    /// Проверить и расшифровать пакет. `nil` — подделка или мусор.
    public func unprotect(_ packet: Data) -> Data? {
        let all = [UInt8](packet)
        guard all.count > RTPPacket.headerSize + Self.tagLength else { return nil }
        var bytes = Array(all.dropLast(Self.tagLength))
        let received = Array(all.suffix(Self.tagLength))
        guard let header = RTPPacket.headerLength(bytes) else { return nil }
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        // Оценка ROC по RFC 3711, приложение A.
        var roc = receiveROC
        if let highest = highestSequence {
            if highest < 0x8000 {
                if Int(sequence) - Int(highest) > 0x8000, receiveROC > 0 { roc = receiveROC - 1 }
            } else if Int(highest) - 0x8000 > Int(sequence) {
                roc = receiveROC &+ 1
            }
        }
        // Сравнение тегов за постоянное время — по всем байтам.
        let expected = tag(bytes, roc: roc)
        guard zip(expected, received).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        if let highest = highestSequence {
            if roc > receiveROC || (roc == receiveROC && sequence > highest) {
                receiveROC = roc
                highestSequence = sequence
            }
        } else {
            highestSequence = sequence
        }
        let ssrc = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let index = UInt64(roc) << 16 | UInt64(sequence)
        let stream = Self.keystream(cipher, iv: packetIV(ssrc: ssrc, index: index), length: bytes.count - header)
        for offset in header..<bytes.count { bytes[offset] ^= stream[offset - header] }
        return Data(bytes)
    }
}

/// Один блок AES-128 — основа счётчика AES-CM.
final class AESBlock: @unchecked Sendable {
    private var cryptor: CCCryptorRef?

    init?(key: [UInt8]) {
        let status = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                     CCOptions(kCCOptionECBMode), key, key.count, nil, &cryptor)
        guard status == kCCSuccess else { return nil }
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func encrypt(_ block: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        CCCryptorUpdate(cryptor, block, 16, &output, 16, &moved)
        return output
    }
}
