import AppKit
import SwiftUI

/// Свайп двумя пальцами по трекпаду вбок — соседний день, в неделе —
/// соседняя неделя. Как листание страниц в Safari: пальцы влево — вперёд.
///
/// Горизонтальный таймлайн дня сам листается вбок по часам — там свайп
/// меняет день, только если шкала уже упёрлась в край (`SwipeEdges`)
/// ещё до начала жеста: докрутили до 24:00, отпустили, провели ещё раз —
/// завтра. Иначе каждая прокрутка к вечеру перескакивала бы на завтра.
struct DaySwipe: ViewModifier {
    @EnvironmentObject private var model: AppModel
    /// Края горизонтальной прокрутки; `nil` — вид вбок не прокручивается.
    var edges: SwipeEdges?

    func body(content: Content) -> some View {
        content.background(DaySwipeMonitor(edges: edges) { step in
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            withAnimation(Motion.move) { model.shiftDay(step) }
        })
    }
}

/// Упёрлась ли прокрутка в начало или в конец.
final class SwipeEdges {
    var atStart = true
    var atEnd = true
}

extension View {
    /// Передавать в `SwipeEdges`, у края ли горизонтальная прокрутка.
    func trackSwipeEdges(_ edges: SwipeEdges) -> some View {
        onScrollGeometryChange(for: [Bool].self) { geometry in
            [geometry.contentOffset.x <= 1,
             geometry.contentOffset.x + geometry.containerSize.width >= geometry.contentSize.width - 1]
        } action: { _, value in
            edges.atStart = value[0]
            edges.atEnd = value[1]
        }
    }
}

/// Пустой `NSView` под видом: ловит прокрутку в его границах, не забирая
/// её у прокрутки самого вида.
private struct DaySwipeMonitor: NSViewRepresentable {
    let edges: SwipeEdges?
    let shift: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.edges = edges
        view.shift = shift
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.edges = edges
        view.shift = shift
    }

    final class MonitorView: NSView {
        var edges: SwipeEdges?
        var shift: ((Int) -> Void)?
        private var monitor: Any?
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var fired = false
        private var allowBack = true
        private var allowForward = true

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
            // Только трекпад: у колёсика мыши нет жеста, а вбок оно крутит шкалу.
            guard event.window === window, event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            if event.phase.contains(.began) {
                dx = 0
                dy = 0
                fired = false
                allowBack = edges?.atStart ?? true
                allowForward = edges?.atEnd ?? true
            }
            guard event.phase.contains(.began) || event.phase.contains(.changed) else { return }
            dx += event.scrollingDeltaX
            dy += event.scrollingDeltaY
            guard !fired, abs(dx) > Self.threshold, abs(dx) > abs(dy) * 2 else { return }
            // Содержимое уезжает влево (как у шкалы, листаемой к вечеру) — вперёд.
            let forward = dx < 0
            guard forward ? allowForward : allowBack else { return }
            fired = true
            shift?(forward ? 1 : -1)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
