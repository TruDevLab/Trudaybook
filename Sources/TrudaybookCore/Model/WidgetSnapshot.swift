import Foundation

/// Сводка для виджетов на рабочем столе.
///
/// Виджет — отдельный процесс в песочнице: ни базы, ни почты он не видит.
/// Trudaybook кладёт сводку файлом в свою папку, а виджету подписью
/// разрешено читать только её (`TrudaybookWidgets.entitlements`). В сводке —
/// то, что виджет показывает, и ничего больше: встречи и напоминания на два
/// дня, число неразобранных писем и первые из них, погода.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var location: String?
        /// Цвет календаря `#RRGGBB`.
        public var color: String?

        public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, location: String?, color: String?) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.location = location
            self.color = color
        }
    }

    public struct Reminder: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var due: Date?
        public var done: Bool

        public init(id: String, title: String, due: Date?, done: Bool) {
            self.id = id
            self.title = title
            self.due = due
            self.done = done
        }
    }

    public struct Letter: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var from: String
        /// Тема — если в настройках разрешено показывать её на рабочем столе.
        public var subject: String?
        public var time: Date
        public var important: Bool

        public init(id: String, from: String, subject: String?, time: Date, important: Bool) {
            self.id = id
            self.from = from
            self.subject = subject
            self.time = time
            self.important = important
        }
    }

    public struct Weather: Codable, Equatable, Sendable {
        public var code: Int
        public var temperature: Double?
        public var max: Double?
        public var min: Double?

        public init(code: Int, temperature: Double?, max: Double?, min: Double?) {
            self.code = code
            self.temperature = temperature
            self.max = max
            self.min = min
        }
    }

    public static let version = 1
    public var version = WidgetSnapshot.version
    public var updated: Date
    public var events: [Event]
    public var reminders: [Reminder]
    public var unresolved: Int
    public var important: Int
    public var letters: [Letter]
    public var weather: Weather?

    public init(updated: Date, events: [Event], reminders: [Reminder], unresolved: Int, important: Int,
                letters: [Letter], weather: Weather?) {
        self.updated = updated
        self.events = events
        self.reminders = reminders
        self.unresolved = unresolved
        self.important = important
        self.letters = letters
        self.weather = weather
    }

    public static let maxEvents = 40
    public static let maxReminders = 30
    public static let maxLetters = 6
    /// Потолок файла: сводка — килобайты; больше — чужой или битый файл.
    public static let maxFileSize = 256 * 1024

    /// Папка сводки — в настоящем домашнем каталоге: в песочнице виджета
    /// `homeDirectoryForCurrentUser` указывает в его контейнер.
    public static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Trudaybook/widget", isDirectory: true)
    }

    public static var file: URL { folder.appendingPathComponent("snapshot.json") }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    public static func decode(_ data: Data) -> WidgetSnapshot? {
        guard data.count <= maxFileSize else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data), snapshot.version == version else { return nil }
        return snapshot
    }

    /// Сводка из элементов календаря (сегодня и завтра — виджет сам
    /// перелистнёт полночь) и неразобранных писем.
    public static func make(now: Date, calendarItems: [TimelineItem], unresolved: [TimelineItem],
                            isImportant: (TimelineItem) -> Bool, showSubjects: Bool,
                            weather: Weather?) -> WidgetSnapshot {
        let events = calendarItems
            .filter { $0.kind == .event && $0.event?.myResponse != .declined && $0.event?.isCancelled != true }
            .sorted { $0.time < $1.time }
            .prefix(maxEvents)
            .map { item in
                Event(id: item.id, title: String(item.title.prefix(200)), start: item.time,
                      end: item.end ?? item.time.addingTimeInterval(1800), isAllDay: item.isAllDay,
                      location: item.event?.location.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) },
                      color: item.color.map(hex))
            }
        let reminders = calendarItems
            .filter { $0.kind == .reminder }
            .sorted { $0.time < $1.time }
            .prefix(maxReminders)
            .map { Reminder(id: $0.id, title: String($0.title.prefix(200)),
                            due: ($0.reminder?.hasTime ?? false) ? $0.time : nil,
                            done: $0.reminder?.isCompleted ?? false) }
        let mail = unresolved.filter { $0.kind == .mail }
        let important = mail.filter(isImportant)
        // Первыми — важные, потом свежие.
        let letters = (important + mail.filter { !isImportant($0) })
            .prefix(maxLetters)
            .map { item in
                Letter(id: item.id, from: String((item.mail?.from.display ?? "").prefix(100)),
                       subject: showSubjects ? String(item.title.prefix(200)) : nil,
                       time: item.time, important: isImportant(item))
            }
        return WidgetSnapshot(updated: now, events: Array(events), reminders: Array(reminders),
                              unresolved: mail.count, important: important.count, letters: Array(letters),
                              weather: weather)
    }

    static func hex(_ color: RGB) -> String {
        let value = { (component: Double) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value(color.red), value(color.green), value(color.blue))
    }

    /// Встречи, которые ещё идут или впереди, — на момент `date`.
    public func upcoming(at date: Date, calendar: Calendar = .current) -> [Event] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return events.filter { !$0.isAllDay && $0.end > date && $0.start < dayEnd }
    }

    /// События на весь день — на день `date`.
    public func allDay(at date: Date, calendar: Calendar = .current) -> [Event] {
        events.filter { $0.isAllDay && calendar.isDate($0.start, inSameDayAs: date) }
    }

    /// Напоминания дня `date`: невыполненные, по сроку.
    public func openReminders(at date: Date, calendar: Calendar = .current) -> [Reminder] {
        reminders.filter { !$0.done && ($0.due.map { calendar.isDate($0, inSameDayAs: date) || $0 < date } ?? true) }
    }

    /// Когда виджету перерисоваться: начало или конец ближайшей встречи.
    public func nextChange(after date: Date) -> Date? {
        events.flatMap { [$0.start, $0.end] }.filter { $0 > date }.min()
    }
}
