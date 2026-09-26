import Foundation

/// Правило повтора — общее для календаря macOS и Exchange.
public struct RecurrenceRule: Hashable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable {
        case daily, weekly, monthly, yearly
    }

    public enum End: Hashable, Sendable {
        case never
        /// До этого дня включительно.
        case until(Date)
        case count(Int)
    }

    public var frequency: Frequency
    /// Каждые N дней, недель, месяцев.
    public var interval: Int
    /// Дни недели для еженедельного повтора, как в `Calendar`: 1 — воскресенье, 2 — понедельник…
    public var weekdays: Set<Int>
    public var end: End

    public init(frequency: Frequency, interval: Int = 1, weekdays: Set<Int> = [], end: End = .never) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.end = end
    }

    /// По будням.
    public static let weekdaysOnly = RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])

    public var isWeekdaysOnly: Bool {
        frequency == .weekly && interval == 1 && weekdays == [2, 3, 4, 5, 6]
    }

    /// «Каждую неделю: пн, ср», «Каждые 2 дня · до 31 декабря», «Каждый месяц · 10 раз».
    public func summary(start: Date, calendar: Calendar = .current) -> String {
        var text: String
        switch frequency {
        case .daily:
            text = interval == 1 ? String(localized: "Каждый день") : String(localized: "Каждые \(interval) \(Self.plural(interval, String(localized: "день"), String(localized: "дня"), String(localized: "дней")))")
        case .weekly:
            if isWeekdaysOnly {
                text = String(localized: "По будням")
            } else {
                text = interval == 1 ? String(localized: "Каждую неделю") : String(localized: "Каждые \(interval) \(Self.plural(interval, String(localized: "неделю"), String(localized: "недели"), String(localized: "недель")))")
                let days = (weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : Array(weekdays))
                    .sorted { Self.mondayFirst($0) < Self.mondayFirst($1) }
                text += ": " + days.map { Self.shortWeekday($0) }.joined(separator: ", ")
            }
        case .monthly:
            text = interval == 1 ? String(localized: "Каждый месяц") : String(localized: "Каждые \(interval) \(Self.plural(interval, String(localized: "месяц"), String(localized: "месяца"), String(localized: "месяцев")))")
            text += String(localized: ", \(calendar.component(.day, from: start)) числа")
        case .yearly:
            let formatter = AppLanguage.formatter(ru: "d MMMM", template: "dMMMM")
            formatter.calendar = calendar
            text = String(localized: "Каждый год, \(formatter.string(from: start))")
        }
        switch end {
        case .never:
            break
        case .until(let date):
            let sameYear = calendar.isDate(date, equalTo: start, toGranularity: .year)
            let formatter = AppLanguage.formatter(ru: sameYear ? "d MMMM" : "d MMMM yyyy", template: sameYear ? "dMMMM" : "dMMMMyyyy")
            formatter.calendar = calendar
            text += String(localized: " · до \(formatter.string(from: date))")
        case .count(let count):
            text += String(localized: " · \(count) \(Self.plural(count, String(localized: "раз"), String(localized: "раза"), String(localized: "раз")))")
        }
        return text
    }

    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return many }
        if ones == 1 { return one }
        if (2...4).contains(ones) { return few }
        return many
    }

    /// Понедельник — первый день недели: 2 → 0 … 1 (воскресенье) → 6.
    public static func mondayFirst(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    public static func shortWeekday(_ weekday: Int) -> String {
        [String(localized: "вс"), String(localized: "пн"), String(localized: "вт"), String(localized: "ср"), String(localized: "чт"), String(localized: "пт"), String(localized: "сб")][(weekday - 1 + 7) % 7]
    }
}

/// Что именно менять или удалять в повторяющейся встрече.
public enum RecurrenceScope: String, CaseIterable, Sendable {
    case thisEvent
    case thisAndFollowing
    case all

    public var title: String {
        switch self {
        case .thisEvent: return String(localized: "Только это событие")
        case .thisAndFollowing: return String(localized: "Это и все следующие")
        case .all: return String(localized: "Все события серии")
        }
    }
}

/// Встреча, как её заполняют в редакторе: новая или правка существующей.
public struct EventDraft: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    /// Календарь, куда сохранить (`CalendarSourceInfo.id`).
    public var calendarID: String?
    /// Обязательные участники. Приглашения рассылает только Exchange.
    public var attendees: [Person]
    public var optionalAttendees: [Person]
    public var recurrence: RecurrenceRule?
    /// Повтор, который редактор не умеет показать (например, «вторая среда
    /// месяца», заведённый в Outlook). Такой повтор не трогаем при сохранении.
    public var hasUnsupportedRecurrence: Bool
    /// Встреча уже повторяется — при сохранении спросить, что менять.
    public var isRecurringSeries: Bool
    /// Файлы, которые прикрепить (и разослать участникам). Только Exchange.
    public var attachments: [MailBody.Attachment] = []

    public init(title: String = "", start: Date, end: Date, isAllDay: Bool = false, location: String = "",
                notes: String = "", calendarID: String? = nil, attendees: [Person] = [],
                optionalAttendees: [Person] = [], recurrence: RecurrenceRule? = nil,
                hasUnsupportedRecurrence: Bool = false, isRecurringSeries: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendarID = calendarID
        self.attendees = attendees
        self.optionalAttendees = optionalAttendees
        self.recurrence = recurrence
        self.hasUnsupportedRecurrence = hasUnsupportedRecurrence
        self.isRecurringSeries = isRecurringSeries
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Новое напоминание.
public struct ReminderDraft: Hashable, Sendable {
    public var title: String
    public var due: Date?
    /// Срок с точным временем, а не только днём.
    public var hasTime: Bool
    public var notes: String
    public var listID: String?

    public init(title: String = "", due: Date? = nil, hasTime: Bool = true, notes: String = "", listID: String? = nil) {
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.notes = notes
        self.listID = listID
    }
}

// MARK: - Занятость участников

/// Отрезок занятости в календаре человека.
public struct BusyInterval: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case busy, tentative, away, elsewhere
    }

    public var start: Date
    public var end: Date
    public var kind: Kind
    /// Тема — если человек разрешил её видеть.
    public var subject: String?

    public init(start: Date, end: Date, kind: Kind, subject: String? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
        self.subject = subject
    }
}

/// Занятость одного человека за период.
public struct PersonAvailability: Hashable, Sendable {
    public var busy: [BusyInterval]
    /// Рабочие часы, если сервер их знает: минуты от полуночи.
    public var workday: ClosedRange<Int>?
    /// Почему занятость неизвестна: внешний адрес, нет доступа.
    public var problem: String?

    public init(busy: [BusyInterval] = [], workday: ClosedRange<Int>? = nil, problem: String? = nil) {
        self.busy = busy
        self.workday = workday
        self.problem = problem
    }
}

/// Планирование встреч: занятость коллег и поиск по адресной книге.
/// Даёт Exchange; в тестовом режиме — выдуманная занятость.
public protocol SchedulingService: AnyObject, Sendable {
    /// Занятость по адресам (в нижнем регистре) за `[from, to)`.
    func availability(of addresses: [String], from: Date, to: Date) async throws -> [String: PersonAvailability]
    /// Люди из адресной книги компании по части имени или адреса.
    func searchDirectory(_ text: String) async throws -> [Person]
}

public enum SchedulingMath {
    /// Первое время начала не раньше `from`, когда все свободны `duration`
    /// секунд, внутри рабочего дня `workday` (минуты от полуночи). Шаг — 15 минут.
    public static func firstFreeSlot(
        busy: [[BusyInterval]],
        from: Date,
        duration: TimeInterval,
        workday: ClosedRange<Int> = 9 * 60...19 * 60,
        searchDays: Int = 14,
        calendar: Calendar = .current
    ) -> Date? {
        let step: TimeInterval = 15 * 60
        let all = busy.flatMap { $0 }.filter { $0.kind != .elsewhere }
        var candidate = Date(timeIntervalSinceReferenceDate: (from.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
        let limit = from.addingTimeInterval(Double(searchDays) * 86_400)
        while candidate < limit {
            let dayStart = calendar.startOfDay(for: candidate)
            let open = dayStart.addingTimeInterval(Double(workday.lowerBound) * 60)
            let close = dayStart.addingTimeInterval(Double(workday.upperBound) * 60)
            if calendar.isDateInWeekend(candidate) || candidate.addingTimeInterval(duration) > close {
                // Следующий рабочий день с начала рабочего дня.
                guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
                candidate = next.addingTimeInterval(Double(workday.lowerBound) * 60)
                continue
            }
            if candidate < open {
                candidate = open
                continue
            }
            let end = candidate.addingTimeInterval(duration)
            if let clash = all.filter({ $0.start < end && $0.end > candidate }).max(by: { $0.end < $1.end }) {
                // Сразу за самым поздним мешающим отрезком, по сетке шага.
                candidate = Date(timeIntervalSinceReferenceDate: (clash.end.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
                continue
            }
            return candidate
        }
        return nil
    }
}
