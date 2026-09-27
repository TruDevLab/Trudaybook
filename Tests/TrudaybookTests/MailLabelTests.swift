import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Метки писем")
struct MailLabelTests {
    private func letter(_ address: String, bulk: Bool = false, automatic: Bool = false) -> TimelineItem {
        TimelineItem(id: "mail:a:1:INBOX", title: "Тема", time: Date(timeIntervalSince1970: 1_800_000_000),
                     detail: .mail(MailInfo(accountID: "a", from: Person(name: "Анна", address: address),
                                            snippet: "Начало письма", isBulk: bulk, isAutomatic: automatic)))
    }

    @Test("Ответ модели разбирается при любом написании")
    func разбор() {
        #expect(MailLabel(loose: "important") == .important)
        #expect(MailLabel(loose: " Newsletter.") == .newsletter)
        #expect(MailLabel(loose: "рассылка") == .newsletter)
        #expect(MailLabel(loose: "Уведомление") == .notification)
        #expect(MailLabel(loose: "personal") == .conversation)
        #expect(MailLabel(loose: "что-то") == nil)
    }

    @Test("Правила: рассылка по заголовкам, робот по адресу, остальное — модели")
    func правила() throws {
        #expect(MailLabelRules.guess(try #require(letter("news@shop.example", bulk: true).mail)) == .newsletter)
        #expect(MailLabelRules.guess(try #require(letter("jira@company.example", automatic: true).mail)) == .notification)
        #expect(MailLabelRules.guess(try #require(letter("no-reply@bank.example").mail)) == .notification)
        #expect(MailLabelRules.guess(try #require(letter("notifications@github.example").mail)) == .notification)
        #expect(MailLabelRules.guess(try #require(letter("anna@company.example").mail)) == nil)
        #expect(!MailLabelRules.isRobot("olga@company.example"))
    }

    /// Выбор человека главнее: ни Trunook, ни правило его не переписывают.
    @Test("Метку человека Trunook не переписывает")
    func человекГлавнее() {
        #expect(!MailLabelRules.trunookMayWrite(over: StoredLabel(label: .important, source: .user)))
        #expect(MailLabelRules.trunookMayWrite(over: StoredLabel(label: .important, source: .trunook)))
        #expect(MailLabelRules.trunookMayWrite(over: nil))
        let stored = StoredLabel(label: .conversation, source: .user)
        #expect(MailLabelRules.effective(stored: stored, mail: letter("x@y", bulk: true).mail) == .conversation)
    }

    @Test("Метки хранятся, меняются и снимаются")
    func хранение() throws {
        let store = try ItemStateStore.inMemory()
        try store.setLabel(StoredLabel(label: .newsletter, source: .trunook), for: "m1")
        try store.setLabel(StoredLabel(label: .important, source: .user), for: "m2")
        try store.setLabel(StoredLabel(label: .conversation, source: .user), for: "m1")
        #expect(store.allLabels() == ["m1": StoredLabel(label: .conversation, source: .user),
                                      "m2": StoredLabel(label: .important, source: .user)])
        try store.setLabel(nil, for: "m2")
        #expect(store.allLabels()["m2"] == nil)
    }

    @Test("Заголовки рассылки и робота распознаются")
    func заголовки() {
        let bulk = ParsedMessage(headerData: Data("From: a@b\r\nList-Unsubscribe: <mailto:u@b>\r\n\r\n".utf8))
        #expect(bulk.isBulk)
        let precedence = ParsedMessage(headerData: Data("From: a@b\r\nPrecedence: Bulk\r\n\r\n".utf8))
        #expect(precedence.isBulk)
        let robot = ParsedMessage(headerData: Data("From: a@b\r\nAuto-Submitted: auto-generated\r\n\r\n".utf8))
        #expect(robot.isAutomatic)
        let person = ParsedMessage(headerData: Data("From: a@b\r\nAuto-Submitted: no\r\n\r\n".utf8))
        #expect(!person.isAutomatic && !person.isBulk)
    }
}

@Suite("Просьбы к модели Trunook")
struct TrunookModelRequestTests {
    @Test("Пересказ: текст обрезан, пути ответа в просьбе нет")
    func пересказ() throws {
        let payload = TrunookModelRequest.summary(id: "X", language: "ru", subject: "Тема", from: "Анна",
                                                  date: Date(timeIntervalSince1970: 0),
                                                  text: String(repeating: "я", count: 20_000))
        #expect(payload["kind"] as? String == "summary")
        #expect(payload["reply"] == nil)
        let letter = try #require(payload["letter"] as? [String: Any])
        #expect((letter["text"] as? String)?.count == TrunookModelRequest.maxText)
    }

    @Test("Метки: ярлыки m1…, номера писем модели не видны")
    func ярлыки() {
        let items = (1...3).map { index in
            TimelineItem(id: "mail:acc:\(index):INBOX", title: "Тема \(index)", time: Date(),
                         detail: .mail(MailInfo(accountID: "acc", from: Person(name: "Иван", address: "i@x.example"))))
        }
        let (letters, ids) = TrunookModelRequest.letters(items)
        #expect(letters.map(\.key) == ["m1", "m2", "m3"])
        #expect(ids["m2"] == "mail:acc:2:INBOX")
        let payload = TrunookModelRequest.labels(id: "X", language: "ru", letters: letters)
        let sent = String(data: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(), encoding: .utf8) ?? ""
        #expect(!sent.contains("mail:acc"))
    }

    @Test("Ответы: пересказ, метки, отказ облака, мусор")
    func ответы() {
        func answer(_ json: [String: Any]) -> TrunookModelRequest.Answer? {
            TrunookModelRequest.parseAnswer((try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        }
        #expect(answer(["ok": true, "summary": " • пункт "]) == .summary("• пункт"))
        #expect(answer(["ok": true, "labels": ["m1": "newsletter", "m2": "нечто"]]) == .labels(["m1": .newsletter]))
        #expect(answer(["ok": false, "code": "cloud", "error": "облако"]) == .failed(code: "cloud", message: "облако"))
        #expect(TrunookModelRequest.parseAnswer(Data("не json".utf8)) == nil)
    }

    @Test("HTML превращается в текст без стилей и тегов")
    func текст() {
        let body = MailBody(html: "<html><head><style>p{color:red}</style></head><body><p>Привет,&nbsp;Анна!</p><p>Срок &mdash; пятница.</p><script>x()</script></body></html>")
        #expect(TrunookModelRequest.plainText(body) == "Привет, Анна!\nСрок — пятница.")
    }
}

@Suite("Команда метки от помощника")
struct TrunookLabelCommandTests {
    @Test("Метка ставится, снимается, мусор отклоняется")
    func разбор() throws {
        #expect(try TrunookCommand.parse(["action": "label", "letter": "m1", "label": "newsletter"]).get()
                == .label(letter: "m1", label: .newsletter))
        #expect(try TrunookCommand.parse(["action": "label", "letter": "m1", "label": "none"]).get()
                == .label(letter: "m1", label: nil))
        #expect(throws: TrunookCommand.ParseError.self) {
            try TrunookCommand.parse(["action": "label", "letter": "m1", "label": "delete-all"]).get()
        }
        #expect(try TrunookCommand.parse(["action": "list", "label": "важное"]).get()
                == .list(from: nil, importantOnly: false, limit: 10, label: .important))
    }

    @Test("Список по метке и с меткой в ответе")
    func список() {
        let a = TimelineItem(id: "a", title: "Скидки", time: Date(timeIntervalSince1970: 2),
                             detail: .mail(MailInfo(accountID: "x", from: Person(name: "Магазин", address: "news@shop.example"))))
        let b = TimelineItem(id: "b", title: "Отчёт", time: Date(timeIntervalSince1970: 1),
                             detail: .mail(MailInfo(accountID: "x", from: Person(name: "Анна", address: "anna@company.example"))))
        let labels: [String: MailLabel] = ["a": .newsletter, "b": .important]
        let only = TrunookCommand.listing([a, b], from: nil, importantOnly: false, limit: 10, label: .important,
                                          priority: { _ in .none }, labelOf: { labels[$0.id] })
        #expect(only.map { $0["id"] as? String } == ["b"])
        #expect(only.first?["label"] as? String == "important")
    }
}
