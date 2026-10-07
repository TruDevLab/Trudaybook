import AppKit
import SwiftUI
import TrudaybookCore

/// Перетаскивание строки из нижнего списка — своим сеансом AppKit.
///
/// `onDrag` в строке системного `List` не работает: таблица под списком
/// забирает перетаскивание себе, и ни плашки под курсором, ни броска не
/// получается (проверено синтетическими событиями: замыкание `onDrag`
/// зовётся, а сеанс так и не начинается). Поэтому строка ловит сдвиг мыши
/// жестом и сама начинает сеанс у своего `NSView` — с той же строкой
/// номера на доске обмена, что ждут шкала и кнопки действий.
struct ListDragSource: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewState private var anchor = ListDragAnchor()

    func body(content: Content) -> some View {
        content
            .background(ListDragAnchorView(anchor: anchor))
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        guard !anchor.started else { return }
                        anchor.started = true
                        anchor.begin(item, model: model)
                    }
                    .onEnded { _ in anchor.started = false }
            )
    }
}

/// Держатель `NSView` строки и источник сеанса перетаскивания.
@MainActor
final class ListDragAnchor: NSObject, NSDraggingSource {
    weak var view: NSView?
    var started = false
    private weak var model: AppModel?

    func begin(_ item: TimelineItem, model: AppModel) {
        guard let view, let event = NSApp.currentEvent,
              [.leftMouseDragged, .leftMouseDown].contains(event.type) else {
            started = false
            return
        }
        self.model = model
        model.dragging = item
        let renderer = ImageRenderer(content: DragPreview(item: item))
        renderer.scale = view.window?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 200, height: 30))
        // Плашка — прямо под курсором, как у карточек таймлайна.
        let point = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - 16, y: point.y - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        let dragging = NSDraggingItem(pasteboardWriter: item.id as NSString)
        dragging.setDraggingFrame(frame, contents: image)
        DebugLog.write("перетаскивание начато: \(item.kind.rawValue), из списка")
        let session = view.beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            started = false
            model?.dragging = nil
        }
    }
}

/// Пустой `NSView` под строкой: у него начинается сеанс перетаскивания.
private struct ListDragAnchorView: NSViewRepresentable {
    let anchor: ListDragAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Щелчки — мимо: под строкой он только ради сеанса перетаскивания.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
