import Foundation
import Testing
@testable import TrudaybookCore
@testable import TrudaybookMail

@Suite("Безопасность: ссылки, вложения, Exchange")
struct SecurityTests {
    @Test("Ссылки из письма: сайты и mailto — сразу, файлы и программы — с вопросом, код — никогда")
    func ссылки() throws {
        func decide(_ text: String) throws -> MailLinkPolicy.Decision { MailLinkPolicy.decide(try #require(URL(string: text))) }
        #expect(try decide("https://example.test/a") == .open)
        #expect(try decide("HTTP://example.test") == .open)
        #expect(try decide("mailto:a@example.test") == .open)
        #expect(try decide("file:///Users/me/Downloads/invoice.command") == .ask)
        #expect(try decide("smb://server/share") == .ask)
        #expect(try decide("x-apple.systempreferences:com.apple.preference.security") == .ask)
        #expect(try decide("javascript:alert(1)") == .block)
        #expect(try decide("data:text/html,<b>x</b>") == .block)
    }

    @Test("Вложения: исполняемые узнаются, имя не притворяется другим расширением")
    func вложения() {
        #expect(AttachmentRisk.isExecutable(name: "Счёт.command"))
        #expect(AttachmentRisk.isExecutable(name: "setup.PKG"))
        #expect(!AttachmentRisk.isExecutable(name: "Отчёт.pdf"))
        // «счёт‮fdp.command» выглядит как «счёт command.pdf».
        let disguised = "счёт\u{202E}fdp.command"
        #expect(AttachmentRisk.safeName(disguised) == "счётfdp.command")
        #expect(AttachmentRisk.isExecutable(name: disguised))
        #expect(AttachmentRisk.safeName("../../.ssh/id_rsa") == "-..-.ssh-id_rsa")
        #expect(AttachmentRisk.safeName("...") == nil)
        #expect(AttachmentRisk.safeName("a\nb\tc.txt") == "abc.txt")
        let long = String(repeating: "а", count: 400) + ".pdf"
        #expect((AttachmentRisk.safeName(long) ?? "").count == 200)
        #expect(AttachmentRisk.safeName(long)?.hasSuffix(".pdf") == true)
    }

    @Test("Exchange — только HTTPS")
    func exchange() {
        #expect(EWSClient.endpoint(for: "post.company.test")?.absoluteString == "https://post.company.test/EWS/Exchange.asmx")
        #expect(EWSClient.endpoint(for: "https://post.company.test/EWS/Exchange.asmx") != nil)
        #expect(EWSClient.endpoint(for: "http://post.company.test/EWS/Exchange.asmx") == nil)
        #expect(MailAccount.exchange(email: "a@company.test", name: "", server: "http://post.company.test", login: "") == nil)
    }

    @Test("Имя файла письма — без символов направления")
    func имяПисьма() {
        #expect(!MessageBuilder.exportFileName("Счёт\u{202E}fdp").contains("\u{202E}"))
    }
}

/// Связка ключей в памяти: записи и сколько раз к ним обращались.
private final class MemoryKeychain: SecretBackend, @unchecked Sendable {
    var items: [String: Data] = [:]
    var reads: [String] = []
    /// Эти записи «не даются» — как если человек нажал «Запретить».
    var denied: Set<String> = []

    func read(_ account: String) -> (status: OSStatus, data: Data?) {
        reads.append(account)
        if denied.contains(account) { return (errSecAuthFailed, nil) }
        guard let data = items[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func write(_ account: String, data: Data, label: String) -> OSStatus {
        if denied.contains(account) { return errSecAuthFailed }
        items[account] = data
        return errSecSuccess
    }

    func delete(_ account: String) { items[account] = nil }
}

@Suite("Секреты — одной записью Связки ключей")
struct SecretVaultTests {
    @Test("Прежние отдельные записи (пароль и ключ кэша) переносятся в одну и удаляются")
    func перенос() throws {
        let keychain = MemoryKeychain()
        let oldKey = Data(repeating: 7, count: 32)
        keychain.items = ["acc-1": Data("секрет".utf8), "mail-cache-key": oldKey]
        let vault = SecretVault(backend: keychain)
        #expect(vault.password(for: "acc-1") == "секрет")
        #expect(vault.cacheKey() == oldKey)
        #expect(Set(keychain.items.keys) == ["trudaybook-secrets"])

        // Следующий запуск — одна запись, одно чтение на всё.
        keychain.reads = []
        let next = SecretVault(backend: keychain)
        #expect(next.password(for: "acc-1") == "секрет")
        #expect(next.cacheKey() == oldKey)
        #expect(next.password(for: "acc-1") == "секрет")
        #expect(keychain.reads == ["trudaybook-secrets"])
    }

    @Test("Новый ключ кэша и пароль — в ту же запись; удаление ящика убирает пароль")
    func запись() throws {
        let keychain = MemoryKeychain()
        let vault = SecretVault(backend: keychain)
        let key = try #require(vault.cacheKey())
        #expect(key.count == 32)
        try vault.setPassword("p1", for: "a")
        try vault.setPassword("p2", for: "b")
        vault.deletePassword(for: "a")
        #expect(Set(keychain.items.keys) == ["trudaybook-secrets"])
        let next = SecretVault(backend: keychain)
        #expect(next.password(for: "a") == nil)
        #expect(next.password(for: "b") == "p2")
        #expect(next.cacheKey() == key)
    }

    @Test("Связка отказала — запись не затирается пустой, пароль не записывается")
    func отказ() throws {
        let keychain = MemoryKeychain()
        let saved = SecretVault(backend: keychain)
        try saved.setPassword("p", for: "a")
        let before = keychain.items
        keychain.denied = ["trudaybook-secrets"]
        let vault = SecretVault(backend: keychain)
        #expect(vault.password(for: "a") == nil)
        #expect(vault.cacheKey() == nil)
        #expect(throws: Keychain.Failure.self) { try vault.setPassword("x", for: "b") }
        keychain.denied = []
        #expect(keychain.items == before)
    }

    @Test("Прежний ключ кэша не дался — новый не заводится: кэш под старым не пропадёт")
    func старыйКлючНеДался() {
        let keychain = MemoryKeychain()
        keychain.items = ["mail-cache-key": Data(repeating: 1, count: 32)]
        keychain.denied = ["mail-cache-key"]
        let vault = SecretVault(backend: keychain)
        #expect(vault.cacheKey() == nil)
        #expect(keychain.items["trudaybook-secrets"] == nil)
    }
}
