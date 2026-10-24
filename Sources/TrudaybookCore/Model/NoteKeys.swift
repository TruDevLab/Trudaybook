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

    /// Свободная заметка — без даты, со своим названием (первая строка).
    /// Лежит в той же таблице, что и заметки периодов: редактор, запись
    /// и сверка между окнами у них общие. В отметки календаря и в Trunook
    /// не идёт — туда берутся только ключи дней.
    public static let freePrefix = "note:"

    public static func newFreeKey() -> String { freePrefix + UUID().uuidString }

    public static func isFreeKey(_ key: String) -> Bool { key.hasPrefix(freePrefix) }

    /// Период и его первый день по ключу: `2026-09-27`, `2026-W39`, `2026-09`.
    /// У свободной заметки и у чужого ключа — `nil`.
    public static func parse(_ key: String, calendar: Calendar = .current) -> (period: NotePeriod, date: Date)? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0].count == 4, let year = Int(parts[0]) else { return nil }
        if parts.count == 3, isDayKey(key), let month = Int(parts[1]), let day = Int(parts[2]),
           let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
            return (.day, date)
        }
        if parts.count == 2, parts[1].hasPrefix("W"), let week = Int(parts[1].dropFirst()) {
            let iso = isoCalendar(timeZone: calendar.timeZone)
            guard let date = iso.date(from: DateComponents(weekOfYear: week, yearForWeekOfYear: year)) else { return nil }
            return (.week, date)
        }
        if parts.count == 2, parts[1].count == 2, let month = Int(parts[1]), (1...12).contains(month),
           let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) {
            return (.month, date)
        }
        return nil
    }

    /// Название свободной заметки — первая непустая строка, без меток
    /// списка, не длиннее 80 знаков. Пустая — `nil`.
    public static func title(of text: String) -> String? {
        let markers = [NoteMarkers.bullet, NoteMarkers.unchecked, NoteMarkers.checked, "- "]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for marker in markers where line.hasPrefix(marker) { line.removeFirst(marker.count) }
            guard !line.isEmpty else { continue }
            return line.count > 80 ? String(line.prefix(79)) + "…" : line
        }
        return nil
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
