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

    /// Та же встреча — ссылкой для приложения сервиса, без браузера.
    public struct NativeApp: Hashable, Sendable {
        /// Ссылка в схеме приложения (`zoommtg:`, `msteams:`, `telemost:`).
        public let url: URL
        /// Кому её можно отдать: требование к подписи программы. Схему
        /// может перехватить любая программа — ссылку с паролем встречи
        /// получит только подписанная самим сервисом.
        public let requirement: String
    }

    /// Ссылка для приложения — Zoom, Teams и Телемост: их схемы известны и
    /// принимают ту же встречу. У остальных `nil` — откроется браузер.
    /// Хост сверяется строго (`zoom.us` или `*.zoom.us`), а не «содержит»:
    /// `zoom.us.example.com` сюда не пройдёт.
    public var nativeApp: NativeApp? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else { return nil }
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }

        if under("zoom.us") || under("zoom.com") {
            // /j/<номер> — встреча, /w/<номер> — вебинар.
            let parts = components.path.split(separator: "/")
            guard parts.count == 2, parts[0] == "j" || parts[0] == "w",
                  let number = parts.last, (9...13).contains(number.count),
                  number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            var target = URLComponents()
            target.scheme = "zoommtg"
            target.host = host
            target.path = "/join"
            var query = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(number))]
            if let password = components.queryItems?.first(where: { $0.name == "pwd" })?.value {
                // Пароль — как его пишет Zoom; всё прочее из ссылки не передаём.
                guard password.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) else { return nil }
                query.append(URLQueryItem(name: "pwd", value: password))
            }
            target.queryItems = query
            return target.url.map {
                NativeApp(url: $0, requirement: #"identifier "us.zoom.xos" and anchor apple generic and certificate leaf[subject.OU] = "BJ4HAAB9B3""#)
            }
        }
        if host == "teams.microsoft.com" {
            // Приглашение Teams: путь и параметры те же, меняется только схема.
            let path = components.percentEncodedPath
            guard path.hasPrefix("/l/meetup-join/") else { return nil }
            var text = "msteams:" + path
            if let query = components.percentEncodedQuery { text += "?" + query }
            return URL(string: text).map {
                NativeApp(url: $0, requirement: #"(identifier "com.microsoft.teams2" or identifier "com.microsoft.teams") and anchor apple generic and certificate leaf[subject.OU] = "UBF8T346G9""#)
            }
        }
        if Self.telemostHosts.contains(host) {
            // Как передаёт сайт Телемоста его приложению (видно в журнале
            // приложения): `telemost://https//хост/j/номер` — без двоеточия.
            let parts = components.path.split(separator: "/")
            guard parts.count == 2, parts[0] == "j", let number = parts.last,
                  (6...20).contains(number.count), number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return URL(string: "telemost://https//\(host)/j/\(number)").map {
                NativeApp(url: $0, requirement: #"identifier "ru.yandex.desktop.telemost" and anchor apple generic and certificate leaf[subject.OU] = "477EAT77S3""#)
            }
        }
        return nil
    }

    /// Адреса Телемоста — списком: по «содержит» прошёл бы чужой хост.
    private static let telemostHosts: Set<String> = [
        "telemost.yandex.ru", "telemost.360.yandex.ru", "telemost.yandex.com", "telemost.360.yandex.com",
    ]

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
