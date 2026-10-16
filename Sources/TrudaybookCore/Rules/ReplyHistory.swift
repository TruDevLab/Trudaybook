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

/// Начатый ответ на письмо: черновик в «Черновиках», отвечающий на него.
public enum ReplyDrafts {
    /// Черновик ответа на `original` — самый свежий из тех, чей `In-Reply-To`
    /// (или последняя ссылка `References`) — это письмо.
    public static func draft(for original: TimelineItem, in drafts: [TimelineItem]) -> TimelineItem? {
        guard let messageID = original.mail?.messageID else { return nil }
        return drafts
            .filter { target(of: $0) == messageID }
            .max { $0.time < $1.time }
    }

    /// На какое письмо отвечает черновик.
    public static func target(of draft: TimelineItem) -> String? {
        draft.mail.flatMap { $0.inReplyTo ?? $0.references.last }
    }

    /// Свой текст черновика без цитаты: её `MessageBuilder` дописывает
    /// в текстовую часть под подписью «… пишет:», а в окне ответа цитата —
    /// отдельно, из самого письма.
    public static func ownText(_ text: String, attribution: String?) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let attribution, let range = normalized.range(of: "\n\n" + attribution) {
            return String(normalized[..<range.lowerBound])
        }
        return ReplyHistory.stripQuoted(normalized)
    }
}
