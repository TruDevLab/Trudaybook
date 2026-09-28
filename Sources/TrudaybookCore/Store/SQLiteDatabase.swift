import Foundation
import SQLite3

/// Тонкая обёртка над SQLite: открыть, выполнить, прочитать строки.
///
/// Общая для отметок «разобрано» и для кэша писем. Потоков не касается:
/// каждый владелец держит свою базу и обращается к ней из одного места.
public final class SQLiteDatabase {
    private var db: OpaquePointer?

    public enum Value: Sendable {
        case text(String)
        case real(Double)
        case integer(Int64)
        case blob(Data)
        case null

        public static func date(_ date: Date?) -> Value {
            date.map { .real($0.timeIntervalSince1970) } ?? .null
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case open(String)
        case sql(String)

        public var description: String {
            switch self {
            case .open(let message): return String(localized: "не открылась база: \(message)")
            case .sql(let message): return String(localized: "ошибка SQLite: \(message)")
            }
        }
    }

    /// Строка результата.
    public struct Row {
        fileprivate let statement: OpaquePointer

        public func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        public func real(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        public func integer(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
        }

        public func date(_ column: Int32) -> Date? {
            real(column).map(Date.init(timeIntervalSince1970:))
        }

        public func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }

    /// Файл в «Поддержке приложений»: `~/Library/Application Support/Trudaybook/<имя>`.
    public static func applicationSupportURL(_ name: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = support.appendingPathComponent("Trudaybook", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Только владельцу: почта, заметки, ящики. Раньше папка была 0755,
        // и другой пользователь этого Mac мог дойти до файлов, если открыт
        // путь к ним.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return folder.appendingPathComponent(name)
    }

    /// `path` — путь к файлу или `":memory:"`.
    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(db)
            db = nil
            throw Failure.open(message)
        }
        // Кэш писем пишется из фона и читается интерфейсом — журнал WAL
        // не даёт чтению ждать записи.
        try? execute("PRAGMA journal_mode = WAL")
    }

    deinit {
        sqlite3_close(db)
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw Failure.sql(message)
        }
    }

    public func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func query(_ sql: String, _ values: [Value] = [], row: (Row) -> Void) {
        guard let statement = try? prepare(sql, values) else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(Row(statement: statement))
        }
    }

    /// Несколько записей одной транзакцией — в разы быстрее по одной.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Строку SQLite должен скопировать сам: Swift-строка живёт только
    /// на время вызова.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.sql(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}
