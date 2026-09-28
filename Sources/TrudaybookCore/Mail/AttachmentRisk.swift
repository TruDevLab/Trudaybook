import Foundation

/// Вложения из писем: имя и тип задаёт отправитель.
public enum AttachmentRisk {
    /// Расширения, которые не открывают документ, а запускают код: скрипты,
    /// установщики, программы, ярлыки на команды и автоматизации.
    static let executable: Set<String> = [
        "app", "command", "sh", "bash", "zsh", "csh", "tool", "pkg", "mpkg", "dmg", "iso",
        "scpt", "scptd", "applescript", "workflow", "action", "terminal", "jar", "py", "pl", "rb",
        "js", "jse", "vbs", "exe", "msi", "bat", "cmd", "ps1", "com", "scr", "reg",
        "webloc", "inetloc", "fileloc", "url", "desktop", "mobileconfig", "kext", "plugin", "prefpane",
    ]

    public static func isExecutable(name: String) -> Bool {
        guard let cleaned = safeName(name) else { return false }
        let ext = (cleaned as NSString).pathExtension.lowercased()
        return executable.contains(ext)
    }

    /// Безопасное имя файла. Убирается:
    /// - путь (`/`, `:`) и точки в начале — не выйти из папки и не спрятать файл;
    /// - управляющие символы и символы направления письма (U+202E и родня):
    ///   с ними `счёт‮fdp.command` выглядит как «счёт command.pdf»;
    /// - лишняя длина — больше 200 знаков имя не бывает, а файловая система
    ///   на длинном оборвёт запись.
    /// `nil` — от имени ничего не осталось.
    public static func safeName(_ name: String) -> String? {
        let invisible: Set<Unicode.Scalar> = [
            "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{061C}", "\u{FEFF}", "\u{200B}",
        ]
        let scalars = name.unicodeScalars.filter { scalar in
            !invisible.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
        }
        var cleaned = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let base = (cleaned as NSString).deletingPathExtension
            let keep = 200 - (ext.isEmpty ? 0 : ext.count + 1)
            cleaned = String(base.prefix(max(keep, 1))) + (ext.isEmpty ? "" : "." + ext)
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
