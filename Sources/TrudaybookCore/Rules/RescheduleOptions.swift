import Foundation

/// Быстрые варианты «Перенести» для окна переноса.
public struct RescheduleOption: Hashable, Sendable, Identifiable {
    public var title: String
    public var date: Date
    public var id: String { title }

    public init(title: String, date: Date) {
        self.title = title
        self.date = date
    }
}

public enum RescheduleOptions {
    public static let morningHour = 9
    public static let eveningHour = 18

    /// Письмо и напоминание откладываются относительно «сейчас»,
    /// встреча сдвигается относительно своего начала.
    public static func options(
        for item: TimelineItem,
        now: Date,
        calendar: Calendar = .current
    ) -> [RescheduleOption] {
        switch item.kind {
        case .mail, .reminder:
            return later(from: now, calendar: calendar)
        case .event:
            return shifts(of: item.time, calendar: calendar)
        }
    }

    static func later(from now: Date, calendar: Calendar) -> [RescheduleOption] {
        var result: [RescheduleOption] = []
        result.append(RescheduleOption(title: String(localized: "Через час"), date: roundUp(now.addingTimeInterval(3600), calendar: calendar)))

        let today = calendar.startOfDay(for: now)
        if let evening = calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: today),
           evening.timeIntervalSince(now) >= 3600 {
            result.append(RescheduleOption(title: String(localized: "Сегодня вечером"), date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow) {
            result.append(RescheduleOption(title: String(localized: "Завтра утром"), date: morning))
        }
        // Следующий понедельник, а если сегодня понедельник — через неделю.
        var monday = DateComponents()
        monday.weekday = 2
        monday.hour = morningHour
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           let next = calendar.nextDate(after: tomorrow, matching: monday, matchingPolicy: .nextTime),
           // Если понедельник завтра, он уже есть как «Завтра утром».
           !result.contains(where: { $0.date == next }) {
            result.append(RescheduleOption(title: String(localized: "В понедельник"), date: next))
        }
        return result
    }

    static func shifts(of start: Date, calendar: Calendar) -> [RescheduleOption] {
        [
            RescheduleOption(title: String(localized: "На 30 минут позже"), date: start.addingTimeInterval(30 * 60)),
            RescheduleOption(title: String(localized: "На час позже"), date: start.addingTimeInterval(3600)),
            calendar.date(byAdding: .day, value: 1, to: start).map {
                RescheduleOption(title: String(localized: "Завтра в то же время"), date: $0)
            },
            calendar.date(byAdding: .day, value: 7, to: start).map {
                RescheduleOption(title: String(localized: "Через неделю"), date: $0)
            },
        ].compactMap { $0 }
    }

    /// Округление вверх до пяти минут: «отложить до 14:37» выглядит странно.
    static func roundUp(_ date: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = parts.minute ?? 0
        guard let floored = calendar.date(from: parts) else { return date }
        if floored == date, minute % 5 == 0 { return date }
        parts.minute = (minute / 5 + 1) * 5
        return calendar.date(from: parts) ?? date
    }
}
