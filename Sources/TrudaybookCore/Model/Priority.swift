import Foundation

/// Приоритет элемента списка — как в «Напоминаниях»: три уровня и «без приоритета».
///
/// Ставит его человек, хранится у нас (`ItemStateStore`). Пока человек
/// ничего не выбрал, берётся важность, которую указал отправитель
/// (`Importance`, `X-Priority`, важность Exchange).
public enum Priority: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case none = 0
    case high = 1
    case medium = 2
    case low = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: String(localized: "Без приоритета")
        case .high: String(localized: "Высокий")
        case .medium: String(localized: "Средний")
        case .low: String(localized: "Низкий")
        }
    }

    /// Значок уровня — как в Jira: две стрелки вверх, «равно», стрелка вниз.
    public var symbol: String {
        switch self {
        case .none: "minus"
        case .high: "chevron.up.2"
        case .medium: "equal"
        case .low: "chevron.down"
        }
    }

    /// Клавиша в окне: 1 — высокий, 2 — средний, 3 — низкий, 0 — снять.
    public var key: String { String(rawValue) }

    /// Место при сортировке: высокий первым, без приоритета последним.
    public var rank: Int { self == .none ? 4 : rawValue }

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rank < rhs.rank }

    /// Важность из заголовков письма. `Importance: high`, `X-Priority: 1 (Highest)`,
    /// `Priority: urgent`. Обычная важность — `nil`: её не отмечаем.
    public static func fromHeaders(importance: String?, xPriority: String?, priority: String? = nil) -> Priority? {
        if let value = importance?.trimmingCharacters(in: .whitespaces).lowercased() {
            if value.hasPrefix("high") { return .high }
            if value.hasPrefix("low") { return .low }
        }
        if let value = xPriority?.trimmingCharacters(in: .whitespaces), let digit = value.first?.wholeNumberValue {
            switch digit {
            case 1, 2: return .high
            case 4, 5: return .low
            default: break
            }
        }
        if let value = priority?.trimmingCharacters(in: .whitespaces).lowercased() {
            if value.hasPrefix("urgent") { return .high }
            if value.hasPrefix("non-urgent") { return .low }
        }
        return nil
    }
}

public enum PrioritySort {
    /// Сначала по приоритету, внутри уровня — в прежнем порядке.
    public static func sorted(_ items: [TimelineItem], priority: (TimelineItem) -> Priority) -> [TimelineItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                let left = priority(lhs.element).rank, right = priority(rhs.element).rank
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
