import Foundation

/// Значение в ответе IMAP: атом, строка (в кавычках или литерал), список, NIL.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    /// Атом или строка как текст.
    public var text: String? {
        switch self {
        case .atom(let value): return value
        case .string(let data): return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        case .list, .nil_: return nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let data): return data
        case .atom(let value): return Data(value.utf8)
        case .list, .nil_: return nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    public var number: UInt64? { text.flatMap { UInt64($0) } }
}

/// Одна строка ответа сервера (с литералами внутри).
public enum IMAPResponse: Equatable, Sendable {
    /// `a1 OK [READ-WRITE] SELECT completed`
    case tagged(tag: String, status: String, code: String?, text: String)
    /// `* OK [UIDVALIDITY 3857529045] UIDs valid`, `* BYE ...`
    case status(status: String, code: String?, text: String)
    /// Прочие данные: `* 5 FETCH (...)`, `* LIST (...) "/" INBOX`, `* SEARCH 1 2`.
    case data([IMAPValue])
    /// `+ idling`
    case continuation(String)
}

public enum IMAPParseError: Error, Equatable {
    case unexpectedEnd
    case malformed(String)
}

/// Разбор ответов IMAP.
///
/// Намеренно узкий: письма берутся сырыми и разбираются MIME-разборщиком,
/// поэтому от IMAP нужны только атомы, строки, литералы и списки — без
/// `ENVELOPE` и `BODYSTRUCTURE` с их десятками частных случаев.
public enum IMAPParser {
    static let statusWords: Set<String> = ["OK", "NO", "BAD", "BYE", "PREAUTH"]

    /// Сколько байт литерала ждёт строка: `... {123}` в конце.
    /// Читатель сети по этому числу дочитывает литерал и следующую строку.
    public static func pendingLiteral(in line: Data) -> Int? {
        var bytes = [UInt8](line)
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard bytes.last == 0x7D, let open = bytes.lastIndex(of: 0x7B) else { return nil }
        var digits = bytes[(open + 1)..<(bytes.count - 1)]
        if digits.last == 0x2B { digits = digits.dropLast() } // {n+}
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    public static func parse(_ data: Data) throws -> IMAPResponse {
        var scanner = Scanner(bytes: [UInt8](data))
        if scanner.peek == 0x2B { // «+»
            scanner.index += 1
            scanner.skipSpaces()
            return .continuation(scanner.restOfLine())
        }
        let first = try scanner.readAtom()
        scanner.skipSpaces()
        if first == "*" {
            let save = scanner.index
            if let word = try? scanner.readAtom(), statusWords.contains(word.uppercased()) {
                scanner.skipSpaces()
                let (code, text) = scanner.codeAndText()
                return .status(status: word.uppercased(), code: code, text: text)
            }
            scanner.index = save
            return .data(try scanner.readValues())
        }
        let status = try scanner.readAtom().uppercased()
        scanner.skipSpaces()
        let (code, text) = scanner.codeAndText()
        return .tagged(tag: first, status: status, code: code, text: text)
    }

    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
        var atEnd: Bool {
            guard let peek else { return true }
            return peek == 0x0D || peek == 0x0A
        }

        mutating func skipSpaces() {
            while peek == 0x20 { index += 1 }
        }

        mutating func restOfLine() -> String {
            var end = bytes.count
            while end > index, bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D { end -= 1 }
            let text = String(decoding: bytes[index..<max(index, end)], as: UTF8.self)
            index = bytes.count
            return text
        }

        /// `[CODE ...] text` → код без скобок и текст.
        mutating func codeAndText() -> (String?, String) {
            var code: String?
            if peek == 0x5B, let close = bytes[index...].firstIndex(of: 0x5D) {
                code = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
                index = close + 1
                skipSpaces()
            }
            return (code, restOfLine())
        }

        mutating func readValues(until terminator: UInt8? = nil) throws -> [IMAPValue] {
            var values: [IMAPValue] = []
            while true {
                skipSpaces()
                if let terminator, peek == terminator {
                    index += 1
                    return values
                }
                if atEnd {
                    if terminator != nil { throw IMAPParseError.unexpectedEnd }
                    return values
                }
                values.append(try readValue())
            }
        }

        mutating func readValue() throws -> IMAPValue {
            guard let byte = peek else { throw IMAPParseError.unexpectedEnd }
            switch byte {
            case 0x28: // (
                index += 1
                return .list(try readValues(until: 0x29))
            case 0x22: // "
                return .string(try readQuoted())
            case 0x7B: // {
                return .string(try readLiteral())
            default:
                let atom = try readAtom()
                return atom.uppercased() == "NIL" ? .nil_ : .atom(atom)
            }
        }

        mutating func readQuoted() throws -> Data {
            index += 1
            var out: [UInt8] = []
            while let byte = peek {
                index += 1
                if byte == 0x5C, let next = peek { // \
                    out.append(next)
                    index += 1
                } else if byte == 0x22 {
                    return Data(out)
                } else {
                    out.append(byte)
                }
            }
            throw IMAPParseError.unexpectedEnd
        }

        mutating func readLiteral() throws -> Data {
            guard let close = bytes[index...].firstIndex(of: 0x7D) else { throw IMAPParseError.unexpectedEnd }
            var digits = bytes[(index + 1)..<close]
            if digits.last == 0x2B { digits = digits.dropLast() }
            guard let count = Int(String(decoding: digits, as: UTF8.self)) else {
                throw IMAPParseError.malformed("литерал")
            }
            index = close + 1
            if peek == 0x0D { index += 1 }
            if peek == 0x0A { index += 1 }
            guard index + count <= bytes.count else { throw IMAPParseError.unexpectedEnd }
            let data = Data(bytes[index..<(index + count)])
            index += count
            return data
        }

        /// Атом. Квадратные скобки внутри атома читаются целиком, с пробелами:
        /// `BODY[HEADER.FIELDS (FROM TO)]<0>` — один ключ.
        mutating func readAtom() throws -> String {
            let start = index
            var depth = 0
            while let byte = peek {
                if byte == 0x5B { depth += 1 }
                if byte == 0x5D { depth = max(depth - 1, 0) }
                if depth == 0, byte == 0x20 || byte == 0x28 || byte == 0x29 || byte == 0x0D || byte == 0x0A {
                    break
                }
                index += 1
            }
            guard index > start else { throw IMAPParseError.malformed("пустой атом") }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}

/// Ответ `FETCH` как словарь: `UID` → 123, `FLAGS` → (...), `BODY[]` → данные.
public struct IMAPFetch: Sendable {
    public var sequence: UInt64
    public var attributes: [String: IMAPValue]

    public init?(_ values: [IMAPValue]) {
        guard values.count >= 3, let sequence = values[0].number,
              values[1].text?.uppercased() == "FETCH", let items = values[2].list else { return nil }
        self.sequence = sequence
        var attributes: [String: IMAPValue] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].text?.uppercased() {
                attributes[key] = items[index + 1]
            }
            index += 2
        }
        self.attributes = attributes
    }

    public var uid: UInt32? { attributes["UID"]?.number.map { UInt32(truncatingIfNeeded: $0) } }

    public var flags: [String] {
        attributes["FLAGS"]?.list?.compactMap(\.text) ?? []
    }

    public var internalDate: Date? {
        attributes["INTERNALDATE"]?.text.flatMap(IMAPDate.parseInternal)
    }

    public var size: Int? { attributes["RFC822.SIZE"]?.number.map(Int.init) }

    /// Секция `BODY[...]` по началу ключа: сервер может вернуть
    /// `BODY[HEADER.FIELDS (FROM TO)]` с другим регистром или порядком полей.
    public func section(_ prefix: String) -> Data? {
        let key = attributes.keys.first { $0.hasPrefix(prefix.uppercased()) }
        return key.flatMap { attributes[$0]?.data }
    }
}

/// Строка `LIST`: флаги, разделитель, имя папки.
public struct IMAPMailbox: Hashable, Sendable {
    /// Имя как на сервере (модифицированный UTF-7) — для команд.
    public var rawName: String
    public var flags: [String]
    public var delimiter: String?

    public init?(_ values: [IMAPValue]) {
        guard values.count >= 4, values[0].text?.uppercased() == "LIST",
              let flags = values[1].list?.compactMap(\.text) else { return nil }
        self.flags = flags
        delimiter = values[2].text
        guard let name = values[3].text else { return nil }
        rawName = name
    }

    public init(rawName: String, flags: [String], delimiter: String?) {
        self.rawName = rawName
        self.flags = flags
        self.delimiter = delimiter
    }

    /// Имя для человека: UTF-7 раскрыт, путь — последний кусок.
    public var displayName: String {
        let decoded = ModifiedUTF7.decode(rawName)
        guard let delimiter, !delimiter.isEmpty else { return decoded }
        return decoded.components(separatedBy: delimiter).last ?? decoded
    }

    public var isSelectable: Bool {
        !flags.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame || $0.caseInsensitiveCompare("\\NonExistent") == .orderedSame }
    }

    /// Особая роль папки по RFC 6154: `\Sent`, `\Archive`, `\Trash`…
    public func has(_ flag: String) -> Bool {
        flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }
}

/// Имена папок в IMAP — модифицированный UTF-7 (RFC 3501, 5.1.3):
/// «Отправленные» на проводе выглядит как `&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-`.
public enum ModifiedUTF7 {
    public static func decode(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            guard let dash = text[index...].firstIndex(of: "-") else {
                result += text[index...]
                break
            }
            let chunk = text[text.index(after: index)..<dash]
            if chunk.isEmpty {
                result.append("&")
            } else {
                var base64 = chunk.replacingOccurrences(of: ",", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                    result += decoded
                } else {
                    result += "&" + chunk + "-"
                }
            }
            index = text.index(after: dash)
        }
        return result
    }

    public static func encode(_ text: String) -> String {
        var result = ""
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            let data = pending.data(using: .utf16BigEndian) ?? Data()
            let base64 = data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: ",")
            result += "&" + base64 + "-"
            pending = ""
        }
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }
}

/// Даты IMAP: `23-Sep-2026` для поиска, `23-Sep-2026 13:15:30 +0300` для INTERNALDATE.
public enum IMAPDate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func formatter(_ format: String, zone: TimeZone? = nil) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        let key = format + (zone?.identifier ?? "")
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let zone { formatter.timeZone = zone }
        cache[key] = formatter
        return formatter
    }

    public static func parseInternal(_ text: String) -> Date? {
        formatter("d-MMM-yyyy HH:mm:ss Z").date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// День для `SEARCH SINCE` — в часовом поясе человека: сервер сравнивает
    /// только даты, без времени.
    public static func searchDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("d-MMM-yyyy", zone: timeZone).string(from: date)
    }
}

/// Сборка аргументов команд.
public enum IMAPArgument {
    /// Строка в кавычках, а если внутри не-ASCII или перевод строки —
    /// её надо слать литералом; этим занимается клиент.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func needsLiteral(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value > 0x7E || $0.value < 0x20 }
    }

    /// Набор UID: `1:5,8,10:12`.
    public static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            let start = sorted[index]
            var end = start
            while index + 1 < sorted.count, sorted[index + 1] == end + 1 {
                index += 1
                end = sorted[index]
            }
            ranges.append(start == end ? "\(start)" : "\(start):\(end)")
            index += 1
        }
        return ranges.joined(separator: ",")
    }
}
