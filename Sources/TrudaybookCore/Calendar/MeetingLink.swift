import Foundation

/// Ссылка на онлайн-встречу с опознанным сервисом.
///
/// Перенесено из Trunook (`Calendar/CalendarItem.swift`) без изменений логики.
public struct MeetingLink: Hashable, Sendable {
    public let url: URL
    public let provider: Provider

    public enum Provider: String, Sendable {
        case zoom = "Zoom"
        case teams = "Teams"
        case meet = "Google Meet"
        case telemost = "Телемост"
        case webex = "Webex"
        case whereby = "Whereby"
        case other = "Встреча"
    }

    public init(url: URL, provider: Provider) {
        self.url = url
        self.provider = provider
    }

    /// Ищет ссылку по всем полям, куда её кладут разные календари:
    /// приглашения Exchange пишут в notes, Google — в url, а люди руками —
    /// в location. Проверяем всё, в порядке надёжности.
    public static func extract(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = make(from: url) { return link }
        for text in [location, notes].compactMap({ $0 }) {
            if let link = firstLink(in: text) { return link }
        }
        return nil
    }

    private static func firstLink(in text: String) -> MeetingLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range).compactMap(\.url)

        // Сначала знакомый сервис по всему тексту: в приглашении обычно
        // соседствуют ссылка на конференцию и ссылки на карты или телефоны.
        for candidate in matches {
            if let link = make(from: candidate), link.provider != .other {
                return link
            }
        }
        return matches.first.flatMap { make(from: $0) }
    }

    private static func make(from url: URL) -> MeetingLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        let provider: Provider
        switch true {
        case host.contains("zoom.us"), host.contains("zoom.com"):
            provider = .zoom
        case host.contains("teams.microsoft.com"), host.contains("teams.live.com"):
            provider = .teams
        case host.contains("meet.google.com"):
            provider = .meet
        case host.contains("telemost.yandex"), host.contains("telemost.360"):
            provider = .telemost
        case host.contains("webex.com"):
            provider = .webex
        case host.contains("whereby.com"):
            provider = .whereby
        default:
            // Ссылку без узнаваемого хоста считаем встречей, только если она
            // похожа на приглашение, а не на вложение или карту.
            guard path.contains("meet") || path.contains("call") || path.contains("conf") else {
                return nil
            }
            provider = .other
        }
        return MeetingLink(url: url, provider: provider)
    }
}
