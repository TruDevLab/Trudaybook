import Foundation
import EventKit
import AppKit

/// Календарь или список напоминаний — для выбора в настройках.
public struct CalendarSourceInfo: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case events, reminders }

    public var id: String
    public var title: String
    public var color: RGB?
    public var kind: Kind
    /// Учётная запись: «iCloud», «Exchange», «На Mac».
    public var group: String
    /// Можно добавлять и менять события.
    public var isWritable: Bool
    /// Можно приглашать участников — только календарь Exchange.
    public var supportsAttendees: Bool
    /// Значок учётной записи для заголовка группы (SF Symbols).
    public var groupSymbol: String
    /// Свой календарь Exchange, подключённый через «Учётные записи интернета» macOS
    /// (не делегированный календарь коллеги).
    public var isSystemExchange: Bool

    public init(id: String, title: String, color: RGB?, kind: Kind, group: String,
                isWritable: Bool = true, supportsAttendees: Bool = false, isSystemExchange: Bool = false,
                groupSymbol: String = "calendar") {
        self.groupSymbol = groupSymbol
        self.id = id
        self.title = title
        self.color = color
        self.kind = kind
        self.group = group
        self.isWritable = isWritable
        self.supportsAttendees = supportsAttendees
        self.isSystemExchange = isSystemExchange
    }
}

/// Источник встреч и напоминаний.
@MainActor
public protocol CalendarProvider: AnyObject {
    /// Что мешает читать календарь, человеческими словами. `nil` — всё в порядке.
    var accessProblem: String? { get }
    /// Все календари и списки напоминаний.
    func calendars() -> [CalendarSourceInfo]
    /// Скрытые календари и списки. Хранятся скрытые, а не показанные:
    /// календарь, добавленный в системе позже, появляется сам.
    var hiddenCalendarIDs: Set<String> { get set }
    /// Вызывается, когда данные поменялись снаружи (в Календаре, на телефоне).
    var onChange: (() -> Void)? { get set }

    func requestAccess() async
    /// Встречи и напоминания со сроком в промежутке `[from, to)`.
    func items(from: Date, to: Date) async -> [TimelineItem]
    /// Невыполненные напоминания со сроком раньше `date`.
    func overdueReminders(before date: Date) async -> [TimelineItem]
    /// Перенести встречу (длительность сохраняется) или срок напоминания.
    func move(_ item: TimelineItem, to start: Date) async throws
    /// Отметить напоминание выполненным или вернуть в невыполненные.
    func setCompleted(_ item: TimelineItem, _ done: Bool) async throws

    /// Встреча в виде черновика — для редактора. У повторяющейся — вместе
    /// с правилом повтора всей серии.
    func draft(for item: TimelineItem) async throws -> EventDraft
    func create(_ draft: EventDraft) async throws
    /// Изменить встречу; у повторяющейся — `scope` решает, какие вхождения.
    func update(_ item: TimelineItem, to draft: EventDraft, scope: RecurrenceScope) async throws
    func delete(_ item: TimelineItem, scope: RecurrenceScope) async throws
    func createReminder(_ draft: ReminderDraft) async throws
    /// «Отклонить»: встреча — отказ организатору или отмена своей (где это
    /// умеет календарь) и уход из календаря; напоминание — удалить.
    func decline(_ item: TimelineItem) async throws

    /// Чей это элемент и календарь — чтобы общий календарь знал, кому
    /// передать правку.
    func owns(itemID: String) -> Bool
    func owns(calendarID: String) -> Bool
}

public enum CalendarError: LocalizedError {
    case notFound
    case notAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return String(localized: "Элемент не найден в календаре — возможно, его уже удалили")
        case .notAllowed(let reason): return reason
        }
    }
}

/// Календарь и напоминания macOS через EventKit.
///
/// Рабочие календари — Exchange, Google, iCloud — попадают сюда сами, если
/// подключены в «Учётных записях интернета».
@MainActor
public final class EventKitCalendar: CalendarProvider {
    private let store = EKEventStore()
    public var onChange: (() -> Void)?
    public var hiddenCalendarIDs: Set<String> = []
    private var observer: NSObjectProtocol?

    public func calendars() -> [CalendarSourceInfo] {
        var result: [CalendarSourceInfo] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            result += store.calendars(for: .event).map { Self.info($0, kind: .events) }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            result += store.calendars(for: .reminder).map { Self.info($0, kind: .reminders) }
        }
        return result.sorted { ($0.group, $0.title) < ($1.group, $1.title) }
    }

    private static func info(_ calendar: EKCalendar, kind: CalendarSourceInfo.Kind) -> CalendarSourceInfo {
        let source = calendar.source
        let (group, symbol) = describe(source)
        return CalendarSourceInfo(id: calendar.calendarIdentifier, title: calendar.title,
                                  color: rgb(calendar), kind: kind, group: group,
                                  isWritable: calendar.allowsContentModifications,
                                  // Делегированный календарь коллеги напрямую не читается — не копия.
                                  isSystemExchange: source?.sourceType == .exchange && source?.isDelegate == false,
                                  groupSymbol: symbol)
    }

    /// Чья учётная запись — понятными словами: «через macOS» — подключено
    /// в «Учётных записях интернета», в отличие от ящика Exchange,
    /// подключённого в самом Trudaybook («напрямую»).
    static func describe(_ source: EKSource?) -> (group: String, symbol: String) {
        guard let source else { return ("Другое", "calendar") }
        let title = source.title
        switch source.sourceType {
        case .local:
            return ("На этом Mac", "laptopcomputer")
        case .exchange:
            return source.isDelegate
                ? ("Exchange через macOS · календарь коллеги: \(title)", "person.2")
                : ("Exchange через macOS · учётная запись «\(title)»", "building.2")
        case .birthdays:
            return ("Дни рождения из Контактов", "gift")
        case .subscribed:
            return ("Подписки", "link")
        case .calDAV:
            let lower = title.lowercased()
            if lower.contains("icloud") { return ("iCloud", "icloud") }
            if lower.contains("google") || lower.contains("gmail") { return ("Google через macOS · \(title)", "globe") }
            if lower.contains("yandex") || lower.contains("яндекс") { return ("Яндекс через macOS · \(title)", "globe") }
            return ("\(title) через macOS", "globe")
        default:
            return (title, "calendar")
        }
    }

    /// Видимые календари нужного вида. `nil` — показывать нечего: пустой
    /// список в предикате EventKit означал бы «все», а не «никакие».
    private func visible(_ type: EKEntityType) -> [EKCalendar]? {
        let shown = store.calendars(for: type).filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        return shown.isEmpty ? nil : shown
    }

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    public var accessProblem: String? {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        switch (events == .fullAccess, reminders == .fullAccess) {
        case (true, true): return nil
        case (true, false): return String(localized: "Нет доступа к Напоминаниям")
        case (false, true): return String(localized: "Нет доступа к Календарю")
        case (false, false): return String(localized: "Нет доступа к Календарю и Напоминаниям")
        }
    }

    public func requestAccess() async {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            _ = try? await store.requestFullAccessToReminders()
        }
    }

    // MARK: - Чтение

    public func items(from: Date, to: Date) async -> [TimelineItem] {
        var result: [TimelineItem] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess, let calendars = visible(.event) {
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
            result += store.events(matching: predicate)
                .filter { $0.status != .canceled }
                .compactMap(Self.item(from:))
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let lists = visible(.reminder) {
            let open = await fetch(store.predicateForIncompleteReminders(
                withDueDateStarting: from, ending: to, calendars: lists))
            // Выполненные ищем по дате выполнения с запасом, а срок проверяем
            // сами: выполнить могли и накануне срока.
            let done = await fetch(store.predicateForCompletedReminders(
                withCompletionDateStarting: from.addingTimeInterval(-7 * 86_400),
                ending: to.addingTimeInterval(86_400), calendars: lists))
            result += (open + done)
                .compactMap(Self.item(from:))
                .filter { $0.time >= from && $0.time < to }
        }
        return result
    }

    public func overdueReminders(before date: Date) async -> [TimelineItem] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let lists = visible(.reminder) else { return [] }
        let reminders = await fetch(store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: date, calendars: lists))
        return reminders.compactMap(Self.item(from:))
    }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Правка

    public func move(_ item: TimelineItem, to start: Date) async throws {
        switch item.kind {
        case .event:
            guard let event = occurrence(of: item) else { throw CalendarError.notFound }
            guard event.calendar.allowsContentModifications else {
                throw CalendarError.notAllowed(String(localized: "Календарь «\(event.calendar.title)» не разрешает правку"))
            }
            let duration = (event.endDate ?? event.startDate).timeIntervalSince(event.startDate)
            event.startDate = start
            event.endDate = start.addingTimeInterval(duration)
            // Повторяющаяся встреча переносится одним вхождением: сдвинув
            // сегодняшнюю планёрку, никто не ждёт, что уедут все остальные.
            try store.save(event, span: .thisEvent, commit: true)

        case .reminder:
            guard let reminder = reminder(of: item) else { throw CalendarError.notFound }
            let old = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: start)
            // Сигнал в самом напоминании едет вместе со сроком.
            if let old, let alarms = reminder.alarms {
                for alarm in alarms {
                    if let absolute = alarm.absoluteDate {
                        alarm.absoluteDate = absolute.addingTimeInterval(start.timeIntervalSince(old))
                    }
                }
            }
            try store.save(reminder, commit: true)
            // Список мог молча не принять новый срок (часть задач Exchange
            // хранит только дату) — тогда напоминание «возвращается на
            // место». Лучше сказать об этом, чем делать вид, что перенесли.
            let identifier = String(item.id.dropFirst("reminder:".count))
            store.refreshSourcesIfNecessary()
            if let saved = store.calendarItem(withIdentifier: identifier) as? EKReminder,
               let components = saved.dueDateComponents,
               let due = Calendar.current.date(from: components), abs(due.timeIntervalSince(start)) > 90 {
                throw CalendarError.notAllowed(String(localized: "Список «\(saved.calendar?.title ?? "")» не сохранил новое время напоминания"))
            }

        case .mail:
            break
        }
    }

    public func setCompleted(_ item: TimelineItem, _ done: Bool) async throws {
        guard item.kind == .reminder else { return }
        guard let reminder = reminder(of: item) else { throw CalendarError.notFound }
        reminder.isCompleted = done
        try store.save(reminder, commit: true)
    }

    // MARK: - Создание и правка

    public func owns(itemID: String) -> Bool {
        (itemID.hasPrefix("event:") && !itemID.hasPrefix("event:ews:") && !itemID.hasPrefix("event:demo-"))
            || (itemID.hasPrefix("reminder:") && !itemID.hasPrefix("reminder:demo-"))
    }

    public func owns(calendarID: String) -> Bool {
        store.calendar(withIdentifier: calendarID) != nil
    }

    public func draft(for item: TimelineItem) async throws -> EventDraft {
        guard let event = occurrence(of: item) else { throw CalendarError.notFound }
        let rule = event.recurrenceRules?.first
        return EventDraft(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate ?? event.startDate,
            isAllDay: event.isAllDay,
            location: event.location ?? "",
            notes: event.notes ?? "",
            calendarID: event.calendar?.calendarIdentifier,
            attendees: (event.attendees ?? []).filter { !$0.isCurrentUser }.map(Self.person),
            recurrence: rule.flatMap(Self.rule(from:)),
            hasUnsupportedRecurrence: rule != nil && Self.rule(from: rule!) == nil,
            isRecurringSeries: event.hasRecurrenceRules
        )
    }

    public func create(_ draft: EventDraft) async throws {
        guard draft.attachments.isEmpty else {
            throw CalendarError.notAllowed(String(localized: "Файлы прикрепляются только ко встречам календаря Exchange: календарь macOS вложений не хранит"))
        }
        guard draft.attendees.isEmpty, draft.optionalAttendees.isEmpty else {
            throw CalendarError.notAllowed(String(localized: "Пригласить участников можно только во встречу календаря Exchange: календарь macOS не даёт их добавлять"))
        }
        let event = EKEvent(eventStore: store)
        event.calendar = try writableCalendar(draft.calendarID)
        apply(draft, to: event, withRecurrence: true)
        try store.save(event, span: .thisEvent, commit: true)
    }

    public func update(_ item: TimelineItem, to draft: EventDraft, scope: RecurrenceScope) async throws {
        guard let occurrence = occurrence(of: item) else { throw CalendarError.notFound }
        guard occurrence.calendar.allowsContentModifications else {
            throw CalendarError.notAllowed(String(localized: "Календарь «\(occurrence.calendar.title)» не разрешает правку"))
        }
        if let calendarID = draft.calendarID, calendarID != occurrence.calendar.calendarIdentifier {
            occurrence.calendar = try writableCalendar(calendarID)
        }
        guard occurrence.hasRecurrenceRules else {
            apply(draft, to: occurrence, withRecurrence: true)
            try store.save(occurrence, span: .futureEvents, commit: true)
            return
        }
        switch scope {
        case .thisEvent:
            // Отдельное вхождение правилом повтора не обладает.
            apply(draft, to: occurrence, withRecurrence: false)
            try store.save(occurrence, span: .thisEvent, commit: true)
        case .thisAndFollowing:
            apply(draft, to: occurrence, withRecurrence: !draft.hasUnsupportedRecurrence)
            try store.save(occurrence, span: .futureEvents, commit: true)
        case .all:
            // Вся серия правится через первое вхождение: время сдвигается
            // на столько же, на сколько его сдвинули у выбранного.
            guard let identifier = Self.eventIdentifier(from: item.id),
                  let first = store.event(withIdentifier: identifier) else { throw CalendarError.notFound }
            var shifted = draft
            shifted.start = first.startDate.addingTimeInterval(draft.start.timeIntervalSince(occurrence.startDate))
            shifted.end = shifted.start.addingTimeInterval(draft.duration)
            if first.calendar.calendarIdentifier != occurrence.calendar.calendarIdentifier {
                first.calendar = occurrence.calendar
            }
            apply(shifted, to: first, withRecurrence: !draft.hasUnsupportedRecurrence)
            try store.save(first, span: .futureEvents, commit: true)
        }
    }

    public func delete(_ item: TimelineItem, scope: RecurrenceScope) async throws {
        guard let occurrence = occurrence(of: item) else { throw CalendarError.notFound }
        guard occurrence.calendar.allowsContentModifications else {
            throw CalendarError.notAllowed(String(localized: "Календарь «\(occurrence.calendar.title)» не разрешает удаление"))
        }
        guard occurrence.hasRecurrenceRules else {
            try store.remove(occurrence, span: .thisEvent, commit: true)
            return
        }
        switch scope {
        case .thisEvent:
            try store.remove(occurrence, span: .thisEvent, commit: true)
        case .thisAndFollowing:
            try store.remove(occurrence, span: .futureEvents, commit: true)
        case .all:
            guard let identifier = Self.eventIdentifier(from: item.id),
                  let first = store.event(withIdentifier: identifier) else { throw CalendarError.notFound }
            try store.remove(first, span: .futureEvents, commit: true)
        }
    }

    /// Календарь macOS отвечать на приглашения не умеет: встреча просто
    /// удаляется из календаря.
    public func decline(_ item: TimelineItem) async throws {
        switch item.kind {
        case .event:
            try await delete(item, scope: .thisEvent)
        case .reminder:
            guard let reminder = reminder(of: item) else { throw CalendarError.notFound }
            try store.remove(reminder, commit: true)
        case .mail:
            break
        }
    }

    public func createReminder(_ draft: ReminderDraft) async throws {
        let reminder = EKReminder(eventStore: store)
        if let listID = draft.listID, let list = store.calendar(withIdentifier: listID) {
            reminder.calendar = list
        } else if let list = store.defaultCalendarForNewReminders() {
            reminder.calendar = list
        } else {
            throw CalendarError.notAllowed(String(localized: "Нет списка напоминаний — создайте его в «Напоминаниях»"))
        }
        reminder.title = draft.title
        reminder.notes = draft.notes.isEmpty ? nil : draft.notes
        if let due = draft.due {
            let fields: Set<Calendar.Component> = draft.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due)
            // Со временем — ещё и сигнал, иначе «Напоминания» промолчат.
            if draft.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
    }

    private func writableCalendar(_ id: String?) throws -> EKCalendar {
        if let id, let calendar = store.calendar(withIdentifier: id) {
            guard calendar.allowsContentModifications else {
                throw CalendarError.notAllowed(String(localized: "Календарь «\(calendar.title)» только для чтения"))
            }
            return calendar
        }
        guard let fallback = store.defaultCalendarForNewEvents else {
            throw CalendarError.notAllowed(String(localized: "Нет календаря для новых событий"))
        }
        return fallback
    }

    private func apply(_ draft: EventDraft, to event: EKEvent, withRecurrence: Bool) {
        event.title = draft.title.isEmpty ? String(localized: "Новая встреча") : draft.title
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        // Весь день: в черновике конец — следующая полночь (так ждёт Exchange),
        // а EventKit считает однодневным событие, которое кончается в тот же день.
        event.endDate = draft.isAllDay
            ? max(draft.start, draft.end.addingTimeInterval(-1))
            : max(draft.end, draft.start.addingTimeInterval(60))
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        if withRecurrence {
            event.recurrenceRules = draft.recurrence.map { [Self.ekRule(from: $0)] }
        }
    }

    nonisolated static func ekRule(from rule: RecurrenceRule) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let days = rule.frequency == .weekly && !rule.weekdays.isEmpty
            ? rule.weekdays.sorted().compactMap { EKWeekday(rawValue: $0).map(EKRecurrenceDayOfWeek.init) }
            : nil
        let end: EKRecurrenceEnd? = switch rule.end {
        case .never: nil
        case .until(let date): EKRecurrenceEnd(end: Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date)
        case .count(let count): EKRecurrenceEnd(occurrenceCount: count)
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: rule.interval, daysOfTheWeek: days,
                                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                daysOfTheYear: nil, setPositions: nil, end: end)
    }

    /// Правило EventKit в наше. Сложные («вторая среда месяца») — `nil`:
    /// их показывает и меняет только сам Календарь.
    nonisolated static func rule(from rule: EKRecurrenceRule) -> RecurrenceRule? {
        guard rule.daysOfTheMonth == nil, rule.monthsOfTheYear == nil, rule.weeksOfTheYear == nil,
              rule.daysOfTheYear == nil, rule.setPositions == nil else { return nil }
        let frequency: RecurrenceRule.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        if frequency != .weekly, rule.daysOfTheWeek != nil { return nil }
        if rule.daysOfTheWeek?.contains(where: { $0.weekNumber != 0 }) == true { return nil }
        let end: RecurrenceRule.End
        if let date = rule.recurrenceEnd?.endDate {
            end = .until(date)
        } else if let count = rule.recurrenceEnd?.occurrenceCount, count > 0 {
            end = .count(count)
        } else {
            end = .never
        }
        return RecurrenceRule(frequency: frequency, interval: rule.interval,
                              weekdays: Set(rule.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue } ?? []), end: end)
    }

    /// Нужное вхождение встречи.
    ///
    /// У повторяющегося события идентификатор один на весь ряд, и
    /// `event(withIdentifier:)` отдаёт первое вхождение. Сохранив правку
    /// в него, мы перенесли бы не ту встречу. Поэтому ищем по дню и сверяем
    /// начало — так же сделано в Trunook.
    private func occurrence(of item: TimelineItem) -> EKEvent? {
        guard let identifier = Self.eventIdentifier(from: item.id) else { return nil }
        guard let direct = store.event(withIdentifier: identifier) else { return nil }
        guard direct.hasRecurrenceRules else { return direct }
        let dayStart = Calendar.current.startOfDay(for: item.time)
        let predicate = store.predicateForEvents(
            withStart: dayStart, end: dayStart.addingTimeInterval(86_400), calendars: [direct.calendar])
        return store.events(matching: predicate).first { event in
            event.eventIdentifier == identifier && abs(event.startDate.timeIntervalSince(item.time)) < 60
        } ?? direct
    }

    private func reminder(of item: TimelineItem) -> EKReminder? {
        let identifier = String(item.id.dropFirst("reminder:".count))
        return store.calendarItem(withIdentifier: identifier) as? EKReminder
    }

    // MARK: - Приведение к TimelineItem

    static func eventIdentifier(from id: String) -> String? {
        guard id.hasPrefix("event:"), let at = id.lastIndex(of: "@") else { return nil }
        return String(id[id.index(id.startIndex, offsetBy: "event:".count)..<at])
    }

    static func item(from event: EKEvent) -> TimelineItem? {
        guard let start = event.startDate else { return nil }
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let attendees = (event.attendees ?? []).map { participant in
            Attendee(person: person(participant), response: response(participant.participantStatus),
                     isMe: participant.isCurrentUser)
        }
        let organizer = event.organizer
        // Своя встреча: без участников или я организатор. Чужую можно сдвинуть
        // только у себя — организатор и остальные об этом не узнают.
        let mine = organizer == nil || organizer?.isCurrentUser == true || attendees.isEmpty
        return TimelineItem(
            id: "event:\(identifier)@\(Int(start.timeIntervalSince1970))",
            title: event.title?.isEmpty == false ? event.title : String(localized: "Без названия"),
            time: start,
            end: event.endDate,
            isAllDay: event.isAllDay,
            color: rgb(event.calendar),
            detail: .event(EventInfo(
                calendarTitle: event.calendar?.title ?? "",
                location: event.location,
                notes: event.notes,
                link: MeetingLink.extract(url: event.url, location: event.location, notes: event.notes),
                organizer: organizer.map(person),
                attendees: attendees,
                canReschedule: mine && event.calendar?.allowsContentModifications == true,
                isRecurring: event.hasRecurrenceRules,
                recurrenceSummary: event.recurrenceRules?.first.flatMap(rule(from:))?.summary(start: start),
                calendarID: event.calendar?.calendarIdentifier,
                canEdit: event.calendar?.allowsContentModifications == true,
                canDecline: event.calendar?.allowsContentModifications == true,
                uid: event.calendarItemExternalIdentifier,
                isCancelled: event.status == .canceled
            ))
        )
    }

    static func item(from reminder: EKReminder) -> TimelineItem? {
        guard let components = reminder.dueDateComponents,
              let due = Calendar.current.date(from: components) else { return nil }
        let hasTime = components.hour != nil
        return TimelineItem(
            id: "reminder:\(reminder.calendarItemIdentifier)",
            title: reminder.title?.isEmpty == false ? reminder.title : String(localized: "Напоминание"),
            time: due,
            isAllDay: !hasTime,
            color: rgb(reminder.calendar),
            detail: .reminder(ReminderInfo(
                listTitle: reminder.calendar?.title ?? "",
                notes: reminder.notes,
                isCompleted: reminder.isCompleted,
                hasTime: hasTime
            ))
        )
    }

    static func person(_ participant: EKParticipant) -> Person {
        let url = participant.url.absoluteString
        let address = url.lowercased().hasPrefix("mailto:") ? String(url.dropFirst("mailto:".count)) : nil
        return Person(name: participant.name, address: address?.removingPercentEncoding ?? address)
    }

    private static func response(_ status: EKParticipantStatus) -> Attendee.Response {
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending: return .pending
        default: return .unknown
        }
    }

    private static func rgb(_ calendar: EKCalendar?) -> RGB? {
        guard let color = calendar?.color?.usingColorSpace(.sRGB) else { return nil }
        return RGB(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }
}
