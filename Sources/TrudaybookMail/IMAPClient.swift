import Foundation

public enum MailNetworkError: LocalizedError, Equatable {
    case closed
    case timeout
    case server(String)
    case authentication(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return String(localized: "Сервер закрыл соединение")
        case .timeout: return String(localized: "Сервер не ответил вовремя")
        case .server(let text): return String(localized: "Сервер ответил ошибкой: \(text)")
        case .authentication(let text): return String(localized: "Не удалось войти: \(text)")
        case .protocolError(let text): return String(localized: "Непонятный ответ сервера: \(text)")
        }
    }
}

/// Поток байтов до почтового сервера.
///
/// `URLSessionStreamTask`, а не Network.framework: он умеет включить TLS
/// посреди соединения (`startSecureConnection`), а без этого не работает
/// STARTTLS у SMTP на порту 587. Для IMAP на 993 TLS включается сразу.
final class MailStream: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private let timeout: TimeInterval

    init(host: String, port: Int, implicitTLS: Bool, timeout: TimeInterval = 60) {
        session = URLSession(configuration: .ephemeral)
        task = session.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        if implicitTLS { task.startSecureConnection() }
        task.resume()
    }

    func startTLS() {
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.cancel()
        session.invalidateAndCancel()
    }

    func write(_ data: Data) async throws {
        let task = self.task
        let timeout = self.timeout
        try await OnceContinuation.run { resume in
            task.write(data, timeout: timeout) { error in
                resume(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    /// Строка до `\n` включительно.
    func readLine(timeout custom: TimeInterval? = nil) async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex...newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            try await fill(timeout: custom ?? timeout)
        }
    }

    func read(count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill(timeout: timeout)
        }
        let chunk = buffer.prefix(count)
        buffer = Data(buffer.dropFirst(count))
        return Data(chunk)
    }

    private func fill(timeout: TimeInterval) async throws {
        let task = self.task
        let (data, atEOF): (Data?, Bool) = try await OnceContinuation.run { resume in
            task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout) { data, atEOF, error in
                resume(error.map { .failure($0) } ?? .success((data, atEOF)))
            }
        }
        if let data, !data.isEmpty {
            buffer.append(data)
        } else if atEOF {
            throw MailNetworkError.closed
        }
    }
}

/// Continuation, которое возобновляется ровно один раз.
///
/// `URLSessionStreamTask` при обрыве соединения зовёт обработчик чтения
/// дважды: с ошибкой таймаута и ещё раз при отмене. Встроенный async-вариант
/// `readData` на втором вызове роняет процесс (повторное возобновление
/// continuation) — это поймано на недоступном сервере. Второй вызов здесь
/// просто отбрасывается.
enum OnceContinuation {
    static func run<T>(_ body: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            body { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
        }
    }

    /// Работа с пределом по времени. Не через группу задач: группа ждёт
    /// завершения всех детей, и зависшее ожидание сети подвесило бы и её.
    /// Здесь по истечении срока ошибка возвращается сразу, а зависшая
    /// работа отменяется и дочищается вызывающим (закрытием соединения).
    static func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await run { resume in
            let work = Task {
                do { resume(.success(try await operation())) } catch { resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                work.cancel()
                resume(.failure(MailNetworkError.timeout))
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}

/// Состояние папки после `SELECT`.
public struct IMAPSelection: Sendable, Equatable {
    public var exists: Int = 0
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32 = 0
    public var readOnly = false
}

/// Соединение с IMAP-сервером. Команды идут строго по одной.
public actor IMAPClient {
    public let host: String
    public let port: Int
    private var stream: MailStream?
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []
    public private(set) var selected: String?
    /// Отладочный журнал обмена; пароль в него не попадает.
    private var log: (@Sendable (String) -> Void)?

    public init(host: String, port: Int = 993) {
        self.host = host
        self.port = port
    }

    public var isConnected: Bool { stream != nil }

    public func setLog(_ log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    public func connect() async throws {
        disconnect()
        log?("соединяюсь с \(host):\(port)")
        let stream = MailStream(host: host, port: port, implicitTLS: true)
        self.stream = stream
        do {
            let greeting = try await readResponse()
            log?("← приветствие: \(greeting)")
            if case .status(let status, let code, let text) = greeting {
                guard status == "OK" || status == "PREAUTH" else { throw MailNetworkError.server(text) }
                if let code, code.uppercased().hasPrefix("CAPABILITY") { parseCapabilities(code) }
            }
            if capabilities.isEmpty { try await run("CAPABILITY") }
        } catch {
            log?("соединение не удалось: \(error)")
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        stream?.close()
        stream = nil
        selected = nil
    }

    public func login(user: String, password: String) async throws {
        do {
            // Пароль с не-ASCII символами в кавычках слать нельзя — литералом.
            if IMAPArgument.needsLiteral(password) || IMAPArgument.needsLiteral(user) {
                try await run("LOGIN", literals: [Data(user.utf8), Data(password.utf8)], redacted: true)
            } else {
                try await run("LOGIN \(IMAPArgument.quoted(user)) \(IMAPArgument.quoted(password))", redacted: true)
            }
        } catch MailNetworkError.server(let text) {
            throw MailNetworkError.authentication(text)
        }
        // После входа сервер часто сообщает больше возможностей.
        try await run("CAPABILITY")
    }

    public func logout() async {
        _ = try? await run("LOGOUT")
        disconnect()
    }

    // MARK: - Папки

    public func listMailboxes() async throws -> [IMAPMailbox] {
        let responses = try await run(#"LIST "" "*""#)
        return responses.compactMap { response in
            if case .data(let values) = response { return IMAPMailbox(values) }
            return nil
        }
    }

    @discardableResult
    public func select(_ mailbox: String, readOnly: Bool = false) async throws -> IMAPSelection {
        let responses = try await run("\(readOnly ? "EXAMINE" : "SELECT") \(IMAPArgument.quoted(mailbox))")
        var selection = IMAPSelection(readOnly: readOnly)
        for response in responses {
            switch response {
            case .data(let values) where values.count == 2 && values[1].text?.uppercased() == "EXISTS":
                selection.exists = Int(values[0].number ?? 0)
            case .status(_, let code?, _):
                let parts = code.split(separator: " ")
                if parts.first?.uppercased() == "UIDVALIDITY", parts.count > 1 { selection.uidValidity = UInt32(parts[1]) ?? 0 }
                if parts.first?.uppercased() == "UIDNEXT", parts.count > 1 { selection.uidNext = UInt32(parts[1]) ?? 0 }
            default:
                break
            }
        }
        selected = mailbox
        return selection
    }

    // MARK: - Письма

    public func uidSearch(_ criteria: String) async throws -> [UInt32] {
        Self.searchResults(try await run("UID SEARCH \(criteria)"))
    }

    /// Поиск по тексту на сервере. Слово с кириллицей уходит литералом
    /// с `CHARSET UTF-8`, иначе сервер его не поймёт.
    public func uidSearchText(_ text: String, field: String = "TEXT") async throws -> [UInt32] {
        if IMAPArgument.needsLiteral(text) {
            return Self.searchResults(try await run("UID SEARCH CHARSET UTF-8 \(field)", literals: [Data(text.utf8)]))
        }
        return try await uidSearch("\(field) \(IMAPArgument.quoted(text))")
    }

    private static func searchResults(_ responses: [IMAPResponse]) -> [UInt32] {
        responses.flatMap { response -> [UInt32] in
            guard case .data(let values) = response, values.first?.text?.uppercased() == "SEARCH" else { return [] }
            return values.dropFirst().compactMap { $0.number.map { UInt32(truncatingIfNeeded: $0) } }
        }
    }

    public func uidFetch(_ uids: [UInt32], items: String) async throws -> [IMAPFetch] {
        guard !uids.isEmpty else { return [] }
        let responses = try await run("UID FETCH \(IMAPArgument.uidSet(uids)) \(items)")
        return responses.compactMap { response in
            if case .data(let values) = response { return IMAPFetch(values) }
            return nil
        }
    }

    public func uidStore(_ uids: [UInt32], _ change: String) async throws {
        guard !uids.isEmpty else { return }
        try await run("UID STORE \(IMAPArgument.uidSet(uids)) \(change)")
    }

    /// Переложить письма в другую папку. Без расширения MOVE — копией,
    /// пометкой «удалено» и вычисткой.
    public func uidMove(_ uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        let set = IMAPArgument.uidSet(uids)
        if capabilities.contains("MOVE") {
            try await run("UID MOVE \(set) \(IMAPArgument.quoted(mailbox))")
            return
        }
        try await run("UID COPY \(set) \(IMAPArgument.quoted(mailbox))")
        try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        // UID EXPUNGE трогает только эти письма, а простой EXPUNGE вычистил бы
        // и чужие пометки «удалено» — если сервер его не умеет, так и быть.
        try await run(capabilities.contains("UIDPLUS") ? "UID EXPUNGE \(set)" : "EXPUNGE")
    }

    /// Положить письмо в папку — копию отправленного в «Отправленные».
    public func append(_ message: Data, to mailbox: String, flags: String = "(\\Seen)") async throws {
        try await run("APPEND \(IMAPArgument.quoted(mailbox)) \(flags)", literals: [message])
    }

    public func noop() async throws {
        try await run("NOOP")
    }

    // MARK: - Обмен

    /// Отправить команду и собрать ответы до завершающей строки с тегом.
    /// `NO` и `BAD` превращаются в ошибку с текстом сервера.
    ///
    /// Литералы дописываются в конец команды: ` {n}`, ожидание `+` от сервера,
    /// байты; следующий литерал — так же, с пробелом перед `{`.
    @discardableResult
    func run(_ command: String, literals: [Data] = [], redacted: Bool = false) async throws -> [IMAPResponse] {
        guard let stream else { throw MailNetworkError.closed }
        tagCounter += 1
        let tag = "t\(tagCounter)"
        let shown = redacted ? (command.split(separator: " ").first.map(String.init) ?? "") + " ***" : command
        log?("→ \(tag) \(shown)")

        var responses: [IMAPResponse] = []
        if literals.isEmpty {
            try await stream.write(Data("\(tag) \(command)\r\n".utf8))
        } else {
            var prefix = "\(tag) \(command)"
            for literal in literals {
                try await stream.write(Data("\(prefix) {\(literal.count)}\r\n".utf8))
                // Ждём приглашения «+»; всё, что сервер скажет до него, — тоже ответы.
                waiting: while true {
                    let response = try await readResponse()
                    switch response {
                    case .continuation:
                        break waiting
                    case .tagged(tag, let status, _, let text):
                        throw status == "OK" ? MailNetworkError.protocolError(text) : MailNetworkError.server(text)
                    default:
                        responses.append(response)
                    }
                }
                try await stream.write(literal)
                prefix = ""
            }
            try await stream.write(Data("\r\n".utf8))
        }

        while true {
            let response = try await readResponse()
            if case .tagged(let responseTag, let status, let code, let text) = response, responseTag == tag {
                log?("← \(tag) \(status) \(text)")
                guard status == "OK" else {
                    throw MailNetworkError.server([code.map { "[\($0)]" }, text].compactMap { $0 }.joined(separator: " "))
                }
                if let code, code.uppercased().hasPrefix("CAPABILITY") { parseCapabilities(code) }
                return responses
            }
            if case .data(let values) = response, values.first?.text?.uppercased() == "CAPABILITY" {
                capabilities = Set(values.dropFirst().compactMap { $0.text?.uppercased() })
            }
            if case .status("BYE", _, let text) = response, !command.hasPrefix("LOGOUT") {
                disconnect()
                throw MailNetworkError.server(text)
            }
            responses.append(response)
        }
    }

    private func readResponse() async throws -> IMAPResponse {
        guard let stream else { throw MailNetworkError.closed }
        var line = try await stream.readLine()
        while let count = IMAPParser.pendingLiteral(in: line) {
            line += try await stream.read(count: count)
            line += try await stream.readLine()
        }
        do {
            return try IMAPParser.parse(line)
        } catch {
            throw MailNetworkError.protocolError(String(decoding: line.prefix(200), as: UTF8.self))
        }
    }

    private func parseCapabilities(_ code: String) {
        capabilities = Set(code.split(separator: " ").dropFirst().map { $0.uppercased() })
    }
}
