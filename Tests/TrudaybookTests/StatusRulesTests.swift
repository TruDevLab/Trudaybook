import Foundation
import Testing
@testable import TrudaybookCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func mail(_ id: String = "mail:a:1", at time: Date = now.addingTimeInterval(-3600), answered: Bool = false) -> TimelineItem {
    TimelineItem(
        id: id,
        title: "Письмо",
        time: time,
        detail: .mail(MailInfo(accountID: "a", from: Person(name: "Анна", address: "anna@example.com"),
                               isAnsweredOnServer: answered))
    )
}

private func event(start: Date, minutes: Double = 60, canReschedule: Bool = true, attendees: [Attendee] = []) -> TimelineItem {
    TimelineItem(
        id: "event:1@\(Int(start.timeIntervalSince1970))",
        title: "Встреча",
        time: start,
        end: start.addingTimeInterval(minutes * 60),
        detail: .event(EventInfo(calendarTitle: "Работа", attendees: attendees, canReschedule: canReschedule))
    )
}

private func reminder(due: Date, completed: Bool = false) -> TimelineItem {
    TimelineItem(id: "reminder:1", title: "Позвонить", time: due,
                 detail: .reminder(ReminderInfo(listTitle: "Дела", isCompleted: completed)))
}

@Suite("Статусы писем")
struct MailStatusTests {
    @Test func newMailIsOpen() {
        #expect(StatusRules.status(of: mail(), local: nil, now: now) == .open)
    }

    @Test func archivedWinsOverEverything() {
        let local = LocalState(archivedAt: now, answeredAt: now, snoozedUntil: now.addingTimeInterval(3600))
        #expect(StatusRules.status(of: mail(), local: local, now: now) == .done(.archived))
    }

    @Test func answeredOnServerCountsAsDone() {
        #expect(StatusRules.status(of: mail(answered: true), local: nil, now: now) == .done(.answered))
    }

    @Test func snoozedUntilFuture() {
        let until = now.addingTimeInterval(3600)
        #expect(StatusRules.status(of: mail(), local: LocalState(snoozedUntil: until), now: now) == .snoozed(until: until))
    }

    @Test func snoozeExpiredReturnsToOpenAtSnoozeTime() {
        let until = now.addingTimeInterval(-60)
        let local = LocalState(snoozedUntil: until)
        #expect(StatusRules.status(of: mail(), local: local, now: now) == .open)
        #expect(StatusRules.effectiveTime(of: mail(), local: local) == until)
    }

    @Test func unresolvedRespectsCutoff() {
        let cutoff = now.addingTimeInterval(-86_400)
        #expect(StatusRules.isUnresolved(mail(at: now.addingTimeInterval(-3600)), local: nil, now: now, mailCutoff: cutoff))
        #expect(!StatusRules.isUnresolved(mail(at: now.addingTimeInterval(-2 * 86_400)), local: nil, now: now, mailCutoff: cutoff))
    }

    @Test func snoozedIsNotUnresolvedUntilItReturns() {
        let cutoff = now.addingTimeInterval(-86_400)
        let local = LocalState(snoozedUntil: now.addingTimeInterval(600))
        #expect(!StatusRules.isUnresolved(mail(), local: local, now: now, mailCutoff: cutoff))
        #expect(StatusRules.isUnresolved(mail(), local: local, now: now.addingTimeInterval(601), mailCutoff: cutoff))
    }
}

@Suite("Статусы встреч и напоминаний")
struct EventReminderStatusTests {
    @Test func eventLifecycle() {
        let item = event(start: now.addingTimeInterval(600))
        #expect(StatusRules.status(of: item, local: nil, now: now) == .upcoming)
        #expect(StatusRules.status(of: item, local: nil, now: now.addingTimeInterval(1200)) == .open)
        #expect(StatusRules.status(of: item, local: nil, now: now.addingTimeInterval(4200)) == .done(.passed))
    }

    @Test func pastEventIsNeverUnresolved() {
        let item = event(start: now.addingTimeInterval(-7200))
        #expect(!StatusRules.isUnresolved(item, local: nil, now: now, mailCutoff: .distantPast))
    }

    @Test func overdueReminderIsUnresolvedRegardlessOfCutoff() {
        let item = reminder(due: now.addingTimeInterval(-30 * 86_400))
        #expect(StatusRules.isUnresolved(item, local: nil, now: now, mailCutoff: now.addingTimeInterval(-86_400)))
    }

    @Test func completedReminderIsDone() {
        #expect(StatusRules.status(of: reminder(due: now, completed: true), local: nil, now: now) == .done(.completed))
    }
}

@Suite("Доступность действий")
struct AvailabilityTests {
    @Test func foreignMeetingCannotBeRescheduled() {
        let item = event(start: now, canReschedule: false)
        #expect(!StatusRules.availability(of: .reschedule, for: item, local: nil, now: now).isEnabled)
    }

    @Test func meetingWithoutPeopleHasNobodyToReplyTo() {
        #expect(!StatusRules.availability(of: .reply, for: event(start: now), local: nil, now: now).isEnabled)
        let withPeople = event(start: now, attendees: [
            Attendee(person: Person(name: "Иван", address: "ivan@example.com"), response: .accepted),
        ])
        #expect(StatusRules.availability(of: .reply, for: withPeople, local: nil, now: now).isEnabled)
    }

    @Test func reminderCannotBeReplied() {
        #expect(!StatusRules.availability(of: .reply, for: reminder(due: now), local: nil, now: now).isEnabled)
    }
}

@Suite("Варианты переноса")
struct RescheduleOptionsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // Сентябрь 2026: 21-е — понедельник.
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test func morningOffersEveningTomorrowAndMonday() {
        let options = RescheduleOptions.options(for: mail(), now: date(23, 10, 37), calendar: calendar)
        #expect(options.map(\.title) == ["Через час", "Сегодня вечером", "Завтра утром", "В понедельник"])
        #expect(options[0].date == date(23, 11, 40))
        #expect(options[1].date == date(23, 18))
        #expect(options[2].date == date(24, 9))
        #expect(options[3].date == date(28, 9))
    }

    @Test func lateEveningDropsTonight() {
        let titles = RescheduleOptions.options(for: mail(), now: date(23, 17, 30), calendar: calendar).map(\.title)
        #expect(!titles.contains("Сегодня вечером"))
    }

    @Test func sundayDoesNotRepeatMondayTwice() {
        let options = RescheduleOptions.options(for: mail(), now: date(27, 10), calendar: calendar)
        #expect(options.filter { $0.date == date(28, 9) }.count == 1)
    }

    @Test func roundUpCrossesHour() {
        #expect(RescheduleOptions.roundUp(date(23, 10, 58), calendar: calendar) == date(23, 11, 0))
        #expect(RescheduleOptions.roundUp(date(23, 10, 55), calendar: calendar) == date(23, 10, 55))
    }

    @Test func eventShiftsFromItsOwnStart() {
        let start = date(23, 15)
        let options = RescheduleOptions.options(for: event(start: start), now: date(23, 9), calendar: calendar)
        #expect(options.first?.date == date(23, 15, 30))
        #expect(options.contains { $0.title == "Завтра в то же время" && $0.date == date(24, 15) })
    }
}
