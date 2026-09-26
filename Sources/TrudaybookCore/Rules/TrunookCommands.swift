import Foundation

/// Команда из Trunook (помощник в вырезе): что сделать с почтой.
///
/// Список закрытый. Всё в нём обратимо и остаётся в Trudaybook: отложить,
/// поставить приоритет, отметить разобранным, открыть, подготовить ответ.
/// Отправить письмо, переслать, удалить — таких команд нет вовсе: ответ
/// помощник только кладёт черновиком, а отправляет человек.
public enum TrunookCommand: Equatable, Sendable {
    /// Неразобранные письма: от кого (слова), только важные, сколько.
    case list(from: String?, importantOnly: Bool, limit: Int)
    case open(letter: String)
    case snooze(letter: String, until: Date)
    case priority(letter: String, level: Priority)
    case done(letter: String)
    case draft(letter: String, text: String)

    public enum ParseError: Error, Equatable, Sendable {
        case unknownAction(String)
        case missing(String)
        case badDate
        case badLevel(String)
    }

    /// Потолок файла команды: это строка-другая и короткий текст ответа.
    public static let maxFileSize = 64 * 1024
    /// Потолок текста черновика.
    public static let maxDraftLength = 8000

    public static func parse(_ json: [String: Any]) -> Result<TrunookCommand, ParseError> {
        let action = (json["action"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        func text(_ key: String) -> String? {
            (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func letter() -> Result<String, ParseError> {
            text("letter").map { .success(String($0.prefix(300))) } ?? .failure(.missing("letter"))
        }
        switch action {
        case "list":
            let limit = (json["limit"] as? NSNumber)?.intValue ?? 10
            return .success(.list(from: text("from"),
                                  importantOnly: (json["important_only"] as? NSNumber)?.boolValue ?? false,
                                  limit: min(max(limit, 1), 30)))
        case "open":
            return letter().map { .open(letter: $0) }
        case "done":
            return letter().map { .done(letter: $0) }
        case "snooze":
            guard let raw = text("until") else { return .failure(.missing("until")) }
            guard let until = ISO8601DateFormatter().date(from: raw) else { return .failure(.badDate) }
            return letter().map { .snooze(letter: $0, until: until) }
        case "priority":
            let raw = text("level")?.lowercased() ?? ""
            let levels: [String: Priority] = ["high": .high, "medium": .medium, "low": .low, "none": .none]
            guard let level = levels[raw] else { return .failure(.badLevel(raw)) }
            return letter().map { .priority(letter: $0, level: level) }
        case "draft":
            guard let body = text("text") else { return .failure(.missing("text")) }
            return letter().map { .draft(letter: $0, text: String(body.prefix(maxDraftLength))) }
        default:
            return .failure(.unknownAction(String(action.prefix(40))))
        }
    }

    // MARK: - Какое письмо

    public enum Match: Equatable, Sendable {
        case found(TimelineItem)
        case none
        case ambiguous([TimelineItem])
    }

    /// Письмо по номеру (`mail:…`) или по словам из отправителя и темы.
    /// Все слова должны найтись; подошло несколько — выбирает человек,
    /// а не угадывает помощник.
    public static func resolve(_ query: String, in letters: [TimelineItem]) -> Match {
        if let exact = letters.first(where: { $0.id == query }) { return .found(exact) }
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !words.isEmpty else { return .none }
        let found = letters.filter { item in
            guard let mail = item.mail else { return false }
            let haystack = [mail.from.display, mail.from.address ?? "", item.title].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        .sorted { $0.time > $1.time }
        switch found.count {
        case 0: return .none
        case 1: return .found(found[0])
        default: return .ambiguous(Array(found.prefix(3)))
        }
    }

    /// Неразобранные письма для ответа на `list`: свежие сверху,
    /// с началом текста — по нему помощник и пересказывает.
    public static func listing(_ letters: [TimelineItem], from: String?, importantOnly: Bool, limit: Int,
                               priority: (TimelineItem) -> Priority) -> [[String: Any]] {
        let words = from?.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 } ?? []
        let formatter = ISO8601DateFormatter()
        return letters
            .filter { item in
                guard let mail = item.mail else { return false }
                if importantOnly, priority(item) != .high { return false }
                let sender = (mail.from.display + " " + (mail.from.address ?? "")).lowercased()
                return words.allSatisfy { sender.contains($0) }
            }
            .sorted { $0.time > $1.time }
            .prefix(limit)
            .map { item in
                [
                    "id": item.id,
                    "from": item.mail?.from.display ?? "",
                    "title": String(item.title.prefix(160)),
                    "time": formatter.string(from: item.time),
                    "important": priority(item) == .high,
                    "snippet": String((item.mail?.snippet ?? "").prefix(240)),
                ]
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
