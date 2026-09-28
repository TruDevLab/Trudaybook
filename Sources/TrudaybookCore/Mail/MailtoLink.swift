import Foundation

/// Ссылка `mailto:` (RFC 6068) — из браузера, документа или другой
/// программы, когда Trudaybook назначен почтой по умолчанию.
///
/// Ссылка чужая: из неё берутся только адреса, тема и текст. Заголовки
/// вроде `In-Reply-To` или `From` игнорируются — ссылка не должна
/// выдавать письмо за ответ или менять отправителя.
public struct MailtoLink: Equatable, Sendable {
    public var to: [Person]
    public var cc: [Person]
    /// Скрытой копии в черновике нет: адреса отсюда человек добавит сам.
    /// В «Копию» их переносить нельзя — скрытые получатели стали бы видны.
    public var bcc: [Person]
    public var subject: String
    public var body: String

    /// Потолок текста из ссылки: в адресной строке длинного письма не бывает,
    /// а мегабайт мусора в редакторе ни к чему.
    public static let maxBody = 20_000

    public static func parse(_ url: URL) -> MailtoLink? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var link = MailtoLink(to: addresses(String(parts.first ?? "")), cc: [], bcc: [], subject: "", body: "")
        guard parts.count > 1 else { return link }
        for pair in parts[1].split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decode(String(field[0])).lowercased()
            let value = field.count > 1 ? decode(String(field[1])) : ""
            switch name {
            case "to": link.to += addresses(value)
            case "cc": link.cc += addresses(value)
            case "bcc": link.bcc += addresses(value)
            case "subject":
                link.subject = String(value.prefix(500))
                    .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            case "body":
                link.body = String(value.prefix(maxBody)).replacingOccurrences(of: "\r\n", with: "\n")
            default:
                break
            }
        }
        return link
    }

    /// `+` в mailto — плюс, а не пробел (в отличие от форм HTML).
    static func decode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// Адреса через запятую; без «@» — не адрес.
    static func addresses(_ text: String) -> [Person] {
        decode(text).split(separator: ",").compactMap { part in
            let address = part.trimmingCharacters(in: .whitespaces)
            guard address.contains("@"), address.count <= 320, !address.contains(where: \.isNewline) else { return nil }
            return Person(name: nil, address: address)
        }
    }
}
