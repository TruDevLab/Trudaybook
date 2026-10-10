import Foundation

/// Несколько источников встреч как один: календарь macOS и календари Exchange.
///
/// Чтение — из всех сразу, правка — тому, чей элемент (`owns(itemID:)`),
/// создание — тому, чей выбран календарь (`owns(calendarID:)`).
@MainActor
public final class CombinedCalendar: CalendarProvider {
    public private(set) var sources: [CalendarProvider]

    public init(_ sources: [CalendarProvider]) {
        self.sources = sources
    }

    /// Подключили или отключили ящик Exchange — меняется и набор календарей.
    public func replaceSources(_ new: [CalendarProvider]) {
        sources = new
        for source in sources {
            source.onChange = onChange
            source.hiddenCalendarIDs = hiddenCalendarIDs
        }
    }

    public var accessProblem: String? {
        sources.compactMap(\.accessProblem).first
    }

    public var hiddenCalendarIDs: Set<String> = [] {
        didSet { for source in sources { source.hiddenCalendarIDs = hiddenCalendarIDs } }
    }

    public var onChange: (() -> Void)? {
        didSet { for source in sources { source.onChange = onChange } }
    }

    public func calendars() -> [CalendarSourceInfo] {
        sources.flatMap { $0.calendars() }
    }

    public func requestAccess() async {
        for source in sources { await source.requestAccess() }
    }

    public func items(from: Date, to: Date) async -> [TimelineItem] {
        var result: [TimelineItem] = []
        for source in sources { result += await source.items(from: from, to: to) }
        return result
    }

    public func overdueReminders(before date: Date) async -> [TimelineItem] {
        var result: [TimelineItem] = []
        for source in sources { result += await source.overdueReminders(before: date) }
        return result
    }

    public func move(_ item: TimelineItem, to start: Date) async throws {
        try await source(ofItem: item.id).move(item, to: start)
    }

    public func setCompleted(_ item: TimelineItem, _ done: Bool) async throws {
        try await source(ofItem: item.id).setCompleted(item, done)
    }

    public func draft(for item: TimelineItem) async throws -> EventDraft {
        try await source(ofItem: item.id).draft(for: item)
    }

    public func create(_ draft: EventDraft) async throws {
        let target = draft.calendarID.flatMap { id in sources.first { $0.owns(calendarID: id) } } ?? sources.first
        guard let target else { throw CalendarError.notAllowed(String(localized: "Нет календаря для новой встречи")) }
        try await target.create(draft)
    }

    public func update(_ item: TimelineItem, to draft: EventDraft, scope: RecurrenceScope) async throws {
        let from = try source(ofItem: item.id)
        // Перенос между календарями разных источников — это «создать там
        // и удалить здесь».
        if let target = draft.calendarID, !from.owns(calendarID: target),
           let other = sources.first(where: { $0.owns(calendarID: target) }) {
            try await other.create(draft)
            try await from.delete(item, scope: item.event?.isRecurring == true ? .all : .thisEvent)
            return
        }
        try await from.update(item, to: draft, scope: scope)
    }

    public func delete(_ item: TimelineItem, scope: RecurrenceScope) async throws {
        try await source(ofItem: item.id).delete(item, scope: scope)
    }

    public func decline(_ item: TimelineItem) async throws {
        try await source(ofItem: item.id).decline(item)
    }

    public func createReminder(_ draft: ReminderDraft) async throws {
        let target = draft.listID.flatMap { id in sources.first { $0.owns(calendarID: id) } } ?? sources.first
        guard let target else { throw CalendarError.notAllowed(String(localized: "Нет списка напоминаний")) }
        try await target.createReminder(draft)
    }

    public func owns(itemID: String) -> Bool {
        sources.contains { $0.owns(itemID: itemID) }
    }

    public func owns(calendarID: String) -> Bool {
        sources.contains { $0.owns(calendarID: calendarID) }
    }

    public func richDescription(of item: TimelineItem) async throws -> MailBody? {
        try await source(ofItem: item.id).richDescription(of: item)
    }

    private func source(ofItem id: String) throws -> CalendarProvider {
        guard let source = sources.first(where: { $0.owns(itemID: id) }) else { throw CalendarError.notFound }
        return source
    }
}
