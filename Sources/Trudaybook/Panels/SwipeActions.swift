import SwiftUI
import TrudaybookCore

/// Быстрое действие по свайпу строки в списке писем. Свайп влево открывает
/// действие справа от строки, вправо — слева; какое — в настройках.
enum SwipeAction: String, CaseIterable, Identifiable {
    case none
    case archive
    case done
    case priorityHigh
    case priorityMedium
    case priorityLow
    case snoozeHour
    case snoozeTomorrow
    case reply

    var id: String { rawValue }

    /// Название в настройках.
    var title: String {
        switch self {
        case .none: String(localized: "Ничего")
        case .archive: String(localized: "В архив")
        case .done: String(localized: "Разобрано")
        case .priorityHigh: String(localized: "Высокий приоритет")
        case .priorityMedium: String(localized: "Средний приоритет")
        case .priorityLow: String(localized: "Низкий приоритет")
        case .snoozeHour: String(localized: "Отложить на час")
        case .snoozeTomorrow: String(localized: "Отложить до завтра, 9:00")
        case .reply: String(localized: "Ответить")
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .archive: "archivebox"
        case .done: "checkmark"
        case .priorityHigh: Priority.high.symbol
        case .priorityMedium: Priority.medium.symbol
        case .priorityLow: Priority.low.symbol
        case .snoozeHour: "clock"
        case .snoozeTomorrow: "sunrise"
        case .reply: "arrowshape.turn.up.left"
        }
    }

    var tint: Color {
        switch self {
        case .none: .gray
        case .archive: .indigo
        case .done: .green
        case .priorityHigh: Priority.high.color
        case .priorityMedium: Priority.medium.color
        case .priorityLow: Priority.low.color
        case .snoozeHour, .snoozeTomorrow: .orange
        case .reply: .blue
        }
    }

    var priority: Priority? {
        switch self {
        case .priorityHigh: .high
        case .priorityMedium: .medium
        case .priorityLow: .low
        default: nil
        }
    }

    static let leftKey = "swipeLeft"
    static let rightKey = "swipeRight"
}

extension AppModel {
    /// Подходит ли действие строке: отвечать можно только на письмо,
    /// архивировать — то, что ещё не в архиве.
    func canSwipe(_ action: SwipeAction, on item: TimelineItem) -> Bool {
        switch action {
        case .none: false
        case .archive: availability(of: .archive, for: item).isEnabled
        case .done: item.kind == .mail && !status(of: item).isDone
        case .priorityHigh, .priorityMedium, .priorityLow: true
        case .snoozeHour, .snoozeTomorrow: availability(of: .reschedule, for: item).isEnabled
        case .reply: item.kind == .mail
        }
    }

    /// Подпись кнопки под строкой: у приоритета, который уже стоит, — «Снять».
    func swipeTitle(_ action: SwipeAction, on item: TimelineItem) -> String {
        if let priority = action.priority, self.priority(of: item) == priority { return String(localized: "Снять приоритет") }
        switch action {
        case .snoozeHour: return String(localized: "На час")
        case .snoozeTomorrow: return String(localized: "Завтра")
        case .priorityHigh, .priorityMedium, .priorityLow: return String(localized: "Приоритет")
        default: return action.title
        }
    }

    func performSwipe(_ action: SwipeAction, on item: TimelineItem) {
        switch action {
        case .none:
            break
        case .archive:
            perform(.archive, on: item.id)
        case .done:
            markDone(item.id)
        case .priorityHigh, .priorityMedium, .priorityLow:
            // Повторный свайп снимает приоритет.
            guard let priority = action.priority else { return }
            setPriority(self.priority(of: item) == priority ? .none : priority, for: item.id)
        case .snoozeHour:
            let date = now.addingTimeInterval(3600)
            reschedule(item, to: Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded() * 300))
        case .snoozeTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            reschedule(item, to: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        case .reply:
            perform(.reply, on: item.id)
        }
    }
}
