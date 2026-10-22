import Foundation

/// Свой цвет встречи — только у себя, в Trudaybook: календарь, Exchange
/// и участники о нём не знают. Ставится одной встрече, всей серии или
/// всему календарю: вхождение сильнее серии, серия — календаря, свой цвет
/// календаря — сильнее того, что задан в самом календаре.
public enum EventColors {
    public enum Scope: Sendable {
        /// Только это вхождение повторяющейся встречи.
        case occurrence
        /// Вся серия, а у обычной встречи — она сама.
        case series
    }

    /// Ключи встречи и её серии — как у автоподключения: UID общий у всех
    /// повторений и не меняется при переносе, номер встречи без времени
    /// вхождения — когда UID ещё нет. Перенос не теряет цвет.
    public static func seriesKeys(of item: TimelineItem) -> [String] {
        AutoJoinRules.keys(of: item)
    }

    /// Ключ одного вхождения: у EventKit в номере есть время начала,
    /// у Exchange у каждого вхождения свой номер.
    public static func occurrenceKey(of item: TimelineItem) -> String {
        "occurrence:" + item.id
    }

    /// Ключ своего цвета всего календаря.
    public static func calendarKey(_ calendarID: String) -> String {
        "calendar:" + calendarID
    }

    /// Свой цвет встречи (или её календаря); `nil` — цвет из самого календаря.
    public static func color(of item: TimelineItem, in overrides: [String: RGB]) -> RGB? {
        guard item.kind == .event, !overrides.isEmpty else { return nil }
        if item.event?.isRecurring == true, let own = overrides[occurrenceKey(of: item)] { return own }
        if let series = seriesKeys(of: item).lazy.compactMap({ overrides[$0] }).first { return series }
        return item.event?.calendarID.flatMap { overrides[calendarKey($0)] }
    }

    /// Чей цвет на встрече сейчас: вхождения, серии или ничей.
    public static func scope(of item: TimelineItem, in overrides: [String: RGB]) -> Scope? {
        guard item.kind == .event else { return nil }
        if item.event?.isRecurring == true, overrides[occurrenceKey(of: item)] != nil { return .occurrence }
        return seriesKeys(of: item).contains { overrides[$0] != nil } ? .series : nil
    }

    /// Что поменять в отметках, чтобы у встречи стал цвет `color` (`nil` —
    /// вернуть цвет календаря). Цвет `nil` в ответе — удалить ключ.
    ///
    /// Цвет серии убирает свой цвет этого вхождения: иначе встреча, которая
    /// перед глазами, так и осталась бы прежней. Старый ключ серии (до
    /// появления UID) убирается, чтобы не спорить с новым.
    public static func changes(setting color: RGB?, for item: TimelineItem, scope: Scope) -> [(key: String, color: RGB?)] {
        let recurring = item.event?.isRecurring == true
        if scope == .occurrence, recurring {
            return [(occurrenceKey(of: item), color)]
        }
        let keys = seriesKeys(of: item)
        var result: [(key: String, color: RGB?)] = [(keys[0], color)]
        result += keys.dropFirst().map { ($0, nil) }
        if recurring { result.append((occurrenceKey(of: item), nil)) }
        return result
    }
}
