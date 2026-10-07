import Foundation
import Testing
@testable import TrudaybookCore

private let anna = Person(name: "Анна Орлова", address: "anna@x.ru")
private let ivan = Person(name: "Иван Петров", address: "ivan@x.ru")
private let me = Person(name: "Я", address: "me@x.ru")

private func letter(_ id: String, _ title: String, from: Person = anna, to: [Person] = [me], cc: [Person] = [],
                    messageID: String? = nil, references: [String] = [], at seconds: TimeInterval = 0) -> TimelineItem {
    TimelineItem(id: id, title: title, time: Date(timeIntervalSince1970: seconds),
                 detail: .mail(MailInfo(accountID: "a", from: from, to: to, cc: cc,
                                        messageID: messageID, references: references)))
}

@Suite("Поиск по письмам")
struct MailSearchTests {
    @Test func wordsMatchSenderRecipientsAndCopy() {
        let item = letter("1", "Договор", from: anna, to: [ivan], cc: [me])
        #expect(MailSearchQuery("орлова").matches(item))
        #expect(MailSearchQuery("петров").matches(item))
        #expect(MailSearchQuery("me@x.ru").matches(item))
        #expect(MailSearchQuery("договор анна").matches(item))
        #expect(!MailSearchQuery("договор сидоров").matches(item))
    }

    @Test func fieldsNarrowTheSearch() {
        let item = letter("1", "Договор", from: anna, to: [ivan], cc: [me])
        #expect(MailSearchQuery("от:анна").matches(item))
        #expect(!MailSearchQuery("от:иван").matches(item))
        #expect(MailSearchQuery("кому:иван").matches(item))
        #expect(!MailSearchQuery("кому:me@x.ru").matches(item))
        #expect(MailSearchQuery("копия:me@x.ru").matches(item))
        #expect(MailSearchQuery("from:anna to:ivan cc:me").matches(item))
        #expect(MailSearchQuery("от:\"анна орлова\"").matches(item))
    }

    @Test func yoIsTheSameAsYe() {
        #expect(MailSearchQuery("Фёдор").matches(letter("1", "Привет", from: Person(name: "Федор Иванов", address: "f@x.ru"))))
    }

    @Test func bareFieldNameIsPlainWord() {
        let query = MailSearchQuery("от:")
        #expect(query.from.isEmpty && query.words == ["от:"])
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(MailSearchQuery("  ").matches(letter("1", "x")))
    }
}

@Suite("Диалоги")
struct ThreadGroupingTests {
    private func group(_ items: [TimelineItem]) -> [MailThread] {
        ThreadGrouping.group(items, time: \.time)
    }

    @Test func referencesLinkRepliesToTheOriginal() {
        let first = letter("1", "Договор", messageID: "a@x", at: 100)
        let reply = letter("2", "Re: Договор", messageID: "b@x", references: ["a@x"], at: 200)
        let again = letter("3", "Re: Re: Договор", messageID: "c@x", references: ["a@x", "b@x"], at: 300)
        let other = letter("4", "Отпуск", messageID: "d@x", at: 250)
        let threads = group([again, other, reply, first])
        #expect(threads.count == 2)
        #expect(threads[0].items.map(\.id) == ["3", "2", "1"])
        #expect(threads[1].items.map(\.id) == ["4"])
    }

    @Test func middleOfTheChainMayBeMissing() {
        let first = letter("1", "Договор", messageID: "a@x", at: 100)
        let last = letter("3", "Re: Договор", messageID: "c@x", references: ["a@x", "b@x"], at: 300)
        #expect(group([last, first]).count == 1)
    }

    @Test func subjectLinksOnlyWithReplyPrefix() {
        let plain = letter("1", "Привет", at: 100)
        let alsoPlain = letter("2", "Привет", from: ivan, at: 200)
        #expect(group([plain, alsoPlain]).count == 2)
        let reply = letter("3", "Отв: Привет", at: 300)
        #expect(group([reply, alsoPlain, plain]).count == 1)
    }

    @Test func keyDoesNotChangeWhenANewReplyArrives() {
        let first = letter("1", "Договор", messageID: "a@x", at: 100)
        let reply = letter("2", "Re: Договор", messageID: "b@x", references: ["a@x"], at: 200)
        let before = group([reply, first])[0].key
        let newest = letter("3", "Re: Договор", messageID: "c@x", references: ["a@x", "b@x"], at: 300)
        #expect(group([newest, reply, first])[0].key == before)
    }

    @Test func subjectPrefixesAreStripped() {
        #expect(ThreadGrouping.baseSubject("RE: Fwd: Ответ: Отчёт ") == "отчет")
        #expect(ThreadGrouping.baseSubject("Re[2]: Отчёт") == "отчет")
    }
}

@Suite("Скрытая копия")
struct BccTests {
    @Test func bccIsOnlyInTheSentCopy() throws {
        let mail = OutgoingMail(to: [ivan], bcc: [anna], subject: "Тема", text: "Текст")
        let sent = String(decoding: MessageBuilder.build(mail, from: me, messageID: "id@x"), as: UTF8.self)
        #expect(!sent.contains("Bcc:"))
        #expect(!sent.contains("anna@x.ru"))
        let copy = String(decoding: MessageBuilder.build(mail, from: me, messageID: "id@x", includeBcc: true), as: UTF8.self)
        #expect(copy.contains("Bcc: "))
        #expect(copy.contains("anna@x.ru"))
    }

    @Test func bccOnlyLetterHasNoVisibleRecipients() {
        let mail = OutgoingMail(to: [], bcc: [anna], subject: "Тема", text: "Текст")
        let sent = String(decoding: MessageBuilder.build(mail, from: me, messageID: "id@x"), as: UTF8.self)
        #expect(sent.contains("To: undisclosed-recipients:;"))
    }
}

@Suite("Шаблон ответа")
struct ReplyTemplateTests {
    @Test func quotedTailIsCut() {
        let text = """
        Иван, добрый день!
        Когда пришлёте договор?

        23 сентября 2026, 10:00, Анна Орлова пишет:
        > Договор пришлю завтра
        """
        #expect(ReplyHistory.stripQuoted(text) == "Иван, добрый день!\nКогда пришлёте договор?")
        let outlook = "Согласен.\n\nОт: Анна Орлова\nОтправлено: 23 сентября\nТема: Договор"
        #expect(ReplyHistory.stripQuoted(outlook) == "Согласен.")
        // Письмо из одной цитаты — оставляем как есть, лучше длинно, чем пусто.
        #expect(ReplyHistory.stripQuoted("> только цитата") == "> только цитата")
    }

    @Test func historyKeepsNewestWithinBudget() {
        let items = (1...6).map { index in
            letter("\(index)", "Re: Договор", from: index % 2 == 0 ? me : anna, at: TimeInterval(index * 100))
        }
        let texts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, String(repeating: "т", count: 1500)) })
        let history = ReplyHistory.letters(older: items, texts: texts, isMine: { $0 == me }, budget: 4000)
        // Самые свежие, в хронологическом порядке, пока хватает бюджета.
        #expect(history.map(\.date.timeIntervalSince1970) == [400, 500, 600])
        #expect(history.map(\.mine) == [true, false, true])
        #expect(history.reduce(0) { $0 + $1.text.count } <= 4000)
    }

    @Test func requestAndAnswerRoundTrip() throws {
        let payload = TrunookModelRequest.reply(
            id: "x", language: "ru", me: "me@x.ru", subject: "Договор", from: "Анна <anna@x.ru>",
            date: Date(timeIntervalSince1970: 0), text: "Когда?",
            history: [.init(from: "me@x.ru", date: Date(timeIntervalSince1970: -60), text: "Пришлю", mine: true)])
        #expect(payload["kind"] as? String == "reply")
        #expect((payload["history"] as? [[String: Any]])?.first?["mine"] as? Bool == true)
        #expect(JSONSerialization.isValidJSONObject(payload))
        let answer = Data(#"{"ok":true,"reply":"  Анна, добрый день!\n[дата]  "}"#.utf8)
        #expect(TrunookModelRequest.parseAnswer(answer) == .reply("Анна, добрый день!\n[дата]"))
        let empty = Data(#"{"ok":true,"reply":"  "}"#.utf8)
        if case .failed(let code, _)? = TrunookModelRequest.parseAnswer(empty) { #expect(code == "empty") } else { Issue.record("пустой шаблон принят") }
    }
}

@Suite("Кнопки поиска")
struct SearchScopeTests {
    @Test func scopeTurnsBareWordsIntoFieldSearch() {
        #expect(MailSearchQuery.scoped("иван петров", .from) == "от:иван от:петров")
        #expect(MailSearchQuery.scoped("иван кому:анна", .cc) == "копия:иван кому:анна")
        #expect(MailSearchQuery.scoped("\"Иван Петров\"", .to) == "кому:\"Иван Петров\"")
        #expect(MailSearchQuery.scoped("иван", .all) == "иван")
        let item = letter("1", "Договор", from: anna, to: [ivan], cc: [me])
        #expect(MailSearchQuery(MailSearchQuery.scoped("орлова", .from)).matches(item))
        #expect(!MailSearchQuery(MailSearchQuery.scoped("орлова", .to)).matches(item))
        #expect(MailSearchQuery(MailSearchQuery.scoped("иван петров", .to)).matches(item))
    }
}
