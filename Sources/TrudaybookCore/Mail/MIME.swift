import Foundation

/// Разбор писем: заголовки RFC 5322, MIME, кодировки.
///
/// Письма из IMAP берутся сырыми (`BODY[HEADER]`, `BODY[]`) и разбираются
/// здесь, а не структурами IMAP (`ENVELOPE`, `BODYSTRUCTURE`): один разборщик
/// на все источники, и он проверяется тестами на настоящих образцах.
public enum MIME {
    // MARK: - Заголовки

    /// Заголовки в порядке следования. Имена сравниваются без учёта регистра.
    public struct Headers: Sendable {
        public var fields: [(name: String, value: String)]

        public init(fields: [(name: String, value: String)] = []) {
            self.fields = fields
        }

        public subscript(name: String) -> String? {
            fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        public func all(_ name: String) -> [String] {
            fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }
    }

    /// Делит сырое письмо на заголовки и тело по первой пустой строке.
    public static func split(_ data: Data) -> (header: Data, body: Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                // «\n\n» или «\n\r\n» — конец заголовков.
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    return (Data(bytes[0..<index + 1]), Data(bytes[(index + 2)...]))
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    return (Data(bytes[0..<index + 1]), Data(bytes[(index + 3)...]))
                }
            }
            index += 1
        }
        return (data, Data())
    }

    /// Разбирает блок заголовков: склеивает перенесённые строки.
    ///
    /// Байты читаются как UTF-8 (RFC 6532 разрешает его прямо в заголовках),
    /// а если это не UTF-8 — как Latin-1, чтобы ни один байт не потерялся;
    /// закодированные слова раскрываются позже, по полю.
    public static func parseHeaders(_ data: Data) -> Headers {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var fields: [(String, String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                guard !fields.isEmpty else { continue }
                fields[fields.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { fields.append((name, value)) }
            }
        }
        return Headers(fields: fields)
    }

    // MARK: - Закодированные слова (RFC 2047)

    /// Раскрывает `=?koi8-r?B?...?=` и `=?utf-8?Q?...?=`.
    ///
    /// Пробел между двумя соседними закодированными словами по стандарту
    /// не значащий: Outlook режет длинную тему на куски, и без этого правила
    /// в середине слов появлялись бы пробелы.
    public static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        var previousWasWord = false
        for match in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(previousWasWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += gap
            }
            let charset = ns.substring(with: match.range(at: 1))
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes = mode == "B" ? base64(payload) : quotedPrintable(payload, underscoreIsSpace: true)
            result += decode(bytes, charset: charset)
            cursor = match.range.location + match.range.length
            previousWasWord = true
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: - Кодировки содержимого

    public static func base64(_ text: String) -> Data {
        let cleaned = text.filter { !$0.isWhitespace }
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: padded, options: .ignoreUnknownCharacters) ?? Data()
    }

    /// Quoted-printable. В заголовках (`underscoreIsSpace`) «_» означает пробел.
    public static func quotedPrintable(_ text: String, underscoreIsSpace: Bool = false) -> Data {
        quotedPrintable(Data(text.utf8), underscoreIsSpace: underscoreIsSpace)
    }

    public static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D {
                // Мягкий перенос: «=» в конце строки.
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                    continue
                }
                out.append(byte)
            } else if byte == 0x5F, underscoreIsSpace {
                out.append(0x20)
            } else {
                out.append(byte)
            }
            index += 1
        }
        return out
    }

    /// Байты в строку по имени кодировки из письма.
    ///
    /// Имена понимает сама система (`koi8-r`, `windows-1251`, `iso-8859-5`,
    /// `gb2312`…). Если кодировка неизвестна или байты ей не соответствуют,
    /// пробуем UTF-8, затем windows-1251 — самая частая беда русской почты —
    /// и в конце Latin-1, который читает любые байты.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(named: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1251) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func encoding(named name: String) -> String.Encoding? {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        // Язык после «*» (RFC 2231: utf-8*ru) к кодировке не относится.
        let bare = trimmed.split(separator: "*").first.map(String.init) ?? trimmed
        switch bare {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(bare as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: - Content-Type и параметры

    public struct ContentType: Sendable, Equatable {
        /// В нижнем регистре: `text/html`, `multipart/alternative`.
        public var type: String
        public var parameters: [String: String]

        public init(type: String, parameters: [String: String] = [:]) {
            self.type = type
            self.parameters = parameters
        }

        public var isMultipart: Bool { type.hasPrefix("multipart/") }
        public var charset: String? { parameters["charset"] }
        public var boundary: String? { parameters["boundary"] }
    }

    /// `text/plain; charset="koi8-r"; name*=utf-8''%D0%9E...` → тип и параметры.
    ///
    /// Длинные имена файлов RFC 2231 режет на части (`name*0*`, `name*1*`)
    /// и кодирует процентами — такие параметры склеиваются и раскрываются.
    public static func parseParameterized(_ value: String) -> ContentType {
        let parts = splitOutsideQuotes(value, separator: ";")
        let type = (parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var simple: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, value: String)]] = [:]

        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            guard key.contains("*") else {
                simple[key] = raw
                continue
            }
            let encoded = key.hasSuffix("*")
            if encoded { key.removeLast() }
            let pieces = key.split(separator: "*", maxSplits: 1)
            let base = String(pieces[0])
            let index = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
            extended[base, default: []].append((index, encoded, raw))
        }

        for (base, pieces) in extended {
            let sorted = pieces.sorted { $0.index < $1.index }
            var charset: String?
            var bytes = Data()
            for (position, piece) in sorted.enumerated() {
                var value = piece.value
                if piece.encoded, position == 0 {
                    // charset'язык'значение
                    let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        charset = String(fields[0])
                        value = String(fields[2])
                    }
                }
                bytes += piece.encoded ? percentDecoded(value) : Data(value.utf8)
            }
            simple[base] = decode(bytes, charset: charset)
        }
        return ContentType(type: type.isEmpty ? "text/plain" : type, parameters: simple)
    }

    static func percentDecoded(_ text: String) -> Data {
        var out = Data()
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == 0x25, let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16) {
                out.append(value)
            } else {
                out.append(byte)
            }
        }
        return out
    }

    /// Делит строку по разделителю, не заглядывая внутрь кавычек и угловых скобок.
    static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                escaped = true
                current.append(character)
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                angle += 1
                current.append(character)
            case ">" where !inQuotes:
                angle = max(angle - 1, 0)
                current.append(character)
            default:
                if character == separator, !inQuotes, angle == 0 {
                    parts.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: - Адреса, даты, идентификаторы

    /// `"Иванов, Иван" <i@x.ru>, =?utf-8?B?...?= <a@x.ru>, b@x.ru (Боб)`.
    public static func parseAddresses(_ value: String) -> [Person] {
        splitOutsideQuotes(value, separator: ",").compactMap { raw in
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Группа «Имя: a@x, b@y;» и пустая «undisclosed-recipients:;» —
            // имя группы до двоеточия отбрасываем.
            if let colon = token.firstIndex(of: ":") {
                let head = token[..<colon]
                if !head.contains("@"), !head.contains("<"), !head.contains("\"") {
                    token = String(token[token.index(after: colon)...])
                }
            }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\r\n"))
            guard !token.isEmpty else { return nil }

            if let open = token.lastIndex(of: "<"), let close = token.lastIndex(of: ">"), open < close {
                let address = token[token.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = token[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                    name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                }
                name = decodeWords(name).trimmingCharacters(in: .whitespaces)
                return Person(name: name.isEmpty ? nil : name, address: address.isEmpty ? nil : address)
            }
            // «b@x.ru (Боб)» — имя в комментарии.
            if let open = token.firstIndex(of: "("), let close = token.lastIndex(of: ")"), open < close {
                let address = token[..<open].trimmingCharacters(in: .whitespaces)
                let name = decodeWords(String(token[token.index(after: open)..<close]))
                return Person(name: name.isEmpty ? nil : name, address: address)
            }
            guard token.contains("@") else { return nil }
            return Person(name: nil, address: token)
        }
    }

    /// Дата письма. Почтовые программы пишут её по-разному: без дня недели,
    /// с комментарием «(MSK)», с зоной словом или цифрами.
    public static func parseDate(_ value: String) -> Date? {
        var text = value.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let comma = text.firstIndex(of: ","), text.distance(from: text.startIndex, to: comma) <= 4 {
            text = String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        for format in ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss zzz",
                       "d MMM yy HH:mm:ss Z", "d MMM yyyy HH:mm:ss"] {
            if let date = dateFormatter(format).date(from: text) { return date }
        }
        return nil
    }

    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func dateFormatter(_ format: String) -> DateFormatter {
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let cached = formatters[format] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        formatters[format] = formatter
        return formatter
    }

    /// `<a@x> <b@y>` → `["a@x", "b@y"]`.
    public static func messageIDs(_ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<([^<>\\s]+)>") else { return [] }
        let ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

// MARK: - Части письма

/// Часть письма в дереве MIME.
public struct MIMEPart: Sendable {
    public var headers: MIME.Headers
    public var contentType: MIME.ContentType
    /// Тело до снятия Content-Transfer-Encoding.
    public var rawBody: Data
    public var children: [MIMEPart]

    public init(data: Data, defaultType: String = "text/plain") {
        let (header, body) = MIME.split(data)
        headers = MIME.parseHeaders(header)
        contentType = headers["Content-Type"].map(MIME.parseParameterized) ?? MIME.ContentType(type: defaultType)
        rawBody = body
        children = []
        if contentType.isMultipart, let boundary = contentType.boundary {
            // В multipart/digest части по умолчанию — вложенные письма.
            let childDefault = contentType.type == "multipart/digest" ? "message/rfc822" : "text/plain"
            children = MIMEPart.splitMultipart(body, boundary: boundary).map { MIMEPart(data: $0, defaultType: childDefault) }
        }
    }

    /// Тело после снятия base64 или quoted-printable.
    public var decodedBody: Data {
        let encoding = headers["Content-Transfer-Encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch encoding {
        case "base64": return MIME.base64(String(decoding: rawBody, as: UTF8.self))
        case "quoted-printable": return MIME.quotedPrintable(rawBody)
        default: return rawBody
        }
    }

    public var text: String {
        MIME.decode(decodedBody, charset: contentType.charset)
    }

    public var disposition: MIME.ContentType? {
        headers["Content-Disposition"].map(MIME.parseParameterized)
    }

    public var filename: String? {
        (disposition?.parameters["filename"] ?? contentType.parameters["name"]).map(MIME.decodeWords)
    }

    public var contentID: String? {
        headers["Content-ID"].flatMap { MIME.messageIDs($0).first ?? $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
    }

    public var isAttachment: Bool {
        if disposition?.type == "attachment" { return true }
        if contentType.type.hasPrefix("text/"), filename == nil { return false }
        return !contentType.isMultipart
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?

        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            // Разделитель действителен только в начале строки.
            let atLineStart = range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == 0x0A
            guard atLineStart else {
                searchStart = range.upperBound
                continue
            }
            if let start = partStart {
                var end = range.lowerBound
                // Перевод строки перед разделителем принадлежит разделителю.
                if end > start, body[body.index(before: end)] == 0x0A { end = body.index(before: end) }
                if end > start, body[body.index(before: end)] == 0x0D { end = body.index(before: end) }
                parts.append(body[start..<end])
            }
            var after = range.upperBound
            // «--граница--» — конец.
            if after + 1 < body.endIndex, body[after] == 0x2D, body[after + 1] == 0x2D { break }
            while after < body.endIndex, body[after] == 0x20 || body[after] == 0x09 { after += 1 }
            if after < body.endIndex, body[after] == 0x0D { after += 1 }
            if after < body.endIndex, body[after] == 0x0A { after += 1 }
            partStart = after
            searchStart = after
        }
        return parts.map { Data($0) }
    }
}

// MARK: - Письмо целиком

public struct ParsedMessage: Sendable {
    public var headers: MIME.Headers
    public var subject: String
    public var from: Person?
    public var replyTo: Person?
    public var to: [Person]
    public var cc: [Person]
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    /// Важность от отправителя: `Importance`, `X-Priority`, `Priority`.
    public var priority: Priority?
    /// Приглашение на встречу — по заголовкам: `Content-Class` у Outlook
    /// и Exchange, `text/calendar` в типе у остальных.
    public var isInvitation: Bool
    /// Рассылка по заголовкам списка или массовой отправки.
    public var isBulk: Bool
    /// Отправлено роботом (RFC 3834).
    public var isAutomatic: Bool

    public init(headerData: Data) {
        let headers = MIME.parseHeaders(MIME.split(headerData).header)
        self.headers = headers
        subject = MIME.decodeWords(headers["Subject"] ?? "").trimmingCharacters(in: .whitespaces)
        from = headers["From"].flatMap { MIME.parseAddresses($0).first }
        replyTo = headers["Reply-To"].flatMap { MIME.parseAddresses($0).first }
        to = headers.all("To").flatMap(MIME.parseAddresses)
        cc = headers.all("Cc").flatMap(MIME.parseAddresses)
        date = headers["Date"].flatMap(MIME.parseDate)
        messageID = headers["Message-ID"].flatMap { MIME.messageIDs($0).first }
        inReplyTo = headers["In-Reply-To"].flatMap { MIME.messageIDs($0).first }
        references = headers["References"].map(MIME.messageIDs) ?? []
        priority = Priority.fromHeaders(importance: headers["Importance"] ?? headers["X-MSMail-Priority"],
                                        xPriority: headers["X-Priority"], priority: headers["Priority"])
        let contentClass = headers["Content-Class"]?.lowercased() ?? ""
        let contentType = headers["Content-Type"]?.lowercased() ?? ""
        isInvitation = contentClass.contains("calendarmessage") || contentType.contains("text/calendar")
        let precedence = headers["Precedence"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        isBulk = headers["List-Unsubscribe"] != nil || headers["List-Id"] != nil
            || ["bulk", "list", "junk"].contains(precedence)
        let submitted = headers["Auto-Submitted"]?.lowercased().trimmingCharacters(in: .whitespaces)
        isAutomatic = submitted.map { !$0.isEmpty && $0 != "no" } ?? false
    }

    /// Тело письма для показа: HTML и текст, вложения, картинки внутри письма.
    public static func body(of raw: Data) -> MailBody {
        let root = MIMEPart(data: raw)
        var html: String?
        var text: String?
        var attachments: [MailBody.Attachment] = []
        var calendar: String?
        var inline: [String: (type: String, data: Data)] = [:]

        func walk(_ part: MIMEPart) {
            if part.contentType.isMultipart {
                part.children.forEach(walk)
                return
            }
            if part.contentType.type == "message/rfc822" {
                // Пересланное письмо показываем вложением.
                attachments.append(.init(name: part.filename ?? String(localized: "Письмо.eml"), size: part.decodedBody.count,
                                         mimeType: part.contentType.type, data: part.decodedBody))
                return
            }
            // Приглашение на встречу: `text/calendar` в теле письма (Outlook,
            // Exchange) или вложение `.ics` (Google). В текст письма не идёт.
            let isCalendar = part.contentType.type == "text/calendar" || part.contentType.type == "application/ics"
                || (part.filename?.lowercased().hasSuffix(".ics") ?? false)
            if isCalendar {
                if calendar == nil { calendar = part.text }
                if part.contentType.type == "text/calendar", !part.isAttachment { return }
            }
            if let id = part.contentID, part.contentType.type.hasPrefix("image/") {
                inline[id] = (part.contentType.type, part.decodedBody)
                if part.disposition?.type != "attachment" { return }
            }
            if part.isAttachment {
                let data = part.decodedBody
                attachments.append(.init(name: part.filename ?? String(localized: "Вложение"), size: data.count,
                                         mimeType: part.contentType.type, data: data))
            } else if part.contentType.type == "text/html", html == nil {
                html = part.text
            } else if part.contentType.type == "text/plain", text == nil {
                text = part.text
            } else if part.contentType.type.hasPrefix("text/"), text == nil {
                text = part.text
            }
        }
        walk(root)

        // Картинки из самого письма (cid:) — прямо в HTML: так их покажет
        // WebKit, которому запрещено ходить в сеть.
        if var document = html, !inline.isEmpty {
            for (id, image) in inline {
                let uri = "data:\(image.type);base64,\(image.data.base64EncodedString())"
                document = document.replacingOccurrences(of: "cid:\(id)", with: uri)
            }
            html = document
        }
        return MailBody(html: html, text: text, attachments: attachments, calendar: calendar)
    }

    /// Первые слова письма для подсказки в списке.
    public static func snippet(_ body: MailBody, length: Int = 160) -> String {
        let plain = body.plainText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(plain.prefix(length))
    }
}
