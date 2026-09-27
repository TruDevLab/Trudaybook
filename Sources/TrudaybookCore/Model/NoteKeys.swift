import Foundation

/// Заметка — на день, на неделю или на месяц.
///
/// Все три живут в одной таблице `day_notes`, различаются ключом:
/// день — `2026-09-27`, неделя — `2026-W39` (ISO 8601), месяц — `2026-09`.
/// Отметки в календаре и общая с Trunook заметка — только у дней.
public enum NotePeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    public var id: String { rawValue }
}

public enum NoteKeys {
    /// Неделя — с понедельника, номер по ISO 8601, как номера недель
    /// в календаре месяца; пояс — человека.
    public static func isoCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func key(_ period: NotePeriod, for date: Date, calendar: Calendar = .current) -> String {
        switch period {
        case .day:
            return ItemStateStore.dayKey(date, calendar: calendar)
        case .week:
            let iso = isoCalendar(timeZone: calendar.timeZone)
            let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
        case .month:
            let parts = calendar.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        }
    }

    /// Ключ дня: ровно `ГГГГ-ММ-ДД`. Недели и месяцы в отметки календаря
    /// и в папку Trunook не идут.
    public static func isDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Дни периода, в который попадает `date`, по порядку (полночь каждого).
    public static func days(_ period: NotePeriod, containing date: Date, calendar: Calendar = .current) -> [Date] {
        let start: Date
        let count: Int
        switch period {
        case .day:
            return [calendar.startOfDay(for: date)]
        case .week:
            let iso = isoCalendar(timeZone: calendar.timeZone)
            start = iso.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            count = 7
        case .month:
            start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
            count = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Соседний период: `-1` — предыдущий, `1` — следующий.
    public static func shift(_ date: Date, by step: Int, _ period: NotePeriod, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component = switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        return calendar.date(byAdding: component, value: step, to: date) ?? date
    }
}
