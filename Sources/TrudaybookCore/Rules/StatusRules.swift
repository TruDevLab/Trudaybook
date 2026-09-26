import Foundation

/// Что пользователь сделал с элементом в самом приложении.
///
/// «Разобрано» — понятие приложения, почтовый сервер о нём не знает,
/// поэтому эти отметки хранятся у нас (`ItemStateStore`).
public struct LocalState: Hashable, Sendable {
    public var archivedAt: Date?
    public var answeredAt: Date?
    /// Письмо отложено и вернётся на таймлайн в это время.
    public var snoozedUntil: Date?
    /// Отмечено выполненным вручную — например, встреча убрана «в архив».
    public var doneAt: Date?

    public init(archivedAt: Date? = nil, answeredAt: Date? = nil, snoozedUntil: Date? = nil, doneAt: Date? = nil) {
        self.archivedAt = archivedAt
        self.answeredAt = answeredAt
        self.snoozedUntil = snoozedUntil
        self.doneAt = doneAt
    }

    public var isEmpty: Bool {
        archivedAt == nil && answeredAt == nil && snoozedUntil == nil && doneAt == nil
    }
}

public enum DoneReason: String, Sendable {
    case answered
    case archived
    case completed
    case passed
    case marked

    public var title: String {
        switch self {
        case .answered: return String(localized: "Отвечено")
        case .archived: return String(localized: "В архиве")
        case .completed: return String(localized: "Выполнено")
        case .passed: return String(localized: "Прошло")
        case .marked: return String(localized: "Разобрано")
        }
    }
}

public enum ItemStatus: Hashable, Sendable {
    /// Ждёт действия: письмо не разобрано, встреча идёт, срок напоминания наступил.
    case open
    /// Ещё не наступило: будущая встреча или напоминание.
    case upcoming
    /// Письмо отложено до этого времени.
    case snoozed(until: Date)
    case done(DoneReason)

    public var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

public enum ItemAction: String, CaseIterable, Sendable, Identifiable {
    case archive
    case reply
    case replyAll
    case reschedule
    /// Встреча — отказ организатору (или отмена своей), напоминание — удалить.
    case decline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .archive: return String(localized: "В архив")
        case .reply: return String(localized: "Ответить")
        case .replyAll: return String(localized: "Ответить всем")
        case .reschedule: return String(localized: "Перенести")
        case .decline: return String(localized: "Отклонить")
        }
    }

    public var symbol: String {
        switch self {
        case .archive: return "archivebox"
        case .reply: return "arrowshape.turn.up.left"
        case .replyAll: return "arrowshape.turn.up.left.2"
        case .reschedule: return "clock.arrow.circlepath"
        case .decline: return "xmark.circle"
        }
    }

    /// Клавиша без модификаторов, когда фокус на таймлайне; в меню — с ⌘.
    /// Заглавная — значит, с Shift: «Ответить всем» — ⇧R.
    public var key: Character {
        switch self {
        case .archive: return "e"
        case .reply: return "r"
        case .replyAll: return "R"
        case .reschedule: return "s"
        case .decline: return "d"
        }
    }

    /// Есть ли смысл в действии для такого элемента — в карточке лишние
    /// кнопки не показываются, а в верхней панели они просто неактивны.
    public func applies(to kind: ItemKind) -> Bool {
        switch (self, kind) {
        case (.decline, .mail), (.reply, .reminder), (.replyAll, .reminder): return false
        default: return true
        }
    }
}

public enum Availability: Hashable, Sendable {
    case enabled
    /// Действие недоступно, причина показывается человеку.
    case disabled(String)

    public var isEnabled: Bool { self == .enabled }
}

public enum StatusRules {
    public static func status(of item: TimelineItem, local: LocalState?, now: Date) -> ItemStatus {
        switch item.detail {
        case .mail(let info):
            if local?.archivedAt != nil { return .done(.archived) }
            if local?.answeredAt != nil || info.isAnsweredOnServer { return .done(.answered) }
            if local?.doneAt != nil { return .done(.marked) }
            if let until = local?.snoozedUntil, until > now { return .snoozed(until: until) }
            return .open

        case .event:
            if local?.doneAt != nil { return .done(.marked) }
            let end = item.end ?? item.time
            if end <= now { return .done(.passed) }
            return item.time <= now ? .open : .upcoming

        case .reminder(let info):
            if info.isCompleted { return .done(.completed) }
            if local?.doneAt != nil { return .done(.marked) }
            return item.time <= now ? .open : .upcoming
        }
    }

    /// Где элемент стоит на таймлайне. Отложенное письмо переезжает
    /// на время, до которого его отложили, — там оно и «всплывает».
    public static func effectiveTime(of item: TimelineItem, local: LocalState?) -> Date {
        if item.kind == .mail, let until = local?.snoozedUntil { return until }
        return item.time
    }

    /// Попадает ли элемент в «Не разобрано».
    ///
    /// - Письмо — пока открыто, начиная с порога `mailCutoff`: при первом
    ///   запуске иначе хлынули бы тысячи старых писем.
    /// - Напоминание — пока просрочено и не выполнено, без порога: старая
    ///   невыполненная задача остаётся задачей.
    /// - Встреча — никогда: прошедшая становится выполненной сама.
    public static func isUnresolved(_ item: TimelineItem, local: LocalState?, now: Date, mailCutoff: Date) -> Bool {
        guard status(of: item, local: local, now: now) == .open else { return false }
        switch item.kind {
        case .mail: return item.time >= mailCutoff
        case .reminder: return true
        case .event: return false
        }
    }

    public static func availability(of action: ItemAction, for item: TimelineItem, local: LocalState?, now: Date) -> Availability {
        let status = status(of: item, local: local, now: now)
        switch (action, item.detail) {
        case (.archive, .mail):
            return local?.archivedAt == nil ? .enabled : .disabled(String(localized: "Письмо уже в архиве"))
        case (.archive, .event):
            return status.isDone ? .disabled(String(localized: "Встреча уже разобрана")) : .enabled
        case (.archive, .reminder):
            return status.isDone ? .disabled(String(localized: "Напоминание уже выполнено")) : .enabled

        case (.reply, .mail), (.replyAll, .mail):
            return .enabled
        case (.reply, .event(let info)), (.replyAll, .event(let info)):
            let hasPeople = info.organizer?.address != nil
                || info.attendees.contains { !$0.isMe && $0.person.address != nil }
            return hasPeople ? .enabled : .disabled(String(localized: "У встречи нет участников — отвечать некому"))
        case (.reply, .reminder), (.replyAll, .reminder):
            return .disabled(String(localized: "На напоминание отвечать некому"))

        case (.decline, .mail):
            return .disabled(String(localized: "Письмо отклонить нельзя — его можно убрать в архив"))
        case (.decline, .event(let info)):
            if !info.canDecline { return .disabled(String(localized: "Календарь «\(info.calendarTitle)» только для чтения")) }
            if let end = item.end, end <= now { return .disabled(String(localized: "Встреча уже прошла")) }
            return .enabled
        case (.decline, .reminder):
            return .enabled

        case (.reschedule, .mail):
            return local?.archivedAt == nil ? .enabled : .disabled(String(localized: "Письмо уже в архиве"))
        case (.reschedule, .event(let info)):
            if !info.canReschedule {
                return .disabled(String(localized: "Встречу назначил другой человек — перенести её может только организатор"))
            }
            return .enabled
        case (.reschedule, .reminder(let info)):
            return info.isCompleted ? .disabled(String(localized: "Напоминание уже выполнено")) : .enabled
        }
    }
}
