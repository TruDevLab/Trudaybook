import Foundation

/// Строка поиска по письмам: слова и необязательные уточнения
/// `от:`, `кому:`, `копия:` (или `from:`, `to:`, `cc:`).
///
/// «от:иван» ищет только по отправителю, «кому:анна» — по получателям,
/// «копия:анна» — по копии; слова без уточнения ищутся везде: в теме, у
/// отправителя, у получателей и в копии. Все слова должны найтись, порядок
/// неважен. Значение с пробелом — в кавычках: `от:"Иван Петров"`.
public struct MailSearchQuery: Equatable, Sendable {
    public var words: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var cc: [String] = []

    public var isEmpty: Bool { words.isEmpty && from.isEmpty && to.isEmpty && cc.isEmpty }

    /// Где искать слова без уточнения — кнопки у поля поиска.
    public enum Scope: String, CaseIterable, Sendable {
        case all, from, to, cc

        var prefix: String? {
            switch self {
            case .all: nil
            case .from: "от:"
            case .to: "кому:"
            case .cc: "копия:"
            }
        }
    }

    /// Строка с выбранной кнопкой — как если бы человек сам написал «от:»
    /// перед каждым словом. Слова с уточнением остаются как есть. Строкой,
    /// а не разобранным запросом: её же получают ящики для поиска в кэше.
    public static func scoped(_ text: String, _ scope: Scope) -> String {
        guard let prefix = scope.prefix else { return text }
        return tokens(text).map { token in
            if split(fold(token)) != nil { return token.contains(" ") ? quoted(token) : token }
            return prefix + (token.contains(" ") ? "\"\(token)\"" : token)
        }.joined(separator: " ")
    }

    private static func quoted(_ token: String) -> String {
        guard let colon = token.firstIndex(of: ":") else { return token }
        return String(token[...colon]) + "\"" + token[token.index(after: colon)...] + "\""
    }

    public init(_ text: String) {
        for token in Self.tokens(text) {
            let lower = Self.fold(token)
            if let (field, value) = Self.split(lower) {
                switch field {
                case .from: from.append(value)
                case .to: to.append(value)
                case .cc: cc.append(value)
                }
            } else {
                words.append(lower)
            }
        }
    }

    private enum Field { case from, to, cc }

    private static let prefixes: [(String, Field)] = [
        ("от:", .from), ("from:", .from), ("кому:", .to), ("to:", .to),
        ("копия:", .cc), ("cc:", .cc),
    ]

    private static func split(_ token: String) -> (Field, String)? {
        for (prefix, field) in prefixes where token.hasPrefix(prefix) {
            let value = String(token.dropFirst(prefix.count))
            // «от:» без значения — человек ещё набирает; уточнением это не считаем.
            return value.isEmpty ? nil : (field, value)
        }
        return nil
    }

    /// Нижний регистр, «ё» как «е»: так пишут и ищут чаще всего.
    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Слова по пробелам; кавычки склеивают слова в одно значение.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Слова, которые надо искать в тексте писем на сервере: уточнения
    /// `от:`/`кому:` сервер по тексту не поймёт — они применяются к найденному.
    public var serverText: String { words.joined(separator: " ") }

    /// Только уточнения `от:`/`кому:`/`копия:` — для писем, которые сервер
    /// нашёл по тексту: слов в теме и у людей у них может и не быть.
    public func matchesFields(_ item: TimelineItem) -> Bool {
        guard !from.isEmpty || !to.isEmpty || !cc.isEmpty else { return true }
        var copy = self
        copy.words = []
        return copy.matches(item)
    }

    public func matches(_ item: TimelineItem) -> Bool {
        guard !isEmpty else { return true }
        let info = item.mail
        func names(_ people: [Person]) -> String {
            people.map { "\($0.name ?? "") \($0.address ?? "")" }.joined(separator: " ")
        }
        let sender = Self.fold(info.map { names([$0.from]) } ?? item.subtitle)
        let recipients = Self.fold(info.map { names($0.to) } ?? "")
        let copies = Self.fold(info.map { names($0.cc) } ?? "")
        let everywhere = Self.fold(item.title) + " " + Self.fold(item.subtitle) + " " + sender + " " + recipients + " " + copies

        return from.allSatisfy(sender.contains)
            && to.allSatisfy(recipients.contains)
            && cc.allSatisfy(copies.contains)
            && words.allSatisfy(everywhere.contains)
    }
}
