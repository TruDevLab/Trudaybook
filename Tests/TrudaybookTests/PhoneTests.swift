import Foundation
import Testing
@testable import TrudaybookCore

@Suite("SIP: сообщения и проверка")
struct SIPMessageTests {
    @Test("Запрос разбирается и собирается обратно; короткие имена заголовков")
    func разбор() throws {
        let text = "INVITE sip:101@pbx.test SIP/2.0\r\n"
            + "v: SIP/2.0/UDP 10.0.0.2:5060;branch=z9hG4bKabc;rport\r\n"
            + "Via: SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bKdef\r\n"
            + "f: \"Иван\" <sip:200@pbx.test>;tag=111\r\n"
            + "t: <sip:101@pbx.test>\r\n"
            + "i: call-1\r\nCSeq: 7 INVITE\r\nl: 5\r\n\r\nhello"
        let message = try #require(SIPMessage.parse(text))
        #expect(message.method == "INVITE")
        #expect(message.requestURI == "sip:101@pbx.test")
        #expect(message.headers("Via").count == 2)
        #expect(message.branch == "z9hG4bKabc")
        #expect(message.fromTag == "111")
        #expect(message.toTag == nil)
        #expect(message.callID == "call-1")
        #expect(message.cseq?.number == 7 && message.cseq?.method == "INVITE")
        #expect(message.body == "hello")
        #expect(SIPHeader.displayName(in: message.header("From")!) == "Иван")
        #expect(SIPHeader.user(in: SIPHeader.uri(in: message.header("From")!)) == "200")
        let again = try #require(SIPMessage.parse(message.serialized()))
        #expect(again.serialized() == message.serialized())
    }

    @Test("Поток TCP режется по Content-Length, пинги пропускаются")
    func поток() {
        var parser = SIPStreamParser()
        let one = SIPMessage(.response(code: 200, reason: "OK"), headers: [("Call-ID", "a")], body: "x=1").serialized()
        let two = SIPMessage(.request(method: "BYE", uri: "sip:a@b"), headers: [("Call-ID", "b")]).serialized()
        let all = Data(("\r\n\r\n" + one + two).utf8)
        var found = parser.append(all.prefix(20))
        found += parser.append(all.dropFirst(20))
        #expect(found.map(\.callID) == ["a", "b"])
        #expect(found.first?.body == "x=1")
    }

    @Test("Адрес, порт, параметры заголовка")
    func адрес() {
        let found = SIPHeader.hostPort(in: "sip:100@10.0.0.1:5080;transport=tcp")
        #expect(found.host == "10.0.0.1" && found.port == 5080)
        #expect(SIPHeader.hostPort(in: "sip:pbx.test").host == "pbx.test")
        #expect(SIPHeader.parameter("tag", in: "<sip:a@b;tag=wrong>;tag=right") == "right")
        #expect(SIPHeader.parameter("rport", in: "SIP/2.0/UDP 1.2.3.4:5060;rport=4000;received=5.6.7.8") == "4000")
        #expect(SIPUserAgent.withoutTag("\"А\" <sip:a@b>;tag=1;x=y") == "\"А\" <sip:a@b>;x=y")
        var account = SIPAccount()
        account.server = "10.0.0.5:5080"
        #expect(account.domain == "10.0.0.5" && account.outbound.port == 5080)
        account.server = "pbx.test"
        account.transport = .tls
        #expect(account.outbound.port == 5061)
    }

    @Test("Digest — пример RFC 2617")
    func дайджест() throws {
        let header = SIPDigest.authorization(
            challenge: "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\"",
            method: "GET", uri: "/dir/index.html", username: "Mufasa", password: "Circle Of Life",
            nc: 1, cnonce: "0a4f113b")
        let value = try #require(header)
        #expect(value.contains("response=\"6629fae49393a05397450978507c4ef1\""))
        #expect(value.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""))
        #expect(value.contains("nc=00000001"))
        // Без qop — старая формула; неизвестный алгоритм не подписываем.
        #expect(SIPDigest.authorization(challenge: "Digest realm=\"r\", nonce=\"n\"", method: "REGISTER",
                                        uri: "sip:x", username: "u", password: "p") != nil)
        #expect(SIPDigest.authorization(challenge: "Digest realm=\"r\", nonce=\"n\", algorithm=SHA-512", method: "REGISTER",
                                        uri: "sip:x", username: "u", password: "p") == nil)
    }
}

@Suite("SIP: звук")
struct PhoneMediaTests {
    @Test("SDP: предложение, разбор и ответ на чужое")
    func sdp() throws {
        let offer = SDPDescription.offer(address: "10.0.0.2", port: 40_000, srtpKey: nil)
        let text = offer.serialized(sessionID: 1, version: 1)
        #expect(text.contains("m=audio 40000 RTP/AVP 8 0 101"))
        let parsed = try #require(SDPDescription.parse(text))
        #expect(parsed.address == "10.0.0.2" && parsed.port == 40_000)
        #expect(parsed.audioPayload == 8 && parsed.dtmfPayload == 101)

        let theirs = "v=0\r\no=- 1 1 IN IP4 1.1.1.1\r\ns=-\r\nc=IN IP4 1.1.1.1\r\nt=0 0\r\n"
            + "m=audio 5000 RTP/AVP 18 0 96\r\na=rtpmap:18 G729/8000\r\na=rtpmap:96 telephone-event/8000\r\na=sendonly\r\n"
            + "m=video 6000 RTP/AVP 99\r\nc=IN IP4 9.9.9.9\r\n"
        let remote = try #require(SDPDescription.parse(theirs))
        #expect(remote.address == "1.1.1.1" && remote.port == 5000)
        #expect(remote.direction == .sendonly)
        let answer = try #require(SDPDescription.answer(to: remote, address: "10.0.0.2", port: 40_002, srtpKey: nil))
        // G.729 не умеем — берём PCMU; тоновый набор — под их номером.
        #expect(answer.payloads == [0, 96])
        #expect(answer.direction == .recvonly)
        // Шифрованное предложение без ключа у нас — не договориться.
        let secure = SDPDescription.offer(address: "1.1.1.1", port: 5000, srtpKey: SRTPContext.newInlineKey())
        #expect(SDPDescription.answer(to: secure, address: "a", port: 1, srtpKey: nil) == nil)
        #expect(SDPDescription.parse(secure.serialized(sessionID: 1, version: 1))?.srtpKey == secure.srtpKey)
    }

    @Test("G.711: тишина и туда-обратно с малой ошибкой")
    func g711() {
        #expect(G711.encodeMuLaw(0) == 0xFF)
        #expect(G711.encodeALaw(0) == 0xD5)
        for sample in stride(from: -32000, through: 32000, by: 731) {
            let value = Int16(sample)
            let mu = Int(G711.decodeMuLaw(G711.encodeMuLaw(value)))
            let a = Int(G711.decodeALaw(G711.encodeALaw(value)))
            let limit = max(64, abs(sample) / 16)
            #expect(abs(mu - sample) <= limit)
            #expect(abs(a - sample) <= limit)
        }
    }

    @Test("RTP: заголовок туда и обратно, RTCP отличается")
    func rtp() throws {
        let packet = RTPPacket(payloadType: 8, marker: true, sequence: 65_535, timestamp: 0xDEADBEEF, ssrc: 0x01020304,
                               payload: Data([1, 2, 3]))
        let parsed = try #require(RTPPacket(packet.data))
        #expect(parsed == packet)
        #expect(!RTPPacket.isRTCP(packet.data))
        #expect(RTPPacket.isRTCP(Data([0x80, 200, 0, 1])))
        #expect(DTMF.event(for: "#") == 11 && DTMF.event(for: "5") == 5 && DTMF.event(for: "x") == nil)
    }

    @Test("SRTP: векторы RFC 3711 — выработка ключей и поток AES-CM")
    func srtpВекторы() throws {
        let master = try #require(AESBlock(key: hex("E1F97A0D3E018BE0D64FA32C06DE4139")))
        let keys = SRTPContext.deriveKeys(master: master, salt: hex("0EC675AD498AFEEBB6960B3AABE6"))
        #expect(keys.cipher == hex("C61E7A93744F39EE10734AFE3FF7A087"))
        #expect(keys.salt == hex("30CBBC08863D8C85D49DB34A9AE1"))
        #expect(keys.auth == hex("CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))

        let session = try #require(AESBlock(key: hex("2B7E151628AED2A6ABF7158809CF4F3C")))
        let stream = SRTPContext.keystream(session, iv: hex("F0F1F2F3F4F5F6F7F8F9FAFBFCFD0000"), length: 48)
        #expect(Array(stream.prefix(16)) == hex("E03EAD0935C95E80E166B16DD92B4EB4"))
        #expect(Array(stream[16..<32]) == hex("D23513162B02D0F72A43A2FE4A5F97AB"))
    }

    @Test("SRTP: шифруется, расшифровывается, подделка отвергается")
    func srtpТудаОбратно() throws {
        let key = SRTPContext.newInlineKey()
        let sender = try #require(SRTPContext(inline: key))
        let receiver = try #require(SRTPContext(inline: key))
        for sequence in [UInt16(65_534), 65_535, 0, 1] {
            let packet = RTPPacket(payloadType: 0, sequence: sequence, timestamp: UInt32(sequence) * 160, ssrc: 42,
                                   payload: Data(repeating: 0x55, count: 160)).data
            let secret = try #require(sender.protect(packet))
            #expect(secret.count == packet.count + SRTPContext.tagLength)
            #expect(secret.subdata(in: 12..<20) != packet.subdata(in: 12..<20))
            #expect(receiver.unprotect(secret) == packet)
            var forged = secret
            forged[20] ^= 1
            #expect(receiver.unprotect(forged) == nil)
        }
    }

    private func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map {
            let start = text.index(text.startIndex, offsetBy: $0)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}

@Suite("Телефон: номера и журнал")
struct PhoneBookTests {
    @Test("Один номер, записанный по-разному")
    func номера() {
        #expect(PhoneNumber.same("+7 (900) 123-45-67", "89001234567"))
        #expect(PhoneNumber.same("101", "101"))
        #expect(!PhoneNumber.same("101", "1101"))
        #expect(PhoneNumber.dialable(" +7 (900) 123-45-67 ") == "+79001234567")
        #expect(PhoneNumber.dialable("*72#") == "*72#")
        #expect(PhoneNumber.dialable("ivan@pbx.test") == "ivan@pbx.test")
    }

    @Test("Имена, избранное, журнал с потолком, файл туда и обратно")
    func книга() throws {
        var book = PhoneBook()
        book.save(number: "+7 900 123 45 67", name: "  Иван  ")
        book.save(number: "89001234567", name: "Иван Петров")
        #expect(book.contacts.count == 1)
        #expect(book.displayName(for: "79001234567") == "Иван Петров")
        #expect(book.displayName(for: "102", fallback: "Склад") == "Склад")
        book.toggleFavorite(number: "102")
        #expect(book.sortedContacts.first?.number == "102")
        #expect(book.sortedContacts.first?.favorite == true)
        for index in 0..<(PhoneBook.maxCalls + 5) {
            book.record(CallRecord(number: "\(index)", direction: .incoming, outcome: .missed,
                                   start: Date(timeIntervalSince1970: 1_790_000_000)))
        }
        #expect(book.calls.count == PhoneBook.maxCalls)
        #expect(book.calls.first?.number == "\(PhoneBook.maxCalls + 4)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try book.save(to: url)
        #expect(PhoneBook.load(from: url) == book)
    }
}

/// Поддельная сеть: что агент отправил и что ему «пришло».
final class FakeSIPTransport: SIPTransport, @unchecked Sendable {
    let kind: SIPTransportKind
    let local: SIPEndpoint? = SIPEndpoint(host: "192.168.1.10", port: 5070)
    private let lock = NSLock()
    private var _sent: [SIPMessage] = []
    private var queue: DispatchQueue?
    private var receive: ((SIPMessage, SIPEndpoint?) -> Void)?

    init(kind: SIPTransportKind = .udp) {
        self.kind = kind
    }

    var sent: [SIPMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    func start(queue: DispatchQueue, ready: @escaping () -> Void,
               receive: @escaping (SIPMessage, SIPEndpoint?) -> Void, failure: @escaping (String) -> Void) {
        self.queue = queue
        self.receive = receive
        ready()
    }

    func send(_ data: Data, to: SIPEndpoint?) {
        guard let message = SIPMessage.parse(data) else { return }
        lock.lock()
        _sent.append(message)
        lock.unlock()
    }

    func stop() {}

    func inject(_ message: SIPMessage) {
        queue?.async { self.receive?(message, SIPEndpoint(host: "10.0.0.1", port: 5060)) }
    }

    /// Ответ сервера на запрос агента.
    func respond(to request: SIPMessage, _ code: Int, toTag: String? = "srv", extra: [(String, String)] = [], body: String = "") {
        var headers: [(String, String)] = request.headers.filter { SIPMessage.canonical($0.name) == "via" }.map { ($0.name, $0.value) }
        headers.append(("From", request.header("From")!))
        headers.append(("To", request.header("To")! + (toTag.map { ";tag=\($0)" } ?? "")))
        headers.append(("Call-ID", request.callID))
        headers.append(("CSeq", request.header("CSeq")!))
        headers += extra
        inject(SIPMessage(.response(code: code, reason: "X"), headers: headers, body: body))
    }
}

/// События агента: приходят с его очереди, читаются из теста.
final class AgentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _registrations: [SIPRegistration] = []
    private var _calls: [SIPCall] = []
    private var _media: [SIPMediaPlan] = []

    var registrations: [SIPRegistration] { lock.lock(); defer { lock.unlock() }; return _registrations }
    var calls: [SIPCall] { lock.lock(); defer { lock.unlock() }; return _calls }
    var media: [SIPMediaPlan] { lock.lock(); defer { lock.unlock() }; return _media }

    func attach(_ agent: SIPUserAgent) {
        agent.onRegistration = { [self] value in lock.lock(); _registrations.append(value); lock.unlock() }
        agent.onCall = { [self] value in lock.lock(); _calls.append(value); lock.unlock() }
        agent.onMediaStart = { [self] value in lock.lock(); _media.append(value); lock.unlock() }
        agent.mediaPort = { _ in 40_000 }
    }
}

@Suite("SIP: регистрация и звонки с поддельной АТС")
struct SIPAgentTests {
    private func account() -> SIPAccount {
        var account = SIPAccount()
        account.server = "pbx.test"
        account.username = "101"
        account.displayName = "Тест"
        return account
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sdp(port: Int = 5004) -> String {
        "v=0\r\no=- 1 1 IN IP4 10.0.0.1\r\ns=-\r\nc=IN IP4 10.0.0.1\r\nt=0 0\r\nm=audio \(port) RTP/AVP 0 101\r\na=rtpmap:101 telephone-event/8000\r\n"
    }

    @Test("Регистрация с проверкой пароля, за NAT — с внешним адресом")
    func регистрация() async throws {
        let fake = FakeSIPTransport()
        let agent = SIPUserAgent(account: account(), password: "secret") { _ in fake }
        let log = AgentLog()
        log.attach(agent)
        agent.start()
        await wait { fake.sent.count == 1 }
        let first = try #require(fake.sent.first)
        #expect(first.method == "REGISTER")
        #expect(first.header("Contact") == "<sip:101@192.168.1.10:5070>")
        fake.respond(to: first, 401, extra: [("WWW-Authenticate", "Digest realm=\"pbx\", nonce=\"abc\", qop=\"auth\"")])
        await wait { fake.sent.count == 2 }
        let second = try #require(fake.sent.last)
        #expect(second.header("Authorization")?.contains("username=\"101\"") == true)
        #expect(second.cseq!.number == first.cseq!.number + 1)
        #expect(!second.serialized().contains("secret"))
        // Сервер видит нас с другого адреса — перерегистрация с ним.
        var natVia = second
        let via = second.header("Via")!.replacingOccurrences(of: ";rport", with: ";rport=40001") + ";received=203.0.113.5"
        natVia.set("Via", via)
        fake.respond(to: natVia, 200)
        await wait { fake.sent.count == 3 }
        let third = try #require(fake.sent.last)
        #expect(third.header("Contact") == "<sip:101@203.0.113.5:40001>")
        fake.respond(to: third, 200, extra: [("Contact", "<sip:101@203.0.113.5:40001>;expires=120")])
        await wait { log.registrations.last == .registered }
        #expect(log.registrations.last == .registered)
    }

    @Test("Входящий: звонит, ответ с SDP, ACK, они кладут трубку")
    func входящий() async throws {
        let fake = FakeSIPTransport()
        let agent = SIPUserAgent(account: account(), password: "p") { _ in fake }
        let log = AgentLog()
        log.attach(agent)
        agent.start()
        await wait { !fake.sent.isEmpty }
        let invite = SIPMessage(.request(method: "INVITE", uri: "sip:101@192.168.1.10:5070"), headers: [
            ("Via", "SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bKin1"), ("From", "\"Иван\" <sip:79001234567@pbx.test>;tag=caller"),
            ("To", "<sip:101@pbx.test>"), ("Call-ID", "in-1"), ("CSeq", "1 INVITE"),
            ("Contact", "<sip:79001234567@10.0.0.1:5060>"), ("Content-Type", "application/sdp"),
        ], body: sdp())
        fake.inject(invite)
        await wait { log.calls.last?.state == .incoming }
        let call = try #require(log.calls.last)
        #expect(call.remoteUser == "79001234567" && call.remoteName == "Иван")
        let codes = fake.sent.compactMap(\.code)
        #expect(codes.contains(100) && codes.contains(180))
        let ringing = try #require(fake.sent.first { $0.code == 180 })
        let tag = try #require(ringing.toTag)

        agent.answer()
        await wait { fake.sent.contains { $0.code == 200 && $0.callID == "in-1" } }
        let ok = try #require(fake.sent.first { $0.code == 200 && $0.callID == "in-1" })
        #expect(ok.toTag == tag)
        #expect(SDPDescription.parse(ok.body)?.payloads == [0, 101])
        await wait { !log.media.isEmpty }
        #expect(log.media.first?.remote.port == 5004)

        fake.inject(SIPMessage(.request(method: "ACK", uri: "sip:101@192.168.1.10:5070"), headers: [
            ("Via", "SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bKack"), ("From", invite.header("From")!),
            ("To", "<sip:101@pbx.test>;tag=\(tag)"), ("Call-ID", "in-1"), ("CSeq", "1 ACK"),
        ]))
        fake.inject(SIPMessage(.request(method: "BYE", uri: "sip:101@192.168.1.10:5070"), headers: [
            ("Via", "SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bKbye"), ("From", invite.header("From")!),
            ("To", "<sip:101@pbx.test>;tag=\(tag)"), ("Call-ID", "in-1"), ("CSeq", "2 BYE"),
        ]))
        await wait { log.calls.last?.state == .ended(.remote) }
        #expect(log.calls.last?.state == .ended(.remote))
        #expect(fake.sent.contains { $0.code == 200 && $0.cseq?.method == "BYE" })
    }

    @Test("Входящий: звонящий сдался — пропущенный, а второй в это время — «занято»")
    func пропущенный() async throws {
        let fake = FakeSIPTransport()
        let agent = SIPUserAgent(account: account(), password: "p") { _ in fake }
        let log = AgentLog()
        log.attach(agent)
        agent.start()
        await wait { !fake.sent.isEmpty }
        func invite(_ id: String, branch: String) -> SIPMessage {
            SIPMessage(.request(method: "INVITE", uri: "sip:101@192.168.1.10:5070"), headers: [
                ("Via", "SIP/2.0/UDP 10.0.0.1:5060;branch=\(branch)"), ("From", "<sip:200@pbx.test>;tag=c"),
                ("To", "<sip:101@pbx.test>"), ("Call-ID", id), ("CSeq", "1 INVITE"),
            ], body: sdp())
        }
        fake.inject(invite("a", branch: "z9hG4bKa"))
        await wait { log.calls.last?.state == .incoming }
        fake.inject(invite("b", branch: "z9hG4bKb"))
        await wait { fake.sent.contains { $0.code == 486 } }
        #expect(fake.sent.first { $0.code == 486 }?.callID == "b")
        fake.inject(SIPMessage(.request(method: "CANCEL", uri: "sip:101@192.168.1.10:5070"), headers: [
            ("Via", "SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bKa"), ("From", "<sip:200@pbx.test>;tag=c"),
            ("To", "<sip:101@pbx.test>"), ("Call-ID", "a"), ("CSeq", "1 CANCEL"),
        ]))
        await wait { log.calls.last?.state == .ended(.missed) }
        #expect(log.calls.last?.state == .ended(.missed))
        #expect(fake.sent.contains { $0.code == 487 && $0.callID == "a" })
    }

    @Test("Исходящий: звонит, ответили, ACK, кладём трубку — BYE")
    func исходящий() async throws {
        let fake = FakeSIPTransport()
        let agent = SIPUserAgent(account: account(), password: "p") { _ in fake }
        let log = AgentLog()
        log.attach(agent)
        agent.start()
        await wait { !fake.sent.isEmpty }
        agent.dial("102")
        await wait { fake.sent.contains { $0.method == "INVITE" } }
        let invite = try #require(fake.sent.first { $0.method == "INVITE" })
        #expect(invite.requestURI == "sip:102@pbx.test")
        #expect(invite.header("From")?.hasPrefix("\"Тест\" <sip:101@pbx.test>") == true)
        fake.respond(to: invite, 180)
        await wait { log.calls.last?.state == .ringing(early: false) }
        fake.respond(to: invite, 200, extra: [("Contact", "<sip:102@10.0.0.9:5060>"), ("Content-Type", "application/sdp")],
                     body: sdp(port: 6000))
        await wait { log.calls.last?.state == .active }
        let ack = try #require(fake.sent.first { $0.method == "ACK" })
        #expect(ack.requestURI == "sip:102@10.0.0.9:5060")
        #expect(ack.toTag == "srv")
        #expect(log.media.last?.remote.port == 6000)
        agent.hangup()
        await wait { fake.sent.contains { $0.method == "BYE" } }
        let bye = try #require(fake.sent.first { $0.method == "BYE" })
        #expect(bye.cseq!.number > invite.cseq!.number)
        #expect(log.calls.last?.state == .ended(.local))
    }

    @Test("Исходящий: занято — ACK на отказ в той же ветке")
    func занято() async throws {
        let fake = FakeSIPTransport()
        let agent = SIPUserAgent(account: account(), password: "p") { _ in fake }
        let log = AgentLog()
        log.attach(agent)
        agent.start()
        await wait { !fake.sent.isEmpty }
        agent.dial("103")
        await wait { fake.sent.contains { $0.method == "INVITE" } }
        let invite = try #require(fake.sent.first { $0.method == "INVITE" })
        fake.respond(to: invite, 486)
        await wait { log.calls.last?.state == .ended(.busy) }
        #expect(log.calls.last?.state == .ended(.busy))
        let ack = try #require(fake.sent.first { $0.method == "ACK" })
        #expect(ack.branch == invite.branch)
    }
}

@Suite("SIP: настоящий UDP на петле")
struct SIPLoopbackTests {
    @Test("Датаграмма уходит и приходит через сокеты BSD")
    func петля() throws {
        let a = try #require(UDPSocket.open(port: 0))
        let b = try #require(UDPSocket.open(port: 0))
        defer {
            close(a)
            close(b)
        }
        let port = try #require(UDPSocket.port(of: b))
        let target = try #require(UDPSocket.resolve("127.0.0.1", port: port))
        UDPSocket.send(a, Data("ping".utf8), to: target)
        var received: (Data, SIPEndpoint)?
        for _ in 0..<100 where received == nil {
            received = UDPSocket.receive(b)
            if received == nil { usleep(10_000) }
        }
        #expect(received?.0 == Data("ping".utf8))
        #expect(received?.1.host == "127.0.0.1")
    }
}
