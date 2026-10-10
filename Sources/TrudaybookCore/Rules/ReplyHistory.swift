import Foundation

/// Прошлая переписка для шаблона ответа: письма до последнего, без
/// процитированного хвоста — иначе в каждом письме цепочки модель читала бы
/// всю историю заново.
public enum ReplyHistory {
    /// Начало процитированной части: «пишет:», «wrote:», «Original Message»,
    /// шапка Outlook («От: … Отправлено: …») и строки с «>».
    private static let quoteStarts: [String] = [
        "^.{0,120}\\s(пишет|писал|писала|wrote)\\s*:\\s*$",
        "^-{2,}\\s*(original message|исходное сообщение|пересылаемое сообщение|forwarded message).*$",
        "^(от|from)\\s*:.{0,200}$",
        "^_{5,}$",
    ]

    /// Письмо без цитаты. Если после очистки ничего не осталось (письмо
    /// целиком из цитаты), возвращается исходный текст.
    public static func stripQuoted(_ text: String) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // «От:» — шапка Outlook только если до неё уже есть свой текст:
            // письмо может и начинаться с «От кого: …».
            let startsQuote = quoteStarts.contains { trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
            if startsQuote, !kept.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            if trimmed.hasPrefix(">") { continue }
            kept.append(line)
        }
        let result = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    /// Письма переписки, что были до последнего, — от старого к новому.
    /// `older` — по возрастанию времени; `texts` — текст письма по номеру
    /// (нет текста — письмо пропускается). Берутся самые свежие, пока не
    /// кончится бюджет знаков: старое письмо дороже новому не бывает.
    public static func letters(older: [TimelineItem], texts: [String: String], isMine: (Person) -> Bool,
                               budget: Int = MailModel.maxHistoryText) -> [MailModel.HistoryLetter] {
        var remaining = budget
        var result: [MailModel.HistoryLetter] = []
        for item in older.reversed() {
            guard result.count < MailModel.maxHistoryLetters, remaining > 200,
                  let info = item.mail, let raw = texts[item.id] else { continue }
            let text = String(stripQuoted(raw).prefix(min(remaining, 2_000)))
            guard !text.isEmpty else { continue }
            remaining -= text.count
            result.append(.init(from: info.from.formatted, date: item.time, text: text, mine: isMine(info.from)))
        }
        return result.reversed()
    }
}
