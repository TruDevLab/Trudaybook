import Foundation

/// Автоподключение: в момент начала встречи открыть её ссылку.
///
/// Включается для всех встреч в настройках или для одной — в её окне;
/// своя отметка встречи сильнее общей настройки.
public enum AutoJoinRules {
    /// Сколько после начала ещё открываем. Приложение могли запустить или
    /// Mac — разбудить уже во время встречи: через пару минут созвон,
    /// открывшийся сам по себе, скорее помешает, чем поможет.
    public static let grace: TimeInterval = 120

    /// Ключи отметки встречи — по порядку поиска. UID общий у всех
    /// повторений и не меняется при переносе; номер серии (без времени
    /// вхождения) — на случай, когда UID у встречи ещё нет.
    public static func keys(of item: TimelineItem) -> [String] {
        var keys: [String] = []
        if let uid = item.event?.uid, !uid.isEmpty { keys.append("uid:" + uid) }
        if let at = item.id.lastIndex(of: "@") {
            keys.append(String(item.id[..<at]))
        } else {
            keys.append(item.id)
        }
        return keys
    }

    /// Встреча, у которой есть что открыть: не на весь день, не отменена,
    /// не отклонена, со ссылкой знакомого сервиса. Ссылки «похоже на созвон»
    /// с чужого адреса сами не открываются — открыть страницу из
    /// приглашения без нажатия значит поверить отправителю.
    public static func canAutoJoin(_ item: TimelineItem) -> Bool {
        guard item.kind == .event, !item.isAllDay, let info = item.event,
              !info.isCancelled, info.myResponse != .declined,
              let link = info.link, link.provider != .other else { return false }
        return true
    }

    /// Включено ли для встречи: своя отметка, иначе общая настройка.
    public static func isEnabled(_ item: TimelineItem, overrides: [String: Bool], global: Bool) -> Bool {
        for key in keys(of: item) {
            if let value = overrides[key] { return value }
        }
        return global
    }

    /// Что открыть сейчас: началась не позже `grace` назад, ещё не открывали.
    /// Начались сразу несколько — открывается одна: два созвона разом — это
    /// не подключение, а путаница. Остальные тоже считаются обработанными
    /// (все id — во втором значении), чтобы не открыться следующей проверкой.
    public static func due(_ events: [TimelineItem], now: Date, overrides: [String: Bool], global: Bool,
                           opened: Set<String>) -> (open: TimelineItem?, handled: [String]) {
        let started = events.filter { item in
            guard !opened.contains(item.id), canAutoJoin(item),
                  isEnabled(item, overrides: overrides, global: global) else { return false }
            let since = now.timeIntervalSince(item.time)
            return since >= 0 && since <= grace && (item.end ?? item.time) > now
        }
        // Позже начавшаяся — та, на которую идут сейчас (как `NearestMeeting`).
        .sorted { ($0.time, $0.title) > ($1.time, $1.title) }
        return (started.first, started.map(\.id))
    }

    /// Когда начнётся ближайшая встреча, которую надо открыть, — для точного
    /// таймера между редкими проверками.
    public static func nextStart(_ events: [TimelineItem], now: Date, overrides: [String: Bool], global: Bool,
                                 opened: Set<String>) -> Date? {
        events.filter { item in
            item.time > now && !opened.contains(item.id) && canAutoJoin(item)
                && isEnabled(item, overrides: overrides, global: global)
        }
        .map(\.time)
        .min()
    }
}
