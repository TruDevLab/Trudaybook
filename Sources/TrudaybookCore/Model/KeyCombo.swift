import Foundation

/// Сочетание клавиш как его видит меню: клавиша и модификаторы.
///
/// Ядро не знает AppKit, поэтому модификаторы — свои; приложение
/// переводит их в `NSEvent.ModifierFlags`. Здесь — то, что легко
/// сломать и стоит проверять тестами: запись ⇧, вид «⇧⌘N» и повторы.
public struct KeyCombo: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let key: String
    public let modifiers: Modifiers

    /// ⇧ с буквой — заглавной буквой и без ⇧ в маске, как в стандартном
    /// меню AppKit. Строчная буква с маской ⇧ в меню рисуется верно, но
    /// нажатие до пункта не доходит. Заглавная без маски — то же самое,
    /// и два таких пункта — повтор.
    public init(_ key: String, _ modifiers: Modifiers = .command) {
        var key = key
        var modifiers = modifiers
        if key.count == 1, let letter = key.first, letter.isLetter, modifiers.contains(.shift) {
            key = key.uppercased()
            modifiers.remove(.shift)
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// Нажат ли ⇧: в маске или заглавной буквой.
    public var hasShift: Bool {
        modifiers.contains(.shift) || (key.count == 1 && key.first.map { $0.isLetter && $0.isUppercase } == true)
    }

    /// Как в меню macOS: «⌃⌥⇧⌘» в этом порядке, затем клавиша.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if hasShift { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.symbol(for: key)
    }

    static func symbol(for key: String) -> String {
        switch key {
        case "\r": "↩"
        case "\u{1b}": "Esc"
        case "\u{8}", "\u{7f}": "⌫"
        case "\t": "⇥"
        case " ": String(localized: "Пробел")
        case "-": "−"
        default: key.uppercased()
        }
    }

    /// Сочетания, занятые больше одного раза: `[сочетание: кем]`.
    /// Пустое — повторов нет.
    public static func duplicates(_ entries: [(combo: KeyCombo, title: String)]) -> [KeyCombo: [String]] {
        Dictionary(grouping: entries, by: \.combo)
            .filter { $0.value.count > 1 }
            .mapValues { $0.map(\.title) }
    }
}
