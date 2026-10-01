import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Текущая или ближайшая встреча")
struct NearestMeetingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let zoom = MeetingLink(url: URL(string: "https://zoom.us/j/1")!, provider: .zoom)

    private func event(_ id: String, in minutes: Double, length: Double = 30, link: Bool = true,
                       cancelled: Bool = false, declined: Bool = false, allDay: Bool = false) -> TimelineItem {
        let me = Attendee(person: Person(name: "Я", address: "me@x"), response: declined ? .declined : .accepted, isMe: true)
        var info = EventInfo(calendarTitle: "Работа", organizer: Person(name: "О", address: "o@x"), attendees: [me])
        info.link = link ? zoom : nil
        info.isCancelled = cancelled
        return TimelineItem(id: id, title: id, time: now.addingTimeInterval(minutes * 60),
                            end: now.addingTimeInterval((minutes + length) * 60), isAllDay: allDay,
                            detail: .event(info))
    }

    @Test("Идущая встреча важнее следующей; из идущих — начавшаяся позже")
    func идущая() {
        let items = [event("день", in: -120, length: 480), event("созвон", in: -5), event("потом", in: 60)]
        #expect(NearestMeeting.pick(items, now: now, needsLink: true)?.id == "созвон")
    }

    @Test("За 10 минут до начала встреча уже текущая")
    func заранее() {
        let items = [event("идёт", in: -20, length: 30), event("скоро", in: 8)]
        #expect(NearestMeeting.pick(items, now: now, needsLink: true)?.id == "скоро")
        // Следующая через полчаса — пока текущая та, что идёт.
        let later = [event("идёт", in: -20, length: 30), event("позже", in: 30)]
        #expect(NearestMeeting.pick(later, now: now, needsLink: true)?.id == "идёт")
    }

    @Test("Нет идущих — ближайшая следующая; прошедшие не считаются")
    func следующая() {
        let items = [event("прошла", in: -60), event("вторая", in: 120), event("первая", in: 45)]
        #expect(NearestMeeting.pick(items, now: now, needsLink: true)?.id == "первая")
    }

    @Test("Отменённые, отклонённые, на весь день и без ссылки — мимо")
    func исключения() {
        let items = [event("отменена", in: 0, cancelled: true), event("отклонена", in: 0, declined: true),
                     event("весь день", in: -60, length: 1440, allDay: true), event("очная", in: 0, link: false),
                     event("онлайн", in: 90)]
        #expect(NearestMeeting.pick(items, now: now, needsLink: true)?.id == "онлайн")
        // Для фокуса в окошке ссылка не нужна.
        #expect(NearestMeeting.pick(items, now: now, needsLink: false)?.id == "очная")
        #expect(NearestMeeting.pick([event("прошла", in: -60)], now: now, needsLink: false) == nil)
    }
}

@Suite("Ответ организатора")
struct OrganizerResponseTests {
    private let organizer = Person(name: "О", address: "Org@X")
    private let guest = Person(name: "Г", address: "g@x")

    @Test("Организатор без ответа — принял; гость без ответа — без ответа")
    func organizerAccepted() {
        let info = EventInfo(calendarTitle: "Работа", organizer: organizer,
                             attendees: [Attendee(person: Person(name: "О", address: "org@x"), response: .pending),
                                         Attendee(person: guest, response: .pending)])
        #expect(info.response(of: info.attendees[0]) == .accepted)
        #expect(info.response(of: info.attendees[1]) == .pending)
    }

    @Test("Отменённая встреча и явный отказ организатора — как есть")
    func cancelledOrDeclined() {
        var info = EventInfo(calendarTitle: "Работа", organizer: organizer,
                             attendees: [Attendee(person: organizer, response: .unknown)])
        info.isCancelled = true
        #expect(info.response(of: info.attendees[0]) == .unknown)
        let declined = EventInfo(calendarTitle: "Работа", organizer: organizer,
                                 attendees: [Attendee(person: organizer, response: .declined)])
        #expect(declined.response(of: declined.attendees[0]) == .declined)
    }
}
