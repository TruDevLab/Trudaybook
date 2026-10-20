import Foundation
import Testing
@testable import TrudaybookCore

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return calendar
}

private func day(_ number: Int, _ hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: number, hour: hour))!
}

private func event(_ id: String = "event:A@1", from start: Date, to end: Date, allDay: Bool = false,
                   uid: String? = "U1", recurring: Bool = false) -> TimelineItem {
    TimelineItem(id: id, title: "Отпуск", time: start, end: end, isAllDay: allDay,
                 detail: .event(EventInfo(calendarTitle: "Личное", isRecurring: recurring, uid: uid)))
}

@Suite("Многодневные события")
struct MultiDayEventTests {
    @Test("Отпуск на 8 дней — в каждом своём дне, но не в дне после")
    func отпуск() {
        let vacation = event(from: day(12), to: day(20), allDay: true)
        for number in 12...19 {
            #expect(vacation.overlaps(from: day(number), to: day(number + 1)))
        }
        #expect(!vacation.overlaps(from: day(20), to: day(21)))
        #expect(!vacation.overlaps(from: day(11), to: day(12)))
        #expect(vacation.isAllDayBand)
    }

    @Test("Встреча на сутки и дольше — в полосе «на весь день», короткая — на шкале")
    func полоса() {
        #expect(event(from: day(12, 9), to: day(15, 18)).isAllDayBand)
        #expect(!event(from: day(12, 9), to: day(12, 18)).isAllDayBand)
        // Ночная смена через полночь — ещё не сутки.
        #expect(!event(from: day(12, 22), to: day(13, 6)).isAllDayBand)
    }

    @Test("Длинная встреча — не «ближайшая»: отпуск не заслоняет созвоны")
    func ближайшая() {
        let call = event("event:B@2", from: day(13, 11), to: day(13, 12))
        let trip = event("event:C@3", from: day(12, 9), to: day(16, 18))
        #expect(NearestMeeting.pick([trip, call], now: day(13, 10), needsLink: false)?.id == call.id)
    }
}

@Suite("Напоминание на весь день")
struct AllDayReminderTests {
    @Test("Срок ровно в полночь — дата без времени")
    func полночь() {
        #expect(!EventKitCalendar.hasTime(DateComponents(year: 2026, month: 10, day: 19)))
        #expect(!EventKitCalendar.hasTime(DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 0)))
        #expect(EventKitCalendar.hasTime(DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 30)))
        #expect(EventKitCalendar.hasTime(DateComponents(year: 2026, month: 10, day: 19, hour: 9)))
    }

    @Test("На весь день — в «Не разобрано» только когда кончился его день")
    func неРазобрано() {
        let reminder = TimelineItem(id: "reminder:1", title: "Купить", time: day(19), isAllDay: true,
                                    detail: .reminder(ReminderInfo(listTitle: "Дела")))
        #expect(!StatusRules.isUnresolved(reminder, local: nil, now: day(19, 15), mailCutoff: .distantPast, calendar: calendar))
        #expect(StatusRules.isUnresolved(reminder, local: nil, now: day(20, 9), mailCutoff: .distantPast, calendar: calendar))
        // Со временем — как раньше: просрочено, как только наступил срок.
        var timed = reminder
        timed.isAllDay = false
        timed.time = day(19, 9)
        #expect(StatusRules.isUnresolved(timed, local: nil, now: day(19, 15), mailCutoff: .distantPast, calendar: calendar))
    }
}

@Suite("Свой цвет встречи")
struct EventColorTests {
    private let red = RGB(1, 0, 0)
    private let blue = RGB(0, 0, 1)

    @Test("Цвет встречи переживает перенос: ключ — UID, а не время")
    func перенос() {
        let meeting = event(from: day(12, 9), to: day(12, 10))
        var overrides: [String: RGB] = [:]
        for change in EventColors.changes(setting: red, for: meeting, scope: .series) {
            overrides[change.key] = change.color
        }
        let moved = event("event:A@999", from: day(13, 9), to: day(13, 10))
        #expect(EventColors.color(of: moved, in: overrides) == red)
        #expect(EventColors.scope(of: moved, in: overrides) == .series)
    }

    @Test("Серия и одно вхождение: своё сильнее серии, цвет серии снимает своё")
    func серия() {
        let first = event("event:S@1", from: day(12, 9), to: day(12, 10), uid: "SERIES", recurring: true)
        let second = event("event:S@2", from: day(13, 9), to: day(13, 10), uid: "SERIES", recurring: true)
        var overrides: [String: RGB] = [:]
        func apply(_ color: RGB?, _ item: TimelineItem, _ scope: EventColors.Scope) {
            for change in EventColors.changes(setting: color, for: item, scope: scope) {
                overrides[change.key] = change.color
            }
        }
        apply(red, first, .series)
        apply(blue, second, .occurrence)
        #expect(EventColors.color(of: first, in: overrides) == red)
        #expect(EventColors.color(of: second, in: overrides) == blue)
        #expect(EventColors.scope(of: second, in: overrides) == .occurrence)
        apply(red, second, .series)
        #expect(EventColors.color(of: second, in: overrides) == red)
        apply(nil, second, .series)
        #expect(EventColors.color(of: first, in: overrides) == nil)
        #expect(EventColors.scope(of: first, in: overrides) == nil)
    }

    @Test("Цвета хранятся в базе; nil — забыть")
    func база() throws {
        let store = try ItemStateStore.inMemory()
        try store.setEventColor("#FF0000", for: "uid:U1")
        try store.setEventColor("#0000FF", for: "occurrence:event:S@2")
        #expect(store.allEventColors() == ["uid:U1": "#FF0000", "occurrence:event:S@2": "#0000FF"])
        try store.setEventColor(nil, for: "uid:U1")
        #expect(store.allEventColors() == ["occurrence:event:S@2": "#0000FF"])
    }
}
