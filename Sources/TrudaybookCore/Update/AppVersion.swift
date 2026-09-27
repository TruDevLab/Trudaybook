import Foundation

/// Номер версии, который можно сравнить.
///
/// Строками сравнивать нельзя: `"0.9.0" > "0.10.0"` — правда для строк
/// и ложь для версий. Отсюда разбор на числа и сравнение по частям
/// (как в Trunook, `Update/AppVersion.swift`).
///
/// Номер сборки (`CFBundleVersion`) сюда не входит: он собирается из даты
/// машины сборки, со стороны выпуска его взять неоткуда, и у пересобранной
/// сегодня 0.1.0 он больше, чем у выпущенной вчера 0.1.1.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    /// Части номера без хвостовых нулей: и 0.2, и 0.2.0 дают `[0, 2]`.
    public let parts: [Int]
    /// Хвост вроде «-beta»: такая версия младше одноимённой без хвоста.
    public let isPrerelease: Bool
    /// Как номер записан у источника — его и показывают человеку.
    public let text: String

    /// Разбирает «0.2.0», «v0.2.0», «0.2» и «0.2.0-beta.1». Ведущая «v» —
    /// из имени тега GitHub.
    public init?(_ source: String) {
        var rest = Substring(source.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }

        let head = rest.prefix { $0.isNumber || $0 == "." }
        let pieces = head.split(separator: ".", omittingEmptySubsequences: true)
        let numbers = pieces.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == pieces.count else { return nil }

        var normalized = numbers
        while normalized.count > 1, normalized.last == 0 { normalized.removeLast() }

        parts = normalized
        // Хвост — только «-» или «+»: «0.1.0 (2609261522)» — формат показа
        // с номером сборки, а не предрелиз.
        let tail = rest[head.endIndex...].first
        isPrerelease = tail == "-" || tail == "+"
        text = String(head)
    }

    public var description: String { text }

    private func part(_ index: Int) -> Int {
        index < parts.count ? parts[index] : 0
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.parts == rhs.parts && lhs.isPrerelease == rhs.isPrerelease
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0 ..< max(lhs.parts.count, rhs.parts.count) where lhs.part(index) != rhs.part(index) {
            return lhs.part(index) < rhs.part(index)
        }
        return lhs.isPrerelease && !rhs.isPrerelease
    }
}
