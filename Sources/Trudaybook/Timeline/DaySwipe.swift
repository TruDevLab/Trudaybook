import AppKit
import SwiftUI

/// Свайп двумя пальцами по трекпаду вбок — соседний день, в неделе —
/// соседняя неделя. Как листание страниц в Safari: пальцы влево — вперёд.
/// Шкала прокручивается только вверх-вниз, поэтому жест вбок ни с чем
/// не спорит.
struct DaySwipe: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content.background(DaySwipeMonitor { step in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            withAnimation(Motion.move) { model.shiftDay(step) }
        })
    }
}

/// Пустой `NSView` под видом: ловит прокрутку в его границах, не забирая
/// её у прокрутки самого вида.
private struct DaySwipeMonitor: NSViewRepresentable {
    let shift: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.shift = shift
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.shift = shift
    }

    final class MonitorView: NSView {
        var shift: ((Int) -> Void)?
        private var monitor: Any?
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var fired = false

        /// Столько точек вбок — и жест считается листанием, а не дрожью пальцев.
        static let threshold: CGFloat = 120

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            // Только трекпад: у колёсика мыши нет жеста.
            guard event.window === window, event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if event.phase.contains(.began) {
                dx = 0
                dy = 0
                fired = false
            }
            guard event.phase.contains(.began) || event.phase.contains(.changed) else { return }
            dx += event.scrollingDeltaX
            dy += event.scrollingDeltaY
            guard !fired, abs(dx) > Self.threshold, abs(dx) > abs(dy) * 2 else { return }
            // Содержимое уезжает влево — вперёд, как страницы в Safari.
            fired = true
            shift?(dx < 0 ? 1 : -1)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
