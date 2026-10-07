import Foundation

/// Просьба к модели Trunook: пересказать письмо, разметить список,
/// подготовить повестку дня или итоги недели и месяца по заметкам.
///
/// Файлом, как и всё между Trudaybook и Trunook: просьба — в папку
/// Trunook `mail-requests`, ответ — в нашу `trunook-answers`, под тем же
/// номером. Путь ответа в просьбе не передаётся: Trunook пишет только
/// в эту одну папку, и чужой файл не направит его писать куда-то ещё.
///
/// Отвечает только модель на этом Mac — это проверяет Trunook и говорит
/// `cloud`, если его модель облачная: письма в интернет не уходят.
public enum TrunookModelRequest {
    public static let version = 1
    /// Сколько текста письма отдавать модели. Больше — дольше и хуже:
    /// местная модель на длинном тексте теряет начало.
    public static let maxText = 12_000
    /// Писем в одной просьбе о метках: ответ на 25 строк маленькая модель
    /// держит, на сотню — сбивается со счёта.
    public static let batchSize = 25

    public struct Letter: Equatable, Sendable {
        public var key: String
        public var subject: String
        public var from: String
        public var snippet: String
        public var bulk: Bool

        public init(key: String, subject: String, from: String, snippet: String, bulk: Bool) {
            self.key = key
            self.subject = subject
            self.from = from
            self.snippet = snippet
            self.bulk = bulk
        }
    }

    /// Письмо из прошлой переписки — для шаблона ответа.
    public struct HistoryLetter: Equatable, Sendable {
        public var from: String
        public var date: Date
        public var text: String
        /// Письмо написал сам человек.
        public var mine: Bool

        public init(from: String, date: Date, text: String, mine: Bool) {
            self.from = from
            self.date = date
            self.text = text
            self.mine = mine
        }
    }

    /// Сколько писем прошлой переписки отдавать модели и сколько знаков в них.
    public static let maxHistoryLetters = 4
    public static let maxHistoryText = 6_000

    /// Шаблон ответа: последнее письмо и то, что было до него. Модель
    /// видит, как человек обычно отвечает в этой переписке, и что уже
    /// решено, — но сама ничего не решает.
    public static func reply(id: String, language: String, me: String, subject: String, from: String,
                             date: Date, text: String, history: [HistoryLetter]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "version": version, "id": id, "kind": "reply", "language": language,
            "me": String(me.prefix(200)),
            "letter": [
                "subject": String(subject.prefix(300)),
                "from": String(from.prefix(200)),
                "date": iso.string(from: date),
                "text": String(text.prefix(maxText)),
            ],
            "history": history.suffix(maxHistoryLetters).map { letter in
                [
                    "from": String(letter.from.prefix(200)),
                    "date": iso.string(from: letter.date),
                    "mine": letter.mine,
                    "text": String(letter.text.prefix(maxHistoryText)),
                ] as [String: Any]
            },
        ]
    }

    public static func summary(id: String, language: String, subject: String, from: String,
                               date: Date, text: String) -> [String: Any] {
        [
            "version": version, "id": id, "kind": "summary", "language": language,
            "letter": [
                "subject": String(subject.prefix(300)),
                "from": String(from.prefix(200)),
                "date": ISO8601DateFormatter().string(from: date),
                "text": String(text.prefix(maxText)),
            ],
        ]
    }

    public static func labels(id: String, language: String, letters: [Letter]) -> [String: Any] {
        [
            "version": version, "id": id, "kind": "labels", "language": language,
            "letters": letters.prefix(batchSize).map { letter in
                [
                    "key": letter.key,
                    "subject": String(letter.subject.prefix(200)),
                    "from": String(letter.from.prefix(200)),
                    "snippet": String(letter.snippet.prefix(300)),
                    "bulk": letter.bulk,
                ] as [String: Any]
            },
        ]
    }

    /// Повестка дня. Времена — строкой «10:00» в поясе человека: модели
    /// пояса ни к чему, а ошибиться на час с ними легко.
    public static func agenda(id: String, language: String, day: String, weekday: String,
                              input: DayAgenda.Input, time: (Date) -> String) -> [String: Any] {
        [
            "version": version, "id": id, "kind": "agenda", "language": language,
            "day": day, "weekday": weekday,
            "meetings": input.meetings.map { meeting in
                [
                    "key": meeting.key,
                    "title": String(meeting.title.prefix(200)),
                    "start": meeting.isAllDay ? "" : time(meeting.start),
                    "end": meeting.isAllDay ? "" : meeting.end.map(time) ?? "",
                    "allDay": meeting.isAllDay,
                    "location": String((meeting.location ?? "").prefix(200)),
                    "people": meeting.people.map { String($0.prefix(100)) },
                ] as [String: Any]
            },
            "reminders": input.reminders.map { reminder in
                [
                    "title": String(reminder.title.prefix(200)),
                    "time": reminder.due.map(time) ?? "",
                    "done": reminder.done,
                ] as [String: Any]
            },
            "letters": input.letters.map { letter in
                [
                    "key": letter.key,
                    "subject": String(letter.subject.prefix(200)),
                    "from": String(letter.from.prefix(200)),
                    "snippet": String(letter.snippet.prefix(200)),
                    "important": letter.important,
                ] as [String: Any]
            },
        ]
    }

    /// Итоги недели или месяца по заметкам дней.
    public static func digest(id: String, language: String, period: NotePeriod, title: String,
                              notes: [NoteDigest.Note]) -> [String: Any] {
        [
            "version": version, "id": id, "kind": "digest", "language": language,
            "period": period.rawValue, "title": String(title.prefix(200)),
            "notes": notes.map { ["day": $0.day, "text": $0.text] },
        ]
    }

    /// Письма для просьбы о метках. Ярлык — «m1», «m2»…: номер письма
    /// у нас длинный и с адресом ящика, модели его знать незачем.
    public static func letters(_ items: [TimelineItem]) -> (letters: [Letter], ids: [String: String]) {
        var ids: [String: String] = [:]
        let letters = items.compactMap { item -> Letter? in
            guard let mail = item.mail else { return nil }
            let key = "m\(ids.count + 1)"
            ids[key] = item.id
            let from = [mail.from.name, mail.from.address.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
            return Letter(key: key, subject: item.title, from: from, snippet: mail.snippet,
                          bulk: mail.isBulk || mail.isAutomatic)
        }
        return (letters, ids)
    }

    // MARK: - Ответ

    public enum Answer: Equatable, Sendable {
        case summary(String)
        case labels([String: MailLabel])
        case agenda(DayAgenda.Answer)
        /// Итоги периода — облегчённым Markdown.
        case text(String)
        /// Шаблон ответа на письмо: простой текст, без темы и подписи.
        case reply(String)
        case failed(code: String, message: String)
    }

    /// Пунктов «главного» в повестке — не больше: список на десять пунктов
    /// уже не главное.
    public static let maxFocus = 7

    /// Потолок файла ответа: пересказ — абзац, метки — строка на письмо.
    public static let maxAnswerSize = 128 * 1024

    public static func parseAnswer(_ data: Data) -> Answer? {
        guard data.count <= maxAnswerSize,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard (json["ok"] as? NSNumber)?.boolValue == true else {
            let code = (json["code"] as? String) ?? "failed"
            let message = (json["error"] as? String).map { String($0.prefix(600)) }
                ?? String(localized: "Trunook не смог ответить.")
            return .failed(code: code, message: message)
        }
        if let summary = json["summary"] as? String {
            let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failed(code: "empty", message: String(localized: "Модель вернула пустой пересказ."))
                                : .summary(String(text.prefix(4000)))
        }
        if let agenda = json["agenda"] as? [String: Any] {
            let focus = ((agenda["focus"] as? [Any]) ?? [])
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(maxFocus)
                .map { String($0.prefix(300)) }
            var meetings: [String: String] = [:]
            for (key, value) in (agenda["meetings"] as? [String: Any]) ?? [:] {
                guard key.range(of: "^e[0-9]{1,2}$", options: .regularExpression) != nil,
                      let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                meetings[key] = String(text.prefix(300))
            }
            return .agenda(DayAgenda.Answer(focus: Array(focus), meetings: meetings))
        }
        if let reply = json["reply"] as? String {
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failed(code: "empty", message: String(localized: "Модель вернула пустой шаблон."))
                                   : .reply(String(trimmed.prefix(6000)))
        }
        if let text = json["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failed(code: "empty", message: String(localized: "Модель вернула пустой ответ."))
                                   : .text(String(trimmed.prefix(8000)))
        }
        if let raw = json["labels"] as? [String: Any] {
            var labels: [String: MailLabel] = [:]
            for (key, value) in raw {
                guard let text = value as? String, let label = MailLabel(loose: text) else { continue }
                labels[key] = label
            }
            return .labels(labels)
        }
        return nil
    }

    // MARK: - Текст письма

    /// Текст письма для модели: из простого текста, а нет его — из HTML.
    ///
    /// Без стилей, скриптов и тегов; ссылки и картинки выпадают, абзацы
    /// остаются. Модели нужен смысл, а не вёрстка, и каждая лишняя тысяча
    /// знаков — секунды ожидания.
    public static func plainText(_ body: MailBody) -> String {
        if let text = body.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return collapse(text)
        }
        return collapse(stripHTML(body.html ?? ""))
    }

    public static func stripHTML(_ html: String) -> String {
        var text = html
        for block in ["style", "script", "head", "title"] {
            text = text.replacingOccurrences(of: "<\(block)[^>]*>[\\s\\S]*?</\(block)>", with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/tr|/h[1-6]|/blockquote)[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&laquo;": "«", "&raquo;": "»", "&mdash;": "—",
                        "&ndash;": "–", "&hellip;": "…"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        return text
    }

    /// Пробелы — в один, пустые строки — не больше одной подряд.
    static func collapse(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
