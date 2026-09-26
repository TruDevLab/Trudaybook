import Foundation
import TrudaybookCore

/// Письмо в кэше: сырые заголовки и флаги. Тело — отдельно и по запросу.
public struct CachedMessage: Sendable, Equatable {
    public var mailbox: String
    public var uid: UInt32
    public var internalDate: Date
    public var flags: [String]
    public var header: Data
    public var size: Int

    public init(mailbox: String, uid: UInt32, internalDate: Date, flags: [String], header: Data, size: Int) {
        self.mailbox = mailbox
        self.uid = uid
        self.internalDate = internalDate
        self.flags = flags
        self.header = header
        self.size = size
    }
}

/// Кэш почты в SQLite: `~/Library/Application Support/Trudaybook/mail.sqlite`.
///
/// Таймлайн открывается из кэша мгновенно, а сервер спрашивается только
/// о новом. Письма хранятся сырыми: разбирает их MIME-разборщик, и если он
/// станет умнее, перекачивать ничего не придётся.
public final class MailCache: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSLock()

    public static func open() throws -> MailCache {
        try MailCache(path: SQLiteDatabase.applicationSupportURL("mail.sqlite").path)
    }

    public static func inMemory() throws -> MailCache {
        try MailCache(path: ":memory:")
    }

    private init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                account TEXT NOT NULL,
                mailbox TEXT NOT NULL,
                uid INTEGER NOT NULL,
                internal_date REAL NOT NULL,
                flags TEXT NOT NULL,
                header BLOB NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (account, mailbox, uid)
            );
            CREATE INDEX IF NOT EXISTS messages_by_date ON messages (account, mailbox, internal_date);
            CREATE TABLE IF NOT EXISTS bodies (
                account TEXT NOT NULL,
                mailbox TEXT NOT NULL,
                uid INTEGER NOT NULL,
                raw BLOB NOT NULL,
                fetched_at REAL NOT NULL,
                PRIMARY KEY (account, mailbox, uid)
            );
            CREATE TABLE IF NOT EXISTS mailbox_state (
                account TEXT NOT NULL,
                mailbox TEXT NOT NULL,
                uidvalidity INTEGER NOT NULL,
                PRIMARY KEY (account, mailbox)
            );
            CREATE TABLE IF NOT EXISTS remote_ids (
                account TEXT NOT NULL,
                uid INTEGER NOT NULL,
                remote_id TEXT NOT NULL,
                PRIMARY KEY (account, uid)
            );
            CREATE UNIQUE INDEX IF NOT EXISTS remote_ids_by_id ON remote_ids (account, remote_id);
            CREATE TABLE IF NOT EXISTS uid_sequence (
                account TEXT PRIMARY KEY,
                last INTEGER NOT NULL
            );
            """)
        try migrate()
    }

    private func migrate() throws {
        var version: Int64 = 0
        db.query("PRAGMA user_version") { row in version = row.integer(0) ?? 0 }
        if version < 1 {
            // Раньше номер письма Exchange выдавался как «наибольший + 1», и
            // номер ушедшего письма (архив, ответ на приглашение) доставался
            // новому — под старым письмом открывалось чужое тело. Номера
            // теперь только растут. Счёт начинаем с запасом: номера, уже
            // забытые выше нынешнего наибольшего, тоже не должны вернуться
            // (по ним в приложении хранятся «в архиве», приоритеты). Тела —
            // кэш, их проще скачать заново, чем искать подменённые.
            try db.transaction {
                try db.run("""
                    INSERT OR REPLACE INTO uid_sequence (account, last)
                    SELECT account, MAX(uid) + 10000 FROM remote_ids GROUP BY account
                    """)
                try db.run("DELETE FROM bodies")
                try db.run("PRAGMA user_version = 1")
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Заголовки

    public func upsert(_ messages: [CachedMessage], account: String) throws {
        try locked {
            try db.transaction {
                for message in messages {
                    try db.run("""
                        INSERT INTO messages (account, mailbox, uid, internal_date, flags, header, size)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(account, mailbox, uid) DO UPDATE SET
                            internal_date = excluded.internal_date, flags = excluded.flags,
                            header = excluded.header, size = excluded.size
                        """, [.text(account), .text(message.mailbox), .integer(Int64(message.uid)),
                              .date(message.internalDate), .text(message.flags.joined(separator: " ")),
                              .blob(message.header), .integer(Int64(message.size))])
                }
            }
        }
    }

    public func updateFlags(_ flags: [UInt32: [String]], mailbox: String, account: String) throws {
        try locked {
            try db.transaction {
                for (uid, list) in flags {
                    try db.run("UPDATE messages SET flags = ? WHERE account = ? AND mailbox = ? AND uid = ?",
                               [.text(list.joined(separator: " ")), .text(account), .text(mailbox), .integer(Int64(uid))])
                }
            }
        }
    }

    public func delete(_ uids: [UInt32], mailbox: String, account: String) throws {
        try locked {
            try db.transaction {
                for uid in uids {
                    let key: [SQLiteDatabase.Value] = [.text(account), .text(mailbox), .integer(Int64(uid))]
                    try db.run("DELETE FROM messages WHERE account = ? AND mailbox = ? AND uid = ?", key)
                    try db.run("DELETE FROM bodies WHERE account = ? AND mailbox = ? AND uid = ?", key)
                }
            }
        }
    }

    public func messages(mailbox: String, account: String, from: Date, to: Date) -> [CachedMessage] {
        locked {
            read("""
                SELECT mailbox, uid, internal_date, flags, header, size FROM messages
                WHERE account = ? AND mailbox = ? AND internal_date >= ? AND internal_date < ?
                ORDER BY internal_date
                """, [.text(account), .text(mailbox), .date(from), .date(to)])
        }
    }

    /// Папка как на сервере: без писем, которые мы из неё уже убрали.
    public func latest(mailbox: String, account: String, limit: Int) -> [CachedMessage] {
        locked {
            read("""
                SELECT mailbox, uid, internal_date, flags, header, size FROM messages
                WHERE account = ? AND mailbox = ? AND instr(flags, ?) = 0
                ORDER BY internal_date DESC LIMIT ?
                """, [.text(account), .text(mailbox), .text(Self.movedFlag), .integer(Int64(limit))])
        }
    }

    // MARK: - Ушедшие письма

    /// Отметка письма, которое мы сами убрали из папки (в архив, ответом на
    /// приглашение). Строка остаётся: таймлайн дня показывает его разобранным,
    /// а тело открывается из кэша. Сверка с сервером таких не видит.
    public static let movedFlag = "$TrudaybookMoved"

    public func markMoved(_ uids: [UInt32], mailbox: String, account: String) throws {
        try locked {
            try db.transaction {
                for uid in uids {
                    try db.run("""
                        UPDATE messages SET flags = TRIM(flags || ' ' || ?1)
                        WHERE account = ?2 AND mailbox = ?3 AND uid = ?4 AND instr(flags, ?1) = 0
                        """, [.text(Self.movedFlag), .text(account), .text(mailbox), .integer(Int64(uid))])
                }
            }
        }
    }

    /// Ушедшие письма старше даты — забыть совсем, вместе с телами.
    public func pruneMoved(before date: Date, account: String) throws {
        try locked {
            try db.transaction {
                let values: [SQLiteDatabase.Value] = [.text(account), .text(Self.movedFlag), .date(date)]
                try db.run("""
                    DELETE FROM bodies WHERE account = ?1 AND (mailbox, uid) IN (
                        SELECT mailbox, uid FROM messages WHERE account = ?1 AND instr(flags, ?2) > 0 AND internal_date < ?3)
                    """, values)
                try db.run("DELETE FROM messages WHERE account = ?1 AND instr(flags, ?2) > 0 AND internal_date < ?3", values)
            }
        }
    }

    public func message(uid: UInt32, mailbox: String, account: String) -> CachedMessage? {
        locked {
            read("SELECT mailbox, uid, internal_date, flags, header, size FROM messages WHERE account = ? AND mailbox = ? AND uid = ?",
                 [.text(account), .text(mailbox), .integer(Int64(uid))]).first
        }
    }

    public func uids(mailbox: String, account: String, since: Date) -> [UInt32] {
        locked {
            var result: [UInt32] = []
            // Ушедшие нами — не в счёт: на сервере их в этой папке уже нет.
            db.query("SELECT uid FROM messages WHERE account = ? AND mailbox = ? AND internal_date >= ? AND instr(flags, ?) = 0",
                     [.text(account), .text(mailbox), .date(since), .text(Self.movedFlag)]) { row in
                if let uid = row.integer(0) { result.append(UInt32(truncatingIfNeeded: uid)) }
            }
            return result
        }
    }

    private func read(_ sql: String, _ values: [SQLiteDatabase.Value]) -> [CachedMessage] {
        var result: [CachedMessage] = []
        db.query(sql, values) { row in
            guard let mailbox = row.text(0), let uid = row.integer(1), let date = row.date(2) else { return }
            result.append(CachedMessage(
                mailbox: mailbox,
                uid: UInt32(truncatingIfNeeded: uid),
                internalDate: date,
                flags: (row.text(3) ?? "").split(separator: " ").map(String.init),
                header: row.blob(4) ?? Data(),
                size: Int(row.integer(5) ?? 0)
            ))
        }
        return result
    }

    // MARK: - Тела

    public func body(uid: UInt32, mailbox: String, account: String) -> Data? {
        locked {
            var raw: Data?
            db.query("SELECT raw FROM bodies WHERE account = ? AND mailbox = ? AND uid = ?",
                     [.text(account), .text(mailbox), .integer(Int64(uid))]) { row in raw = row.blob(0) }
            return raw
        }
    }

    public func storeBody(_ raw: Data, uid: UInt32, mailbox: String, account: String) throws {
        try locked {
            try db.run("""
                INSERT OR REPLACE INTO bodies (account, mailbox, uid, raw, fetched_at) VALUES (?, ?, ?, ?, ?)
                """, [.text(account), .text(mailbox), .integer(Int64(uid)), .blob(raw), .date(Date())])
        }
    }

    /// Тела, которые давно не открывали, — выбросить: их всегда можно
    /// скачать снова, а место на диске не бесконечно.
    public func pruneBodies(olderThan date: Date) throws {
        try locked { try db.run("DELETE FROM bodies WHERE fetched_at < ?", [.date(date)]) }
    }

    // MARK: - Состояние папок

    public func uidValidity(mailbox: String, account: String) -> UInt32? {
        locked {
            var value: UInt32?
            db.query("SELECT uidvalidity FROM mailbox_state WHERE account = ? AND mailbox = ?",
                     [.text(account), .text(mailbox)]) { row in value = row.integer(0).map { UInt32(truncatingIfNeeded: $0) } }
            return value
        }
    }

    /// Новая UIDVALIDITY значит, что старые UID ничего не стоят:
    /// кэш папки сбрасывается целиком.
    public func resetIfNeeded(uidValidity: UInt32, mailbox: String, account: String) throws {
        guard self.uidValidity(mailbox: mailbox, account: account) != uidValidity else { return }
        try locked {
            try db.transaction {
                let key: [SQLiteDatabase.Value] = [.text(account), .text(mailbox)]
                try db.run("DELETE FROM messages WHERE account = ? AND mailbox = ?", key)
                try db.run("DELETE FROM bodies WHERE account = ? AND mailbox = ?", key)
                try db.run("INSERT OR REPLACE INTO mailbox_state (account, mailbox, uidvalidity) VALUES (?, ?, ?)",
                           key + [.integer(Int64(uidValidity))])
            }
        }
    }

    // MARK: - Номера писем Exchange

    /// Короткий номер для длинного Id письма Exchange. Номер нужен, чтобы
    /// письма Exchange лежали в кэше так же, как письма IMAP (по UID),
    /// и не меняется, пока у письма тот же Id.
    public func localUID(for remoteID: String, account: String) throws -> UInt32 {
        try locked {
            var found: Int64?
            db.query("SELECT uid FROM remote_ids WHERE account = ? AND remote_id = ?",
                     [.text(account), .text(remoteID)]) { row in found = row.integer(0) }
            if let found { return UInt32(truncatingIfNeeded: found) }
            // Номер никогда не выдаётся второй раз: по нему живут тело в кэше,
            // выделение, «в архиве» и приоритет в приложении.
            var last: Int64 = 0
            db.query("""
                SELECT MAX(COALESCE((SELECT MAX(uid) FROM remote_ids WHERE account = ?1), 0),
                           COALESCE((SELECT last FROM uid_sequence WHERE account = ?1), 0))
                """, [.text(account)]) { row in last = row.integer(0) ?? 0 }
            let uid = last + 1
            try db.transaction {
                try db.run("INSERT INTO remote_ids (account, uid, remote_id) VALUES (?, ?, ?)",
                           [.text(account), .integer(uid), .text(remoteID)])
                try db.run("INSERT OR REPLACE INTO uid_sequence (account, last) VALUES (?, ?)",
                           [.text(account), .integer(uid)])
            }
            return UInt32(truncatingIfNeeded: uid)
        }
    }

    public func remoteID(uid: UInt32, account: String) -> String? {
        locked {
            var found: String?
            db.query("SELECT remote_id FROM remote_ids WHERE account = ? AND uid = ?",
                     [.text(account), .integer(Int64(uid))]) { row in found = row.text(0) }
            return found
        }
    }

    public func forgetRemoteIDs(_ uids: [UInt32], account: String) throws {
        try locked {
            try db.transaction {
                for uid in uids {
                    try db.run("DELETE FROM remote_ids WHERE account = ? AND uid = ?", [.text(account), .integer(Int64(uid))])
                }
            }
        }
    }

    /// Забыть ящик целиком — когда его удаляют из настроек.
    public func forget(account: String) throws {
        try locked {
            try db.transaction {
                for table in ["messages", "bodies", "mailbox_state", "remote_ids", "uid_sequence"] {
                    try db.run("DELETE FROM \(table) WHERE account = ?", [.text(account)])
                }
            }
        }
    }
}
