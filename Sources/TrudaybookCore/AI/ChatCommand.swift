import Foundation

/// Команды в поле чата: `/mail слова` и `/cal слова` (или `/письмо`, `/встреча`)
/// — приложить письмо или встречу, найденные по словам темы.
///
/// Команда — всегда в конце набранного: человек пишет вопрос, ставит `/mail`,
/// набирает слова и выбирает из списка; выбранное становится плашкой,
/// а команда со словами из поля уходит.
public enum ChatCommand {
    public enum Kind: String, CaseIterable, Sendable {
        case mail, cal

        /// Как её можно набрать. Первое — как вставляет кнопка «+».
        public var names: [String] {
            switch self {
            case .mail: ["mail", "письмо"]
            case .cal: ["cal", "встреча"]
            }
        }
    }

    public struct Found: Equatable, Sendable {
        /// `nil` — команда ещё набирается («/ma»): предложить сами команды.
        public var kind: Kind?
        /// Слова после команды — или начало имени команды, пока она набирается.
        public var query: String
        /// Набранное до команды.
        public var before: String
    }

    /// Команда в конце текста. Косая черта — в начале или после пробела:
    /// адрес «a/b» и дробь «1/2» командами не считаются.
    public static func find(in text: String) -> Found? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        if slash != text.startIndex, !text[text.index(before: slash)].isWhitespace { return nil }
        let rest = text[text.index(after: slash)...]
        guard !rest.contains(where: \.isNewline) else { return nil }
        let name = rest.prefix { !$0.isWhitespace }.lowercased()
        let query = rest.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        let before = String(text[..<slash])
        if let kind = Kind.allCases.first(where: { $0.names.contains(name) }) {
            return Found(kind: kind, query: query, before: before)
        }
        // Имя ещё не дописано и после него ничего нет — подсказать команды.
        guard rest.count == name.count, !commands(matching: name).isEmpty else { return nil }
        return Found(kind: nil, query: name, before: before)
    }

    /// Команды, чьё имя начинается с набранного.
    public static func commands(matching prefix: String) -> [Kind] {
        let lower = prefix.lowercased()
        return Kind.allCases.filter { kind in kind.names.contains { $0.hasPrefix(lower) } }
    }

    /// Все ли слова запроса есть в полях (тема, отправитель…). Без учёта
    /// регистра и «ё»: «отчет» находит «Отчёт».
    public static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fold(fields.joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
