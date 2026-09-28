import Foundation
import TrudaybookCore
import WidgetKit

/// Сводка для виджетов на рабочем столе (`WidgetSnapshot`).
///
/// Пишется, только когда изменилась: виджеты перерисовываются по сигналу
/// (`WidgetCenter`), а у системы на это ограниченный бюджет. Файл — 0600
/// в своей папке; виджету подписью разрешено читать только её. В тестовом
/// режиме не пишется: настоящие виджеты показывали бы выдуманную почту.
@MainActor
final class WidgetFeed {
    private var lastData: Data?
    private var lastCalendarLoad: Date?
    private var calendarItems: [TimelineItem] = []

    /// Темы писем в виджете — видны всем, кто смотрит на рабочий стол.
    var showSubjects: Bool {
        get { UserDefaults.standard.object(forKey: "widgetSubjects") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "widgetSubjects"); lastData = nil }
    }

    /// Встречи на сегодня и завтра — не чаще раза в пять минут (или сразу
    /// после изменений в календаре, `force`).
    func calendarIsStale(now: Date, force: Bool) -> Bool {
        force || lastCalendarLoad.map { now.timeIntervalSince($0) > 300 } ?? true
    }

    func setCalendar(_ items: [TimelineItem], at now: Date) {
        calendarItems = items
        lastCalendarLoad = now
    }

    func publish(now: Date, unresolved: [TimelineItem], isImportant: (TimelineItem) -> Bool,
                 weather: WidgetSnapshot.Weather?) {
        var snapshot = WidgetSnapshot.make(now: now, calendarItems: calendarItems, unresolved: unresolved,
                                           isImportant: isImportant, showSubjects: showSubjects, weather: weather)
        // Время записи в сравнение не входит: иначе файл менялся бы каждые полминуты.
        snapshot.updated = .distantPast
        guard let comparable = snapshot.encoded(), comparable != lastData else { return }
        lastData = comparable
        snapshot.updated = now
        guard let data = snapshot.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: WidgetSnapshot.folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: WidgetSnapshot.file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: WidgetSnapshot.file.path)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            DebugLog.write("виджеты: сводка не записана — \(error.localizedDescription)")
        }
    }
}
