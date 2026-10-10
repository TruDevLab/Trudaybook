import Foundation

/// Что отдаётся местной модели (Ollama на этом Mac): письма для пересказа
/// и меток, прошлая переписка для шаблона ответа, текст письма без вёрстки.
///
/// Промты и разбор ответов — `ModelPrompts`, связь с Ollama — `Ollama`.
/// Раньше всё это шло через Trunook файлами; теперь Trudaybook спрашивает
/// модель сам, а правила промтов перенесены как были — их отлаживали на
/// `qwen3:8b`.
public enum MailModel {
    /// Сколько текста письма отдавать модели. Больше — дольше и хуже:
    /// местная модель на длинном тексте теряет начало.
    public static let maxText = 12_000
    /// Писем в одной просьбе о метках: ответ на 25 строк маленькая модель
    /// держит, на сотню — сбивается со счёта.
    public static let batchSize = 25
    /// Сколько писем прошлой переписки отдавать модели и сколько знаков в них.
    public static let maxHistoryLetters = 4
    public static let maxHistoryText = 6_000
    /// Пунктов «главного» в повестке — не больше: список на десять пунктов
    /// уже не главное.
    public static let maxFocus = 7

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

    /// Письма для просьбы о метках. Ярлык — «m1», «m2»…: номер письма
    /// у нас длинный и с адресом ящика, модели его знать незачем.
    public static func letters(_ items: [TimelineItem]) -> (letters: [Letter], ids: [String: String]) {
        var ids: [String: String] = [:]
        let letters = items.compactMap { item -> Letter? in
            guard let mail = item.mail else { return nil }
            let key = "m\(ids.count + 1)"
            ids[key] = item.id
            let from = [mail.from.name, mail.from.address.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
            return Letter(key: key, subject: String(item.title.prefix(200)), from: String(from.prefix(200)),
                          snippet: String(mail.snippet.prefix(300)), bulk: mail.isBulk || mail.isAutomatic)
        }
        return (letters, ids)
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
