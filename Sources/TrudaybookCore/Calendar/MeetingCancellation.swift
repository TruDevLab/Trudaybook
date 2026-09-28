import Foundation

/// Отмена встречи: какому событию календаря относится письмо об отмене
/// и что удалять — вхождение или всю серию.
///
/// Сначала — по UID (Exchange и CalDAV хранят UID из iCalendar). Без него —
/// по названию без приставки «Отменено:» и времени начала: так письмо не
/// зачеркнёт чужую встречу с тем же названием в другой день.
public enum MeetingCancellation {
    static let prefixes = ["отменено:", "отменена:", "отмена:", "canceled:", "cancelled:", "已取消:", "取消:"]

    public static func normalizedTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text
    }

    public static func matches(_ event: TimelineItem, _ cancellation: Invitation) -> Bool {
        guard cancellation.method == .cancel, event.kind == .event else { return false }
        let start = cancellation.recurrenceID ?? cancellation.start
        let sameTime = abs(event.time.timeIntervalSince(start)) < 90
        if let uid = event.event?.uid, !uid.isEmpty, uid.caseInsensitiveCompare(cancellation.uid) == .orderedSame {
            // Отменена вся серия — любое её вхождение; иначе — только это время.
            return cancellation.isSeriesCancellation || sameTime
        }
        return sameTime && normalizedTitle(event.title) == normalizedTitle(cancellation.summary)
    }

    /// Вся серия — только если отменили серию и встреча действительно повторяется.
    public static func scope(for cancellation: Invitation, event: TimelineItem) -> RecurrenceScope {
        cancellation.isSeriesCancellation && event.event?.isRecurring == true ? .all : .thisEvent
    }
}
