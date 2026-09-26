import Foundation
import Testing
@testable import TrudaybookCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func letter(_ id: String, from address: String, minutesAgo: Double = 10) -> TimelineItem {
    TimelineItem(id: id, title: "Письмо", time: now.addingTimeInterval(-minutesAgo * 60),
                 detail: .mail(MailInfo(accountID: "a", from: Person(name: nil, address: address))))
}

private func meeting(_ id: String = "event:1", inMinutes: Double, minutes: Double = 30, allDay: Bool = false,
                     organizer: String? = nil, attendees: [String] = [], me: String? = nil) -> TimelineItem {
    let start = now.addingTimeInterval(inMinutes * 60)
    var people = attendees.map { Attendee(person: Person(name: nil, address: $0), response: .accepted) }
    if let me { people.append(Attendee(person: Person(name: nil, address: me), response: .accepted, isMe: true)) }
    return TimelineItem(id: "\(id)@\(Int(start.timeIntervalSince1970))", title: "Встреча", time: start,
                        end: start.addingTimeInterval(minutes * 60), isAllDay: allDay,
                        detail: .event(EventInfo(calendarTitle: "Работа",
                                                 organizer: organizer.map { Person(name: nil, address: $0) },
                                                 attendees: people)))
}

@Suite struct TrunookRulesTests {
    @Test func meetingIsDueInsideTheLeadWindowOnce() {
        let soon = meeting(inMinutes: 4)
        let later = meeting("event:2", inMinutes: 20)
        let started = meeting("event:3", inMinutes: -1)
        let allDay = meeting("event:4", inMinutes: 3, allDay: true)
        let due = TrunookRules.meetingsDue([later, started, allDay, soon], now: now, lead: 300, announced: [])
        #expect(due.map(\.id) == [soon.id])
        #expect(TrunookRules.meetingsDue([soon], now: now, lead: 300, announced: [soon.id]).isEmpty)
    }

    @Test func lettersFromParticipantsSkipMeAndStrangers() {
        let event = meeting(inMinutes: 5, organizer: "Boss@Example.com", attendees: ["anna@example.com"],
                            me: "me@example.com")
        let list = [
            letter("mail:a:1", from: "anna@example.com", minutesAgo: 30),
            letter("mail:a:2", from: "boss@example.com", minutesAgo: 5),
            letter("mail:a:3", from: "me@example.com"),
            letter("mail:a:4", from: "someone@else.com"),
        ]
        let found = TrunookRules.letters(from: event, in: list)
        #expect(found.map(\.id) == ["mail:a:2", "mail:a:1"])
    }

    @Test func trunookSeesOnlyMacCalendars() {
        #expect(TrunookRules.trunookSeesItself(meeting(inMinutes: 1)))
        #expect(!TrunookRules.trunookSeesItself(meeting("event:ews:acc:X", inMinutes: 1)))
        #expect(!TrunookRules.trunookSeesItself(meeting("event:demo-1", inMinutes: 1)))
    }

    @Test func snoozeReturnsBetweenChecks() {
        let states: [String: LocalState] = [
            "mail:a:1": LocalState(snoozedUntil: now.addingTimeInterval(-10)),
            "mail:a:2": LocalState(snoozedUntil: now.addingTimeInterval(-100)),
            "mail:a:3": LocalState(snoozedUntil: now.addingTimeInterval(60)),
            "mail:a:4": LocalState(snoozedUntil: now.addingTimeInterval(-10), doneAt: now),
            "event:1": LocalState(snoozedUntil: now.addingTimeInterval(-10)),
        ]
        let back = TrunookRules.returnedSnoozes(states, since: now.addingTimeInterval(-30), now: now)
        #expect(back == ["mail:a:1"])
    }

    @Test func invitationConflictsIgnoreItselfAndAllDay() {
        let start = now.addingTimeInterval(3600), end = start.addingTimeInterval(3600)
        let overlap = meeting("event:1", inMinutes: 90)
        let before = meeting("event:2", inMinutes: 20, minutes: 40)
        let same = TimelineItem(id: "event:3", title: "Архкомитет", time: start, end: end,
                                detail: .event(EventInfo(calendarTitle: "Работа")))
        let allDay = meeting("event:4", inMinutes: 60, allDay: true)
        let found = TrunookRules.conflicts(start: start, end: end, with: [overlap, before, same, allDay],
                                           ignoring: "Архкомитет")
        #expect(found.map(\.id) == [overlap.id])
    }

    @Test func celebrationOnlyWhenListEmptiesLive() {
        #expect(TrunookRules.inboxJustCleared(previous: 3, current: 0, lastCelebration: nil, now: now))
        #expect(!TrunookRules.inboxJustCleared(previous: nil, current: 0, lastCelebration: nil, now: now))
        #expect(!TrunookRules.inboxJustCleared(previous: 0, current: 0, lastCelebration: nil, now: now))
        #expect(!TrunookRules.inboxJustCleared(previous: 2, current: 1, lastCelebration: nil, now: now))
        #expect(!TrunookRules.inboxJustCleared(previous: 1, current: 0, lastCelebration: now.addingTimeInterval(-60), now: now))
        #expect(TrunookRules.inboxJustCleared(previous: 1, current: 0, lastCelebration: now.addingTimeInterval(-7200), now: now))
    }
}

@Suite struct TrunookStateTests {
    private func mail(_ id: String, minutesAgo: Double, title: String = "Тема") -> TimelineItem {
        TimelineItem(id: id, title: title, time: now.addingTimeInterval(-minutesAgo * 60),
                     detail: .mail(MailInfo(accountID: "a", from: Person(name: "Анна", address: "anna@example.com"))))
    }

    @Test func topLetterPrefersImportantThenRecent() {
        let old = mail("mail:a:1", minutesAgo: 90, title: "Важное")
        let fresh = mail("mail:a:2", minutesAgo: 5, title: "Свежее")
        let high: Set<String> = ["mail:a:1"]
        let state = TrunookState.make(unresolved: [fresh, old], today: [old, fresh], updated: now, subjects: true,
                                      priority: { high.contains($0.id) ? .high : .none }, done: { _ in false })
        #expect(state.unresolved == 2)
        #expect(state.important == 1)
        #expect(state.top?.title == "Важное")
        #expect(state.marks.map(\.important) == [true, false])
        let plain = TrunookState.make(unresolved: [fresh, old], today: [], updated: now, subjects: true,
                                      priority: { _ in .none }, done: { _ in false })
        #expect(plain.top?.title == "Свежее")
    }

    @Test func subjectsStayHomeWhenNotAllowed() throws {
        let state = TrunookState.make(unresolved: [mail("mail:a:1", minutesAgo: 1)], today: [], updated: now,
                                      subjects: false, priority: { _ in .none }, done: { _ in false })
        #expect(state.top == nil)
        let text = String(decoding: try state.encoded(), as: UTF8.self)
        #expect(!text.contains("anna@example.com"))
        #expect(!text.contains("Тема"))
    }

    @Test func sameContentIgnoresTimestamp() {
        let a = TrunookState.make(unresolved: [], today: [], updated: now, subjects: true,
                                  priority: { _ in .none }, done: { _ in false })
        var b = a
        b.updated = now.addingTimeInterval(30)
        #expect(a.sameContent(as: b))
        b.unresolved = 1
        #expect(!a.sameContent(as: b))
    }

    @Test func focusNeedsAFutureDeadline() {
        #expect(TrunookFocus(focus: true, until: now.addingTimeInterval(600)).isActive(at: now))
        #expect(!TrunookFocus(focus: true, until: nil).isActive(at: now))
        #expect(!TrunookFocus(focus: true, until: now.addingTimeInterval(-1)).isActive(at: now))
        #expect(!TrunookFocus(focus: false, until: now.addingTimeInterval(600)).isActive(at: now))
        #expect(!TrunookFocus(focus: true, until: now.addingTimeInterval(86_400)).isActive(at: now))
        let json = Data(#"{"focus":true,"until":"2026-09-25T10:25:00Z"}"#.utf8)
        #expect(TrunookFocus.decode(json)?.until != nil)
    }
}

@Suite struct TrunookCommandTests {
    private func mail(_ id: String, from name: String, title: String, minutesAgo: Double = 10) -> TimelineItem {
        TimelineItem(id: id, title: title, time: now.addingTimeInterval(-minutesAgo * 60),
                     detail: .mail(MailInfo(accountID: "a", from: Person(name: name, address: "\(id.suffix(1))@example.com"),
                                            snippet: "Начало текста")))
    }

    @Test func parsesOnlyKnownActions() throws {
        #expect(try TrunookCommand.parse(["action": "done", "letter": "mail:a:1"]).get() == .done(letter: "mail:a:1"))
        #expect(try TrunookCommand.parse(["action": "priority", "letter": "Козлов", "level": "HIGH"]).get()
                == .priority(letter: "Козлов", level: .high))
        #expect(try TrunookCommand.parse(["action": "snooze", "letter": "x", "until": "2026-09-26T09:00:00Z"]).get()
                == .snooze(letter: "x", until: ISO8601DateFormatter().date(from: "2026-09-26T09:00:00Z")!))
        #expect(try TrunookCommand.parse(["action": "list", "limit": 500]).get() == .list(from: nil, importantOnly: false, limit: 30))
        // Отправки нет в списке — и не появится случайно.
        #expect(TrunookCommand.parse(["action": "send", "letter": "x"]) == .failure(.unknownAction("send")))
        #expect(TrunookCommand.parse(["action": "delete", "letter": "x"]) == .failure(.unknownAction("delete")))
        #expect(TrunookCommand.parse(["action": "done"]) == .failure(.missing("letter")))
        #expect(TrunookCommand.parse(["action": "snooze", "letter": "x", "until": "завтра"]) == .failure(.badDate))
        #expect(TrunookCommand.parse(["action": "priority", "letter": "x", "level": "urgent"]) == .failure(.badLevel("urgent")))
        #expect(TrunookCommand.parse(["action": "draft", "letter": "x", "text": "   "]) == .failure(.missing("text")))
    }

    @Test func resolvesLettersByWordsNotGuessing() {
        let a = mail("mail:a:1", from: "Андрей Козлов", title: "Договор: правки юристов", minutesAgo: 30)
        let b = mail("mail:a:2", from: "Андрей Козлов", title: "Обед в пятницу", minutesAgo: 5)
        let c = mail("mail:a:3", from: "Анна Смирнова", title: "Договор аренды")
        #expect(TrunookCommand.resolve("mail:a:3", in: [a, b, c]) == .found(c))
        #expect(TrunookCommand.resolve("Козлов договор", in: [a, b, c]) == .found(a))
        #expect(TrunookCommand.resolve("козлов", in: [a, b, c]) == .ambiguous([b, a]))
        #expect(TrunookCommand.resolve("Петров", in: [a, b, c]) == .none)
        #expect(TrunookCommand.resolve("а", in: [a, b, c]) == .none)
    }

    @Test func listingFiltersBySenderAndImportance() {
        let a = mail("mail:a:1", from: "Андрей Козлов", title: "Договор", minutesAgo: 30)
        let b = mail("mail:a:2", from: "Анна Смирнова", title: "Отчёт", minutesAgo: 5)
        let list = TrunookCommand.listing([a, b], from: nil, importantOnly: false, limit: 10, priority: { _ in .none })
        #expect(list.map { $0["id"] as? String } == ["mail:a:2", "mail:a:1"])
        let kozlov = TrunookCommand.listing([a, b], from: "козлов", importantOnly: false, limit: 10, priority: { _ in .none })
        #expect(kozlov.count == 1)
        let important = TrunookCommand.listing([a, b], from: nil, importantOnly: true, limit: 10,
                                               priority: { $0.id == "mail:a:1" ? .high : .none })
        #expect(important.map { $0["id"] as? String } == ["mail:a:1"])
    }
}

@Suite struct LetterExportTests {
    @Test func exportedLetterReadsBackWithAttachments() throws {
        let item = TimelineItem(
            id: "mail:a:1", title: "Договор: правки / юристов", time: now,
            detail: .mail(MailInfo(accountID: "a", from: Person(name: "Андрей Козлов", address: "andrey@example.com"),
                                   to: [Person(name: nil, address: "me@example.com")], messageID: "x1@example.com")))
        let body = MailBody(html: "<html><body><p>Посмотрите правки</p><script>alert(1)</script></body></html>",
                            text: "Посмотрите правки",
                            attachments: [MailBody.Attachment(name: "договор.pdf", size: 3, mimeType: "application/pdf",
                                                              data: Data([1, 2, 3]))])
        let data = try #require(MessageBuilder.export(item, body: body))
        let headers = MIME.parseHeaders(MIME.split(data).header)
        #expect(MIME.decodeWords(headers["subject"] ?? "") == "Договор: правки / юристов")
        #expect(headers["message-id"] == "<x1@example.com>")
        #expect(headers["from"]?.contains("andrey@example.com") == true)
        let back = ParsedMessage.body(of: data)
        #expect(back.attachments.first?.name == "договор.pdf")
        #expect(back.attachments.first?.data == Data([1, 2, 3]))
        #expect(back.plainText.contains("Посмотрите правки"))
        #expect(back.html?.contains("<script") != true)
        #expect(MessageBuilder.exportFileName("Договор: правки / юристов") == "Договор правки юристов.eml")
    }
}

@Suite struct DayNoteSyncTests {
    @Test func lastEditWins() {
        let early = now, late = now.addingTimeInterval(60)
        #expect(DayNoteSync.step(noteText: "план", noteUpdated: early, fileText: nil, fileModified: nil) == .export)
        #expect(DayNoteSync.step(noteText: "", noteUpdated: nil, fileText: nil, fileModified: nil) == .none)
        #expect(DayNoteSync.step(noteText: "план", noteUpdated: early, fileText: "план\n", fileModified: late) == .none)
        #expect(DayNoteSync.step(noteText: "план", noteUpdated: early, fileText: "план и обед", fileModified: late) == .importFile)
        #expect(DayNoteSync.step(noteText: "план 2", noteUpdated: late, fileText: "план", fileModified: early) == .export)
        #expect(DayNoteSync.step(noteText: "", noteUpdated: nil, fileText: "из Trunook", fileModified: early) == .importFile)
    }

    @Test func onlyDayFilesCount() {
        #expect(DayNoteSync.dayKey(fromFileName: "2026-09-25.txt") == "2026-09-25")
        #expect(DayNoteSync.dayKey(fromFileName: "2026-9-25.txt") == nil)
        #expect(DayNoteSync.dayKey(fromFileName: ".2026-09-25.txt") == nil)
        #expect(DayNoteSync.dayKey(fromFileName: "../etc.txt") == nil)
        #expect(DayNoteSync.fileName("2026-09-25") == "2026-09-25.txt")
    }
}
