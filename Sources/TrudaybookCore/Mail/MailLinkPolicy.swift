import Foundation

/// Что делать со ссылкой, по которой щёлкнули в письме.
public enum MailLinkPolicy {
    public enum Decision: Equatable, Sendable {
        case open, ask, block
    }

    /// Открываются сразу: сайты и письмо (новое письмо в самом Trudaybook).
    static let safe: Set<String> = ["http", "https", "mailto"]
    /// Не открываются никогда: код в адресе и пустышки.
    static let blocked: Set<String> = ["javascript", "vbscript", "data", "about", "blob"]

    public static func decide(_ url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .block }
        if safe.contains(scheme) { return .open }
        if blocked.contains(scheme) { return .block }
        return .ask
    }

    /// Адрес для вопроса — целиком, но не простынёй.
    public static func shown(_ url: URL) -> String {
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}
