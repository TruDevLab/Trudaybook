import Foundation
import AppKit
import Testing
@testable import TrudaybookCore

@Suite("Адреса")
struct AddressListTests {
    @Test func parsesNamesAndBareAddresses() {
        let people = Person.parseList("Анна <anna@x.ru>, ivan@x.ru; \"Петров, И.\" <p@x.ru>")
        #expect(people == [
            Person(name: "Анна", address: "anna@x.ru"),
            Person(name: nil, address: "ivan@x.ru"),
            Person(name: "Петров, И.", address: "p@x.ru"),
        ])
    }

    @Test func emptyPiecesAreSkipped() {
        #expect(Person.parseList(" , ;  ").isEmpty)
    }

    @Test func formatRoundTrips() {
        let people = [Person(name: "Анна", address: "anna@x.ru"), Person(name: nil, address: "ivan@x.ru")]
        #expect(Person.parseList(Person.formatList(people)) == people)
    }
}

@Suite("Ответ на письмо")
struct ReplyBuilderTests {
    private let me = "me@x.ru"
    private let anna = Person(name: "Анна", address: "anna@x.ru")
    private let ivan = Person(name: "Иван", address: "ivan@x.ru")

    private func mail(subject: String = "Договор", replyTo: Person? = nil) -> TimelineItem {
        TimelineItem(
            id: "mail:a:1",
            title: subject,
            time: Date(timeIntervalSince1970: 1_790_000_000),
            detail: .mail(MailInfo(
                accountID: "a", from: anna, replyTo: replyTo,
                to: [Person(name: "Я", address: "ME@x.ru"), ivan], cc: [anna],
                messageID: "m1@x.ru", references: ["m0@x.ru"]
            ))
        )
    }

    @Test func replyGoesToSenderWithThreading() throws {
        let draft = try #require(ReplyBuilder.reply(to: mail(), body: MailBody(text: "Привет\n\nТекст"), all: false, ownAddresses: [me]))
        #expect(draft.to == [anna])
        #expect(draft.cc.isEmpty)
        #expect(draft.subject == "Re: Договор")
        #expect(draft.inReplyTo == "m1@x.ru")
        #expect(draft.references == ["m0@x.ru", "m1@x.ru"])
        // Свой текст пуст, цитата — отдельно: в редакторе без «>».
        #expect(draft.text.isEmpty)
        #expect(draft.quote?.text == "Привет\n\nТекст")
        #expect(draft.quote?.attribution.hasSuffix("Анна пишет:") == true)
        #expect(ReplyBuilder.quotedLines("Привет\n\nТекст") == "> Привет\n>\n> Текст")
    }

    @Test func replyAllSkipsMeAndSender() throws {
        let draft = try #require(ReplyBuilder.reply(to: mail(), body: nil, all: true, ownAddresses: [me]))
        #expect(draft.cc == [ivan])
    }

    @Test func replyToHeaderWins() throws {
        let list = Person(name: "Рассылка", address: "list@x.ru")
        let draft = try #require(ReplyBuilder.reply(to: mail(replyTo: list), body: nil, all: false, ownAddresses: [me]))
        #expect(draft.to == [list])
    }

    @Test func subjectPrefixIsNotDoubled() {
        #expect(ReplyBuilder.replySubject("Re: Договор") == "Re: Договор")
        #expect(ReplyBuilder.replySubject("ОТВ: Договор") == "ОТВ: Договор")
        #expect(ReplyBuilder.replySubject("  Договор ") == "Re: Договор")
    }

    @Test func meetingReplyGoesToOrganizerAndGuests() throws {
        let item = TimelineItem(
            id: "event:1@0", title: "Созвон", time: Date(),
            detail: .event(EventInfo(calendarTitle: "Работа", organizer: anna, attendees: [
                Attendee(person: anna, response: .accepted),
                Attendee(person: ivan, response: .pending),
                Attendee(person: Person(name: "Я", address: me), response: .accepted, isMe: true),
            ]))
        )
        let draft = try #require(ReplyBuilder.reply(to: item, body: nil, all: true, ownAddresses: [me]))
        #expect(draft.to == [anna])
        #expect(draft.cc == [ivan])
    }

    @Test func richTextBecomesCleanHTML() {
        let body = NSFont.systemFont(ofSize: 13)
        let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        let text = NSMutableAttributedString(string: "Привет, ", attributes: [.font: body])
        text.append(NSAttributedString(string: "Анна", attributes: [.font: bold]))
        text.append(NSAttributedString(string: " <&>\n• первое\n• второе\n1. раз\n\nссылка\n\n", attributes: [.font: body]))
        text.addAttribute(.link, value: URL(string: "https://x.ru")!, range: (text.string as NSString).range(of: "ссылка"))
        #expect(RichTextHTML.html(from: text) ==
            "<div>Привет, <b>Анна</b> &lt;&amp;&gt;</div><ul><li>первое</li><li>второе</li></ul>"
            + "<ol><li>раз</li></ol><div><br></div><div><a href=\"https://x.ru\">ссылка</a></div>")
    }

    @Test func htmlIsStrippedForQuote() {
        let text = HTMLText.strip("<html><head><style>p{}</style></head><body><p>Первый&nbsp;абзац</p><p>Второй<br>строка</p></body></html>")
        #expect(text == "Первый абзац\nВторой\nстрока")
    }
}
