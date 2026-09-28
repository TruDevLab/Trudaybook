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
