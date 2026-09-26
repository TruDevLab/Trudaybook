import Foundation
import Testing
@testable import TrudaybookMail

@Suite("Сбои соединения")
struct ConnectionFailureTests {
    /// Зависшая работа прерывается по сроку, а не держит форму вечно.
    @Test func timeoutReturnsEvenIfWorkNeverFinishes() async {
        let started = Date()
        await #expect(throws: MailNetworkError.timeout) {
            try await OnceContinuation.withTimeout(0.3) {
                // Ожидание, которое само не кончается, — как потерянный ответ сети.
                try await withCheckedThrowingContinuation { (_: CheckedContinuation<Void, Error>) in }
            }
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// Недоступный сервер — ошибка, а не падение процесса.
    @Test func refusedConnectionThrows() async {
        let client = IMAPClient(host: "127.0.0.1", port: 1)
        await #expect(throws: (any Error).self) { try await client.connect() }
        await client.disconnect()
    }
}

/// Молчащий сервер (`nc -l 127.0.0.1 <порт>`): принимает соединение,
/// но TLS не начинает. Соединение должно кончиться ошибкой, а не ожиданием
/// навсегда. Медленно (минута), поэтому только по запросу:
/// `TRUDAYBOOK_SILENT_PORT=19993 swift test --filter SilentServer`.
@Suite("Молчащий сервер", .enabled(if: ProcessInfo.processInfo.environment["TRUDAYBOOK_SILENT_PORT"] != nil))
struct SilentServerTests {
    @Test func connectToSilentServerFailsInsteadOfHanging() async {
        let port = Int(ProcessInfo.processInfo.environment["TRUDAYBOOK_SILENT_PORT"] ?? "") ?? 19993
        let client = IMAPClient(host: "127.0.0.1", port: port)
        let started = Date()
        var outcome = "успех"
        do {
            try await OnceContinuation.withTimeout(90) { try await client.connect() }
        } catch {
            outcome = "\(error)"
        }
        print("молчащий сервер: \(outcome) за \(Int(Date().timeIntervalSince(started))) с")
        #expect(outcome != "успех")
    }
}

/// Проверки с настоящими серверами — только по запросу:
/// `TRUDAYBOOK_NET=1 make test`. Без входа: соединение, TLS, приветствие.
@Suite("Сеть", .enabled(if: ProcessInfo.processInfo.environment["TRUDAYBOOK_NET"] != nil))
struct NetworkSmokeTests {
    @Test func iCloudIMAPGreetsAndListsCapabilities() async throws {
        let client = IMAPClient(host: "imap.mail.me.com", port: 993)
        try await client.connect()
        let capabilities = await client.capabilities
        #expect(capabilities.contains("IMAP4REV1") || capabilities.contains("IMAP4"))
        print("возможности iCloud IMAP: \(capabilities.sorted().joined(separator: " "))")
        await client.logout()
    }
}
