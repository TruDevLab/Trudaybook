import Foundation

/// Письмо из файла `.eml` — открыли в Finder, перетащили на значок или
/// выбрали «Открыть файл…».
///
/// Файл чужой и в ящике его нет: письмо показывается только для чтения,
/// с тем же недоверием, что и полученное (без скриптов, картинки из сети
/// не грузятся). Ящика у такого письма нет — `accountID` особый.
public enum EmailFile {
    /// Потолок размера: письма с вложениями бывают большими, но выгрузка
    /// целого ящика в один файл — уже не письмо.
    public static let maxSize = 50 * 1024 * 1024
    /// Ящик письма из файла: ни одному настоящему не совпадёт.
    public static let accountID = "file"

    /// Письмо и его тело; `nil` — в файле не письмо.
    ///
    /// Письмом считается то, у чего есть хотя бы отправитель, дата или
    /// `Message-ID`: текст «ключ: значение» или картинка ими не станут.
    public static func letter(from data: Data, id: String, fallbackDate: Date) -> (item: TimelineItem, body: MailBody)? {
        guard !data.isEmpty, data.count <= maxSize else { return nil }
        let parsed = ParsedMessage(headerData: data)
        guard parsed.from != nil || parsed.date != nil || parsed.messageID != nil else { return nil }
        let body = ParsedMessage.body(of: data)
        let info = MailInfo(
            accountID: accountID,
            from: parsed.from ?? Person(name: String(localized: "Неизвестный отправитель"), address: nil),
            replyTo: parsed.replyTo, to: parsed.to, cc: parsed.cc,
            messageID: parsed.messageID, references: parsed.references,
            snippet: ParsedMessage.snippet(body), isRead: true,
            hasAttachments: !body.attachments.isEmpty, senderPriority: parsed.priority,
            isInvitation: parsed.isInvitation || body.calendar != nil,
            isBulk: parsed.isBulk, isAutomatic: parsed.isAutomatic)
        let title = parsed.subject.isEmpty ? String(localized: "Без темы") : parsed.subject
        let item = TimelineItem(id: id, title: title, time: parsed.date ?? fallbackDate, detail: .mail(info))
        return (item, body)
    }

    /// Номер письма из файла: по пути, чтобы тот же файл второй раз открыл
    /// то же окно, а не второе.
    public static func itemID(for url: URL) -> String {
        "file:" + url.standardizedFileURL.path
    }

    public static func isFileItem(_ id: String) -> Bool { id.hasPrefix("file:") }

    /// Файл письма — по расширению: `.eml` у Outlook, Почты и Thunderbird
    /// одинаковое. `.emlx` Почты — другой формат, его не открываем.
    public static func isEmailFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "eml"
    }
}
