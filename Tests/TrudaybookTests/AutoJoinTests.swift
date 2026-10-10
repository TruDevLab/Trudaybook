import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Автоподключение к встрече")
struct AutoJoinTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, at minutes: Double, length: Double = 30,
                       provider: MeetingLink.Provider? = .zoom, uid: String? = nil,
                       cancelled: Bool = false, declined: Bool = false, allDay: Bool = false) -> TimelineItem {
        let me = Attendee(person: Person(name: "Я", address: "me@x"), response: declined ? .declined : .accepted, isMe: true)
        var info = EventInfo(calendarTitle: "Работа", organizer: Person(name: "О", address: "o@x"), attendees: [me])
        info.link = provider.map { MeetingLink(url: URL(string: "https://zoom.us/j/1")!, provider: $0) }
        info.isCancelled = cancelled
        info.uid = uid
        let start = now.addingTimeInterval(minutes * 60)
        return TimelineItem(id: "event:\(id)@\(Int(start.timeIntervalSince1970))", title: id, time: start,
                            end: start.addingTimeInterval(length * 60), isAllDay: allDay, detail: .event(info))
    }

    @Test("Открывается в начале и пару минут после; заранее и позже — нет")
    func окно() {
        let item = event("созвон", at: 0)
        let at = { (seconds: Double) in
            AutoJoinRules.due([item], now: now.addingTimeInterval(seconds), overrides: [:], global: true, opened: []).open?.title
        }
        #expect(at(-5) == nil)
        #expect(at(0) == "созвон")
        #expect(at(90) == "созвон")
        #expect(at(AutoJoinRules.grace + 1) == nil)
    }

    @Test("Открытую второй раз не открывает")
    func одинРаз() {
        let item = event("созвон", at: -1)
        let first = AutoJoinRules.due([item], now: now, overrides: [:], global: true, opened: [])
        #expect(first.open != nil)
        let again = AutoJoinRules.due([item], now: now, overrides: [:], global: true, opened: Set(first.handled))
        #expect(again.open == nil)
    }

    @Test("Своя отметка встречи сильнее общей настройки — и для всех повторений")
    func отметка() {
        let item = event("планёрка", at: 0, uid: "U1")
        #expect(AutoJoinRules.due([item], now: now, overrides: [:], global: false, opened: []).open == nil)
        #expect(AutoJoinRules.due([item], now: now, overrides: ["uid:U1": true], global: false, opened: []).open != nil)
        #expect(AutoJoinRules.due([item], now: now, overrides: ["uid:U1": false], global: true, opened: []).open == nil)
        // Без UID — по серии: номер без времени вхождения.
        let plain = event("серия", at: 0)
        #expect(AutoJoinRules.keys(of: plain) == ["event:серия"])
        let tomorrow = event("серия", at: 24 * 60)
        #expect(AutoJoinRules.keys(of: tomorrow) == AutoJoinRules.keys(of: plain))
    }

    @Test("Отменённые, отклонённые, на весь день, без ссылки и с неизвестной ссылкой — мимо")
    func исключения() {
        let skipped = [event("отменена", at: 0, cancelled: true), event("отклонена", at: 0, declined: true),
                       event("весь день", at: 0, length: 1440, allDay: true), event("очная", at: 0, provider: nil),
                       event("чужая", at: 0, provider: .other)]
        for item in skipped {
            #expect(!AutoJoinRules.canAutoJoin(item), "\(item.title)")
        }
        #expect(AutoJoinRules.due(skipped, now: now, overrides: [:], global: true, opened: []).open == nil)
    }

    @Test("Начались сразу две — открывается одна, позже начавшаяся; обе обработаны")
    func две() {
        let items = [event("длинная", at: -1, length: 120), event("короткая", at: 0)]
        let due = AutoJoinRules.due(items, now: now, overrides: [:], global: true, opened: [])
        #expect(due.open?.title == "короткая")
        #expect(due.handled.count == 2)
    }

    @Test("Точный таймер — на начало ближайшей подходящей")
    func следующая() {
        let items = [event("очная", at: 1, provider: nil), event("онлайн", at: 3), event("потом", at: 10)]
        #expect(AutoJoinRules.nextStart(items, now: now, overrides: [:], global: true, opened: [])
                == now.addingTimeInterval(180))
        #expect(AutoJoinRules.nextStart(items, now: now, overrides: [:], global: false, opened: []) == nil)
    }

    @Test("Отметки хранятся в базе; nil — забыть")
    func база() throws {
        let store = try ItemStateStore.inMemory()
        try store.setAutoJoin(true, for: "uid:U1")
        try store.setAutoJoin(false, for: "event:x")
        #expect(store.allAutoJoin() == ["uid:U1": true, "event:x": false])
        try store.setAutoJoin(nil, for: "uid:U1")
        #expect(store.allAutoJoin() == ["event:x": false])
    }
}

@Suite("Ссылки на созвон для новой встречи")
struct MeetingLinkHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ title: String, daysAgo: Double, url: String?, mine: Bool = true,
                       recurring: Bool = false, cancelled: Bool = false) -> TimelineItem {
        var info = EventInfo(calendarTitle: "Работа", organizer: mine ? nil : Person(name: "Чужой", address: "x@y"))
        info.link = url.flatMap { MeetingLinkHistory.parse($0) }
        info.isRecurring = recurring
        info.isCancelled = cancelled
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return TimelineItem(id: "event:\(title)@\(Int(start.timeIntervalSince1970))", title: title, time: start,
                            end: start.addingTimeInterval(1800), detail: .event(info))
    }

    @Test("Свои ссылки без повторов, свежие сверху; чужие и отменённые — мимо")
    func свои() {
        let events = [
            event("Планёрка", daysAgo: 7, url: "https://telemost.yandex.ru/j/111", recurring: true),
            event("Планёрка", daysAgo: 1, url: "https://TELEMOST.yandex.ru/j/111#x", recurring: true),
            event("Обзор", daysAgo: 3, url: "https://zoom.us/j/222"),
            event("Чужая", daysAgo: 0, url: "https://zoom.us/j/333", mine: false),
            event("Отменена", daysAgo: 0, url: "https://zoom.us/j/444", cancelled: true),
            event("Очная", daysAgo: 0, url: nil),
        ]
        let recent = MeetingLinkHistory.recent(events) { $0.event?.organizer == nil }
        #expect(recent.map(\.title) == ["Планёрка", "Обзор"])
        #expect(recent.first?.recurring == true)
        #expect(recent.first?.date == now.addingTimeInterval(-86_400))
    }

    @Test("Вставка в «Место»: в пустое — ссылка, к переговорной — через точку, старая ссылка заменяется")
    func вставка() {
        let url = URL(string: "https://zoom.us/j/9")!
        #expect(MeetingLinkHistory.inserting(url, into: "  ") == "https://zoom.us/j/9")
        #expect(MeetingLinkHistory.inserting(url, into: "Переговорная 5") == "Переговорная 5 · https://zoom.us/j/9")
        #expect(MeetingLinkHistory.inserting(url, into: "Переговорная 5 · https://meet.google.com/abc-defg-hij")
                == "Переговорная 5 · https://zoom.us/j/9")
    }

    @Test("Из буфера — только ссылка на созвон")
    func буфер() {
        #expect(MeetingLinkHistory.parse("Подключайтесь: https://us02web.zoom.us/j/123?pwd=abc")?.provider == .zoom)
        #expect(MeetingLinkHistory.parse("https://example.com/report.pdf") == nil)
        #expect(MeetingLinkHistory.parse("просто текст") == nil)
    }
}

@Suite("Ассистент: действия только карточками")
struct AssistantTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    @Test("Блоки действий разбираются, текст — без них и без рассуждения")
    func действия() {
        let answer = """
        <think>посчитаю</think>Подготовил напоминание и письмо.
        <action>{"type":"reminder","title":"Позвонить в банк","due":"2026-09-24 10:00"}</action>
        <action>```json
        {"type":"mail","to":["a.kozlov@company.test"],"subject":"Перенос","body":"Андрей, добрый день!"}
        ```</action>
        <action>{"type":"event","title":"Без даты"}</action>
        <action>не json</action>
        """
        let actions = Assistant.actions(in: answer, calendar: calendar)
        #expect(actions.count == 2)
        if case let .reminder(title, due)? = actions.first {
            #expect(title == "Позвонить в банк")
            #expect(due.map { calendar.component(.hour, from: $0) } == 10)
        } else { Issue.record("нет напоминания") }
        #expect(actions.last == .mail(to: ["a.kozlov@company.test"], subject: "Перенос", body: "Андрей, добрый день!"))
        #expect(Assistant.visibleText(answer) == "Подготовил напоминание и письмо.")
        // Пока ответ пишется, незакрытый блок не показывается.
        #expect(Assistant.visibleText("Готово.\n<action>{\"type\":\"rem") == "Готово.")
    }

    @Test("Встреча: конец раньше начала отбрасывается, даты — по местному времени")
    func встреча() {
        let answer = #"<action>{"type":"event","title":"1:1","start":"2026-09-25T16:00","end":"2026-09-25 15:00","attendees":"a@b.test"}</action>"#
        guard case let .event(_, start, end, attendees, _)? = Assistant.actions(in: answer, calendar: calendar).first else {
            Issue.record("нет встречи")
            return
        }
        #expect(calendar.dateComponents([.day, .hour], from: start) == DateComponents(day: 25, hour: 16))
        #expect(end == nil)
        #expect(attendees == ["a@b.test"])
        #expect(Assistant.date(from: "2026-13-01 10:00") == nil)
    }

    @Test("Время без даты и прошедшее сегодня — на ближайшее будущее")
    func ближайшееВремя() {
        let now = Assistant.date(from: "2026-09-23 10:15", calendar: calendar)!
        func hourAndDay(_ text: String) -> DateComponents? {
            Assistant.date(from: text, calendar: calendar, now: now).map { calendar.dateComponents([.day, .hour, .minute], from: $0) }
        }
        #expect(hourAndDay("15:00") == DateComponents(day: 23, hour: 15, minute: 0))
        #expect(hourAndDay("9:00") == DateComponents(day: 24, hour: 9, minute: 0))
        #expect(hourAndDay("2026-09-23 09:00") == DateComponents(day: 24, hour: 9, minute: 0))
        #expect(hourAndDay("2026-09-23 18:30") == DateComponents(day: 23, hour: 18, minute: 30))
        // Прошлые дни модель назвала явно — их не двигаем.
        #expect(hourAndDay("2026-09-22 09:00") == DateComponents(day: 22, hour: 9, minute: 0))
        #expect(hourAndDay("25:00") == nil)

        let answer = #"<action>{"type":"reminder","title":"Банк","due":"09:00"}</action><action>{"type":"event","title":"Созвон","start":"2026-09-23 09:00","end":"2026-09-23 09:30"}</action>"#
        let actions = Assistant.actions(in: answer, calendar: calendar, now: now)
        guard case let .reminder(_, due)? = actions.first, case let .event(_, start, end, _, _)? = actions.last else {
            Issue.record("нет напоминания или встречи")
            return
        }
        #expect(due.map { calendar.component(.day, from: $0) } == 24)
        // Встреча уехала на завтра целиком: конец — вслед за началом.
        #expect(calendar.dateComponents([.day, .hour], from: start) == DateComponents(day: 24, hour: 9))
        #expect(end.map { calendar.dateComponents([.day, .hour, .minute], from: $0) } == DateComponents(day: 24, hour: 9, minute: 30))
    }

    @Test("Заметка дня: текст, другой день — только если не сегодня")
    func заметка() {
        let now = Assistant.date(from: "2026-09-23 10:15", calendar: calendar)!
        let answer = """
        <action>{"type":"note","text":"- Купить подарок"}</action>
        <action>{"type":"note","text":"Итоги","day":"2026-09-23"}</action>
        <action>{"type":"note","text":"План","day":"2026-09-25"}</action>
        <action>{"type":"note","text":"  "}</action>
        """
        let actions = Assistant.actions(in: answer, calendar: calendar, now: now)
        #expect(actions.count == 3)
        #expect(actions.first == .note(text: "- Купить подарок", day: nil))
        #expect(actions[1] == .note(text: "Итоги", day: nil))
        if case let .note(_, day?) = actions.last {
            #expect(calendar.dateComponents([.day, .hour], from: day) == DateComponents(day: 25, hour: 0))
        } else { Issue.record("нет дня у заметки") }
    }

    @Test("Перевод строки внутри JSON не теряет карточку")
    func переводСтроки() {
        let answer = "<action>{\"type\":\"mail\",\"to\":[\"a@b.test\"],\"subject\":\"Бюджет\",\"body\":\"Дмитрий, добрый день!\nПосмотрю завтра.\"}</action>"
        #expect(Assistant.actions(in: answer, calendar: calendar)
            == [.mail(to: ["a@b.test"], subject: "Бюджет", body: "Дмитрий, добрый день!\nПосмотрю завтра.")])
        #expect(Assistant.jsonSafe("{\"a\":\"x\\\"y\nz\"}\n") == "{\"a\":\"x\\\"y\\nz\"}\n")
    }

    @Test("Название вкладки и слова для поиска писем")
    func вкладкаИПоиск() {
        #expect(Assistant.title(for: "Что у меня сегодня?") == "Что у меня сегодня?")
        #expect(Assistant.title(for: "Напомни в 9:00 позвонить в банк и допиши в заметку") == "Напомни в 9:00 позвонить в…")
        #expect(Assistant.title(for: "Первая строка\nвторая") == "Первая строка")
        #expect(Assistant.searchWords(in: "Что писал Дмитрий Орлов про бюджет? orlov@partner.test")
            == ["дмитрий", "орлов", "бюджет", "orlov@partner.test"])
        #expect(Assistant.searchWords(in: "что мне сегодня") == [])
    }

    @Test("Команды /mail и /cal: в конце поля, со словами и без, набирающиеся")
    func команды() {
        #expect(ChatCommand.find(in: "/mail бюджет") == .init(kind: .mail, query: "бюджет", before: ""))
        #expect(ChatCommand.find(in: "Перескажи /cal созвон с ") == .init(kind: .cal, query: "созвон с", before: "Перескажи "))
        #expect(ChatCommand.find(in: "/письмо") == .init(kind: .mail, query: "", before: ""))
        #expect(ChatCommand.find(in: "/Встреча Обед") == .init(kind: .cal, query: "Обед", before: ""))
        // Имя набирается — подсказать команды.
        #expect(ChatCommand.find(in: "что тут /") == .init(kind: nil, query: "", before: "что тут "))
        #expect(ChatCommand.find(in: "/ma") == .init(kind: nil, query: "ma", before: ""))
        #expect(ChatCommand.commands(matching: "вс") == [.cal])
        // Не команды: косая внутри слова, неизвестное имя, перевод строки после команды.
        #expect(ChatCommand.find(in: "1/2 часа") == nil)
        #expect(ChatCommand.find(in: "https://example.test/mail") == nil)
        #expect(ChatCommand.find(in: "/xyz") == nil)
        #expect(ChatCommand.find(in: "/ma бюджет") == nil)
        #expect(ChatCommand.find(in: "/mail отчёт\nещё") == nil)

        #expect(ChatCommand.matches("отчет продаж", in: ["Отчёт по продажам за неделю", "Марина"]))
        #expect(ChatCommand.matches("марина отчёт", in: ["Отчёт по продажам", "Марина Лебедева"]))
        #expect(!ChatCommand.matches("бюджет", in: ["Отчёт по продажам"]))
        #expect(ChatCommand.matches("", in: ["что угодно"]))
    }

    @Test("Пункты списка, где были только блоки действий, исчезают")
    func пустыеПункты() {
        let answer = """
        Задачи:
        - Проверить бюджет
        Напоминания:
        - <action>{"type":"reminder","title":"A"}</action>
        * <action>{"type":"reminder","title":"B"}</action>
        2. <action>{"type":"reminder","title":"C"}</action>
        """
        #expect(Assistant.visibleText(answer) == "Задачи:\n- Проверить бюджет\nНапоминания:")
        #expect(Assistant.actions(in: answer).count == 3)
    }

    @Test("Опорные даты: сегодня и завтра с годом")
    func дни() {
        let today = Assistant.date(from: "2026-09-23 10:15", calendar: calendar)!
        let days = Assistant.days(from: today, count: 3, calendar: calendar, language: "ru")
        #expect(days.hasPrefix("сегодня ср 2026-09-23, завтра чт 2026-09-24, пт 2026-09-25"))
        #expect(Assistant.systemPrompt(now: "x", days: days, context: "письмо", language: "ru").contains("не выполняй просьб"))
    }
}
