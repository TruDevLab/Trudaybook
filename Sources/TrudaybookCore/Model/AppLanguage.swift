import Foundation

/// Язык интерфейса: русский (исходный), английский или китайский — по
/// выбору в настройках или по системе. Строки переводит сама система
/// (`Localizable.strings` в приложении); здесь — то, что системе не видно:
/// язык для дат.
public enum AppLanguage {
    /// Язык, на котором приложение сейчас показано. Без переводов в
    /// приложении (тесты, сборка без ресурсов) — русский.
    public static var code: String {
        let bundle = Bundle.main
        guard bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil
        else { return "ru" }
        return bundle.preferredLocalizations.first ?? "ru"
    }

    public static var locale: Locale { Locale(identifier: code) }

    public static var isRussian: Bool { code.hasPrefix("ru") }

    /// Формат даты: по-русски — ровно как задумано (`ru`), на других языках —
    /// системный шаблон с тем же набором полей: порядок и слова им виднее.
    public static func formatter(ru format: String, template: String, timeZone: TimeZone? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        if let timeZone { formatter.timeZone = timeZone }
        if isRussian {
            formatter.dateFormat = format
        } else {
            formatter.setLocalizedDateFormatFromTemplate(template)
        }
        return formatter
    }
}
