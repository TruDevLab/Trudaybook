import Foundation

/// Ссылки на созвон для новой встречи: из своих прошлых встреч, свои
/// постоянные и страницы сервисов «создать новую».
///
/// Создать встречу в Zoom, Teams или Телемосте без входа в сервис нельзя,
/// а вход — это ключи сервиса в приложении и запросы к нему. Поэтому ссылка
/// берётся из того, что уже есть у человека, или он создаёт её на сайте
/// сервиса, а приложение подхватывает её из буфера обмена.
public enum MeetingLinkHistory {
    public struct Entry: Hashable, Sendable {
        public let link: MeetingLink
        /// Тема последней встречи с этой ссылкой.
        public let title: String
        /// Начало последней встречи с этой ссылкой.
        public let date: Date
        /// Ссылка повторяющейся встречи живёт дольше разовой (разовая Zoom
        /// перестаёт работать примерно через 30 дней).
        public let recurring: Bool
    }

    /// Ссылки своих встреч, без повторов, свежие сверху. Чужие не берём:
    /// ссылка чужой встречи ведёт в чужую комнату.
    public static func recent(_ events: [TimelineItem], isMine: (TimelineItem) -> Bool,
                              limit: Int = 8) -> [Entry] {
        var latest: [String: Entry] = [:]
        for item in events where item.kind == .event {
            guard let info = item.event, !info.isCancelled, let link = info.link, isMine(item) else { continue }
            let key = identity(of: link.url)
            if let known = latest[key], known.date >= item.time { continue }
            latest[key] = Entry(link: link, title: item.title, date: item.time, recurring: info.isRecurring)
        }
        return latest.values.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    /// Одна и та же комната с разной записью адреса — одна ссылка.
    static func identity(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    /// Ссылка на созвон в тексте: из буфера обмена или из поля настроек.
    public static func parse(_ text: String) -> MeetingLink? {
        MeetingLink.extract(url: nil, location: text, notes: nil)
    }

    /// Поле «Место» со вставленной ссылкой: ссылка на созвон в нём уже
    /// была — заменяется, иначе ссылка дописывается к переговорной.
    public static func inserting(_ url: URL, into location: String) -> String {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return url.absoluteString }
        if let old = parse(trimmed), let range = trimmed.range(of: old.url.absoluteString) {
            return trimmed.replacingCharacters(in: range, with: url.absoluteString)
        }
        return trimmed + " · " + url.absoluteString
    }

    /// Где создать новую встречу без входа в приложение: страница сервиса.
    /// Teams здесь нет — рабочие встречи Teams создаются в Outlook или в
    /// самом Teams, ссылки на «создать» у него нет.
    public static let newMeetingPages: [(provider: MeetingLink.Provider, url: URL)] = [
        (.zoom, URL(string: "https://zoom.us/meeting/schedule")!),
        (.meet, URL(string: "https://meet.google.com/new")!),
        (.telemost, URL(string: "https://telemost.yandex.ru/")!),
    ]
}
