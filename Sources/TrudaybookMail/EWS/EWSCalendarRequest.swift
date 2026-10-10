import Foundation
import TrudaybookCore

/// Встреча, как её описывает Exchange.
struct EWSCalendarItem: Sendable, Equatable {
    enum Response: String, Sendable {
        case unknown = "Unknown", organizer = "Organizer", tentative = "Tentative"
        case accept = "Accept", decline = "Decline", noResponse = "NoResponseReceived"
    }

    struct Guest: Sendable, Equatable {
        var person: Person
        var response: Response
    }

    var id: String
    var changeKey: String?
    var subject: String = ""
    var start: Date?
    var end: Date?
    var isAllDay = false
    var location: String?
    var organizer: Person?
    var isRecurring = false
    /// `Single`, `Occurrence`, `Exception`, `RecurringMaster`.
    var type: String?
    var myResponse: Response = .unknown
    var isCancelled = false
    var isMeeting = false
    /// UID из iCalendar — тот же, что в письме об отмене.
    var uid: String?
    var required: [Guest] = []
    var optional: [Guest] = []
    var body: String?
    var hasDetails = false

    /// Своя встреча: без участников или я её назначил.
    var isMine: Bool { !isMeeting || myResponse == .organizer }
}

/// Повтор серии Exchange: разобранное правило (если редактор его понимает)
/// и сам узор — чтобы сохранить непонятный узор нетронутым.
struct EWSRecurrence: Sendable, Equatable {
    var rule: RecurrenceRule?
    /// Узел узора: `WeeklyRecurrence`, `RelativeMonthlyRecurrence`…
    var pattern: XMLTreeNode
    var rangeStart: String
}

/// Часовой пояс Windows по поясу macOS: Exchange понимает только такие имена.
enum WindowsTimeZone {
    static let names: [String: String] = [
        "Europe/Moscow": "Russian Standard Time", "Europe/Simferopol": "Russian Standard Time",
        "Europe/Kaliningrad": "Kaliningrad Standard Time", "Europe/Samara": "Russia Time Zone 3",
        "Europe/Volgograd": "Volgograd Standard Time", "Europe/Saratov": "Saratov Standard Time",
        "Asia/Yekaterinburg": "Ekaterinburg Standard Time", "Asia/Omsk": "Omsk Standard Time",
        "Asia/Novosibirsk": "N. Central Asia Standard Time", "Asia/Krasnoyarsk": "North Asia Standard Time",
        "Asia/Irkutsk": "North Asia East Standard Time", "Asia/Yakutsk": "Yakutsk Standard Time",
        "Asia/Vladivostok": "Vladivostok Standard Time", "Asia/Magadan": "Magadan Standard Time",
        "Asia/Kamchatka": "Russia Time Zone 11", "Europe/Minsk": "Belarus Standard Time",
        "Europe/Kyiv": "FLE Standard Time", "Europe/Kiev": "FLE Standard Time",
        "Asia/Almaty": "Central Asia Standard Time", "Asia/Tashkent": "West Asia Standard Time",
        "Asia/Tbilisi": "Georgian Standard Time", "Asia/Yerevan": "Caucasus Standard Time",
        "Asia/Baku": "Azerbaijan Standard Time", "Asia/Dubai": "Arabian Standard Time",
        "Europe/Istanbul": "Turkey Standard Time", "Europe/London": "GMT Standard Time",
        "Europe/Berlin": "W. Europe Standard Time", "Europe/Paris": "Romance Standard Time",
        "America/New_York": "Eastern Standard Time", "UTC": "UTC", "GMT": "UTC",
    ]

    static func name(for zone: TimeZone = .current) -> String? {
        names[zone.identifier]
    }
}

/// Запросы календаря и планирования EWS и разбор ответов.
enum EWSCalendarRequest {
    /// Поля встречи для таймлайна — их отдаёт и поиск по календарю.
    static let listFields = [
        "item:Subject", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent", "calendar:Location",
        "calendar:Organizer", "calendar:IsRecurring", "calendar:CalendarItemType", "calendar:MyResponseType",
        "calendar:IsCancelled", "calendar:IsMeeting", "calendar:UID",
    ]

    static func fields(_ uris: [String]) -> String {
        uris.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
    }

    /// Встречи календаря за период — каждое вхождение повтора отдельно.
    static func calendarView(from: Date, to: Date) -> String {
        """
        <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties>\(fields(listFields))</t:AdditionalProperties></m:ItemShape>\
        <m:CalendarView MaxEntriesReturned="500" StartDate="\(EWSRequest.date(from))" EndDate="\(EWSRequest.date(to))"/>\
        <m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem>
        """
    }

    /// Участники и описание — их поиск по календарю не отдаёт.
    static func details(_ ids: [String]) -> String {
        """
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:BodyType>Text</t:BodyType>\
        <t:AdditionalProperties>\(fields(listFields + ["item:Body", "calendar:RequiredAttendees", "calendar:OptionalAttendees"]))\
        </t:AdditionalProperties></m:ItemShape><m:ItemIds>\(ids.map(EWSRequest.itemRef).joined())</m:ItemIds></m:GetItem>
        """
    }

    /// Описание встречи в HTML и список вложений — для правой панели. Список
    /// встреч берёт описание текстом (`details`): HTML с картинками всего
    /// календаря был бы мегабайтами на каждое обновление.
    static func richBody(_ id: String) -> String {
        """
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:BodyType>HTML</t:BodyType>\
        <t:AdditionalProperties><t:FieldURI FieldURI="item:Body"/><t:FieldURI FieldURI="item:Attachments"/>\
        </t:AdditionalProperties></m:ItemShape><m:ItemIds>\(EWSRequest.itemRef(id))</m:ItemIds></m:GetItem>
        """
    }

    /// Вложение встречи без содержимого — из `richBody`.
    struct AttachmentRef: Equatable {
        var id: String
        var name: String
        var contentType: String
        var contentID: String?
        var isInline: Bool
        var size: Int
    }

    static func parseRichBody(_ response: XMLTreeNode) throws -> (html: String?, attachments: [AttachmentRef]) {
        guard let message = try EWSRequest.responseMessages(response).first else {
            throw MailNetworkError.protocolError(String(localized: "пустой ответ"))
        }
        guard EWSRequest.isSuccess(message) else { throw EWSRequest.failure(message) }
        let html = message.first("Body")?.text
        // Вложенные письма (`ItemAttachment`) не берём — только файлы.
        let files = message.first("Attachments")?.all("FileAttachment") ?? []
        let refs = files.compactMap { file -> AttachmentRef? in
            guard let id = file.child("AttachmentId")?.attributes["Id"] else { return nil }
            return AttachmentRef(id: id, name: file.child("Name")?.text ?? "",
                                 contentType: file.child("ContentType")?.text ?? "application/octet-stream",
                                 contentID: file.child("ContentId")?.text,
                                 isInline: file.child("IsInline")?.text.lowercased() == "true",
                                 size: Int(file.child("Size")?.text ?? "") ?? 0)
        }
        return (html?.isEmpty == false ? html : nil, refs)
    }

    static func getAttachments(_ ids: [String]) -> String {
        let refs = ids.map { "<t:AttachmentId Id=\"\(XMLEscape.text($0))\"/>" }.joined()
        return "<m:GetAttachment><m:AttachmentIds>\(refs)</m:AttachmentIds></m:GetAttachment>"
    }

    /// Содержимое вложений по их Id. Не отдал сервер одно — остальные целы.
    static func parseAttachmentContents(_ response: XMLTreeNode) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for message in try EWSRequest.responseMessages(response) where EWSRequest.isSuccess(message) {
            guard let file = message.first("FileAttachment"),
                  let id = file.child("AttachmentId")?.attributes["Id"],
                  let content = file.child("Content")?.text,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { continue }
            result[id] = data
        }
        return result
    }

    /// Серия, к которой относится вхождение: её Id, начало и правило повтора.
    static func master(ofOccurrence id: String) -> String {
        """
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
        \(fields(["calendar:Start", "calendar:End", "calendar:Recurrence"]))</t:AdditionalProperties></m:ItemShape>\
        <m:ItemIds>\(masterRef(id))</m:ItemIds></m:GetItem>
        """
    }

    static func masterRef(_ occurrenceID: String) -> String {
        "<t:RecurringMasterItemId OccurrenceId=\"\(XMLEscape.text(occurrenceID))\"/>"
    }

    // MARK: - Создание и правка

    static func mailbox(_ person: Person) -> String {
        let name = person.name.map { "<t:Name>\(XMLEscape.text($0))</t:Name>" } ?? ""
        return "<t:Mailbox>\(name)<t:EmailAddress>\(XMLEscape.text(person.address ?? ""))</t:EmailAddress></t:Mailbox>"
    }

    static func attendees(_ people: [Person]) -> String {
        people.filter { $0.address != nil }.map { "<t:Attendee>\(mailbox($0))</t:Attendee>" }.joined()
    }

    /// Даты повтора — днём в поясе пользователя.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]

    /// Узор повтора по нашему правилу.
    static func pattern(_ rule: RecurrenceRule, start: Date, calendar: Calendar = .current) -> String {
        switch rule.frequency {
        case .daily:
            return "<t:DailyRecurrence><t:Interval>\(rule.interval)</t:Interval></t:DailyRecurrence>"
        case .weekly:
            let days = (rule.weekdays.isEmpty ? [calendar.component(.weekday, from: start)] : Array(rule.weekdays))
                .sorted().map { weekdayNames[($0 - 1) % 7] }.joined(separator: " ")
            return "<t:WeeklyRecurrence><t:Interval>\(rule.interval)</t:Interval><t:DaysOfWeek>\(days)</t:DaysOfWeek></t:WeeklyRecurrence>"
        case .monthly:
            return "<t:AbsoluteMonthlyRecurrence><t:Interval>\(rule.interval)</t:Interval>"
                + "<t:DayOfMonth>\(calendar.component(.day, from: start))</t:DayOfMonth></t:AbsoluteMonthlyRecurrence>"
        case .yearly:
            return "<t:AbsoluteYearlyRecurrence><t:DayOfMonth>\(calendar.component(.day, from: start))</t:DayOfMonth>"
                + "<t:Month>\(monthNames[calendar.component(.month, from: start) - 1])</t:Month></t:AbsoluteYearlyRecurrence>"
        }
    }

    /// Диапазон повтора: с какого дня и докуда.
    static func range(start: String, end: RecurrenceRule.End) -> String {
        switch end {
        case .never:
            return "<t:NoEndRecurrence><t:StartDate>\(start)</t:StartDate></t:NoEndRecurrence>"
        case .until(let date):
            return "<t:EndDateRecurrence><t:StartDate>\(start)</t:StartDate><t:EndDate>\(day(date))</t:EndDate></t:EndDateRecurrence>"
        case .count(let count):
            return "<t:NumberedRecurrence><t:StartDate>\(start)</t:StartDate><t:NumberOfOccurrences>\(count)</t:NumberOfOccurrences></t:NumberedRecurrence>"
        }
    }

    static func recurrence(pattern: String, range: String) -> String {
        "<t:Recurrence>\(pattern)\(range)</t:Recurrence>"
    }

    /// Новая встреча. С участниками Exchange сам разошлёт приглашения —
    /// если не `sendLater`: тогда встреча сохраняется молча (к ней ещё
    /// прикрепят файлы), а приглашения уйдут следующим запросом.
    static func create(_ draft: EventDraft, recurrence: String?, sendLater: Bool = false) -> String {
        let invite = draft.attendees.isEmpty && draft.optionalAttendees.isEmpty || sendLater ? "SendToNone" : "SendToAllAndSaveCopy"
        var item = "<t:Subject>\(XMLEscape.text(draft.title.isEmpty ? "Новая встреча" : draft.title))</t:Subject>"
        if !draft.notes.isEmpty { item += "<t:Body BodyType=\"Text\">\(XMLEscape.text(draft.notes))</t:Body>" }
        item += "<t:ReminderIsSet>\(draft.isAllDay ? "false" : "true")</t:ReminderIsSet>"
        item += "<t:ReminderMinutesBeforeStart>15</t:ReminderMinutesBeforeStart>"
        item += "<t:Start>\(EWSRequest.date(draft.start))</t:Start><t:End>\(EWSRequest.date(draft.end))</t:End>"
        item += "<t:IsAllDayEvent>\(draft.isAllDay)</t:IsAllDayEvent>"
        if !draft.location.isEmpty { item += "<t:Location>\(XMLEscape.text(draft.location))</t:Location>" }
        if !draft.attendees.isEmpty { item += "<t:RequiredAttendees>\(attendees(draft.attendees))</t:RequiredAttendees>" }
        if !draft.optionalAttendees.isEmpty { item += "<t:OptionalAttendees>\(attendees(draft.optionalAttendees))</t:OptionalAttendees>" }
        if let recurrence { item += recurrence }
        return """
            <m:CreateItem SendMeetingInvitations="\(invite)"><m:SavedItemFolderId>\
            <t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId>\
            <m:Items><t:CalendarItem>\(item)</t:CalendarItem></m:Items></m:CreateItem>
            """
    }

    private static func set(_ uri: String, _ value: String) -> String {
        "<t:SetItemField><t:FieldURI FieldURI=\"\(uri)\"/><t:CalendarItem>\(value)</t:CalendarItem></t:SetItemField>"
    }

    private static func remove(_ uri: String) -> String {
        "<t:DeleteItemField><t:FieldURI FieldURI=\"\(uri)\"/></t:DeleteItemField>"
    }

    /// Правка встречи, вхождения (`reference` — `ItemId`) или всей серии
    /// (`RecurringMasterItemId`). `recurrence` — только для серии.
    static func update(reference: String, draft: EventDraft, recurrence: String?, notify: Bool) -> String {
        var changes = set("item:Subject", "<t:Subject>\(XMLEscape.text(draft.title.isEmpty ? "Новая встреча" : draft.title))</t:Subject>")
        changes += set("item:Body", "<t:Body BodyType=\"Text\">\(XMLEscape.text(draft.notes))</t:Body>")
        changes += set("calendar:Start", "<t:Start>\(EWSRequest.date(draft.start))</t:Start>")
        changes += set("calendar:End", "<t:End>\(EWSRequest.date(draft.end))</t:End>")
        changes += set("calendar:IsAllDayEvent", "<t:IsAllDayEvent>\(draft.isAllDay)</t:IsAllDayEvent>")
        changes += draft.location.isEmpty
            ? remove("calendar:Location")
            : set("calendar:Location", "<t:Location>\(XMLEscape.text(draft.location))</t:Location>")
        changes += draft.attendees.isEmpty
            ? remove("calendar:RequiredAttendees")
            : set("calendar:RequiredAttendees", "<t:RequiredAttendees>\(attendees(draft.attendees))</t:RequiredAttendees>")
        changes += draft.optionalAttendees.isEmpty
            ? remove("calendar:OptionalAttendees")
            : set("calendar:OptionalAttendees", "<t:OptionalAttendees>\(attendees(draft.optionalAttendees))</t:OptionalAttendees>")
        if let recurrence { changes += set("calendar:Recurrence", recurrence) }
        return updateItem(reference: reference, changes: changes, notify: notify)
    }

    /// Перенос: только время.
    static func move(reference: String, start: Date, end: Date, notify: Bool) -> String {
        updateItem(reference: reference,
                   changes: set("calendar:Start", "<t:Start>\(EWSRequest.date(start))</t:Start>")
                       + set("calendar:End", "<t:End>\(EWSRequest.date(end))</t:End>"),
                   notify: notify)
    }

    /// Новый диапазон серии — чтобы закончить её раньше («это и следующие»).
    static func setRecurrence(reference: String, recurrence: String, notify: Bool) -> String {
        updateItem(reference: reference, changes: set("calendar:Recurrence", recurrence), notify: notify)
    }

    private static func updateItem(reference: String, changes: String, notify: Bool) -> String {
        """
        <m:UpdateItem ConflictResolution="AlwaysOverwrite" \
        SendMeetingInvitationsOrCancellations="\(notify ? "SendToAllAndSaveCopy" : "SendToNone")">\
        <m:ItemChanges><t:ItemChange>\(reference)<t:Updates>\(changes)</t:Updates></t:ItemChange></m:ItemChanges></m:UpdateItem>
        """
    }

    /// Прикрепить файлы к встрече (или письму) по её Id.
    static func createAttachments(parent: String, files: [MailBody.Attachment]) -> String {
        let items = files.compactMap { file -> String? in
            guard let data = file.data else { return nil }
            return "<t:FileAttachment><t:Name>\(XMLEscape.text(file.name))</t:Name>"
                + "<t:ContentType>\(XMLEscape.text(file.mimeType))</t:ContentType>"
                + "<t:Content>\(data.base64EncodedString())</t:Content></t:FileAttachment>"
        }.joined()
        return "<m:CreateAttachment><m:ParentItemId Id=\"\(XMLEscape.text(parent))\"/>"
            + "<m:Attachments>\(items)</m:Attachments></m:CreateAttachment>"
    }

    /// Разослать приглашения уже сохранённой встречи: Exchange шлёт их
    /// только вместе с правкой, поэтому правится тема — на ту же самую.
    static func sendInvitations(id: String, subject: String) -> String {
        updateItem(reference: EWSRequest.itemRef(id),
                   changes: set("item:Subject", "<t:Subject>\(XMLEscape.text(subject.isEmpty ? "Новая встреча" : subject))</t:Subject>"),
                   notify: true)
    }

    /// Id созданной встречи из ответа `CreateItem`.
    static func parseCreatedID(_ response: XMLTreeNode) throws -> String {
        guard let message = try EWSRequest.responseMessages(response).first else { throw MailNetworkError.server(String(localized: "пустой ответ")) }
        guard EWSRequest.isSuccess(message) else { throw EWSRequest.failure(message) }
        guard let id = message.first("ItemId")?.attributes["Id"] else { throw MailNetworkError.server(String(localized: "Exchange не вернул встречу")) }
        return id
    }

    /// Id встречи после `CreateAttachment` — у неё сменился ChangeKey,
    /// но Id прежний; достаточно проверить, что всё прикрепилось.
    static func requireAttached(_ response: XMLTreeNode) throws {
        try EWSRequest.requireSuccess(response)
    }

    /// Отказ организатору: Exchange отправит ответ и уберёт встречу из календаря.
    static func decline(_ id: String) -> String {
        "<m:CreateItem MessageDisposition=\"SendAndSaveCopy\"><m:Items>"
            + "<t:DeclineItem><t:ReferenceItemId Id=\"\(XMLEscape.text(id))\"/></t:DeclineItem></m:Items></m:CreateItem>"
    }

    static func delete(reference: String, notify: Bool) -> String {
        """
        <m:DeleteItem DeleteType="MoveToDeletedItems" \
        SendMeetingCancellations="\(notify ? "SendToAllAndSaveCopy" : "SendToNone")">\
        <m:ItemIds>\(reference)</m:ItemIds></m:DeleteItem>
        """
    }

    // MARK: - Планирование

    /// Смещение пояса для запроса занятости. Переход на летнее время
    /// не описываем (окно — сутки-двое, ошибка в час не страшна): у «летнего»
    /// времени сдвиг 0. Даты переходов при этом обязаны различаться —
    /// с одинаковыми Exchange отвечает «The specified time zone isn't valid».
    static func timeZoneElement(_ zone: TimeZone = .current, at date: Date = Date()) -> String {
        let bias = -zone.secondsFromGMT(for: date) / 60
        func rule(month: Int, time: String) -> String {
            "<t:Bias>0</t:Bias><t:Time>\(time)</t:Time><t:DayOrder>5</t:DayOrder><t:Month>\(month)</t:Month><t:DayOfWeek>Sunday</t:DayOfWeek>"
        }
        return "<t:TimeZone><t:Bias>\(bias)</t:Bias>"
            + "<t:StandardTime>\(rule(month: 10, time: "03:00:00"))</t:StandardTime>"
            + "<t:DaylightTime>\(rule(month: 3, time: "02:00:00"))</t:DaylightTime></t:TimeZone>"
    }

    static func localTime(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    static func parseLocalTime(_ text: String?, zone: TimeZone = .current) -> Date? {
        guard let text else { return nil }
        if let exact = EWSRequest.parseDate(text) { return exact }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(text.prefix(19)))
    }

    static func availability(_ addresses: [String], from: Date, to: Date, zone: TimeZone = .current) -> String {
        let boxes = addresses.map {
            "<t:MailboxData><t:Email><t:Address>\(XMLEscape.text($0))</t:Address></t:Email>"
                + "<t:AttendeeType>Required</t:AttendeeType><t:ExcludeConflicts>false</t:ExcludeConflicts></t:MailboxData>"
        }.joined()
        return """
            <m:GetUserAvailabilityRequest>\(timeZoneElement(zone, at: from))\
            <m:MailboxDataArray>\(boxes)</m:MailboxDataArray>\
            <t:FreeBusyViewOptions><t:TimeWindow><t:StartTime>\(localTime(from, zone: zone))</t:StartTime>\
            <t:EndTime>\(localTime(to, zone: zone))</t:EndTime></t:TimeWindow>\
            <t:MergedFreeBusyIntervalInMinutes>15</t:MergedFreeBusyIntervalInMinutes>\
            <t:RequestedView>Detailed</t:RequestedView></t:FreeBusyViewOptions></m:GetUserAvailabilityRequest>
            """
    }

    static func resolveNames(_ text: String) -> String {
        """
        <m:ResolveNames ReturnFullContactData="true" SearchScope="ActiveDirectory">\
        <m:UnresolvedEntry>\(XMLEscape.text(text))</m:UnresolvedEntry></m:ResolveNames>
        """
    }

    // MARK: - Разбор

    static func parseItems(_ response: XMLTreeNode, find: Bool) throws -> [EWSCalendarItem] {
        if find {
            let page = try EWSRequest.responseMessages(response).first
            guard let page, EWSRequest.isSuccess(page) else {
                throw page.map(EWSRequest.failure) ?? MailNetworkError.server(String(localized: "пустой ответ"))
            }
            return page.first("Items")?.children.compactMap { parseItem($0, detailed: false) } ?? []
        }
        return try EWSRequest.responseMessages(response).filter(EWSRequest.isSuccess).flatMap { message in
            message.child("Items")?.children.compactMap { parseItem($0, detailed: true) } ?? []
        }
    }

    static func parseItem(_ node: XMLTreeNode, detailed: Bool) -> EWSCalendarItem? {
        guard let idNode = node.child("ItemId"), let id = idNode.attributes["Id"] else { return nil }
        var item = EWSCalendarItem(id: id, changeKey: idNode.attributes["ChangeKey"])
        item.subject = node.child("Subject")?.text ?? ""
        item.start = EWSRequest.parseDate(node.child("Start")?.text)
        item.end = EWSRequest.parseDate(node.child("End")?.text)
        item.isAllDay = node.child("IsAllDayEvent")?.text == "true"
        item.location = node.child("Location")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        item.organizer = node["Organizer", "Mailbox"].flatMap(EWSRequest.parsePerson)
        item.isRecurring = node.child("IsRecurring")?.text == "true"
        item.type = node.child("CalendarItemType")?.text
        item.myResponse = node.child("MyResponseType").flatMap { EWSCalendarItem.Response(rawValue: $0.text) } ?? .unknown
        item.isCancelled = node.child("IsCancelled")?.text == "true"
        item.isMeeting = node.child("IsMeeting")?.text == "true"
        item.uid = node.child("UID")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.type == "Occurrence" || item.type == "Exception" { item.isRecurring = true }
        if detailed {
            item.hasDetails = true
            item.body = node.child("Body")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            item.required = guests(node.child("RequiredAttendees"))
            item.optional = guests(node.child("OptionalAttendees"))
        }
        return item
    }

    private static func guests(_ node: XMLTreeNode?) -> [EWSCalendarItem.Guest] {
        node?.all("Attendee").compactMap { attendee in
            guard let person = attendee.child("Mailbox").flatMap(EWSRequest.parsePerson) else { return nil }
            let response = attendee.child("ResponseType").flatMap { EWSCalendarItem.Response(rawValue: $0.text) } ?? .unknown
            return EWSCalendarItem.Guest(person: person, response: response)
        } ?? []
    }

    /// Серия: её Id, начало и повтор.
    static func parseMaster(_ response: XMLTreeNode) throws -> (id: String, start: Date?, end: Date?, recurrence: EWSRecurrence?) {
        guard let message = try EWSRequest.responseMessages(response).first else { throw MailNetworkError.server(String(localized: "пустой ответ")) }
        guard EWSRequest.isSuccess(message) else { throw EWSRequest.failure(message) }
        guard let node = message.child("Items")?.children.first, let id = node.child("ItemId")?.attributes["Id"] else {
            throw MailNetworkError.server(String(localized: "серия не найдена"))
        }
        return (id, EWSRequest.parseDate(node.child("Start")?.text), EWSRequest.parseDate(node.child("End")?.text),
                node.child("Recurrence").flatMap(parseRecurrence))
    }

    static func parseRecurrence(_ node: XMLTreeNode) -> EWSRecurrence? {
        let ranges = ["NoEndRecurrence", "EndDateRecurrence", "NumberedRecurrence"]
        guard let pattern = node.children.first(where: { !ranges.contains($0.name) }),
              let range = node.children.first(where: { ranges.contains($0.name) }) else { return nil }
        let start = String((range.child("StartDate")?.text ?? "").prefix(10))
        let end: RecurrenceRule.End
        switch range.name {
        case "EndDateRecurrence":
            end = parseDay(range.child("EndDate")?.text).map { .until($0) } ?? .never
        case "NumberedRecurrence":
            end = Int(range.child("NumberOfOccurrences")?.text ?? "").map { .count($0) } ?? .never
        default:
            end = .never
        }
        let interval = Int(pattern.child("Interval")?.text ?? "") ?? 1
        let rule: RecurrenceRule?
        switch pattern.name {
        case "DailyRecurrence":
            rule = RecurrenceRule(frequency: .daily, interval: interval, end: end)
        case "WeeklyRecurrence":
            let names = (pattern.child("DaysOfWeek")?.text ?? "").split(separator: " ").map(String.init)
            let days = Set(names.compactMap { name in weekdayNames.firstIndex(of: name).map { $0 + 1 } })
            rule = days.isEmpty ? nil : RecurrenceRule(frequency: .weekly, interval: interval, weekdays: days, end: end)
        case "AbsoluteMonthlyRecurrence":
            rule = RecurrenceRule(frequency: .monthly, interval: interval, end: end)
        case "AbsoluteYearlyRecurrence":
            rule = RecurrenceRule(frequency: .yearly, end: end)
        default:
            // «Вторая среда месяца» и подобное — редактор такие не показывает.
            rule = nil
        }
        return EWSRecurrence(rule: rule, pattern: pattern, rangeStart: start)
    }

    static func parseDay(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Занятость по порядку запрошенных адресов.
    /// Коды ответов по каждому адресу — для журнала.
    static func availabilityCodes(_ response: XMLTreeNode) -> [String] {
        (response.child("FreeBusyResponseArray")?.all("FreeBusyResponse") ?? []).map {
            $0["ResponseMessage", "ResponseCode"]?.text ?? "?"
        }
    }

    static func parseAvailability(_ response: XMLTreeNode, zone: TimeZone = .current) -> [PersonAvailability] {
        let answers = response.child("FreeBusyResponseArray")?.all("FreeBusyResponse") ?? []
        return answers.map { answer in
            if let message = answer.child("ResponseMessage"), message.attributes["ResponseClass"] == "Error" {
                let code = message.child("ResponseCode")?.text ?? ""
                let problem = code == "ErrorMailRecipientNotFound"
                    ? String(localized: "не найден в адресной книге компании")
                    : String(localized: "занятость недоступна")
                return PersonAvailability(problem: problem)
            }
            guard let view = answer.child("FreeBusyView") else { return PersonAvailability(problem: String(localized: "занятость недоступна")) }
            if view.child("FreeBusyViewType")?.text == "None" {
                return PersonAvailability(problem: String(localized: "календарь закрыт"))
            }
            let busy = view.child("CalendarEventArray")?.all("CalendarEvent").compactMap { event -> BusyInterval? in
                guard let start = parseLocalTime(event.child("StartTime")?.text, zone: zone),
                      let end = parseLocalTime(event.child("EndTime")?.text, zone: zone) else { return nil }
                let kind: BusyInterval.Kind?
                switch event.child("BusyType")?.text {
                case "Busy": kind = .busy
                case "Tentative": kind = .tentative
                case "OOF": kind = .away
                case "WorkingElsewhere": kind = .elsewhere
                default: kind = nil
                }
                guard let kind else { return nil }
                let subject = event["CalendarEventDetails", "Subject"]?.text
                return BusyInterval(start: start, end: end, kind: kind, subject: subject?.isEmpty == false ? subject : nil)
            } ?? []
            let periods = view["WorkingHours", "WorkingPeriodArray"]?.all("WorkingPeriod") ?? []
            let workday = periods.first.flatMap { period -> ClosedRange<Int>? in
                guard let from = Int(period.child("StartTimeInMinutes")?.text ?? ""),
                      let to = Int(period.child("EndTimeInMinutes")?.text ?? ""), from < to else { return nil }
                return from...to
            }
            return PersonAvailability(busy: busy, workday: workday)
        }
    }

    /// Найденные в адресной книге. Внутренние адреса Exchange (`/O=…`)
    /// без почтового адреса отбрасываются: пригласить по ним нельзя.
    static func parseResolved(_ response: XMLTreeNode) -> [Person] {
        let messages = response.child("ResponseMessages")?.children ?? []
        return messages.flatMap { message in
            message.child("ResolutionSet")?.all("Resolution").compactMap { resolution -> Person? in
                guard let mailbox = resolution.child("Mailbox"),
                      let person = EWSRequest.parsePerson(mailbox), person.address != nil else { return nil }
                let name = resolution["Contact", "DisplayName"]?.text ?? person.name
                return Person(name: name?.isEmpty == false ? name : person.name, address: person.address)
            } ?? []
        }
    }
}

extension XMLTreeNode {
    /// Узел обратно в XML — с приставкой `t:`: так в запрос возвращается
    /// повтор, который мы прочитали, но не разобрали.
    func xml(prefix: String = "t") -> String {
        let attributes = self.attributes.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(XMLEscape.text($0.value))\"" }.joined()
        let inner = children.isEmpty ? XMLEscape.text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                                      : children.map { $0.xml(prefix: prefix) }.joined()
        return "<\(prefix):\(name)\(attributes)>\(inner)</\(prefix):\(name)>"
    }
}

/// Пояс по имени из приглашения: имя IANA («Europe/Moscow») или Windows
/// («Russian Standard Time» — так пишут Outlook и Exchange).
public enum MailTimeZones {
    public static func zone(named name: String) -> TimeZone? {
        if let zone = TimeZone(identifier: name) { return zone }
        let reversed = WindowsTimeZone.names.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }
        return reversed.flatMap { TimeZone(identifier: $0.key) }
    }
}
