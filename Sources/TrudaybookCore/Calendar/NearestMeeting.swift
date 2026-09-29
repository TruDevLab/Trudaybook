import Foundation

/// Какая встреча сейчас главная: к ней подключаются сочетанием клавиш,
/// на ней стоит фокус в окошке строки меню.
public enum NearestMeeting {
    /// За столько до начала встреча уже «текущая»: подключаются заранее.
    public static let lead: TimeInterval = 10 * 60

    /// Идущая (или начинающаяся в ближайшие 10 минут) встреча, а если такой
    /// нет — следующая. Из нескольких идущих — начавшаяся позже всех: длинный
    /// блок «Работа 9–18» не должен заслонять созвон в 11:00.
    /// Отменённые, отклонённые и встречи на весь день не считаются;
    /// `needsLink` — только онлайн-встречи со ссылкой.
    public static func pick(_ items: [TimelineItem], now: Date, needsLink: Bool) -> TimelineItem? {
        let candidates = items.filter { item in
            guard item.kind == .event, !item.isAllDay, let info = item.event,
                  !info.isCancelled, info.myResponse != .declined else { return false }
            if needsLink, info.link == nil { return false }
            return (item.end ?? item.time) > now
        }
        let current = candidates.filter { $0.time <= now.addingTimeInterval(lead) }
        if let latest = current.max(by: { $0.time < $1.time }) { return latest }
        return candidates.min(by: { $0.time < $1.time })
    }
}
