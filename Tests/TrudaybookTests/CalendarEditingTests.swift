import Foundation
import EventKit
import Testing
@testable import TrudaybookCore
@testable import TrudaybookMail

@Suite("Повторы и планирование")
struct RecurrenceTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 10, _ minute: Int = 0, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func summariesInRussian() {
        let start = date(23) // среда
        #expect(RecurrenceRule(frequency: .daily).summary(start: start, calendar: calendar) == "Каждый день")
        #expect(RecurrenceRule(frequency: .daily, interval: 5).summary(start: start, calendar: calendar) == "Каждые 5 дней")
        #expect(RecurrenceRule.weekdaysOnly.summary(start: start, calendar: calendar) == "По будням")
        #expect(RecurrenceRule(frequency: .weekly, weekdays: [4, 2]).summary(start: start, calendar: calendar)
                == "Каждую неделю: пн, ср")
        #expect(RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [1]).summary(start: start, calendar: calendar)
                == "Каждые 2 недели: вс")
        #expect(RecurrenceRule(frequency: .monthly, end: .count(3)).summary(start: start, calendar: calendar)
                == "Каждый месяц, 23 числа · 3 раза")
        #expect(RecurrenceRule(frequency: .yearly, end: .until(date(31, month: 12))).summary(start: start, calendar: calendar)
                == "Каждый год, 23 сентября · до 31 декабря")
    }

    @Test func eventKitRulesRoundTrip() {
        let rules = [
            RecurrenceRule(frequency: .daily, interval: 2),
            RecurrenceRule(frequency: .weekly, weekdays: [2, 4, 6], end: .count(10)),
            RecurrenceRule(frequency: .monthly),
            RecurrenceRule(frequency: .yearly),
        ]
        for rule in rules {
            #expect(EventKitCalendar.rule(from: EventKitCalendar.ekRule(from: rule)) == rule)
        }
        // «Вторая среда месяца» редактор не показывает — и не ломает.
        let complex = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1,
                                       daysOfTheWeek: [EKRecurrenceDayOfWeek(.wednesday, weekNumber: 2)],
                                       daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                       daysOfTheYear: nil, setPositions: nil, end: nil)
        #expect(EventKitCalendar.rule(from: complex) == nil)
    }

    @Test func firstFreeSlotSkipsBusyAndEvenings() {
        let busy: [[BusyInterval]] = [
            [BusyInterval(start: date(23, 9), end: date(23, 10, 30), kind: .busy)],
            [BusyInterval(start: date(23, 10, 30), end: date(23, 11), kind: .tentative),
             // «Работает в другом месте» — не помеха.
             BusyInterval(start: date(23, 11), end: date(23, 13), kind: .elsewhere)],
        ]
        let slot = SchedulingMath.firstFreeSlot(busy: busy, from: date(23, 8, 50), duration: 30 * 60, calendar: calendar)
        #expect(slot == date(23, 11))

        // После конца рабочего дня — утро следующего; пятница → понедельник.
        let evening = SchedulingMath.firstFreeSlot(busy: [], from: date(25, 18, 45), duration: 30 * 60, calendar: calendar)
        #expect(evening == date(28, 9))
    }
}

@Suite("Календарь Exchange")
struct EWSCalendarTests {
    private func body(_ xml: String) throws -> XMLTreeNode {
        try #require(try XMLTreeNode.parse(Data(xml.utf8)).child("Body")?.children.first)
    }

    static let calendarView = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <m:FindItemResponse xmlns:m="m" xmlns:t="t"><m:ResponseMessages><m:FindItemResponseMessage ResponseClass="Success">
        <m:ResponseCode>NoError</m:ResponseCode><m:RootFolder TotalItemsInView="1" IncludesLastItemInRange="true"><t:Items>
          <t:CalendarItem>
            <t:ItemId Id="OCC1=" ChangeKey="DwAA"/>
            <t:Subject>Планёрка</t:Subject>
            <t:Start>2026-09-23T06:30:00Z</t:Start><t:End>2026-09-23T06:45:00Z</t:End>
            <t:IsAllDayEvent>false</t:IsAllDayEvent>
            <t:Location>Переговорная «Байкал»</t:Location>
            <t:IsMeeting>true</t:IsMeeting><t:IsCancelled>false</t:IsCancelled><t:IsRecurring>false</t:IsRecurring>
            <t:CalendarItemType>Occurrence</t:CalendarItemType><t:MyResponseType>Organizer</t:MyResponseType>
            <t:Organizer><t:Mailbox><t:Name>Иван</t:Name><t:EmailAddress>me@company.test</t:EmailAddress></t:Mailbox></t:Organizer>
          </t:CalendarItem>
        </t:Items></m:RootFolder></m:FindItemResponseMessage></m:ResponseMessages></m:FindItemResponse></s:Body></s:Envelope>
        """

    @Test func occurrencesAreRecurringAndMine() throws {
        let items = try EWSCalendarRequest.parseItems(try body(Self.calendarView), find: true)
        let item = try #require(items.first)
        #expect(item.subject == "Планёрка")
        #expect(item.isRecurring)
        #expect(item.isMine)
        #expect(item.location == "Переговорная «Байкал»")
        #expect(item.start == ISO8601DateFormatter().date(from: "2026-09-23T06:30:00Z"))
    }

    @Test func recurrenceParsedAndKeptAsIs() throws {
        let master = """
            <s:Envelope xmlns:s="s"><s:Body><m:GetItemResponse xmlns:m="m" xmlns:t="t"><m:ResponseMessages>
            <m:GetItemResponseMessage ResponseClass="Success"><m:Items><t:CalendarItem>
            <t:ItemId Id="MASTER="/><t:Start>2026-09-01T06:30:00Z</t:Start><t:End>2026-09-01T06:45:00Z</t:End>
            <t:Recurrence><t:WeeklyRecurrence><t:Interval>1</t:Interval><t:DaysOfWeek>Monday Tuesday Wednesday Thursday Friday</t:DaysOfWeek>
            <t:FirstDayOfWeek>Monday</t:FirstDayOfWeek></t:WeeklyRecurrence>
            <t:NoEndRecurrence><t:StartDate>2026-09-01+03:00</t:StartDate></t:NoEndRecurrence></t:Recurrence>
            </t:CalendarItem></m:Items></m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body></s:Envelope>
            """
        let parsed = try EWSCalendarRequest.parseMaster(try body(master))
        #expect(parsed.id == "MASTER=")
        let recurrence = try #require(parsed.recurrence)
        #expect(recurrence.rule == .weekdaysOnly)
        #expect(recurrence.rangeStart == "2026-09-01")
        // Узор уходит обратно тем же XML — и ещё раз разбирается в то же правило.
        let again = try XMLTreeNode.parse(Data("<t:Recurrence xmlns:t=\"t\">\(recurrence.pattern.xml())<t:NoEndRecurrence><t:StartDate>2026-09-01</t:StartDate></t:NoEndRecurrence></t:Recurrence>".utf8))
        #expect(EWSCalendarRequest.parseRecurrence(again)?.rule == .weekdaysOnly)

        let relative = try XMLTreeNode.parse(Data("""
            <t:Recurrence xmlns:t="t"><t:RelativeMonthlyRecurrence><t:Interval>1</t:Interval><t:DaysOfWeek>Wednesday</t:DaysOfWeek>
            <t:DayOfWeekIndex>Second</t:DayOfWeekIndex></t:RelativeMonthlyRecurrence>
            <t:NumberedRecurrence><t:StartDate>2026-09-09</t:StartDate><t:NumberOfOccurrences>5</t:NumberOfOccurrences></t:NumberedRecurrence></t:Recurrence>
            """.utf8))
        let complex = try #require(EWSCalendarRequest.parseRecurrence(relative))
        #expect(complex.rule == nil)
        #expect(complex.pattern.name == "RelativeMonthlyRecurrence")
    }

    @Test func createAndUpdateAreWellFormed() throws {
        let start = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
        let draft = EventDraft(title: "Обзор & план", start: start, end: start.addingTimeInterval(3600),
                               location: "", notes: "Повестка <важно>",
                               attendees: [Person(name: "Анна", address: "anna@company.test")],
                               recurrence: RecurrenceRule(frequency: .weekly, weekdays: [4], end: .count(4)))
        let series = EWSCalendarRequest.recurrence(
            pattern: EWSCalendarRequest.pattern(draft.recurrence!, start: start),
            range: EWSCalendarRequest.range(start: "2026-09-23", end: .count(4)))
        let requests = [
            EWSCalendarRequest.create(draft, recurrence: series),
            EWSCalendarRequest.update(reference: EWSCalendarRequest.masterRef("OCC1="), draft: draft, recurrence: series, notify: true),
            EWSCalendarRequest.move(reference: EWSRequest.itemRef("OCC1="), start: start, end: start, notify: false),
            EWSCalendarRequest.delete(reference: EWSCalendarRequest.masterRef("OCC1="), notify: true),
            EWSCalendarRequest.calendarView(from: start, to: start),
            EWSCalendarRequest.details(["A=", "B="]),
            EWSCalendarRequest.master(ofOccurrence: "OCC1="),
            EWSCalendarRequest.availability(["a@company.test"], from: start, to: start.addingTimeInterval(86_400)),
            EWSCalendarRequest.resolveNames("Смир"),
        ]
        for request in requests {
            let envelope = try XMLTreeNode.parse(Data(EWSRequest.envelope(request, timeZone: "Russian Standard Time").utf8))
            #expect(envelope["Body"]?.children.count == 1)
        }
        let created = try XMLTreeNode.parse(Data(EWSRequest.envelope(requests[0]).utf8))
        let item = try #require(created.first("CalendarItem"))
        #expect(created.first("CreateItem")?.attributes["SendMeetingInvitations"] == "SendToAllAndSaveCopy")
        #expect(item.child("Subject")?.text == "Обзор & план")
        #expect(item.first("DaysOfWeek")?.text == "Wednesday")
        #expect(item.first("NumberOfOccurrences")?.text == "4")
        // Порядок полей CalendarItem по схеме Exchange: Subject … Start, End … Recurrence.
        let order = item.children.map(\.name)
        #expect(order.firstIndex(of: "Start")! < order.firstIndex(of: "End")!)
        #expect(order.firstIndex(of: "RequiredAttendees")! < order.firstIndex(of: "Recurrence")!)
        let context = try XMLTreeNode.parse(Data(EWSRequest.envelope(requests[0], timeZone: "Russian Standard Time").utf8))
        #expect(context.first("TimeZoneDefinition")?.attributes["Id"] == "Russian Standard Time")
    }

    @Test func availabilityAndDirectory() throws {
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        let response = """
            <s:Envelope xmlns:s="s"><s:Body><GetUserAvailabilityResponse xmlns="m">
            <FreeBusyResponseArray>
              <FreeBusyResponse><ResponseMessage ResponseClass="Success"><ResponseCode>NoError</ResponseCode></ResponseMessage>
                <FreeBusyView><FreeBusyViewType>Detailed</FreeBusyViewType><CalendarEventArray>
                  <CalendarEvent><StartTime>2026-09-23T10:00:00</StartTime><EndTime>2026-09-23T11:00:00</EndTime><BusyType>Busy</BusyType>
                    <CalendarEventDetails><Subject>Бюджет</Subject></CalendarEventDetails></CalendarEvent>
                  <CalendarEvent><StartTime>2026-09-23T12:00:00</StartTime><EndTime>2026-09-23T13:00:00</EndTime><BusyType>Free</BusyType></CalendarEvent>
                </CalendarEventArray>
                <WorkingHours><WorkingPeriodArray><WorkingPeriod><DayOfWeek>Monday Tuesday</DayOfWeek>
                  <StartTimeInMinutes>540</StartTimeInMinutes><EndTimeInMinutes>1080</EndTimeInMinutes></WorkingPeriod></WorkingPeriodArray></WorkingHours>
                </FreeBusyView></FreeBusyResponse>
              <FreeBusyResponse><ResponseMessage ResponseClass="Error"><ResponseCode>ErrorMailRecipientNotFound</ResponseCode></ResponseMessage></FreeBusyResponse>
            </FreeBusyResponseArray></GetUserAvailabilityResponse></s:Body></s:Envelope>
            """
        let answers = EWSCalendarRequest.parseAvailability(try body(response), zone: moscow)
        #expect(answers.count == 2)
        #expect(answers[0].busy.count == 1)
        #expect(answers[0].busy.first?.subject == "Бюджет")
        #expect(answers[0].busy.first?.start == ISO8601DateFormatter().date(from: "2026-09-23T07:00:00Z"))
        #expect(answers[0].workday == 540...1080)
        #expect(answers[1].problem == "не найден в адресной книге компании")

        let resolved = """
            <s:Envelope xmlns:s="s"><s:Body><m:ResolveNamesResponse xmlns:m="m" xmlns:t="t"><m:ResponseMessages>
            <m:ResolveNamesResponseMessage ResponseClass="Warning"><m:ResponseCode>ErrorNameResolutionMultipleResults</m:ResponseCode>
            <m:ResolutionSet TotalItemsInView="2">
              <t:Resolution><t:Mailbox><t:Name>Смирнова Ольга</t:Name><t:EmailAddress>o.smirnova@company.test</t:EmailAddress>
                <t:RoutingType>SMTP</t:RoutingType></t:Mailbox><t:Contact><t:DisplayName>Ольга Смирнова</t:DisplayName></t:Contact></t:Resolution>
              <t:Resolution><t:Mailbox><t:Name>Смирнов (уволен)</t:Name><t:EmailAddress>/O=COMPANY/CN=X</t:EmailAddress>
                <t:RoutingType>EX</t:RoutingType></t:Mailbox></t:Resolution>
            </m:ResolutionSet></m:ResolveNamesResponseMessage></m:ResponseMessages></m:ResolveNamesResponse></s:Body></s:Envelope>
            """
        let people = EWSCalendarRequest.parseResolved(try body(resolved))
        #expect(people == [Person(name: "Ольга Смирнова", address: "o.smirnova@company.test")])
    }

    @Test func windowsTimeZones() {
        #expect(WindowsTimeZone.name(for: TimeZone(identifier: "Europe/Moscow")!) == "Russian Standard Time")
        #expect(WindowsTimeZone.name(for: TimeZone(identifier: "Asia/Yekaterinburg")!) == "Ekaterinburg Standard Time")
    }
}

@Suite("Общий календарь")
@MainActor
struct CombinedCalendarTests {
    @Test func routesEditsToTheOwner() async throws {
        let now = Date(timeIntervalSince1970: 1_790_152_200) // 2026-09-23 12:30 МСК
        let demo = DemoCalendar(clock: { now })
        let combined = CombinedCalendar([demo])
        let dayStart = Calendar.current.startOfDay(for: now)
        let before = await combined.items(from: dayStart, to: dayStart.addingTimeInterval(86_400))
        let standup = try #require(before.first { $0.title == "Планёрка" })
        #expect(combined.owns(itemID: standup.id))

        let draft = try await combined.draft(for: standup)
        #expect(draft.isRecurringSeries)
        #expect(draft.recurrence == .weekdaysOnly)

        // «Только это событие» не трогает завтрашнюю планёрку.
        var renamed = draft
        renamed.title = "Планёрка (перенесена)"
        try await combined.update(standup, to: renamed, scope: .thisEvent)
        let today = await combined.items(from: dayStart, to: dayStart.addingTimeInterval(86_400))
        let tomorrow = await combined.items(from: dayStart.addingTimeInterval(86_400), to: dayStart.addingTimeInterval(2 * 86_400))
        #expect(today.contains { $0.title == "Планёрка (перенесена)" })
        #expect(tomorrow.contains { $0.title == "Планёрка" })

        // «Это и следующие» при удалении: сегодня и дальше — нет, вчера — есть.
        try await combined.delete(standup, scope: .thisAndFollowing)
        let later = await combined.items(from: dayStart, to: dayStart.addingTimeInterval(3 * 86_400))
        let yesterday = await combined.items(from: dayStart.addingTimeInterval(-86_400), to: dayStart)
        #expect(!later.contains { $0.title.hasPrefix("Планёрка") })
        #expect(yesterday.contains { $0.title == "Планёрка" })

        // Новая встреча попадает в свой день.
        try await combined.create(EventDraft(title: "Созвон", start: now.addingTimeInterval(3600),
                                             end: now.addingTimeInterval(5400), calendarID: "demo-cal-Работа"))
        let withNew = await combined.items(from: dayStart, to: dayStart.addingTimeInterval(86_400))
        #expect(withNew.contains { $0.title == "Созвон" })
    }
}

@Suite("Отклонить и ответить всем")
@MainActor
struct DeclineTests {
    private let now = Date(timeIntervalSince1970: 1_790_152_200) // 2026-09-23 12:30 МСК

    private func mail() -> TimelineItem {
        TimelineItem(id: "mail:A:1:INBOX", title: "Письмо", time: now,
                     detail: .mail(MailInfo(accountID: "A", from: Person(name: "Анна", address: "anna@x.ru"))))
    }

    @Test func availabilityByKind() {
        let letter = mail()
        #expect(StatusRules.availability(of: .decline, for: letter, local: nil, now: now).isEnabled == false)
        #expect(StatusRules.availability(of: .replyAll, for: letter, local: nil, now: now).isEnabled)
        #expect(!ItemAction.decline.applies(to: .mail))
        #expect(!ItemAction.replyAll.applies(to: .reminder))

        let past = TimelineItem(id: "event:x@1", title: "Было", time: now.addingTimeInterval(-7200),
                                end: now.addingTimeInterval(-3600), detail: .event(EventInfo(calendarTitle: "Работа")))
        #expect(StatusRules.availability(of: .decline, for: past, local: nil, now: now) == .disabled("Встреча уже прошла"))
        let readOnly = TimelineItem(id: "event:y@1", title: "ДР", time: now.addingTimeInterval(3600),
                                    detail: .event(EventInfo(calendarTitle: "Дни рождения", canDecline: false)))
        #expect(StatusRules.availability(of: .decline, for: readOnly, local: nil, now: now).isEnabled == false)
    }

    @Test func declineRemovesEventAndReminder() async throws {
        let demo = DemoCalendar(clock: { self.now })
        let combined = CombinedCalendar([demo])
        let dayStart = Calendar.current.startOfDay(for: now)
        let day = await combined.items(from: dayStart, to: dayStart.addingTimeInterval(86_400))
        let meeting = try #require(day.first { $0.title == "Ревью дизайна" })
        let reminder = try #require(day.first { $0.title == "Позвонить в банк" })
        try await combined.decline(meeting)
        try await combined.decline(reminder)
        let after = await combined.items(from: dayStart, to: dayStart.addingTimeInterval(86_400))
        #expect(!after.contains { $0.id == meeting.id || $0.id == reminder.id })
        #expect(after.contains { $0.title == "Обед" })
    }

    @Test func declineRequestIsWellFormed() throws {
        let envelope = try XMLTreeNode.parse(Data(EWSRequest.envelope(EWSCalendarRequest.decline("OCC&1=")).utf8))
        #expect(envelope.first("DeclineItem")?.child("ReferenceItemId")?.attributes["Id"] == "OCC&1=")
        #expect(envelope.first("CreateItem")?.attributes["MessageDisposition"] == "SendAndSaveCopy")
    }
}
