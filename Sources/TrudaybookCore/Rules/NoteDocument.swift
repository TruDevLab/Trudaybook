import Foundation

/// Кусок заметки, собранной приложением: повестка дня или итоги периода.
///
/// Заметку собирает ядро списком блоков, а оформленным текстом её делает
/// приложение (`NoteRichText`): так раскладку повестки можно проверить
/// тестом, не поднимая AppKit.
public enum NoteBlock: Equatable, Sendable {
    /// Заголовок заметки.
    case title(String)
    /// Раздел: «Главное», «Встречи»…
    case heading(String)
    /// Встреча в повестке.
    case subheading(String)
    /// Подпись над местом для записей — «Протокол».
    case label(String)
    case text(String)
    /// Второстепенная строка: место, участники.
    case detail(String)
    /// Пункт списка; пустой — место, куда писать.
    case bullet(String)
    case numbered(Int, String)
    /// Пункт с галочкой: напоминание дня.
    case check(String, done: Bool)
    /// Пустая строка между разделами.
    case spacer
}

public enum NoteMarkers {
    /// Метки списков в начале строки — те же, что ставит редактор.
    public static let bullet = "• "
    public static let unchecked = "☐ "
    public static let checked = "☑ "
}

// MARK: - Текст модели

/// Ответ модели — облегчённый Markdown — в блоки заметки.
///
/// Модели пишут списки кто «- », кто «* », кто «• », заголовки — «## » или
/// «**Итоги:**». Всё приводится к меткам редактора; звёздочки и обратные
/// кавычки убираются — в заметке они были бы мусором.
public enum NoteMarkdown {
    public static func blocks(from text: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = blocks.last, last != .spacer { blocks.append(.spacer) }
                continue
            }
            blocks.append(block(line))
        }
        while blocks.last == .spacer { blocks.removeLast() }
        return blocks
    }

    static func block(_ line: String) -> NoteBlock {
        if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
            let level = line[match].filter { $0 == "#" }.count
            let text = inline(String(line[match.upperBound...]))
            return level >= 3 ? .subheading(text) : .heading(text)
        }
        if let match = line.range(of: "^[-*•–]\\s+\\[( |x|X)\\]\\s*", options: .regularExpression) {
            let done = line[match].lowercased().contains("[x]")
            return .check(inline(String(line[match.upperBound...])), done: done)
        }
        if let match = line.range(of: "^[-*•–]\\s+", options: .regularExpression) {
            return .bullet(inline(String(line[match.upperBound...])))
        }
        if let match = line.range(of: "^\\d{1,3}[.)]\\s+", options: .regularExpression) {
            let number = Int(line[match].filter(\.isNumber)) ?? 1
            return .numbered(number, inline(String(line[match.upperBound...])))
        }
        // Строка целиком жирным — заголовок раздела: «**Решения:**».
        if line.hasPrefix("**"), line.hasSuffix("**") || line.hasSuffix("**:"), line.count > 4 {
            return .heading(inline(line).trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
        }
        return .text(inline(line))
    }

    /// Без разметки внутри строки: `**жирный**`, `__так__`, `` `код` ``.
    static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Повестка дня

/// Повестка дня: встречи, напоминания и важные письма, а от модели
/// Trunook — главное на день и строка «к встрече» у каждой встречи.
///
/// Раскладка — наша, а не модели: под каждой встречей должен быть
/// раздел «Протокол», и маленькая местная модель его то забудет, то
/// переименует. Модель дописывает только то, что умеет лучше правил.
public enum DayAgenda {
    public struct Meeting: Equatable, Sendable {
        public var key: String
        public var title: String
        public var start: Date
        public var end: Date?
        public var isAllDay: Bool
        public var location: String?
        public var people: [String]
        /// Неразобранные письма от участников: «тема — имя».
        public var letters: [String]

        public init(key: String, title: String, start: Date, end: Date?, isAllDay: Bool,
                    location: String?, people: [String], letters: [String] = []) {
            self.key = key
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.location = location
            self.people = people
            self.letters = letters
        }
    }

    public struct Reminder: Equatable, Sendable {
        public var title: String
        public var due: Date?
        public var done: Bool

        public init(title: String, due: Date?, done: Bool) {
            self.title = title
            self.due = due
            self.done = done
        }
    }

    public struct Letter: Equatable, Sendable {
        public var key: String
        public var subject: String
        public var from: String
        public var snippet: String
        public var important: Bool

        public init(key: String, subject: String, from: String, snippet: String, important: Bool) {
            self.key = key
            self.subject = subject
            self.from = from
            self.snippet = snippet
            self.important = important
        }
    }

    public struct Input: Equatable, Sendable {
        public var meetings: [Meeting]
        public var reminders: [Reminder]
        public var letters: [Letter]

        public init(meetings: [Meeting], reminders: [Reminder], letters: [Letter]) {
            self.meetings = meetings
            self.reminders = reminders
            self.letters = letters
        }

        public var isEmpty: Bool { meetings.isEmpty && reminders.isEmpty && letters.isEmpty }
    }

    /// Что дописала модель.
    public struct Answer: Equatable, Sendable {
        public var focus: [String]
        /// Ярлык встречи («e1») → что подготовить.
        public var meetings: [String: String]

        public init(focus: [String], meetings: [String: String]) {
            self.focus = focus
            self.meetings = meetings
        }
    }

    public static let maxMeetings = 20
    public static let maxReminders = 20
    public static let maxLetters = 15
    public static let maxPeople = 8
    public static let maxMeetingLetters = 3

    /// Что пойдёт в повестку из элементов дня и неразобранных писем.
    ///
    /// Встречи — кроме отклонённых; напоминания — все, выполненные тоже
    /// (галочкой). Письма — сначала важные (выбор человека или метка),
    /// потом свежие от людей: из них модель выберет, что главное.
    public static func input(dayItems: [TimelineItem], letters: [TimelineItem],
                             isImportant: (TimelineItem) -> Bool) -> Input {
        let events = dayItems
            .filter { $0.kind == .event && $0.event?.myResponse != .declined && $0.event?.isCancelled != true }
            .sorted { ($0.isAllDay ? 0 : 1, $0.time) < ($1.isAllDay ? 0 : 1, $1.time) }
            .prefix(maxMeetings)
        let mail = letters.filter { $0.kind == .mail }
        let meetings = events.enumerated().map { index, item in
            let others = (item.event?.attendees ?? []).filter { !$0.isMe && $0.response != .declined }
            // «К встрече» — правилом, а не моделью: письма от участников.
            // Маленькая модель вместо связи писем со встречей писала
            // «подготовить материалы к планёрке».
            let addresses = Set(others.compactMap(\.person.normalizedAddress)
                                + [item.event?.organizer?.normalizedAddress].compactMap { $0 })
            let related = mail
                .filter { letter in letter.mail?.from.normalizedAddress.map(addresses.contains) ?? false }
                .prefix(maxMeetingLetters)
                .map { "«\($0.title)» — \($0.mail?.from.display ?? "")" }
            return Meeting(key: "e\(index + 1)", title: item.title, start: item.time, end: item.end,
                           isAllDay: item.isAllDay, location: item.event?.location.flatMap { $0.isEmpty ? nil : $0 },
                           people: Array(others.map(\.person.display).prefix(maxPeople)), letters: Array(related))
        }
        let reminders = dayItems
            .filter { $0.kind == .reminder }
            .sorted { $0.time < $1.time }
            .prefix(maxReminders)
            .map { Reminder(title: $0.title, due: ($0.reminder?.hasTime ?? false) ? $0.time : nil,
                            done: $0.reminder?.isCompleted ?? false) }
        let important = mail.filter(isImportant)
        let others = mail.filter { item in
            guard !isImportant(item), let info = item.mail else { return false }
            return !info.isBulk && !info.isAutomatic
        }
        let chosen = (important + others).prefix(maxLetters)
        let picked = chosen.enumerated().map { index, item in
            Letter(key: "m\(index + 1)", subject: item.title, from: item.mail?.from.display ?? "",
                   snippet: String((item.mail?.snippet ?? "").prefix(200)), important: isImportant(item))
        }
        return Input(meetings: meetings, reminders: Array(reminders), letters: picked)
    }

    /// Подписи разделов — переведённые приложением.
    public struct Words: Sendable {
        public var focus: String
        public var meetings: String
        public var noMeetings: String
        public var allDay: String
        public var people: String
        public var prepare: String
        public var protocolLabel: String
        public var reminders: String
        public var letters: String
        public var from: String
        public var lettersFromPeople: String

        public init(focus: String, meetings: String, noMeetings: String, allDay: String, people: String,
                    prepare: String, protocolLabel: String, reminders: String, letters: String, from: String,
                    lettersFromPeople: String) {
            self.focus = focus
            self.meetings = meetings
            self.noMeetings = noMeetings
            self.allDay = allDay
            self.people = people
            self.prepare = prepare
            self.protocolLabel = protocolLabel
            self.reminders = reminders
            self.letters = letters
            self.from = from
            self.lettersFromPeople = lettersFromPeople
        }

    }

    /// Повестка блоками. Без ответа модели — те же разделы без «Главного»
    /// и строк «к встрече»: её можно вставить, когда Trunook недоступен.
    public static func document(_ input: Input, answer: Answer?, title: String, words: Words,
                                time: (Date) -> String) -> [NoteBlock] {
        var blocks: [NoteBlock] = [.title(title)]

        let focus = answer?.focus.filter { !$0.isEmpty } ?? []
        if !focus.isEmpty {
            blocks += [.spacer, .heading(words.focus)]
            // Главное — дела на день: с галочкой, чтобы отмечать сделанное.
            blocks += focus.map { .check($0, done: false) }
        }

        blocks += [.spacer, .heading(words.meetings)]
        if input.meetings.isEmpty {
            blocks.append(.detail(words.noMeetings))
        }
        // События на весь день — строкой: день рождения или отпуск не
        // встреча, протокол им ни к чему.
        let allDay = input.meetings.filter(\.isAllDay)
        if !allDay.isEmpty {
            blocks.append(.detail("\(words.allDay): \(allDay.map(\.title).joined(separator: " · "))"))
        }
        for (index, meeting) in input.meetings.filter({ !$0.isAllDay }).enumerated() {
            if index > 0 || !allDay.isEmpty { blocks.append(.spacer) }
            let when: String
            if let end = meeting.end, end > meeting.start {
                when = "\(time(meeting.start))–\(time(end))"
            } else {
                when = time(meeting.start)
            }
            blocks.append(.subheading("\(when) · \(meeting.title)"))
            var details: [String] = []
            if let location = meeting.location { details.append(location) }
            if !meeting.people.isEmpty { details.append("\(words.people): \(meeting.people.joined(separator: ", "))") }
            if !details.isEmpty { blocks.append(.detail(details.joined(separator: " · "))) }
            if !meeting.letters.isEmpty {
                blocks.append(.text("\(words.lettersFromPeople): \(meeting.letters.joined(separator: "; "))"))
            }
            if let prepare = answer?.meetings[meeting.key], !prepare.isEmpty {
                blocks.append(.text("\(words.prepare): \(prepare)"))
            }
            blocks.append(.label(words.protocolLabel))
            blocks.append(.bullet(""))
        }

        if !input.reminders.isEmpty {
            blocks += [.spacer, .heading(words.reminders)]
            blocks += input.reminders.map { reminder in
                let text = reminder.due.map { "\(time($0)) · \(reminder.title)" } ?? reminder.title
                return .check(text, done: reminder.done)
            }
        }

        let important = input.letters.filter(\.important)
        if !important.isEmpty {
            blocks += [.spacer, .heading(words.letters)]
            // Важное письмо — это «ответить»: тоже с галочкой.
            blocks += important.map { letter in
                .check(letter.from.isEmpty ? letter.subject : "\(letter.subject) — \(words.from) \(letter.from)", done: false)
            }
        }
        return blocks
    }
}

// MARK: - Итоги недели и месяца

public enum NoteDigest {
    /// Сколько текста заметок отдавать модели всего: месяц заметок —
    /// десятки тысяч знаков, а местная модель на длинном теряет начало.
    public static let maxText = 12_000
    /// Меньше этого заметку не режем: от трёх строк смысла не остаётся.
    public static let minPerNote = 400

    public struct Note: Equatable, Sendable {
        public var day: String
        public var text: String

        public init(day: String, text: String) {
            self.day = day
            self.text = text
        }
    }

    /// Заметки дней по порядку, без пустых; каждая — не длиннее своей доли,
    /// всё вместе — не длиннее `maxText`.
    public static func notes(_ texts: [String: String], days: [String]) -> [Note] {
        let present = days.compactMap { day -> Note? in
            let text = texts[day]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : Note(day: day, text: text)
        }
        guard !present.isEmpty else { return [] }
        let share = max(minPerNote, maxText / present.count)
        var total = 0
        var result: [Note] = []
        for note in present {
            let text = String(note.text.prefix(min(share, maxText - total)))
            guard !text.isEmpty else { break }
            total += text.count
            result.append(Note(day: note.day, text: text))
        }
        return result
    }

    /// Итоги блоками: наш заголовок и текст модели.
    public static func document(title: String, text: String) -> [NoteBlock] {
        var body = NoteMarkdown.blocks(from: text)
        // Модель любит начать со своего заголовка («# Итоги недели»), а он
        // у нас уже есть. Свой — это заголовок, за которым сразу раздел.
        if case .heading? = body.first,
           body.dropFirst().first(where: { $0 != .spacer }).map({ if case .heading = $0 { true } else { false } }) == true {
            body.removeFirst()
        }
        while body.first == .spacer { body.removeFirst() }
        return [.title(title), .spacer] + body
    }
}
