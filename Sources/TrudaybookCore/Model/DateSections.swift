import Foundation

/// Раздел списка «Не разобрано» по давности: Сегодня, Вчера, дни недели
/// (по дате), Старше 7 дней, Старше 30 дней.
public enum DateSection: Hashable, Sendable {
    case today
    case yesterday
    /// Один день из последней недели (2–7 дней назад) — начало этого дня.
    case day(Date)
    case olderThanWeek
    case olderThanMonth

    /// Ключ для запоминания свёрнутых разделов. У дня ключ — дата: свёрнутый
    /// «вторник» через неделю станет частью «Старше 7 дней» и забудется.
    public var key: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .day(let date): "day:\(Int(date.timeIntervalSince1970))"
        case .olderThanWeek: "older7"
        case .olderThanMonth: "older30"
        }
    }
}

public enum DateSections {
    /// Разбить список, не меняя порядка внутри раздела. Разделы — от
    /// свежего к старому; пустых нет. Будущее время (отложенное письмо уже
    /// вернулось, напоминание на вечер) — «Сегодня».
    public static func group(_ items: [TimelineItem], time: (TimelineItem) -> Date,
                             now: Date, calendar: Calendar) -> [(section: DateSection, items: [TimelineItem])] {
        let today = calendar.startOfDay(for: now)
        var buckets: [DateSection: [TimelineItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: time(item))
            let age = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            let section: DateSection = switch age {
            case ...0: .today
            case 1: .yesterday
            case 2...7: .day(day)
            case 8...30: .olderThanWeek
            default: .olderThanMonth
            }
            buckets[section, default: []].append(item)
        }
        let days = buckets.keys.compactMap { section -> Date? in
            if case .day(let date) = section { return date }
            return nil
        }.sorted(by: >)
        let order: [DateSection] = [.today, .yesterday] + days.map(DateSection.day) + [.olderThanWeek, .olderThanMonth]
        return order.compactMap { section in buckets[section].map { (section, $0) } }
    }
}
