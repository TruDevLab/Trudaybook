import Foundation
import Testing
@testable import TrudaybookCore
@testable import TrudaybookMail

@Suite("Шифрование кэша писем")
struct MailCacheSealingTests {
    @Test("Заголовки и тела на диске зашифрованы, чужой ключ не читает, подделка не проходит")
    func шифр() throws {
        let key = try #require(DataSealer(keyData: DataSealer.newKeyData()))
        let plain = Data("Subject: Секрет\r\n\r\n".utf8)
        let sealed = try key.seal(plain)
        #expect(DataSealer.isSealed(sealed))
        #expect(!sealed.contains(plain))
        #expect(key.open(sealed) == plain)
        let other = try #require(DataSealer(keyData: DataSealer.newKeyData()))
        #expect(other.open(sealed) == nil)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        #expect(key.open(tampered) == nil)
        // Старая запись открытым текстом читается как есть.
        #expect(key.open(plain) == plain)
        #expect(DataSealer(keyData: Data(count: 16)) == nil)
    }

    @Test("Кэш с ключом: пишет шифром, читает обратно")
    func кэш() throws {
        let key = try #require(DataSealer(keyData: DataSealer.newKeyData()))
        let cache = try MailCache.inMemory(sealer: key)
        let header = Data("Subject: Отчёт\r\nFrom: a@x\r\n\r\n".utf8)
        try cache.upsert([CachedMessage(mailbox: "INBOX", uid: 1, internalDate: Date(), flags: [], header: header, size: 10)],
                         account: "a")
        try cache.storeBody(Data("тело".utf8), uid: 1, mailbox: "INBOX", account: "a")
        #expect(cache.body(uid: 1, mailbox: "INBOX", account: "a") == Data("тело".utf8))
        #expect(cache.message(uid: 1, mailbox: "INBOX", account: "a")?.header == header)
    }
}
