import Foundation
import TrudaybookCore

/// Календарь Exchange через EWS: встречи, приглашения, повторы, занятость
/// коллег и адресная книга. Тот же сервер и тот же пароль, что у почты.
public actor EWSCalendarService: SchedulingService {
    public nonisolated let account: MailAccount
    private let password: @Sendable () -> String?
    private let log: @Sendable (String) -> Void
    private var client: EWSClient?
    /// Подробности встреч (участники, описание) по Id — пока не сменился ChangeKey.
    private var details: [String: EWSCalendarItem] = [:]

    public init(account: MailAccount, password: @escaping @Sendable () -> String?,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.account = account
        self.password = password
        self.log = log
    }

    private func call(_ operation: String, _ body: String, withTimeZone: Bool = false) async throws -> XMLTreeNode {
        if client == nil {
            guard let url = account.ewsURL.flatMap(URL.init(string:)) else {
                throw MailNetworkError.server(String(localized: "не указан сервер Exchange"))
            }
            guard let password = password() else {
                throw MailNetworkError.authentication(String(localized: "пароль не найден в Связке ключей — введите его в настройках"))
            }
            client = EWSClient(url: url, user: account.imapUser, password: password, log: log)
        }
        do {
            return try await client!.call(operation, body: body,
                                          timeZone: withTimeZone ? WindowsTimeZone.name() : nil)
        } catch MailNetworkError.authentication(let reason) {
            client = nil
            throw MailNetworkError.authentication(reason)
        }
    }

    // MARK: - Чтение

    func items(from: Date, to: Date) async throws -> [EWSCalendarItem] {
        let listed = try EWSCalendarRequest.parseItems(
            try await call("FindItem", EWSCalendarRequest.calendarView(from: from, to: to)), find: true)
        let stale = listed.filter { item in details[item.id]?.changeKey != item.changeKey }.map(\.id)
        for batch in stale.chunked(into: 50) {
            let detailed = try EWSCalendarRequest.parseItems(
                try await call("GetItem", EWSCalendarRequest.details(batch)), find: false)
            for item in detailed { details[item.id] = item }
        }
        return listed.map { details[$0.id] ?? $0 }
    }

    func draft(for id: String, calendarID: String) async throws -> EventDraft {
        var item = details[id]
        if item?.hasDetails != true {
            item = try EWSCalendarRequest.parseItems(try await call("GetItem", EWSCalendarRequest.details([id])), find: false).first
        }
        guard let item, let start = item.start else { throw CalendarError.notFound }
        let me = account.email.lowercased()
        var draft = EventDraft(
            title: item.subject, start: start, end: item.end ?? start, isAllDay: item.isAllDay,
            location: item.location ?? "", notes: item.body ?? "", calendarID: calendarID,
            attendees: item.required.map(\.person).filter { $0.normalizedAddress != me },
            optionalAttendees: item.optional.map(\.person).filter { $0.normalizedAddress != me },
            isRecurringSeries: item.isRecurring
        )
        if item.isRecurring {
            let master = try await master(of: id)
            draft.recurrence = master.recurrence?.rule
            draft.hasUnsupportedRecurrence = master.recurrence != nil && master.recurrence?.rule == nil
        }
        return draft
    }

    // MARK: - Правка

    private func recurrence(_ rule: RecurrenceRule, start: Date) -> String {
        EWSCalendarRequest.recurrence(pattern: EWSCalendarRequest.pattern(rule, start: start),
                                      range: EWSCalendarRequest.range(start: EWSCalendarRequest.day(start), end: rule.end))
    }

    func create(_ draft: EventDraft, recurrenceXML: String? = nil) async throws {
        let series = recurrenceXML ?? draft.recurrence.map { recurrence($0, start: draft.start) }
        let guests = draft.attendees.count + draft.optionalAttendees.count
        let files = draft.attachments.filter { $0.data != nil }
        guard !files.isEmpty else {
            try EWSRequest.requireSuccess(try await call("CreateItem", EWSCalendarRequest.create(draft, recurrence: series),
                                                         withTimeZone: true))
            log("встреча создана\(guests == 0 ? "" : ", приглашений: \(guests)")")
            return
        }
        // С файлами — в три шага: сохранить молча, прикрепить, потом разослать.
        // Иначе приглашения ушли бы раньше файлов.
        let id = try EWSCalendarRequest.parseCreatedID(try await call(
            "CreateItem", EWSCalendarRequest.create(draft, recurrence: series, sendLater: true), withTimeZone: true))
        try await attach(files, to: id)
        if guests > 0 {
            try EWSRequest.requireSuccess(try await call(
                "UpdateItem", EWSCalendarRequest.sendInvitations(id: id, subject: draft.title), withTimeZone: true))
        }
        log("встреча создана, вложений: \(files.count)\(guests == 0 ? "" : ", приглашений: \(guests)")")
    }

    private func attach(_ files: [MailBody.Attachment], to id: String) async throws {
        guard !files.isEmpty else { return }
        try EWSCalendarRequest.requireAttached(try await call(
            "CreateAttachment", EWSCalendarRequest.createAttachments(parent: id, files: files)))
    }

    func move(id: String, start: Date, end: Date, notify: Bool) async throws {
        try EWSRequest.requireSuccess(try await call(
            "UpdateItem", EWSCalendarRequest.move(reference: EWSRequest.itemRef(id), start: start, end: end, notify: notify),
            withTimeZone: true))
    }

    private func master(of id: String) async throws -> (id: String, start: Date?, end: Date?, recurrence: EWSRecurrence?) {
        try EWSCalendarRequest.parseMaster(try await call("GetItem", EWSCalendarRequest.master(ofOccurrence: id)))
    }

    /// Первое ли это вхождение серии — тогда «это и следующие» равно «все».
    private func isFirst(_ occurrenceStart: Date, of series: EWSRecurrence) -> Bool {
        EWSCalendarRequest.day(occurrenceStart) <= series.rangeStart
    }

    /// Закончить серию накануне дня вхождения.
    private func endSeries(occurrenceID: String, before occurrenceStart: Date, series: EWSRecurrence, notify: Bool) async throws {
        let calendar = Calendar.current
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: occurrenceStart)) ?? occurrenceStart
        let recurrence = EWSCalendarRequest.recurrence(
            pattern: series.pattern.xml(),
            range: EWSCalendarRequest.range(start: series.rangeStart, end: .until(dayBefore)))
        try EWSRequest.requireSuccess(try await call(
            "UpdateItem", EWSCalendarRequest.setRecurrence(reference: EWSCalendarRequest.masterRef(occurrenceID),
                                                           recurrence: recurrence, notify: notify),
            withTimeZone: true))
    }

    func update(id: String, occurrenceStart: Date, isRecurring: Bool, draft: EventDraft,
                scope: RecurrenceScope, notify: Bool) async throws {
        guard isRecurring else {
            try await attach(draft.attachments.filter { $0.data != nil }, to: id)
            // Обычная встреча может стать повторяющейся.
            let series = draft.recurrence.map { recurrence($0, start: draft.start) }
            try EWSRequest.requireSuccess(try await call(
                "UpdateItem", EWSCalendarRequest.update(reference: EWSRequest.itemRef(id), draft: draft,
                                                        recurrence: series, notify: notify),
                withTimeZone: true))
            log("встреча изменена")
            return
        }
        switch scope {
        case .thisEvent:
            try await attach(draft.attachments.filter { $0.data != nil }, to: id)
            try EWSRequest.requireSuccess(try await call(
                "UpdateItem", EWSCalendarRequest.update(reference: EWSRequest.itemRef(id), draft: draft,
                                                        recurrence: nil, notify: notify),
                withTimeZone: true))

        case .all:
            if draft.recurrence == nil, !draft.hasUnsupportedRecurrence {
                // Повтор убрали: вместо серии — одна встреча.
                try await delete(id: id, occurrenceStart: occurrenceStart, isRecurring: true, scope: .all, notify: notify)
                try await create(draft)
                return
            }
            let master = try await master(of: id)
            try await attach(draft.attachments.filter { $0.data != nil }, to: master.id)
            // Время серии сдвигается на столько же, на сколько его сдвинули у вхождения.
            var shifted = draft
            let base = master.start ?? occurrenceStart
            shifted.start = base.addingTimeInterval(draft.start.timeIntervalSince(occurrenceStart))
            shifted.end = shifted.start.addingTimeInterval(draft.duration)
            let series = draft.hasUnsupportedRecurrence ? nil : draft.recurrence.map { recurrence($0, start: shifted.start) }
            try EWSRequest.requireSuccess(try await call(
                "UpdateItem", EWSCalendarRequest.update(reference: EWSCalendarRequest.masterRef(id), draft: shifted,
                                                        recurrence: series, notify: notify),
                withTimeZone: true))

        case .thisAndFollowing:
            let master = try await master(of: id)
            guard let series = master.recurrence else { throw CalendarError.notFound }
            if isFirst(occurrenceStart, of: series) {
                try await update(id: id, occurrenceStart: occurrenceStart, isRecurring: true, draft: draft, scope: .all, notify: notify)
                return
            }
            // Как в Outlook: старая серия кончается накануне, с этого дня — новая.
            try await endSeries(occurrenceID: id, before: occurrenceStart, series: series, notify: notify)
            guard draft.recurrence != nil || draft.hasUnsupportedRecurrence else {
                try await create(draft)
                return
            }
            let end = draft.recurrence?.end ?? series.rule?.end ?? .never
            let pattern = draft.recurrence.map { EWSCalendarRequest.pattern($0, start: draft.start) } ?? series.pattern.xml()
            try await create(draft, recurrenceXML: EWSCalendarRequest.recurrence(
                pattern: pattern, range: EWSCalendarRequest.range(start: EWSCalendarRequest.day(draft.start), end: end)))
        }
        log("встреча изменена: \(scope.rawValue)")
    }

    func delete(id: String, occurrenceStart: Date, isRecurring: Bool, scope: RecurrenceScope, notify: Bool) async throws {
        let reference: String
        switch (isRecurring, scope) {
        case (false, _), (true, .thisEvent):
            reference = EWSRequest.itemRef(id)
        case (true, .all):
            reference = EWSCalendarRequest.masterRef(id)
        case (true, .thisAndFollowing):
            let master = try await master(of: id)
            guard let series = master.recurrence else { throw CalendarError.notFound }
            if isFirst(occurrenceStart, of: series) {
                reference = EWSCalendarRequest.masterRef(id)
            } else {
                try await endSeries(occurrenceID: id, before: occurrenceStart, series: series, notify: notify)
                log("серия закончена накануне \(EWSCalendarRequest.day(occurrenceStart))")
                return
            }
        }
        try EWSRequest.requireSuccess(try await call("DeleteItem", EWSCalendarRequest.delete(reference: reference, notify: notify)))
        log("встреча удалена: \(scope.rawValue)")
    }

    /// Отказаться от встречи: организатор получит отказ.
    func decline(id: String) async throws {
        try EWSRequest.requireSuccess(try await call("CreateItem", EWSCalendarRequest.decline(id)))
        log("отказ от встречи отправлен")
    }

    // MARK: - Планирование

    public func availability(of addresses: [String], from: Date, to: Date) async throws -> [String: PersonAvailability] {
        var unique: [String] = []
        for address in addresses.map({ $0.lowercased() }) where !unique.contains(address) { unique.append(address) }
        guard !unique.isEmpty else { return [:] }
        let response = try await call("GetUserAvailability", EWSCalendarRequest.availability(unique, from: from, to: to))
        let answers = EWSCalendarRequest.parseAvailability(response)
        let failed = EWSCalendarRequest.availabilityCodes(response).filter { $0 != "NoError" }
        if !failed.isEmpty { log("занятость: не у всех — \(failed.joined(separator: ", "))") }
        var result: [String: PersonAvailability] = [:]
        for (index, address) in unique.enumerated() where index < answers.count {
            result[address] = answers[index]
        }
        return result
    }

    public func searchDirectory(_ text: String) async throws -> [Person] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        do {
            return EWSCalendarRequest.parseResolved(try await call("ResolveNames", EWSCalendarRequest.resolveNames(query)))
        } catch MailNetworkError.server {
            // «Никого не нашлось» Exchange сообщает ошибкой.
            return []
        }
    }
}

/// Календарь Exchange в общем календаре приложения.
@MainActor
public final class ExchangeCalendar: CalendarProvider {
    public let service: EWSCalendarService
    public var onChange: (() -> Void)?
    public var hiddenCalendarIDs: Set<String> = []
    /// Последняя ошибка чтения — показывается в настройках календарей.
    public private(set) var lastProblem: String?
    private let account: MailAccount
    public let calendarID: String

    public init(account: MailAccount, password: @escaping @Sendable () -> String?,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.account = account
        service = EWSCalendarService(account: account, password: password, log: log)
        calendarID = "ews-cal:\(account.id)"
    }

    public var accessProblem: String? { nil }

    public func calendars() -> [CalendarSourceInfo] {
        [CalendarSourceInfo(id: calendarID, title: String(localized: "Календарь"), color: Self.color, kind: .events,
                            group: "Exchange напрямую · \(account.email)", isWritable: true, supportsAttendees: true,
                            groupSymbol: "building.2.crop.circle")]
    }

    static let color = RGB(0.0, 0.45, 0.78)

    public func requestAccess() async {}

    public func items(from: Date, to: Date) async -> [TimelineItem] {
        guard !hiddenCalendarIDs.contains(calendarID) else { return [] }
        do {
            let items = try await service.items(from: from, to: to)
            lastProblem = nil
            return items.filter { !$0.isCancelled }.compactMap(item)
        } catch {
            lastProblem = MailAccounts.describe(error)
            return []
        }
    }

    public func overdueReminders(before date: Date) async -> [TimelineItem] { [] }

    private var prefix: String { "event:ews:\(account.id):" }

    private func remoteID(_ item: TimelineItem) throws -> String {
        guard item.id.hasPrefix(prefix) else { throw CalendarError.notFound }
        return String(item.id.dropFirst(prefix.count))
    }

    /// Рассылать ли участникам: только своей встрече с участниками.
    private func notify(_ item: TimelineItem) -> Bool {
        guard let info = item.event else { return false }
        return info.canEdit && info.attendees.contains { !$0.isMe }
    }

    public func move(_ item: TimelineItem, to start: Date) async throws {
        let duration = (item.end ?? item.time).timeIntervalSince(item.time)
        try await service.move(id: try remoteID(item), start: start, end: start.addingTimeInterval(duration), notify: notify(item))
        onChange?()
    }

    public func setCompleted(_ item: TimelineItem, _ done: Bool) async throws {}

    public func draft(for item: TimelineItem) async throws -> EventDraft {
        var draft = try await service.draft(for: try remoteID(item), calendarID: calendarID)
        // Вхождение серии — со своим временем, а не временем первого.
        draft.start = item.time
        draft.end = item.end ?? item.time
        return draft
    }

    public func create(_ draft: EventDraft) async throws {
        try await service.create(draft)
        onChange?()
    }

    public func update(_ item: TimelineItem, to draft: EventDraft, scope: RecurrenceScope) async throws {
        guard item.event?.canEdit == true else {
            throw CalendarError.notAllowed(String(localized: "Встречу назначил другой человек — изменить её может только организатор"))
        }
        let notify = notify(item) || !draft.attendees.isEmpty || !draft.optionalAttendees.isEmpty
        try await service.update(id: try remoteID(item), occurrenceStart: item.time,
                                 isRecurring: item.event?.isRecurring == true, draft: draft, scope: scope, notify: notify)
        onChange?()
    }

    public func delete(_ item: TimelineItem, scope: RecurrenceScope) async throws {
        try await service.delete(id: try remoteID(item), occurrenceStart: item.time,
                                 isRecurring: item.event?.isRecurring == true, scope: scope, notify: notify(item))
        onChange?()
    }

    public func createReminder(_ draft: ReminderDraft) async throws {
        throw CalendarError.notAllowed(String(localized: "Напоминания хранятся в «Напоминаниях» macOS"))
    }

    /// Своя встреча — отмена участникам (или просто удаление, если их нет),
    /// чужая — отказ организатору. У повторяющейся — только это вхождение.
    public func decline(_ item: TimelineItem) async throws {
        let id = try remoteID(item)
        if item.event?.canEdit == true {
            try await service.delete(id: id, occurrenceStart: item.time, isRecurring: item.event?.isRecurring == true,
                                     scope: .thisEvent, notify: notify(item))
        } else {
            try await service.decline(id: id)
        }
        onChange?()
    }

    public func owns(itemID: String) -> Bool { itemID.hasPrefix(prefix) }
    public func owns(calendarID: String) -> Bool { calendarID == self.calendarID }

    private func item(_ event: EWSCalendarItem) -> TimelineItem? {
        guard let start = event.start else { return nil }
        let me = account.email.lowercased()
        var attendees = (event.required + event.optional).map { guest in
            Attendee(person: guest.person, response: Self.response(guest.response), isMe: guest.person.normalizedAddress == me)
        }
        // Свой ответ Exchange хранит отдельно (`MyResponseType`) — в копии
        // списка участников у себя он часто «неизвестен». Ставим его в свою
        // строку, а если своей строки нет (позвали списком рассылки) — добавляем.
        if event.isMeeting, event.myResponse != .organizer {
            let mine = Self.response(event.myResponse == .unknown ? .noResponse : event.myResponse)
            if let index = attendees.firstIndex(where: \.isMe) {
                attendees[index].response = mine
            } else {
                attendees.append(Attendee(person: Person(name: account.displayName, address: account.email),
                                          response: mine, isMe: true))
            }
        }
        // Организатора Exchange в списке участников обычно не держит.
        if event.isMeeting, let organizer = event.organizer,
           !attendees.contains(where: { $0.person.normalizedAddress == organizer.normalizedAddress }) {
            attendees.insert(Attendee(person: organizer, response: .accepted,
                                      isMe: organizer.normalizedAddress == me), at: 0)
        }
        return TimelineItem(
            id: prefix + event.id,
            title: event.subject.isEmpty ? String(localized: "Без названия") : event.subject,
            time: start,
            end: event.end,
            isAllDay: event.isAllDay,
            color: Self.color,
            detail: .event(EventInfo(
                calendarTitle: "Exchange",
                location: event.location?.isEmpty == false ? event.location : nil,
                notes: event.body?.isEmpty == false ? event.body : nil,
                link: MeetingLink.extract(url: nil, location: event.location, notes: event.body),
                organizer: event.isMeeting ? event.organizer : nil,
                attendees: event.isMeeting ? attendees : [],
                canReschedule: event.isMine,
                isRecurring: event.isRecurring,
                calendarID: calendarID,
                canEdit: event.isMine
            ))
        )
    }

    private static func response(_ response: EWSCalendarItem.Response) -> Attendee.Response {
        switch response {
        case .accept, .organizer: return .accepted
        case .decline: return .declined
        case .tentative: return .tentative
        case .noResponse: return .pending
        case .unknown: return .unknown
        }
    }
}
