import Foundation

/// Сообщение SIP (RFC 3261): запрос или ответ, заголовки, тело.
///
/// Заголовки — списком, а не словарём: Via и Record-Route повторяются,
/// и порядок их важен — ответ возвращается по Via сверху вниз.
public struct SIPMessage: Equatable, Sendable {
    public enum Start: Equatable, Sendable {
        case request(method: String, uri: String)
        case response(code: Int, reason: String)
    }

    public var start: Start
    public var headers: [(name: String, value: String)]
    public var body: String

    public init(_ start: Start, headers: [(String, String)] = [], body: String = "") {
        self.start = start
        self.headers = headers.map { (name: $0.0, value: $0.1) }
        self.body = body
    }

    public static func == (lhs: SIPMessage, rhs: SIPMessage) -> Bool {
        lhs.start == rhs.start && lhs.body == rhs.body
            && lhs.headers.map(\.name) == rhs.headers.map(\.name)
            && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    public var method: String? {
        if case let .request(method, _) = start { return method }
        return nil
    }

    public var code: Int? {
        if case let .response(code, _) = start { return code }
        return nil
    }

    public var requestURI: String? {
        if case let .request(_, uri) = start { return uri }
        return nil
    }

    // MARK: - Заголовки

    /// Короткие имена (RFC 3261 §7.3.3) — сервер вправе прислать любые.
    static let compact: [String: String] = [
        "v": "via", "f": "from", "t": "to", "i": "call-id", "m": "contact",
        "l": "content-length", "c": "content-type", "k": "supported", "s": "subject",
        "e": "content-encoding", "o": "event", "r": "refer-to", "u": "allow-events",
    ]

    static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        return compact[lower] ?? lower
    }

    /// Первый заголовок с этим именем.
    public func header(_ name: String) -> String? {
        let key = Self.canonical(name)
        return headers.first { Self.canonical($0.name) == key }?.value
    }

    /// Все значения заголовка; значения через запятую в одной строке
    /// (`Via: a, b`) разбираются на отдельные.
    public func headers(_ name: String) -> [String] {
        let key = Self.canonical(name)
        return headers.filter { Self.canonical($0.name) == key }
            .flatMap { SIPHeader.splitList($0.value) }
    }

    /// Заменить заголовок (все с этим именем) одним значением.
    public mutating func set(_ name: String, _ value: String) {
        let key = Self.canonical(name)
        if let index = headers.firstIndex(where: { Self.canonical($0.name) == key }) {
            headers[index].value = value
            var seen = false
            headers.removeAll { header in
                guard Self.canonical(header.name) == key else { return false }
                defer { seen = true }
                return seen
            }
        } else {
            headers.append((name, value))
        }
    }

    public mutating func remove(_ name: String) {
        let key = Self.canonical(name)
        headers.removeAll { Self.canonical($0.name) == key }
    }

    public var callID: String { header("Call-ID") ?? "" }

    /// Номер и метод из CSeq.
    public var cseq: (number: Int, method: String)? {
        guard let value = header("CSeq") else { return nil }
        let parts = value.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let number = Int(parts[0]) else { return nil }
        return (number, parts[1].uppercased())
    }

    public var fromTag: String? { header("From").flatMap { SIPHeader.parameter("tag", in: $0) } }
    public var toTag: String? { header("To").flatMap { SIPHeader.parameter("tag", in: $0) } }
    /// Ветка верхнего Via — по ней ответ находит свою транзакцию.
    public var branch: String? { headers("Via").first.flatMap { SIPHeader.parameter("branch", in: $0) } }

    // MARK: - Текст

    public func serialized() -> String {
        var lines: [String] = []
        switch start {
        case let .request(method, uri): lines.append("\(method) \(uri) SIP/2.0")
        case let .response(code, reason): lines.append("SIP/2.0 \(code) \(reason)")
        }
        for header in headers where Self.canonical(header.name) != "content-length" {
            lines.append("\(header.name): \(header.value)")
        }
        lines.append("Content-Length: \(body.utf8.count)")
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    public var data: Data { Data(serialized().utf8) }

    /// Разбор одного сообщения целиком (UDP: одна датаграмма — одно сообщение).
    public static func parse(_ data: Data) -> SIPMessage? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> SIPMessage? {
        let separator = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
        let head = separator.map { String(text[..<$0.lowerBound]) } ?? text
        var body = separator.map { String(text[$0.upperBound...]) } ?? ""
        var lines = head.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        // Пустые строки перед сообщением — пинги keep-alive, не ошибка.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let start: Start
        if parts[0] == "SIP/2.0" {
            guard let code = Int(parts[1]), (100...699).contains(code) else { return nil }
            start = .response(code: code, reason: parts.count > 2 ? parts[2] : "")
        } else {
            guard parts.count == 3, parts[2] == "SIP/2.0", parts[0].allSatisfy({ $0.isLetter }) else { return nil }
            start = .request(method: parts[0].uppercased(), uri: parts[1])
        }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            // Продолжение заголовка — строка с пробела (folding).
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name, value))
        }
        var message = SIPMessage(start, headers: headers)
        if let length = message.header("Content-Length").flatMap(Int.init), length < body.utf8.count {
            body = String(decoding: Array(body.utf8.prefix(length)), as: UTF8.self)
        }
        message.body = body
        return message
    }
}

/// Поток TCP или TLS: сообщения идут подряд, границу задаёт Content-Length.
public struct SIPStreamParser: Sendable {
    private var buffer = Data()
    /// Потолок буфера: сообщение SIP — килобайты; четверть мегабайта без
    /// конца заголовков — не SIP, а мусор, копить его незачем.
    static let maxBuffer = 256 * 1024

    public init() {}

    public mutating func append(_ data: Data) -> [SIPMessage] {
        buffer.append(data)
        var result: [SIPMessage] = []
        while true {
            // Пинги keep-alive (CRLF) между сообщениями — пропустить.
            while let first = buffer.first, first == 13 || first == 10 { buffer.removeFirst() }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxBuffer { buffer.removeAll() }
                break
            }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            var length = 0
            for line in head.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                if SIPMessage.canonical(line[..<colon].trimmingCharacters(in: .whitespaces)) == "content-length" {
                    length = max(0, Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0)
                }
            }
            let total = end.upperBound - buffer.startIndex + length
            guard total <= Self.maxBuffer else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= total else { break }
            let chunk = Data(buffer.prefix(total))
            buffer = Data(buffer.dropFirst(total))
            if let message = SIPMessage.parse(chunk) { result.append(message) }
        }
        return result
    }
}

/// Разбор значений заголовков: адреса, параметры, списки.
public enum SIPHeader {
    /// Список через запятую — без запятых внутри кавычек и `<…>`.
    public static func splitList(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var angle = 0
        for char in value {
            switch char {
            case "\"": quoted.toggle()
            case "<" where !quoted: angle += 1
            case ">" where !quoted: angle = max(0, angle - 1)
            case "," where !quoted && angle == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(char)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// Параметр заголовка: `;tag=abc` — снаружи `<…>`, где живут параметры
    /// самого заголовка, а не адреса.
    public static func parameter(_ name: String, in value: String) -> String? {
        let tail: Substring
        let bracketed: Bool
        if let close = value.lastIndex(of: ">") {
            tail = value[value.index(after: close)...]
            bracketed = true
        } else {
            tail = value[...]
            bracketed = false
        }
        // Без скобок первая часть — сам адрес или `SIP/2.0/UDP host`, не параметр.
        for part in tail.split(separator: ";").dropFirst(bracketed ? 0 : 1) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard let key = pair.first?.trimmingCharacters(in: .whitespaces), key.lowercased() == name.lowercased() else { continue }
            return pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : ""
        }
        return nil
    }

    /// Адрес из `"Имя" <sip:100@host>;tag=…` — `sip:100@host`.
    public static func uri(in value: String) -> String {
        if let open = value.firstIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            return String(value[value.index(after: open)..<close])
        }
        return String(value.split(separator: ";").first ?? Substring(value)).trimmingCharacters(in: .whitespaces)
    }

    /// Отображаемое имя из `"Иван" <sip:…>` или `Иван <sip:…>`.
    public static func displayName(in value: String) -> String? {
        guard let open = value.firstIndex(of: "<") else { return nil }
        var name = value[..<open].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return name.isEmpty ? nil : name
    }

    /// Пользователь из адреса: `sip:+7900…@host;user=phone` — `+7900…`.
    public static func user(in uri: String) -> String {
        var text = uri
        for scheme in ["sips:", "sip:", "tel:"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if let at = text.firstIndex(of: "@") { text = String(text[..<at]) }
        text = String(text.split(separator: ";").first ?? "")
        return text.removingPercentEncoding ?? text
    }

    /// Хост и порт из адреса: `sip:100@10.0.0.1:5080;transport=tcp`.
    public static func hostPort(in uri: String) -> (host: String, port: Int?) {
        var text = uri
        for scheme in ["sips:", "sip:"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        text = String(text.split(separator: ";").first ?? "")
        text = String(text.split(separator: "?").first ?? "")
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        let parts = text.split(separator: ":")
        return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) : nil)
    }

    /// Параметры вызова проверки (`Digest realm="…", nonce="…"`).
    public static func challenge(_ value: String) -> [String: String] {
        var text = value.trimmingCharacters(in: .whitespaces)
        if let space = text.firstIndex(of: " ") { text = String(text[text.index(after: space)...]) }
        var result: [String: String] = [:]
        for part in splitList(text) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }

    /// Случайная строка для tag, branch, Call-ID.
    public static func token(_ length: Int = 16) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Имя для заголовка: в кавычках, без управляющих символов.
    public static func quoted(_ name: String) -> String {
        let clean = name.filter { !$0.isNewline && $0 != "\"" && $0 != "\\" }
        return "\"\(clean)\""
    }
}
