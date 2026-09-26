import Foundation
import Testing
@testable import TrudaybookCore
@testable import TrudaybookMail

@Suite("Исходящее письмо")
struct MessageBuilderTests {
    private let anna = Person(name: "Анна Смирнова", address: "anna@x.ru")
    private let me = Person(name: "Иван", address: "me@icloud.com")

    private var reply: OutgoingMail {
        OutgoingMail(
            to: [anna],
            cc: [Person(name: "Petrov, I.", address: "p@x.ru")],
            subject: "Re: Согласование бюджета на IV квартал — финальная версия документа",
            text: "Согласен.\nОтправлю завтра.",
            html: "Согласен.<br><b>Отправлю завтра.</b>",
            quote: .init(attribution: "23 сентября 2026, 07:48, Анна пишет:",
                         html: "<html><head><style>p{}</style></head><body><p>Прошу согласовать</p><script>x()</script></body></html>",
                         text: "Прошу согласовать"),
            inReplyTo: "orig@x.ru",
            references: ["root@x.ru", "orig@x.ru"]
        )
    }

    @Test func builtMessageParsesBack() {
        let raw = MessageBuilder.build(reply, from: me, date: Date(timeIntervalSince1970: 1_790_158_530), messageID: "new@icloud.com")
        let header = ParsedMessage(headerData: raw)
        #expect(header.subject == reply.subject)
        #expect(header.from == me)
        #expect(header.to == [anna])
        #expect(header.cc.first?.name == "Petrov, I.")
        #expect(header.messageID == "new@icloud.com")
        #expect(header.inReplyTo == "orig@x.ru")
        #expect(header.references == ["root@x.ru", "orig@x.ru"])

        let body = ParsedMessage.body(of: raw)
        let html = body.html ?? ""
        #expect(html.contains("<b>Отправлю завтра.</b>"))
        #expect(html.contains("<blockquote type=\"cite\""))
        #expect(html.contains("<p>Прошу согласовать</p>"))
        // Чужие скрипты и <head> в цитату не попадают.
        #expect(!html.contains("x()"))
        #expect(!html.contains("p{}"))
        // Текстовая копия — с «>», для программ без HTML.
        #expect(body.text?.contains("Согласен.\r\nОтправлю завтра.\r\n\r\n23 сентября 2026, 07:48, Анна пишет:\r\n> Прошу согласовать") == true)
    }

    @Test func longCyrillicSubjectIsSplitIntoShortWords() {
        let encoded = MessageBuilder.encodeHeader(reply.subject)
        for line in encoded.components(separatedBy: "\r\n") {
            #expect(line.trimmingCharacters(in: .whitespaces).count <= 75)
        }
        #expect(MIME.decodeWords(encoded.replacingOccurrences(of: "\r\n", with: "")) == reply.subject)
        #expect(MessageBuilder.encodeHeader("Plain subject") == "Plain subject")
    }

    @Test func dotStuffingAndLineEndings() {
        let stuffed = String(decoding: SMTPClient.dotStuffed(Data("a\n.b\r\n..c\n.".utf8)), as: UTF8.self)
        #expect(stuffed == "a\r\n..b\r\n...c\r\n..\r\n")
    }
}

@Suite("Кэш почты")
struct MailCacheTests {
    private func message(_ uid: UInt32, day: Double) -> CachedMessage {
        CachedMessage(mailbox: "INBOX", uid: uid, internalDate: Date(timeIntervalSince1970: day * 86_400),
                      flags: ["\\Seen"], header: Data("Subject: \(uid)\r\n\r\n".utf8), size: 10)
    }

    @Test func rangeQueriesAndFlags() throws {
        let cache = try MailCache.inMemory()
        try cache.upsert([message(1, day: 1), message(2, day: 2), message(3, day: 3)], account: "a")
        #expect(cache.messages(mailbox: "INBOX", account: "a", from: Date(timeIntervalSince1970: 86_400 * 2),
                               to: Date(timeIntervalSince1970: 86_400 * 4)).map(\.uid) == [2, 3])
        #expect(cache.latest(mailbox: "INBOX", account: "a", limit: 1).map(\.uid) == [3])
        try cache.updateFlags([2: ["\\Seen", "\\Answered"]], mailbox: "INBOX", account: "a")
        #expect(cache.message(uid: 2, mailbox: "INBOX", account: "a")?.flags == ["\\Seen", "\\Answered"])
        #expect(cache.messages(mailbox: "INBOX", account: "b", from: .distantPast, to: .distantFuture).isEmpty)
    }

    @Test func newUIDValidityDropsTheMailbox() throws {
        let cache = try MailCache.inMemory()
        try cache.resetIfNeeded(uidValidity: 7, mailbox: "INBOX", account: "a")
        try cache.upsert([message(1, day: 1)], account: "a")
        try cache.storeBody(Data("raw".utf8), uid: 1, mailbox: "INBOX", account: "a")
        try cache.resetIfNeeded(uidValidity: 7, mailbox: "INBOX", account: "a")
        #expect(cache.latest(mailbox: "INBOX", account: "a", limit: 10).count == 1)
        try cache.resetIfNeeded(uidValidity: 8, mailbox: "INBOX", account: "a")
        #expect(cache.latest(mailbox: "INBOX", account: "a", limit: 10).isEmpty)
        #expect(cache.body(uid: 1, mailbox: "INBOX", account: "a") == nil)
    }

    @Test func itemIDKeepsColonsInMailboxName() {
        let id = IMAPMailProvider.itemID(account: "A-1", mailbox: "Work:Projects", uid: 42)
        let parsed = IMAPMailProvider.parse(id)
        #expect(parsed?.0 == "Work:Projects")
        #expect(parsed?.1 == 42)
        #expect(IMAPMailProvider.parse("mail:demo:20260923-4") == nil)
    }

    @Test func presetsGuessedByDomain() {
        #expect(MailPreset.guess(for: "ivan@icloud.com") == .iCloud)
        #expect(MailPreset.guess(for: "ivan@ya.ru") == .yandex)
        let icloud = MailPreset.iCloud.account(email: "ivan@icloud.com", name: "Иван")
        #expect(icloud.imapUser == "ivan")
        #expect(icloud.smtpUser == "ivan@icloud.com")
        #expect(icloud.smtpSecurity == .startTLS)
    }

    @Test func appleAppPasswordShape() {
        #expect(MailPreset.looksLikeAppleAppPassword("abcd-efgh-ijkl-mnop"))
        #expect(!MailPreset.looksLikeAppleAppPassword("МойПароль123"))
        #expect(!MailPreset.looksLikeAppleAppPassword("abcdefghijklmnop"))
        #expect(MailPreset.cleanPassword("  abcd-efgh-ijkl-mnop\n") == "abcd-efgh-ijkl-mnop")
    }
}

@Suite("Вложения")
struct AttachmentTests {
    @Test func messageWithAttachmentsParsesBack() {
        let pdf = Data((0..<3000).map { UInt8($0 % 251) })
        var mail = OutgoingMail(to: [Person(name: "Анна", address: "anna@x.ru")], subject: "Договор", text: "Во вложении.")
        mail.attachments = [
            MailBody.Attachment(name: "Договор № 5 (финал).pdf", size: pdf.count, mimeType: "application/pdf", data: pdf),
            MailBody.Attachment(name: "notes.txt", size: 5, mimeType: "text/plain", data: Data("привет".utf8)),
        ]
        let raw = MessageBuilder.build(mail, from: Person(name: "Я", address: "me@x.ru"), messageID: "m@x.ru")
        #expect(String(decoding: raw, as: UTF8.self).contains("multipart/mixed"))
        let body = ParsedMessage.body(of: raw)
        #expect(body.text?.contains("Во вложении.") == true)
        #expect(body.attachments.map(\.name) == ["Договор № 5 (финал).pdf", "notes.txt"])
        #expect(body.attachments.first?.data == pdf)
        #expect(body.attachments.last.flatMap { $0.data.map { String(decoding: $0, as: UTF8.self) } } == "привет")
    }

    @Test func withoutAttachmentsStaysAlternative() {
        let raw = MessageBuilder.build(OutgoingMail(to: [], subject: "x", text: "y"), from: Person(name: nil, address: "me@x.ru"),
                                       messageID: "m@x.ru")
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("multipart/alternative"))
        #expect(!text.contains("multipart/mixed"))
    }

    @Test func exchangeAttachmentRequests() throws {
        let file = MailBody.Attachment(name: "План & бюджет.xlsx", size: 3, mimeType: "application/vnd.ms-excel", data: Data([1, 2, 3]))
        let request = try XMLTreeNode.parse(Data(EWSRequest.envelope(
            EWSCalendarRequest.createAttachments(parent: "ITEM=", files: [file])).utf8))
        #expect(request.first("ParentItemId")?.attributes["Id"] == "ITEM=")
        #expect(request.first("Name")?.text == "План & бюджет.xlsx")
        #expect(request.first("Content")?.text == Data([1, 2, 3]).base64EncodedString())

        let later = try XMLTreeNode.parse(Data(EWSRequest.envelope(EWSCalendarRequest.create(
            EventDraft(title: "Обзор", start: Date(), end: Date(), attendees: [Person(name: "А", address: "a@x.ru")]),
            recurrence: nil, sendLater: true)).utf8))
        #expect(later.first("CreateItem")?.attributes["SendMeetingInvitations"] == "SendToNone")

        let created = try XMLTreeNode.parse(Data("""
            <s:Envelope xmlns:s="s"><s:Body><m:CreateItemResponse xmlns:m="m" xmlns:t="t"><m:ResponseMessages>
            <m:CreateItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>
            <m:Items><t:CalendarItem><t:ItemId Id="NEW=" ChangeKey="DwAA"/></t:CalendarItem></m:Items>
            </m:CreateItemResponseMessage></m:ResponseMessages></m:CreateItemResponse></s:Body></s:Envelope>
            """.utf8))
        #expect(try EWSCalendarRequest.parseCreatedID(try #require(created.child("Body")?.children.first)) == "NEW=")
    }
}
