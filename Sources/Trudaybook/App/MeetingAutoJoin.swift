import AppKit
import TrudaybookCore

/// Автоподключение: в момент начала встречи её ссылка открывается сама —
/// в Zoom, Teams, Телемосте… тем же путём, что кнопка «Подключиться»
/// (`MeetingOpener`: в приложение сервиса, только если оно подписано им).
///
/// Часы приложения тикают раз в полминуты — это почти минута опоздания.
/// Поэтому тик ещё и ставит точный таймер на начало ближайшей встречи.
@MainActor
final class MeetingAutoJoin {
    weak var model: AppModel?
    /// Уже открытые (или пропущенные) вхождения — чтобы не открыть второй раз.
    /// В памяти: после перезапуска встречу, начавшуюся больше `grace`
    /// назад, правило и так не откроет.
    private var opened: Set<String> = []
    private var exact: Timer?

    func tick() async {
        guard let model else { return }
        let now = model.currentTime
        let events = await model.autoJoinCandidates(now: now)
        let due = AutoJoinRules.due(events, now: now, overrides: model.autoJoinOverrides,
                                    global: model.autoJoinMeetings, opened: opened)
        opened.formUnion(due.handled)
        if let meeting = due.open, let link = meeting.event?.link {
            if model.options.demo {
                // Тестовые ссылки ведут на настоящие сервисы — не открываем.
                DebugLog.write("автоподключение (тестовый режим): \(link.provider.rawValue)")
            } else {
                DebugLog.write("автоподключение: \(link.provider.rawValue)")
                MeetingOpener.open(link)
            }
            if due.handled.count > 1 {
                DebugLog.write("автоподключение: одновременно ещё \(due.handled.count - 1) — не открыты")
            }
        }
        schedule(AutoJoinRules.nextStart(events, now: now, overrides: model.autoJoinOverrides,
                                         global: model.autoJoinMeetings, opened: opened), now: now)
    }

    /// Таймер ровно на начало: следующий тик часов был бы до полуминуты позже.
    private func schedule(_ start: Date?, now: Date) {
        exact?.invalidate()
        exact = nil
        guard let start else { return }
        let timer = Timer(timeInterval: max(start.timeIntervalSince(now), 0) + 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tick() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        exact = timer
    }
}
