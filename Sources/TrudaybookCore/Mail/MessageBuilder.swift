import Foundation

/// Сборка исходящего письма в формате RFC 5322 + MIME.
///
/// Письмо уходит двумя частями (`multipart/alternative`): HTML с оформлением
/// и цитатой полосой слева — его покажут почти все программы — и текстовая
/// копия, где цитата отмечена «>», для тех, кто HTML не показывает.
public enum MessageBuilder {
    public static func build(
        _ mail: OutgoingMail,
        from: Person,
        date: Date = Date(),
        messageID: String,
        boundary: String = "trudaybook-" + UUID().uuidString
    ) -> Data {
        var headers: [String] = []
        headers.append("From: \(formatAddress(from))")
        headers.append("To: \(mail.to.map(formatAddress).joined(separator: ", "))")
        if !mail.cc.isEmpty {
            headers.append("Cc: \(mail.cc.map(formatAddress).joined(separator: ", "))")
        }
        headers.append("Subject: \(encodeHeader(mail.subject))")
        headers.append("Date: \(dateHeader(date))")
        headers.append("Message-ID: <\(messageID)>")
        if let inReplyTo = mail.inReplyTo {
            headers.append("In-Reply-To: <\(inReplyTo)>")
        }
        if !mail.references.isEmpty {
            headers.append("References: " + mail.references.map { "<\($0)>" }.joined(separator: " "))
        }
        headers.append("MIME-Version: 1.0")
        headers.append("X-Mailer: Trudaybook")

        // С вложениями: снаружи multipart/mixed, внутри — текст и HTML.
        let files = mail.attachments.filter { $0.data != nil }
        let alternative = files.isEmpty ? boundary : "alt-" + boundary
        var lines = headers
        if files.isEmpty {
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: multipart/alternative; boundary=\"\(alternative)\"")
            lines.append("")
        }
        lines.append("--\(alternative)")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(base64Lines(Data(plainText(of: mail).utf8)))
        lines.append("--\(alternative)")
        lines.append("Content-Type: text/html; charset=utf-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(base64Lines(Data(htmlDocument(of: mail).utf8)))
        lines.append("--\(alternative)--")
        for file in files {
            lines.append("--\(boundary)")
            lines += attachmentHeaders(file)
            lines.append("")
            lines.append(base64Lines(file.data ?? Data()))
        }
        if !files.isEmpty { lines.append("--\(boundary)--") }
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Заголовки вложения. Имя — дважды: `filename*` по RFC 2231 (так
    /// правильно) и закодированным словом в `name` (так понимает Outlook).
    static func attachmentHeaders(_ file: MailBody.Attachment) -> [String] {
        let encodedWord = encodeHeader(file.name).replacingOccurrences(of: "\r\n ", with: " ")
        let percent = file.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "file"
        return [
            "Content-Type: \(file.mimeType); name=\"\(encodedWord)\"",
            "Content-Disposition: attachment; filename*=utf-8''\(percent)",
            "Content-Transfer-Encoding: base64",
        ]
    }

    /// Текстовая копия: свой текст, пустая строка, подпись цитаты, цитата с «>».
    public static func plainText(of mail: OutgoingMail) -> String {
        var text = mail.text
        if let quote = mail.quote {
            text += "\n\n\(quote.attribution)\n\(ReplyBuilder.quotedLines(quote.text))"
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// HTML-часть: свой текст и цитата в `blockquote type="cite"` — так её
    /// узнают Mail, Outlook и Gmail и сворачивают у себя.
    public static func htmlDocument(of mail: OutgoingMail) -> String {
        let own = mail.html ?? escapeText(mail.text)
        var body = "<div>\(own)</div>"
        if let quote = mail.quote {
            let quoted = quote.html.map(bodyContent) ?? escapeText(quote.text)
            body += """
                <br><div>\(escape(quote.attribution))</div>\
                <blockquote type="cite" style="margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex">\
                \(quoted)</blockquote>
                """
        }
        return """
            <!DOCTYPE html><html><head><meta charset="utf-8"></head>\
            <body style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px">\(body)</body></html>
            """
    }

    /// Содержимое `<body>` чужого письма — без `<html>`, `<head>` и скриптов.
    static func bodyContent(_ html: String) -> String {
        var content = html
        if let regex = try? NSRegularExpression(pattern: "<body[^>]*>(.*)</body>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            content = String(html[range])
        }
        return content.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapeText(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: - Заголовки

    /// Не-ASCII — закодированными словами UTF-8 по RFC 2047, каждое не длиннее
    /// 75 символов; слова не рвут многобайтовый символ посередине.
    public static func encodeHeader(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 0x7E || $0.value < 0x20 }) else { return text }
        var words: [String] = []
        var chunk = ""
        // «=?utf-8?B?» + «?=» = 12 символов; 45 байт дают 60 символов base64.
        for character in text {
            if (chunk + String(character)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?utf-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    public static func formatAddress(_ person: Person) -> String {
        let address = person.address ?? ""
        guard let name = person.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return address }
        let needsQuotes = name.contains { ",;:<>@\"()[]\\.".contains($0) }
        let shown = name.unicodeScalars.contains(where: { $0.value > 0x7E })
            ? encodeHeader(name)
            : (needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"" : name)
        return "\(shown) <\(address)>"
    }

    static func dateHeader(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// `Message-ID` для нового письма: случайная часть и домен отправителя.
    public static func newMessageID(for address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? "trudaybook.local"
        return "\(UUID().uuidString.lowercased())@\(domain)"
    }
}

extension MessageBuilder {
    /// Полученное письмо файлом `.eml` — вытащить на полку Trunook или
    /// в Finder. Заголовки — как пришло (от кого, кому, когда, Message-ID),
    /// тело — текст и HTML без скриптов, вложения — те, что загружены.
    public static func export(_ item: TimelineItem, body: MailBody) -> Data? {
        guard let info = item.mail else { return nil }
        let mail = OutgoingMail(to: info.to, cc: info.cc, subject: item.title, text: body.plainText,
                                html: body.html.map(bodyContent), references: info.references,
                                attachments: body.attachments.filter { $0.data != nil })
        let id = info.messageID ?? "\(UUID().uuidString)@trudaybook"
        return build(mail, from: info.from, date: item.time, messageID: id)
    }

    /// Имя файла по теме: без знаков, которые Finder не любит.
    public static func exportFileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r"))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String((cleaned.isEmpty ? String(localized: "Письмо") : cleaned).prefix(80)) + ".eml"
    }
}

