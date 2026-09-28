import AppKit
import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Приглашения на встречу")
struct InvitationTests {
    private let outlook = """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        PRODID:Microsoft Exchange Server 2016\r
        BEGIN:VTIMEZONE\r
        TZID:Russian Standard Time\r
        BEGIN:STANDARD\r
        DTSTART:16010101T000000\r
        TZOFFSETFROM:+0300\r
        TZOFFSETTO:+0300\r
        END:STANDARD\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        ORGANIZER;CN="Козлов, Андрей":mailto:kozlov@company.test\r
        ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;CN=Я:mailto:me@company.test\r
        SUMMARY;LANGUAGE=ru-RU:Архитектурный комитет\\, этап 2\r
        DTSTART;TZID=Russian Standard Time:20260925T153000\r
        DTEND;TZID=Russian Standard Time:20260925T163000\r
        UID:040000008200E00074C5B7101A82E0080000000\r
         0ABCDEF\r
        SEQUENCE:2\r
        LOCATION;LANGUAGE=ru-RU:Переговорная «Москва»\r
        RRULE:FREQ=WEEKLY;BYDAY=FR\r
        END:VEVENT\r
        END:VCALENDAR\r
        """

    @Test func parsesOutlookInvitationWithWindowsZone() throws {
        // Пояс по имени Windows: без подсказки — по смещению из VTIMEZONE.
        let invitation = try #require(ICalendar.invitation(from: outlook, timeZone: { _ in nil }))
        #expect(invitation.method == .request)
        #expect(invitation.summary == "Архитектурный комитет, этап 2")
        #expect(invitation.uid == "040000008200E00074C5B7101A82E00800000000ABCDEF")
        #expect(invitation.sequence == 2)
        #expect(invitation.location == "Переговорная «Москва»")
        #expect(invitation.organizer == Person(name: "Козлов, Андрей", address: "kozlov@company.test"))
        #expect(invitation.isRecurring)
        // 15:30 МСК = 12:30 UTC.
        #expect(invitation.start == Date(timeIntervalSince1970: 1_790_339_400))
        #expect(invitation.end.timeIntervalSince(invitation.start) == 3600)
    }

    @Test func parsesGoogleUTCAndDuration() throws {
        let ics = "BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nDTSTART:20260925T123000Z\nDURATION:PT45M\nSUMMARY:Созвон\nUID:g-1\nEND:VEVENT\nEND:VCALENDAR"
        let invitation = try #require(ICalendar.invitation(from: ics))
        #expect(invitation.start == Date(timeIntervalSince1970: 1_790_339_400))
        #expect(invitation.end.timeIntervalSince(invitation.start) == 45 * 60)
    }

    @Test func conflictsIgnoreTheMeetingItself() throws {
        let invitation = try #require(ICalendar.invitation(from: outlook, timeZone: { _ in nil }))
        let busy = TimelineItem(id: "e1", title: "1:1", time: invitation.start.addingTimeInterval(-1800),
                                end: invitation.start.addingTimeInterval(1800), detail: .event(EventInfo(calendarTitle: "Работа")))
        let same = TimelineItem(id: "e2", title: invitation.summary, time: invitation.start, end: invitation.end,
                                detail: .event(EventInfo(calendarTitle: "Работа")))
        let later = TimelineItem(id: "e3", title: "Обед", time: invitation.end, end: invitation.end.addingTimeInterval(3600),
                                 detail: .event(EventInfo(calendarTitle: "Работа")))
        #expect(invitation.conflicts(in: [busy, same, later]).map(\.id) == ["e1"])
    }

    @Test func replyCarriesPartstatAndComment() throws {
        let invitation = try #require(ICalendar.invitation(from: outlook, timeZone: { _ in nil }))
        let reply = ICalendar.reply(to: invitation, response: .decline, me: Person(name: "Иван \"Я\"", address: "me@company.test"),
                                    comment: "В это время занят; можно в понедельник?")
        #expect(reply.contains("METHOD:REPLY"))
        #expect(reply.contains("ATTENDEE;PARTSTAT=DECLINED;CN=\"Иван Я\":mailto:me@company.test"))
        // Длинные строки сложены — сравниваем развёрнутыми.
        let unfolded = reply.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("COMMENT:В это время занят\\; можно в понедельник?"))
        #expect(reply.contains("UID:040000008200E00074C5B7101A82E00800000000ABCDEF"))
        // Строки не длиннее 75 байт (складываются).
        #expect(reply.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })

        let mail = try ICalendar.replyMail(to: invitation, response: .accept, me: Person(name: nil, address: "me@company.test"), comment: nil)
        #expect(mail.to.first?.address == "kozlov@company.test")
        #expect(mail.subject == "Принято: Архитектурный комитет, этап 2")
        #expect(mail.attachments.first?.mimeType.hasPrefix("text/calendar; method=REPLY") == true)
    }

    @Test func bodyKeepsCalendarPartOutOfText() {
        let raw = """
            Content-Type: multipart/alternative; boundary="b"\r
            \r
            --b\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Приглашаю на встречу\r
            --b\r
            Content-Type: text/calendar; charset=utf-8; method=REQUEST\r
            \r
            BEGIN:VCALENDAR\r
            METHOD:REQUEST\r
            END:VCALENDAR\r
            --b--\r
            """
        let body = ParsedMessage.body(of: Data(raw.utf8))
        #expect(body.text?.contains("Приглашаю") == true)
        #expect(body.calendar?.contains("METHOD:REQUEST") == true)
        #expect(body.attachments.isEmpty)
    }

    @Test func headersMarkInvitation() {
        let exchange = ParsedMessage(headerData: Data("Subject: Встреча\r\nContent-Class: urn:content-classes:calendarmessage\r\n\r\n".utf8))
        #expect(exchange.isInvitation)
        let plain = ParsedMessage(headerData: Data("Subject: Письмо\r\nContent-Type: text/plain\r\n\r\n".utf8))
        #expect(!plain.isInvitation)
    }
}

@Suite("Разделы по датам")
struct DateSectionTests {
    @Test func groupsByAge() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = Date(timeIntervalSince1970: 1_790_182_800) // 2026-09-23 20:00 МСК
        let day: TimeInterval = 86_400
        let ages: [(String, TimeInterval)] = [
            ("future", -3600), ("today", 3600), ("yesterday", day), ("d3", 3 * day), ("d3b", 3 * day + 60),
            ("d7", 7 * day), ("w2", 12 * day), ("m2", 45 * day),
        ]
        let items = ages.map { id, age in
            TimelineItem(id: id, title: id, time: now.addingTimeInterval(-age),
                         detail: .mail(MailInfo(accountID: "A", from: Person(name: "X", address: "x@test"))))
        }
        let groups = DateSections.group(items, time: \.time, now: now, calendar: calendar)
        let keys = groups.map { group -> String in
            switch group.section {
            case .today: "today"
            case .yesterday: "yesterday"
            case .day: "day"
            case .olderThanWeek: "7"
            case .olderThanMonth: "30"
            }
        }
        #expect(keys == ["today", "yesterday", "day", "day", "7", "30"])
        #expect(groups[0].items.map(\.id) == ["future", "today"])
        #expect(groups[2].items.map(\.id) == ["d3", "d3b"])
        #expect(groups[3].items.map(\.id) == ["d7"])
    }
}

@Suite("Оформление письма")
struct RichTextColorTests {
    @Test func colorsAndHighlightBecomeInlineStyles() {
        let text = NSMutableAttributedString(string: "Важно и обычно", attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                               .foregroundColor: NSColor.textColor])
        text.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0.85, green: 0.16, blue: 0.16, alpha: 1),
                          range: NSRange(location: 0, length: 5))
        text.addAttribute(.backgroundColor, value: NSColor(srgbRed: 1, green: 0.93, blue: 0.35, alpha: 1),
                          range: NSRange(location: 8, length: 6))
        let html = RichTextHTML.html(from: text)
        #expect(html.contains("<span style=\"color:#D92929\">Важно</span>"))
        #expect(html.contains("<span style=\"background-color:#FFED59\">обычно</span>"))
        // Системный цвет текста — не цвет: «color:#» только у «Важно».
        #expect(html.components(separatedBy: "\"color:#").count == 2)
    }

    @Test func tableBecomesHTMLTable() {
        let table = NSTextTable()
        table.numberOfColumns = 2
        let text = NSMutableAttributedString()
        for (row, column, value) in [(0, 0, "Этап"), (0, 1, "Срок"), (1, 0, "Второй"), (1, 1, "Ноябрь")] {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            text.append(NSAttributedString(string: value + "\n", attributes: [.paragraphStyle: style]))
        }
        text.append(NSAttributedString(string: "После таблицы"))
        let html = RichTextHTML.html(from: text)
        #expect(html.contains("<table"))
        #expect(html.components(separatedBy: "<tr>").count == 3)
        #expect(html.contains(">Этап</td>"))
        #expect(html.contains(">Ноябрь</td>"))
        #expect(html.hasSuffix("<div>После таблицы</div>"))
    }
}

@Suite("Отмена встречи")
struct MeetingCancellationTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ title: String, at time: Date, uid: String? = nil, recurring: Bool = false) -> TimelineItem {
        TimelineItem(id: "e", title: title, time: time, end: time.addingTimeInterval(1800),
                     detail: .event(EventInfo(calendarTitle: "Работа", isRecurring: recurring, uid: uid)))
    }

    private func cancel(uid: String = "U1", summary: String = "Созвон", recurring: Bool = false, occurrence: Date? = nil) -> Invitation {
        Invitation(method: .cancel, uid: uid, summary: summary, start: occurrence ?? start,
                   end: (occurrence ?? start).addingTimeInterval(1800), isRecurring: recurring, recurrenceID: occurrence)
    }

    @Test("По UID и времени; без UID — по названию без «Отменено:» и времени")
    func совпадение() {
        #expect(MeetingCancellation.matches(event("Созвон", at: start, uid: "u1"), cancel()))
        #expect(!MeetingCancellation.matches(event("Созвон", at: start.addingTimeInterval(86_400), uid: "U1"), cancel()))
        #expect(MeetingCancellation.matches(event("Отменено: Созвон", at: start), cancel()))
        #expect(MeetingCancellation.matches(event("Canceled: Созвон", at: start), cancel()))
        #expect(!MeetingCancellation.matches(event("Созвон", at: start.addingTimeInterval(3600)), cancel()))
        #expect(!MeetingCancellation.matches(event("Другое", at: start), cancel()))
        let request = Invitation(method: .request, uid: "U1", summary: "Созвон", start: start, end: start)
        #expect(!MeetingCancellation.matches(event("Созвон", at: start, uid: "U1"), request))
    }

    @Test("Отменена серия — удаляется вся; одно вхождение — только оно")
    func серия() {
        let series = cancel(recurring: true)
        let later = event("Созвон", at: start.addingTimeInterval(7 * 86_400), uid: "U1", recurring: true)
        #expect(series.isSeriesCancellation)
        #expect(MeetingCancellation.matches(later, series))
        #expect(MeetingCancellation.scope(for: series, event: later) == .all)
        let one = cancel(recurring: true, occurrence: start)
        #expect(!one.isSeriesCancellation)
        #expect(!MeetingCancellation.matches(later, one))
        #expect(MeetingCancellation.scope(for: one, event: event("Созвон", at: start, uid: "U1", recurring: true)) == .thisEvent)
    }

    @Test("RECURRENCE-ID разбирается")
    func вхождение() throws {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:U1
        RECURRENCE-ID:20260928T070000Z
        DTSTART:20260928T070000Z
        DTEND:20260928T073000Z
        RRULE:FREQ=WEEKLY
        SUMMARY:Созвон
        END:VEVENT
        END:VCALENDAR
        """
        let invitation = try #require(ICalendar.invitation(from: ics))
        #expect(invitation.method == .cancel)
        #expect(invitation.recurrenceID == ISO8601DateFormatter().date(from: "2026-09-28T07:00:00Z"))
        #expect(!invitation.isSeriesCancellation)
    }
}
