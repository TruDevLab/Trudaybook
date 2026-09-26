import Foundation

/// Отметки «разобрано» по элементам таймлайна — в SQLite.
///
/// Таблица `item_state`: одна строка на элемент, у которого есть хоть одна
/// отметка. Даты — секунды Unix (`REAL`). Строка без отметок удаляется,
/// чтобы база не копила пустые записи за каждое открытое письмо.
/// Таблица `meta` — служебные значения: например, порог `mail_cutoff`.
public final class ItemStateStore {
    private let db: SQLiteDatabase

    /// База в «Поддержке приложений»: `~/Library/Application Support/Trudaybook/state.sqlite`.
    public static func defaultURL() throws -> URL {
        try SQLiteDatabase.applicationSupportURL("state.sqlite")
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    /// База в памяти — для тестов и тестового режима.
    public static func inMemory() throws -> ItemStateStore {
        try ItemStateStore(path: ":memory:")
    }

    private init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS item_state (
                id TEXT PRIMARY KEY,
                archived_at REAL,
                answered_at REAL,
                snoozed_until REAL,
                done_at REAL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS day_notes (
                day TEXT PRIMARY KEY,
                text TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS item_priority (
                id TEXT PRIMARY KEY,
                priority INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
    }

    // MARK: - Отметки

    public func allStates() -> [String: LocalState] {
        var result: [String: LocalState] = [:]
        db.query("SELECT id, archived_at, answered_at, snoozed_until, done_at FROM item_state") { row in
            guard let id = row.text(0) else { return }
            result[id] = LocalState(archivedAt: row.date(1), answeredAt: row.date(2),
                                    snoozedUntil: row.date(3), doneAt: row.date(4))
        }
        return result
    }

    public func state(for id: String) -> LocalState? {
        var found: LocalState?
        db.query("SELECT archived_at, answered_at, snoozed_until, done_at FROM item_state WHERE id = ?", [.text(id)]) { row in
            found = LocalState(archivedAt: row.date(0), answeredAt: row.date(1),
                               snoozedUntil: row.date(2), doneAt: row.date(3))
        }
        return found
    }

    /// Записывает отметки элемента. Пустое состояние удаляет строку.
    public func set(_ state: LocalState, for id: String, now: Date = Date()) throws {
        if state.isEmpty {
            try db.run("DELETE FROM item_state WHERE id = ?", [.text(id)])
            return
        }
        try db.run("""
            INSERT INTO item_state (id, archived_at, answered_at, snoozed_until, done_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                archived_at = excluded.archived_at,
                answered_at = excluded.answered_at,
                snoozed_until = excluded.snoozed_until,
                done_at = excluded.done_at,
                updated_at = excluded.updated_at
            """, [.text(id), .date(state.archivedAt), .date(state.answeredAt),
                  .date(state.snoozedUntil), .date(state.doneAt), .date(now)])
    }

    /// Меняет отметки элемента и возвращает, что получилось.
    @discardableResult
    public func update(_ id: String, now: Date = Date(), _ change: (inout LocalState) -> Void) throws -> LocalState {
        var state = self.state(for: id) ?? LocalState()
        change(&state)
        try set(state, for: id, now: now)
        return state
    }

    // MARK: - Заметки на день

    /// Ключ дня — `yyyy-MM-dd` по календарю человека: заметка привязана
    /// к дню, а не к моменту, и не должна «переезжать» при смене пояса.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func note(for day: String) -> String {
        var text = ""
        db.query("SELECT text FROM day_notes WHERE day = ?", [.text(day)]) { row in text = row.text(0) ?? "" }
        return text
    }

    /// Когда заметку дня правили последний раз.
    public func noteUpdated(for day: String) -> Date? {
        var date: Date?
        db.query("SELECT updated_at FROM day_notes WHERE day = ?", [.text(day)]) { row in date = row.date(0) }
        return date
    }

    /// Пустая заметка (одни пробелы) удаляет строку.
    public func setNote(_ text: String, for day: String, now: Date = Date()) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try db.run("DELETE FROM day_notes WHERE day = ?", [.text(day)])
            return
        }
        try db.run("""
            INSERT INTO day_notes (day, text, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
            """, [.text(day), .text(text), .date(now)])
    }

    /// Дни, у которых есть заметка, — для отметки в календаре месяца.
    public func daysWithNotes() -> Set<String> {
        var days: Set<String> = []
        db.query("SELECT day FROM day_notes") { row in if let day = row.text(0) { days.insert(day) } }
        return days
    }

    // MARK: - Приоритеты

    /// Приоритеты, выбранные человеком. «Без приоритета» тоже хранится:
    /// это отказ от важности, которую поставил отправитель.
    public func allPriorities() -> [String: Priority] {
        var result: [String: Priority] = [:]
        db.query("SELECT id, priority FROM item_priority") { row in
            guard let id = row.text(0), let value = row.integer(1),
                  let priority = Priority(rawValue: Int(value)) else { return }
            result[id] = priority
        }
        return result
    }

    /// `nil` — забыть выбор, снова показывать важность от отправителя.
    public func setPriority(_ priority: Priority?, for id: String) throws {
        guard let priority else {
            try db.run("DELETE FROM item_priority WHERE id = ?", [.text(id)])
            return
        }
        try db.run("""
            INSERT INTO item_priority (id, priority) VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET priority = excluded.priority
            """, [.text(id), .integer(Int64(priority.rawValue))])
    }

    // MARK: - Служебные значения

    public func meta(_ key: String) -> String? {
        var value: String?
        db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { row in value = row.text(0) }
        return value
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(value)])
    }

    /// Порог для «Не разобрано»: письма старше него не считаются.
    ///
    /// Задаётся один раз, при первом запуске, — `days` дней назад — и дальше
    /// не сдвигается: иначе неразобранное письмо «пропадало» бы само через
    /// неделю, а не после действия человека.
    public func mailCutoff(defaultDays days: Int = 7, now: Date = Date()) -> Date {
        if let stored = meta("mail_cutoff"), let seconds = Double(stored) {
            return Date(timeIntervalSince1970: seconds)
        }
        let cutoff = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(days) * 86_400)
        try? setMeta("mail_cutoff", String(cutoff.timeIntervalSince1970))
        return cutoff
    }
}
