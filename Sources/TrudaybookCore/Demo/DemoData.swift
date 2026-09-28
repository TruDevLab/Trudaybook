import Foundation

/// Тестовые почта и календарь: интерфейс проверяется без аккаунтов и доступов.
///
/// Всё строится детерминированно от даты: один и тот же день выглядит
/// одинаково при каждом запуске, а правки (архив, перенос) живут в памяти.
public enum Demo {
    public static let me = Person(name: String(localized: "Я"), address: "me@company.test")

    public static let people: [Person] = [
        Person(name: String(localized: "Ольга Смирнова"), address: "olga.smirnova@company.test"),
        Person(name: String(localized: "Андрей Козлов"), address: "a.kozlov@company.test"),
        Person(name: String(localized: "Марина Лебедева"), address: "marina@company.test"),
        Person(name: String(localized: "Дмитрий Орлов"), address: "orlov@partner.test"),
        Person(name: String(localized: "Екатерина Волкова"), address: "e.volkova@partner.test"),
        Person(name: String(localized: "Бухгалтерия"), address: "buh@company.test"),
        Person(name: "Jira", address: "jira@company.test"),
        Person(name: String(localized: "Служба поддержки"), address: "support@service.test"),
        Person(name: "GitHub", address: "noreply@github.test"),
        Person(name: String(localized: "Игорь Петров"), address: "petrov@company.test"),
    ]

    static let subjects: [String] = [
        String(localized: "Согласование бюджета на IV квартал"),
        String(localized: "Re: Макеты главной страницы"),
        String(localized: "Отчёт по продажам за неделю"),
        String(localized: "[JIRA] PRJ-1423 назначена на вас"),
        String(localized: "Счёт на оплату № 5817"),
        String(localized: "Встреча с подрядчиком — перенос"),
        String(localized: "Договор: правки юристов"),
        String(localized: "Вопрос по интеграции API"),
        String(localized: "Приглашение на конференцию «Цифровой офис»"),
        String(localized: "Итоги планёрки"),
        String(localized: "Доступ к тестовому стенду"),
        String(localized: "Обновление политики отпусков"),
        String(localized: "Новая версия приложения 2.4"),
        String(localized: "Презентация для совета директоров"),
        String(localized: "Re: Сроки по второму этапу"),
        String(localized: "Заявка на командировку"),
        String(localized: "Ваш запрос № 88213 решён"),
        String(localized: "[GitHub] Pull request #512: исправление экспорта"),
    ]

    static let weekdaySlots: [(Int, Int)] = [
        (7, 48), (8, 12), (8, 35), (9, 1), (9, 2), (9, 4), (9, 5), (9, 7), (9, 41), (10, 5),
        (10, 22), (10, 47), (11, 3), (11, 36), (12, 10), (12, 14), (12, 51), (13, 28), (14, 2),
        (14, 9), (14, 40), (15, 15), (15, 48), (16, 20), (16, 26), (16, 31), (17, 5), (17, 44),
        (18, 30), (19, 12), (21, 40),
    ]
    static let weekendSlots: [(Int, Int)] = [(9, 30), (11, 10), (14, 45), (18, 20), (20, 5)]

    static func dayKey(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    static func days(from: Date, to: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func at(_ day: Date, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

/// Предсказуемый генератор случайных чисел: день выглядит одинаково всегда.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Почта

public actor DemoMailProvider: MailProvider {
    public nonisolated let displayName: String
    public nonisolated let ownAddresses: Set<String>

    /// Ящик в идентификаторах писем: `mail:<ящик>:…`.
    public nonisolated let accountID: String
    private let me: Person
    /// Второй тестовый ящик получает свои письма: треть слотов, сдвинутых
    /// на несколько минут, и другие темы. Нужен, чтобы проверять работу
    /// с несколькими ящиками без настоящих.
    private let variant: Int
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private var archived: Set<String> = []
    private var answered: Set<String> = []

    public init(clock: @escaping @Sendable () -> Date, calendar: Calendar = .current,
                accountID: String = "demo", me: Person = Demo.me, variant: Int = 0) {
        self.clock = clock
        self.calendar = calendar
        self.accountID = accountID
        self.me = me
        self.variant = variant
        displayName = variant == 0 ? String(localized: "Тестовая почта") : (me.address ?? accountID)
        ownAddresses = Set([me.normalizedAddress].compactMap { $0 })
    }

    public func messages(from: Date, to: Date) -> [TimelineItem] {
        let now = clock()
        let today = calendar.startOfDay(for: now)
        return Demo.days(from: from, to: to, calendar: calendar).flatMap { day in
            generate(day: day, today: today)
        }
        .filter { $0.time >= from && $0.time < to && $0.time <= now }
        .map { item in
            guard answered.contains(item.id) || archived.contains(item.id), case .mail(var info) = item.detail else { return item }
            var item = item
            if answered.contains(item.id) { info.isAnsweredOnServer = true }
            // Как у настоящих ящиков: ушедшее в архив остаётся на таймлайне.
            if archived.contains(item.id) { info.movedAway = true }
            item.detail = .mail(info)
            return item
        }
    }

    public func body(of itemID: String) -> MailBody {
        if itemID.hasSuffix("-invite") { return invitationBody() }
        if itemID.hasSuffix("-cancel") { return cancellationBody() }
        let seed = itemID.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF_FFFF }
        var random = SeededGenerator(seed: seed)
        let paragraphs = [
            String(localized: "Добрый день!"),
            String(localized: "Высылаю материалы, о которых договаривались. Посмотрите, пожалуйста, до конца недели — нам важно успеть согласовать всё до планирования."),
            String(localized: "Если по срокам что-то не получается, напишите, перенесём. Основные вопросы собрал ниже."),
            String(localized: "1. Бюджет на подрядчиков.\n2. Сроки второго этапа.\n3. Кто отвечает за приёмку."),
            String(localized: "Спасибо!"),
        ]
        let text = paragraphs.joined(separator: "\n\n")
        // Содержимое — короткий текст: вложение можно сохранить и открыть.
        let sample = Data(String(localized: "Тестовое вложение Trudaybook\n").utf8)
        let attachments = Bool.random(using: &random)
            ? [MailBody.Attachment(name: String(localized: "Материалы.txt"), size: sample.count, mimeType: "text/plain", data: sample),
               MailBody.Attachment(name: String(localized: "Смета проекта.csv"), size: sample.count, mimeType: "text/csv", data: sample)]
            : []
        guard Int.random(in: 0..<3, using: &random) == 0 else {
            return MailBody(text: text, attachments: attachments)
        }
        // Часть писем — HTML с картинкой из сети: на них видно, что внешние
        // загрузки по умолчанию заблокированы.
        let html = """
            <html><body style="font-family: -apple-system, Helvetica; font-size: 14px; color: #222;">
            <p><img src="https://images.example.test/banner.png" width="480" height="80" alt="Баннер рассылки"></p>
            \(paragraphs.map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined())
            <p style="color:#888;font-size:12px">Это письмо отправлено автоматически. <a href="https://example.test/unsubscribe">Отписаться</a></p>
            </body></html>
            """
        return MailBody(html: html, text: text, attachments: attachments)
    }

    public func archive(_ itemID: String) {
        archived.insert(itemID)
    }

    public func send(_ mail: OutgoingMail, replyingTo itemID: String?) {
        if let itemID { answered.insert(itemID) }
        sent.append(TimelineItem(
            id: "mail:\(accountID):sent-\(sent.count)",
            title: mail.subject,
            time: clock(),
            detail: .mail(MailInfo(accountID: accountID, from: me, to: mail.to, cc: mail.cc,
                                   snippet: String(mail.text.prefix(120)), isRead: true))
        ))
    }

    private var sent: [TimelineItem] = []

    public func folders() -> [MailFolder] {
        [
            MailFolder(id: "INBOX", name: String(localized: "Входящие"), role: .inbox),
            MailFolder(id: "Sent", name: String(localized: "Отправленные"), role: .sent),
            MailFolder(id: "Archive", name: String(localized: "Архив"), role: .archive),
            MailFolder(id: "Spam", name: String(localized: "Спам"), role: .junk),
            MailFolder(id: "Work/Projects", name: String(localized: "Проекты"), role: .other, path: String(localized: "Работа / Проекты")),
            // Несколько архивов, как бывает в Exchange: выбор в настройках.
            MailFolder(id: "Archive2025", name: String(localized: "Архив 2025"), role: .other),
            MailFolder(id: "Work/Archive", name: String(localized: "Архив"), role: .other, path: String(localized: "Работа / Архив")),
        ]
    }

    public func messages(inFolder folderID: String, limit: Int) -> [TimelineItem] {
        let now = clock()
        let week = messages(from: now.addingTimeInterval(-7 * 86_400), to: now.addingTimeInterval(60))
        let items: [TimelineItem]
        switch folderID {
        case "INBOX":
            items = week
        case "Archive":
            // В архиве — то, что туда переложили, плюс старые отвеченные.
            let all = Demo.days(from: now.addingTimeInterval(-14 * 86_400), to: now, calendar: calendar)
                .flatMap { generate(day: $0, today: calendar.startOfDay(for: now)) }
            items = all.filter { archived.contains($0.id) || $0.mail?.isAnsweredOnServer == true }
        case "Sent":
            // Ответы на отвеченные письма — как будто их отправили с телефона.
            items = sent + week.filter { $0.mail?.isAnsweredOnServer == true }.map { original in
                TimelineItem(
                    id: original.id.replacingOccurrences(of: "mail:\(accountID):", with: "mail:\(accountID):sent-"),
                    title: ReplyBuilder.replySubject(original.title),
                    time: original.time.addingTimeInterval(1800),
                    detail: .mail(MailInfo(accountID: accountID, from: me,
                                           to: [original.mail?.from].compactMap { $0 }, isRead: true))
                )
            }
        default:
            items = []
        }
        return Array(items.sorted { $0.time > $1.time }.prefix(limit))
    }

    public func search(_ text: String, inFolder folderID: String?, fullText: Bool) -> [TimelineItem] {
        let needle = text.lowercased()
        let pool = (folderID.map { [$0] } ?? folders().map(\.id))
            .flatMap { messages(inFolder: $0, limit: 500) }
        return pool.filter { item in
            item.title.lowercased().contains(needle)
                || item.subtitle.lowercased().contains(needle)
                || (fullText && (item.mail?.snippet.lowercased().contains(needle) ?? false))
        }
    }

    public func refresh() {}

    /// Ответ на тестовое приглашение — никуда не уходит.
    public func respond(to itemID: String, invitation: Invitation, response: InvitationResponse, comment: String?) {}

    /// Приглашение на сегодня 15:30–16:30 — поверх тестовой встречи
    /// «1:1 с Андреем» (15:00–16:00): видно, как показывается занятость.
    private func invitationBody() -> MailBody {
        let today = calendar.startOfDay(for: clock())
        let start = today.addingTimeInterval(15.5 * 3600)
        let stamp = { (date: Date) -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: date)
        }
        let ics = [
            "BEGIN:VCALENDAR", "METHOD:REQUEST", "BEGIN:VEVENT",
            "UID:demo-arch-committee", "SEQUENCE:0",
            "DTSTART:\(stamp(start))", "DTEND:\(stamp(start.addingTimeInterval(3600)))",
            String(localized: "SUMMARY:Архитектурный комитет"), String(localized: "LOCATION:Переговорная «Москва»"),
            "ORGANIZER;CN=\"\(Demo.people[1].name ?? "")\":mailto:\(Demo.people[1].address ?? "")",
            String(localized: "ATTENDEE;CN=\"Я\";PARTSTAT=NEEDS-ACTION:mailto:\(me.address ?? "")"),
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        return MailBody(text: String(localized: "Коллеги, приглашаю обсудить архитектуру второго этапа.\n\nПовестка: хранилище, интеграции, сроки."),
                        calendar: ics)
    }

    /// Отмена сегодняшнего «Созвона с подрядчиком» (11:30) — видно, как
    /// отменённая встреча зачёркнута и как её убрать из календаря.
    private func cancellationBody() -> MailBody {
        let today = calendar.startOfDay(for: clock())
        let start = today.addingTimeInterval(11.5 * 3600)
        let stamp = { (date: Date) -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: date)
        }
        let ics = [
            "BEGIN:VCALENDAR", "METHOD:CANCEL", "BEGIN:VEVENT",
            "UID:demo-vendor-call", "SEQUENCE:1", "STATUS:CANCELLED",
            "DTSTART:\(stamp(start))", "DTEND:\(stamp(start.addingTimeInterval(45 * 60)))",
            String(localized: "SUMMARY:Созвон с подрядчиком"),
            "ORGANIZER;CN=\"\(Demo.people[3].name ?? "")\":mailto:\(Demo.people[3].address ?? "")",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        return MailBody(text: String(localized: "Коллеги, созвон переносится на следующую неделю — эту встречу отменяю."),
                        calendar: ics)
    }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {}

    private func generate(day: Date, today: Date) -> [TimelineItem] {
        let key = Demo.dayKey(day, calendar: calendar)
        var random = SeededGenerator(seed: key &+ variant &* 7_919)
        let weekend = calendar.isDateInWeekend(day)
        let allSlots = weekend ? Demo.weekendSlots : Demo.weekdaySlots
        let slots = variant == 0
            ? allSlots
            : allSlots.enumerated().filter { $0.offset % 3 == variant % 3 }.map { ($0.element.0, min(59, $0.element.1 + 11)) }
        let isToday = day == today

        // Сегодня в первом ящике — приглашение на встречу: видно карточку
        // с календарём дня и кнопками ответа.
        let invitation: [TimelineItem] = isToday && variant == 0 ? [TimelineItem(
            id: "mail:\(accountID):\(key)-invite",
            title: String(localized: "Приглашение: Архитектурный комитет"),
            time: Demo.at(day, 9, 12, calendar: calendar),
            detail: .mail(MailInfo(accountID: accountID, from: Demo.people[1], to: [me],
                                   messageID: "\(key)-invite@company.test",
                                   snippet: String(localized: "Приглашаю обсудить архитектуру второго этапа"),
                                   isRead: false, isInvitation: true))
        )] : []

        // И отмена сегодняшнего созвона с подрядчиком.
        let cancellation: [TimelineItem] = isToday && variant == 0 && !calendar.isDateInWeekend(day) ? [TimelineItem(
            id: "mail:\(accountID):\(key)-cancel",
            title: String(localized: "Отменено: Созвон с подрядчиком"),
            time: Demo.at(day, 9, 20, calendar: calendar),
            detail: .mail(MailInfo(accountID: accountID, from: Demo.people[3], to: [me],
                                   messageID: "\(key)-cancel@company.test",
                                   snippet: String(localized: "Созвон переносится на следующую неделю"),
                                   isRead: false, isInvitation: true))
        )] : []

        return invitation + cancellation + slots.enumerated().map { index, slot in
            let sender = Demo.people[Int.random(in: 0..<Demo.people.count, using: &random)]
            let subject = Demo.subjects[Int.random(in: 0..<Demo.subjects.count, using: &random)]
            // Старые письма в основном уже отвечены — с телефона или из другого
            // клиента, — сегодняшние почти все ждут.
            let answeredChance = isToday ? 0.1 : 0.8
            let answeredOnServer = Double.random(in: 0..<1, using: &random) < answeredChance
            // Каждое пятое — рассылка на многих: видно, как сворачивается «Копия».
            let copies = index % 5 == 0
                ? Array(Demo.people.prefix(8))
                : Bool.random(using: &random) ? [Demo.people[Int.random(in: 0..<Demo.people.count, using: &random)]] : []
            let id = "mail:\(accountID):\(key)-\(index)"
            return TimelineItem(
                id: id,
                title: subject,
                time: Demo.at(day, slot.0, slot.1, calendar: calendar),
                detail: .mail(MailInfo(
                    accountID: accountID,
                    from: sender,
                    to: [me],
                    cc: copies.filter { $0 != sender },
                    messageID: "\(id)@company.test",
                    snippet: String(localized: "Добрый день! Высылаю материалы, о которых договаривались…"),
                    isRead: !isToday || index % 3 == 0,
                    isAnsweredOnServer: answeredOnServer,
                    hasAttachments: index % 4 == 1,
                    // Отправитель отметил важность — в списке значок высокого приоритета.
                    senderPriority: index % 5 == 2 ? .high : nil,
                    // Метки по правилу: у поддержки — заголовки рассылки,
                    // Jira — робот.
                    isBulk: sender.address == "support@service.test",
                    isAutomatic: sender.address == "jira@company.test"
                ))
            )
        }
    }
}

// MARK: - Календарь

@MainActor
public final class DemoCalendar: CalendarProvider {
    public var accessProblem: String? { nil }
    public var onChange: (() -> Void)?
    public var hiddenCalendarIDs: Set<String> = []

    public func calendars() -> [CalendarSourceInfo] {
        [
            CalendarSourceInfo(id: String(localized: "demo-cal-Работа"), title: String(localized: "Работа"), color: Self.work, kind: .events,
                               group: String(localized: "Exchange напрямую · me@company.test"), supportsAttendees: true,
                               groupSymbol: "building.2.crop.circle"),
            CalendarSourceInfo(id: String(localized: "demo-cal-Личное"), title: String(localized: "Личное"), color: Self.personal, kind: .events, group: "iCloud",
                               groupSymbol: "icloud"),
            CalendarSourceInfo(id: String(localized: "demo-cal-Дни рождения"), title: String(localized: "Дни рождения"), color: Self.personal, kind: .events,
                               group: String(localized: "Дни рождения из Контактов"), isWritable: false, groupSymbol: "gift"),
            CalendarSourceInfo(id: String(localized: "demo-list-Работа"), title: String(localized: "Работа"), color: Self.tasks, kind: .reminders, group: "iCloud",
                               groupSymbol: "icloud"),
            CalendarSourceInfo(id: String(localized: "demo-list-Личное"), title: String(localized: "Личное"), color: RGB(0.55, 0.36, 0.96), kind: .reminders,
                               group: "iCloud", groupSymbol: "icloud"),
        ]
    }

    private func isVisible(_ item: TimelineItem) -> Bool {
        switch item.detail {
        case .event(let info): return !hiddenCalendarIDs.contains("demo-cal-\(info.calendarTitle)")
        case .reminder(let info): return !hiddenCalendarIDs.contains("demo-list-\(info.listTitle)")
        case .mail: return true
        }
    }

    private let clock: () -> Date
    private let calendar: Calendar
    private var moved: [String: Date] = [:]
    private var completed: Set<String> = []
    /// Правки в памяти: встреча дня (`имя-день`) и серия (`имя`).
    private var overrides: [String: EventDraft] = [:]
    private var seriesOverrides: [String: EventDraft] = [:]
    private var deleted: Set<String> = []
    /// Серия удалена начиная с этого дня.
    private var deletedSeries: [String: Date] = [:]
    private var created: [(id: Int, draft: EventDraft)] = []
    private var createdReminders: [(id: Int, draft: ReminderDraft)] = []

    nonisolated static let work = RGB(0.23, 0.48, 0.95)
    nonisolated static let personal = RGB(0.24, 0.68, 0.42)
    nonisolated static let tasks = RGB(0.96, 0.58, 0.16)

    public init(clock: @escaping () -> Date, calendar: Calendar = .current) {
        self.clock = clock
        self.calendar = calendar
    }

    public func requestAccess() async {}

    public func items(from: Date, to: Date) async -> [TimelineItem] {
        // Берём с запасом по неделе в обе стороны: перенесённая встреча
        // могла приехать из другого дня.
        let start = from.addingTimeInterval(-7 * 86_400)
        let end = to.addingTimeInterval(7 * 86_400)
        return Demo.days(from: start, to: end, calendar: calendar)
            .flatMap(generate(day:))
            .filter { $0.time >= from && $0.time < to && isVisible($0) }
    }

    public func overdueReminders(before date: Date) async -> [TimelineItem] {
        await items(from: date.addingTimeInterval(-30 * 86_400), to: date)
            .filter { $0.kind == .reminder && $0.reminder?.isCompleted == false }
    }

    public func move(_ item: TimelineItem, to start: Date) async throws {
        guard let key = Self.baseKey(of: item.id) else { throw CalendarError.notFound }
        moved[key] = start
        onChange?()
    }

    public func setCompleted(_ item: TimelineItem, _ done: Bool) async throws {
        guard let key = Self.baseKey(of: item.id) else { throw CalendarError.notFound }
        if done { completed.insert(key) } else { completed.remove(key) }
        onChange?()
    }

    // MARK: - Создание и правка (в памяти)

    public func owns(itemID: String) -> Bool {
        itemID.hasPrefix("event:demo-") || itemID.hasPrefix("reminder:demo-")
    }

    public func owns(calendarID: String) -> Bool {
        calendarID.hasPrefix("demo-")
    }

    public func draft(for item: TimelineItem) async throws -> EventDraft {
        guard let info = item.event else { throw CalendarError.notFound }
        let name = Self.seriesName(of: item.id)
        if let key = Self.baseKey(of: item.id), key.hasPrefix("new-"), let number = Int(key.dropFirst(4).split(separator: "-").first ?? ""),
           let found = created.first(where: { $0.id == number }) {
            var draft = found.draft
            draft.start = item.time
            draft.end = item.end ?? item.time
            return draft
        }
        return EventDraft(
            title: item.title, start: item.time, end: item.end ?? item.time, isAllDay: item.isAllDay,
            location: info.location ?? "", notes: info.notes ?? "", calendarID: "demo-cal-\(info.calendarTitle)",
            attendees: info.attendees.filter { !$0.isMe }.map(\.person),
            recurrence: info.isRecurring ? (name == "standup" ? .weekdaysOnly : RecurrenceRule(frequency: .weekly)) : nil,
            isRecurringSeries: info.isRecurring
        )
    }

    public func create(_ draft: EventDraft) async throws {
        created.append((created.count + 1, draft))
        onChange?()
    }

    public func update(_ item: TimelineItem, to draft: EventDraft, scope: RecurrenceScope) async throws {
        guard let key = Self.baseKey(of: item.id) else { throw CalendarError.notFound }
        if key.hasPrefix("new-"), let number = Int(key.dropFirst(4).split(separator: "-").first ?? ""),
           let index = created.firstIndex(where: { $0.id == number }) {
            created[index].draft = draft
        } else if scope == .thisEvent || item.event?.isRecurring != true {
            overrides[key] = draft
        } else {
            seriesOverrides[Self.seriesName(of: item.id)] = draft
        }
        onChange?()
    }

    public func delete(_ item: TimelineItem, scope: RecurrenceScope) async throws {
        guard let key = Self.baseKey(of: item.id) else { throw CalendarError.notFound }
        if key.hasPrefix("new-"), let number = Int(key.dropFirst(4).split(separator: "-").first ?? "") {
            created.removeAll { $0.id == number }
        } else if scope == .thisEvent || item.event?.isRecurring != true {
            deleted.insert(key)
        } else {
            deletedSeries[Self.seriesName(of: item.id)] = scope == .all ? .distantPast : calendar.startOfDay(for: item.time)
        }
        onChange?()
    }

    public func decline(_ item: TimelineItem) async throws {
        guard let key = Self.baseKey(of: item.id) else { throw CalendarError.notFound }
        deleted.insert(key)
        onChange?()
    }

    public func createReminder(_ draft: ReminderDraft) async throws {
        createdReminders.append((createdReminders.count + 1, draft))
        onChange?()
    }

    /// `event:demo-standup-20260923@…` → `standup`.
    static func seriesName(of id: String) -> String {
        guard let key = baseKey(of: id) else { return "" }
        return key.split(separator: "-").first.map(String.init) ?? key
    }

    static func baseKey(of id: String) -> String? {
        if id.hasPrefix("event:demo-"), let at = id.lastIndex(of: "@") {
            return String(id[id.index(id.startIndex, offsetBy: "event:demo-".count)..<at])
        }
        if id.hasPrefix("reminder:demo-") {
            return String(id.dropFirst("reminder:demo-".count))
        }
        return nil
    }

    /// Выпадает ли созданная встреча на этот день — с учётом повтора.
    private func occurs(_ draft: EventDraft, on day: Date) -> Bool {
        let first = calendar.startOfDay(for: draft.start)
        guard day >= first else { return false }
        guard let rule = draft.recurrence else { return day == first }
        if case .until(let last) = rule.end, day > last { return false }
        let days = calendar.dateComponents([.day], from: first, to: day).day ?? 0
        switch rule.frequency {
        case .daily: return days % rule.interval == 0
        case .weekly:
            let weekdays = rule.weekdays.isEmpty ? [calendar.component(.weekday, from: first)] : rule.weekdays
            return weekdays.contains(calendar.component(.weekday, from: day)) && (days / 7) % rule.interval == 0
        case .monthly: return calendar.component(.day, from: day) == calendar.component(.day, from: first)
        case .yearly:
            return calendar.dateComponents([.month, .day], from: day) == calendar.dateComponents([.month, .day], from: first)
        }
    }

    private func generate(day: Date) -> [TimelineItem] {
        let key = Demo.dayKey(day, calendar: calendar)
        let today = calendar.startOfDay(for: clock())
        let weekday = calendar.component(.weekday, from: day)
        let people = Demo.people
        var result: [TimelineItem] = []

        func event(_ name: String, _ hour: Int, _ minute: Int, minutes: Int, title: String,
                   calendarTitle: String = String(localized: "Работа"), color: RGB = DemoCalendar.work,
                   organizer: Person? = Demo.me, attendees: [Person] = [], link: String? = nil,
                   notes: String? = nil, recurring: Bool = false, myResponse: Attendee.Response = .accepted) {
            let baseKey = "\(name)-\(key)"
            if deleted.contains(baseKey) { return }
            if let cut = deletedSeries[name], day >= cut { return }
            let edit = overrides[baseKey] ?? seriesOverrides[name]
            var title = title
            var minutes = minutes
            var start = moved[baseKey] ?? Demo.at(day, hour, minute, calendar: calendar)
            if let edit {
                title = edit.title
                let parts = calendar.dateComponents([.hour, .minute], from: edit.start)
                start = moved[baseKey] ?? Demo.at(day, parts.hour ?? hour, parts.minute ?? minute, calendar: calendar)
                minutes = Int(edit.duration / 60)
            }
            let mine = organizer == nil || organizer == Demo.me || attendees.isEmpty
            let guests = attendees.map { Attendee(person: $0, response: .accepted) }
                + (attendees.isEmpty ? [] : [Attendee(person: Demo.me, response: myResponse, isMe: true)])
            result.append(TimelineItem(
                id: "event:demo-\(baseKey)@\(Int(start.timeIntervalSince1970))",
                title: title,
                time: start,
                end: start.addingTimeInterval(Double(minutes) * 60),
                color: color,
                detail: .event(EventInfo(
                    calendarTitle: calendarTitle,
                    location: link == nil ? nil : String(localized: "Онлайн"),
                    notes: notes,
                    link: link.flatMap(URL.init(string:)).flatMap { MeetingLink.extract(url: $0, location: nil, notes: nil) },
                    organizer: attendees.isEmpty ? nil : organizer,
                    attendees: guests,
                    canReschedule: mine,
                    isRecurring: recurring,
                    recurrenceSummary: recurring ? RecurrenceRule.weekdaysOnly.summary(start: start) : nil,
                    calendarID: "demo-cal-\(calendarTitle)",
                    canEdit: mine
                ))
            ))
        }

        // Созданные в этом запуске: в свой день и, если повторяются, в дни повтора.
        for (number, draft) in created where occurs(draft, on: day) {
            let parts = calendar.dateComponents([.hour, .minute], from: draft.start)
            let start = Demo.at(day, parts.hour ?? 9, parts.minute ?? 0, calendar: calendar)
            let calendarTitle = draft.calendarID.map { String($0.dropFirst("demo-cal-".count)) } ?? String(localized: "Работа")
            result.append(TimelineItem(
                id: "event:demo-new-\(number)-\(key)@\(Int(start.timeIntervalSince1970))",
                title: draft.title.isEmpty ? String(localized: "Новая встреча") : draft.title,
                time: start,
                end: start.addingTimeInterval(draft.duration),
                isAllDay: draft.isAllDay,
                color: calendarTitle == String(localized: "Личное") ? Self.personal : Self.work,
                detail: .event(EventInfo(
                    calendarTitle: calendarTitle,
                    location: draft.location.isEmpty ? nil : draft.location,
                    notes: draft.notes.isEmpty ? nil : draft.notes,
                    organizer: draft.attendees.isEmpty ? nil : Demo.me,
                    attendees: draft.attendees.map { Attendee(person: $0, response: .pending) }
                        + (draft.attendees.isEmpty ? [] : [Attendee(person: Demo.me, response: .accepted, isMe: true)]),
                    isRecurring: draft.recurrence != nil,
                    recurrenceSummary: draft.recurrence?.summary(start: draft.start),
                    calendarID: draft.calendarID
                ))
            ))
        }
        for (number, draft) in createdReminders {
            guard let due = draft.due, calendar.isDate(due, inSameDayAs: day) else { continue }
            result.append(TimelineItem(
                id: "reminder:demo-new\(number)-\(key)",
                title: draft.title.isEmpty ? String(localized: "Напоминание") : draft.title,
                time: draft.hasTime ? due : day,
                isAllDay: !draft.hasTime,
                color: Self.tasks,
                detail: .reminder(ReminderInfo(listTitle: String(localized: "Работа"), notes: draft.notes, hasTime: draft.hasTime))
            ))
        }

        func reminder(_ name: String, _ hour: Int?, title: String, list: String = String(localized: "Работа"),
                      doneIfPast: Bool = true) {
            let baseKey = "\(name)-\(key)"
            if deleted.contains(baseKey) { return }
            let due = moved[baseKey] ?? Demo.at(day, hour ?? 0, 0, calendar: calendar)
            let isDone = completed.contains(baseKey) || (doneIfPast && day < today)
            result.append(TimelineItem(
                id: "reminder:demo-\(baseKey)",
                title: title,
                time: due,
                isAllDay: hour == nil && moved[baseKey] == nil,
                color: Self.tasks,
                detail: .reminder(ReminderInfo(
                    listTitle: list,
                    isCompleted: isDone,
                    hasTime: hour != nil || moved[baseKey] != nil
                ))
            ))
        }

        let isWeekend = calendar.isDateInWeekend(day)
        if !isWeekend {
            event("standup", 9, 30, minutes: 15, title: String(localized: "Планёрка"),
                  attendees: Array(people[0...2]) + [people[9]],
                  link: "https://telemost.yandex.ru/j/12345678901234",
                  notes: String(localized: "Ежедневная планёрка команды. Каждый — две минуты: что сделал, что мешает."),
                  recurring: true)
            event("review", 11, 0, minutes: 60, title: String(localized: "Обзор квартального плана"),
                  organizer: people[0], attendees: [people[0], people[1], people[2]],
                  link: "https://company.zoom.us/j/9988776655",
                  notes: String(localized: "Повестка:\n— итоги III квартала\n— цели на IV квартал\n— риски по срокам"),
                  myResponse: .pending)
            event("vendor", 11, 30, minutes: 45, title: String(localized: "Созвон с подрядчиком"),
                  attendees: [people[3], people[4]],
                  link: "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
                  notes: String(localized: "Обсудить сроки второго этапа и приёмку."))
            event("lunch", 13, 0, minutes: 60, title: String(localized: "Обед"), calendarTitle: String(localized: "Личное"), color: Self.personal,
                  organizer: nil)
            if weekday == 2 || weekday == 4 || weekday == 6 {
                event("oneonone", 15, 0, minutes: 60, title: String(localized: "1:1 с Андреем"), attendees: [people[1]])
            }
            event("design", 17, 30, minutes: 30, title: String(localized: "Ревью дизайна"),
                  organizer: people[2], attendees: [people[2], people[9]],
                  link: "https://meet.google.com/abc-defg-hij", myResponse: .tentative)

            reminder("report", 12, title: String(localized: "Отправить отчёт в бухгалтерию"))
            reminder("vitamins", 8, title: String(localized: "Выпить витамины"), list: String(localized: "Личное"))
        }
        if weekday == 4 {
            // Событие на весь день — у него нет места на шкале, оно в полосе над ней.
            result.append(TimelineItem(
                id: "event:demo-birthday-\(key)@\(Int(day.timeIntervalSince1970))",
                title: String(localized: "День рождения Марины"),
                time: day,
                end: calendar.date(byAdding: .day, value: 1, to: day),
                isAllDay: true,
                color: Self.personal,
                detail: .event(EventInfo(calendarTitle: String(localized: "Дни рождения"), canReschedule: false, canEdit: false, canDecline: false))
            ))
        }
        if day == today {
            reminder("bank", 15, title: String(localized: "Позвонить в банк"), list: String(localized: "Личное"))
            reminder("groceries", nil, title: String(localized: "Купить продукты"), list: String(localized: "Личное"))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            reminder("internet", 18, title: String(localized: "Оплатить счёт за интернет"), list: String(localized: "Личное"), doneIfPast: false)
        }
        if let earlier = calendar.date(byAdding: .day, value: -3, to: today), day == earlier {
            reminder("pass", 10, title: String(localized: "Продлить пропуск в офис"), doneIfPast: false)
        }
        return result
    }
}

// MARK: - Планирование

/// Выдуманная занятость коллег и адресная книга из тестовых людей —
/// чтобы планировщик можно было проверить без Exchange.
public final class DemoScheduling: SchedulingService {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func availability(of addresses: [String], from: Date, to: Date) async throws -> [String: PersonAvailability] {
        var result: [String: PersonAvailability] = [:]
        for address in addresses {
            if !address.hasSuffix("company.test"), !address.hasSuffix("partner.test") {
                result[address] = PersonAvailability(problem: String(localized: "не найден в адресной книге компании"))
                continue
            }
            var busy: [BusyInterval] = []
            for day in Demo.days(from: from, to: to, calendar: calendar) where !calendar.isDateInWeekend(day) {
                let seed = address.unicodeScalars.reduce(Demo.dayKey(day, calendar: calendar)) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
                var random = SeededGenerator(seed: seed)
                var hour = 9.0 + Double(Int.random(in: 0...3, using: &random)) * 0.5
                while hour < 18 {
                    let length = [0.5, 1, 1, 1.5, 2][Int.random(in: 0..<5, using: &random)]
                    let kind: BusyInterval.Kind = Int.random(in: 0..<6, using: &random) == 0 ? .tentative : .busy
                    let start = day.addingTimeInterval(hour * 3600)
                    busy.append(BusyInterval(start: start, end: start.addingTimeInterval(length * 3600), kind: kind,
                                             subject: Demo.subjects[Int.random(in: 0..<Demo.subjects.count, using: &random)]))
                    hour += length + [0.5, 1, 1.5, 2.5][Int.random(in: 0..<4, using: &random)]
                }
            }
            result[address] = PersonAvailability(busy: busy, workday: 9 * 60...18 * 60)
        }
        return result
    }

    public func searchDirectory(_ text: String) async throws -> [Person] {
        let needle = text.lowercased()
        return Demo.people.filter {
            ($0.name ?? "").lowercased().contains(needle) || ($0.address ?? "").lowercased().contains(needle)
        }
    }
}

extension Demo {
    /// Выдуманная погода на три недели вокруг `now` — для тестового режима
    /// и снимков. Одна и та же при каждом запуске: день решает всё.
    public static func weather(around now: Date, calendar: Calendar) -> WeekWeather {
        let today = calendar.startOfDay(for: now)
        let codes = [0, 2, 3, 61, 80, 1, 3, 45, 0, 63, 2, 3, 71, 1]
        var days: [WeekWeather.Day] = []
        var hours: [WeekWeather.Hour] = []
        for offset in -10...10 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let key = dayKey(day, calendar: calendar)
            let code = codes[abs(key) % codes.count]
            let base = 9 + Double(abs(key) % 7)
            let rainy = [51, 61, 63, 80].contains(code)
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            days.append(WeekWeather.Day(date: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                                        code: code, max: base + 6, min: base - 2, precipitation: rainy ? 70 : 10))
            for hour in 0..<24 {
                guard let time = calendar.date(byAdding: .hour, value: hour, to: day) else { continue }
                // Теплее всего к трём часам дня.
                let warmth = cos(Double(hour - 15) / 24 * 2 * .pi)
                let wet = rainy && (11...17).contains(hour)
                hours.append(WeekWeather.Hour(time: time, temperature: base + 2 + 4 * warmth,
                                              code: wet ? code : (hour < 7 || hour > 20 ? 0 : min(code, 3)),
                                              precipitation: wet ? 60 + hour : 5))
            }
        }
        return WeekWeather(updated: now, place: String(localized: "Москва"), days: days, hours: hours)
    }
}

extension Demo {
    /// Заметки рабочих дней вокруг `now` — для проверки итогов недели и
    /// месяца. Как пишет человек: протоколы встреч, решения, дела.
    public static func dayNotes(around now: Date, calendar: Calendar) -> [String: String] {
        let texts = [
            """
            Обзор квартального плана
            Протокол:
            • Бюджет на рекламу режем на 10%, деньги — в поддержку
            • Ольга готовит новый прогноз к пятнице
            ☑ Отправить Андрею цифры по продажам
            """,
            """
            Созвон с партнёром (Дмитрий Орлов)
            Протокол:
            • Договор продлеваем на год, скидка 5%
            • Юристы смотрят правки до среды
            ☐ Напомнить про счёт за сентябрь
            """,
            """
            Ревью дизайна
            Протокол:
            • Новый экран входа принят, тёмную тему доделать
            • Марина собирает отзывы пользователей
            Мысль: вынести настройки уведомлений в отдельный раздел
            """,
            """
            Весь день — отчёт для правления
            • Отчёт отправлен
            • Вопрос о найме двух разработчиков — перенесли на следующую неделю
            """,
            """
            Планёрка
            Протокол:
            • Релиз 2.4 — в понедельник
            • Андрей в отпуске с 5 по 12 октября
            ☐ Согласовать замену на время отпуска
            """,
        ]
        let today = calendar.startOfDay(for: now)
        var notes: [String: String] = [:]
        for offset in -30...0 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  !calendar.isDateInWeekend(day) else { continue }
            let key = dayKey(day, calendar: calendar)
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            notes[String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)] =
                texts[abs(key) % texts.count]
        }
        return notes
    }
}

extension Demo {
    /// Сводка для виджетов — для предпросмотра без приложения и для галереи
    /// виджетов, пока Trudaybook ещё ни разу её не записал.
    public static func widgetSnapshot(now: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        let day = calendar.startOfDay(for: now)
        // От «сейчас», а не от часов дня: в галерее вечером пример не должен
        // быть пустым. Первая встреча — через 45 минут с ближайшей четверти.
        let base = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 900).rounded(.up) * 900)
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            base.addingTimeInterval(Double(hour * 60 + minute) * 60 - 11 * 3600 + 45 * 60)
        }
        return WidgetSnapshot(
            updated: now,
            events: [
                .init(id: "demo-e0", title: String(localized: "День рождения Марины"), start: day, end: day.addingTimeInterval(86_400),
                      isAllDay: true, location: nil, color: "#34C759"),
                .init(id: "demo-e1", title: String(localized: "Обзор квартального плана"), start: at(11), end: at(12),
                      isAllDay: false, location: String(localized: "Переговорная 3"), color: "#3B82F6"),
                .init(id: "demo-e2", title: String(localized: "Созвон с подрядчиком"), start: at(13, 30), end: at(14, 15),
                      isAllDay: false, location: nil, color: "#3B82F6"),
                .init(id: "demo-e3", title: String(localized: "1:1 с Андреем"), start: at(15), end: at(16),
                      isAllDay: false, location: nil, color: "#AF52DE"),
                .init(id: "demo-e4", title: String(localized: "Ревью дизайна"), start: at(17, 30), end: at(18),
                      isAllDay: false, location: String(localized: "Онлайн"), color: "#FF9500"),
            ],
            reminders: [
                .init(id: "demo-r1", title: String(localized: "Отправить отчёт в бухгалтерию"), due: at(12), done: false),
                .init(id: "demo-r2", title: String(localized: "Позвонить в банк"), due: at(15), done: false),
                .init(id: "demo-r3", title: String(localized: "Купить продукты"), due: nil, done: false),
            ],
            unresolved: 12, important: 3,
            letters: [
                .init(id: "demo-m1", from: String(localized: "Ольга Смирнова"), subject: String(localized: "Согласование бюджета на IV квартал"),
                      time: at(9, 4), important: true),
                .init(id: "demo-m2", from: String(localized: "Андрей Козлов"), subject: String(localized: "Re: Макеты главной страницы"),
                      time: at(9, 2), important: true),
                .init(id: "demo-m3", from: String(localized: "Игорь Петров"), subject: String(localized: "Вопрос по интеграции API"),
                      time: at(9, 1), important: false),
            ],
            weather: .init(code: 2, temperature: 14, max: 17, min: 9))
    }
}
