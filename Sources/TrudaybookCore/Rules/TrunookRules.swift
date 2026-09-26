import Foundation

/// Правила связи с вырезом Trunook: что и когда туда сообщать. Без текста
/// и без файлов — только выбор; слова и отправка живут в приложении.
public enum TrunookRules {
    /// Встречи, о которых пора сказать: начало в ближайшие `lead` секунд,
    /// не на весь день, ещё не объявленные. Окно, а не точка: проверка идёт
    /// раз в полминуты, и точный миг всегда проскочил бы.
    public static func meetingsDue(_ events: [TimelineItem], now: Date, lead: TimeInterval,
                                   announced: Set<String>) -> [TimelineItem] {
        events.filter { item in
            guard item.kind == .event, !item.isAllDay, !announced.contains(item.id) else { return false }
            let seconds = item.time.timeIntervalSince(now)
            return seconds > 0 && seconds <= lead
        }
        .sorted { $0.time < $1.time }
    }

    /// Люди встречи, кроме меня: организатор и участники.
    public static func participants(of event: TimelineItem) -> Set<String> {
        guard case .event(let info) = event.detail else { return [] }
        var people = info.attendees.filter { !$0.isMe }.map(\.person)
        if let organizer = info.organizer { people.append(organizer) }
        return Set(people.compactMap(\.normalizedAddress))
    }

    /// Неразобранные письма от людей встречи — свежие сверху.
    public static func letters(from event: TimelineItem, in unresolved: [TimelineItem],
                               mine: (Person) -> Bool = { _ in false }) -> [TimelineItem] {
        let people = participants(of: event)
        guard !people.isEmpty else { return [] }
        return unresolved.filter { item in
            guard let from = item.mail?.from, !mine(from), let address = from.normalizedAddress else { return false }
            return people.contains(address)
        }
        .sorted { $0.time > $1.time }
    }

    /// Встречу из календаря macOS Trunook видит сам и сам о ней напомнит;
    /// календарь Exchange, прочитанный напрямую, ему не виден.
    public static func trunookSeesItself(_ event: TimelineItem) -> Bool {
        event.id.hasPrefix("event:") && !event.id.hasPrefix("event:ews:") && !event.id.hasPrefix("event:demo-")
    }

    /// Письма, чей срок «отложено до» наступил после `since` и не позже `now`.
    public static func returnedSnoozes(_ states: [String: LocalState], since: Date, now: Date) -> [String] {
        states.compactMap { id, state in
            guard id.hasPrefix("mail:"), state.archivedAt == nil, state.answeredAt == nil, state.doneAt == nil,
                  let until = state.snoozedUntil, until > since, until <= now else { return nil }
            return id
        }
        .sorted()
    }

    /// Другие встречи, которые приглашение задевает по времени.
    public static func conflicts(start: Date, end: Date, with events: [TimelineItem],
                                 ignoring title: String? = nil) -> [TimelineItem] {
        events.filter { item in
            guard item.kind == .event, !item.isAllDay else { return false }
            let itemEnd = item.end ?? item.time.addingTimeInterval(1800)
            // Это та же встреча, уже лежащая в календаре, — не конфликт.
            if let title, item.title == title, abs(item.time.timeIntervalSince(start)) < 60 { return false }
            return item.time < end && itemEnd > start
        }
        .sorted { $0.time < $1.time }
    }

    /// «Всё разобрано»: список опустел на глазах, а не был пуст с запуска.
    /// Праздник — не чаще раза в `quiet` секунд: разобрал одно, пришло
    /// новое, разобрал снова — второй залп подряд уже шум.
    public static func inboxJustCleared(previous: Int?, current: Int, lastCelebration: Date?, now: Date,
                                        quiet: TimeInterval = 3600) -> Bool {
        guard let previous, previous > 0, current == 0 else { return false }
        if let lastCelebration, now.timeIntervalSince(lastCelebration) < quiet { return false }
        return true
    }
}

/// Сводка для Trunook: файл `state.json`, который Trudaybook переписывает,
/// а Trunook читает — плитка «Почта» и отметки писем на шкале дня.
/// Только числа, время и (по желанию) тема с отправителем одного письма:
/// ни адресов, ни текста писем.
public struct TrunookState: Codable, Equatable, Sendable {
    public struct Letter: Codable, Equatable, Sendable {
        public var title: String
        public var from: String
    }

    public struct Mark: Codable, Equatable, Sendable {
        public var time: Date
        public var important: Bool
        public var done: Bool
    }

    public var version = 1
    public var updated: Date
    /// Сколько в «Не разобрано».
    public var unresolved: Int
    /// Из них с высоким приоритетом.
    public var important: Int
    /// Главное неразобранное письмо — если разрешено показывать темы.
    public var top: Letter?
    /// Письма сегодняшних Входящих — по времени получения.
    public var marks: [Mark]
    /// Trudaybook принимает команды помощника Trunook — пока это так,
    /// Trunook даёт помощнику инструменты почты.
    public var commands = false

    /// Собрать сводку. `priority` — приоритет письма (свой или отправителя),
    /// `done` — разобрано ли.
    public static func make(unresolved: [TimelineItem], today: [TimelineItem], updated: Date,
                            subjects: Bool, commands: Bool = false, priority: (TimelineItem) -> Priority,
                            done: (TimelineItem) -> Bool) -> TrunookState {
        let letters = unresolved.filter { $0.kind == .mail }
        let important = letters.filter { priority($0) == .high }
        let pick = (important.isEmpty ? letters : important).max { $0.time < $1.time }
        let top = subjects ? pick.flatMap { item in
            item.mail.map { Letter(title: String(item.title.prefix(120)), from: String($0.from.display.prefix(60))) }
        } : nil
        let marks = today.filter { $0.kind == .mail }
            .sorted { $0.time < $1.time }
            .suffix(300)
            .map { Mark(time: $0.time, important: priority($0) == .high, done: done($0)) }
        return TrunookState(updated: updated, unresolved: unresolved.count, important: important.count,
                            top: top, marks: Array(marks), commands: commands)
    }

    /// Та же сводка без времени записи — чтобы не переписывать файл
    /// каждые полминуты, когда ничего не изменилось.
    public func sameContent(as other: TrunookState) -> Bool {
        var a = self, b = other
        a.updated = .distantPast
        b.updated = .distantPast
        return a == b
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Фокус в Trunook: файл `focus.json`, который пишет Trunook, пока идёт
/// рабочая фаза таймера. Trudaybook на это время придерживает уведомления.
public struct TrunookFocus: Codable, Equatable, Sendable {
    public var focus: Bool
    public var until: Date?

    public init(focus: Bool, until: Date?) {
        self.focus = focus
        self.until = until
    }

    /// Фокус идёт сейчас. Срок обязателен: упавший Trunook не должен
    /// оставить почту немой навсегда.
    public func isActive(at now: Date) -> Bool {
        guard focus, let until else { return false }
        return until > now && until < now.addingTimeInterval(4 * 3600)
    }

    public static func decode(_ data: Data) -> TrunookFocus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrunookFocus.self, from: data)
    }
}

/// Заметка дня, общая с Trunook: файл `ГГГГ-ММ-ДД.txt` в папке
/// `trunook/notes`. Кто правил последним — того и текст.
public enum DayNoteSync {
    public enum Step: Equatable, Sendable {
        /// Наша заметка новее — записать файл.
        case export
        /// Файл новее (правили в Trunook) — забрать текст.
        case importFile
        case none
    }

    /// Секунда люфта: время правки файла и базы пишутся не одновременно.
    public static func step(noteText: String, noteUpdated: Date?, fileText: String?, fileModified: Date?) -> Step {
        let same = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            == (fileText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if same { return .none }
        guard let fileText, let fileModified else { return noteText.isEmpty ? .none : .export }
        guard let noteUpdated else { return .importFile }
        return fileModified > noteUpdated.addingTimeInterval(1) ? .importFile : .export
    }

    /// Имя файла дня.
    public static func fileName(_ dayKey: String) -> String { dayKey + ".txt" }

    /// День из имени файла: только `ГГГГ-ММ-ДД.txt` — прочее в папке не наше.
    public static func dayKey(fromFileName name: String) -> String? {
        guard name.hasSuffix(".txt") else { return nil }
        let key = String(name.dropLast(4))
        let parts = key.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return key
    }
}
