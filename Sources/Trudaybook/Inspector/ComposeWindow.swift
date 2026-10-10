import AppKit
import SwiftUI
import TrudaybookCore

/// Новое письмо в отдельном окне — из карточки ассистента.
///
/// Свой черновик, не `model.draft`: письмо из чата не должно занимать
/// правую панель, где человек в это время читает почту, — и отправляет
/// его человек сам, кнопкой в этом окне.
@MainActor
enum ComposeWindow {
    private static var windows: [UUID: NSWindow] = [:]
    private static var closeObservers: [UUID: NSObjectProtocol] = [:]
    static let frameName = "TrudaybookCompose"

    /// Последнее открытое — для снимка (`--compose-window`).
    static var current: NSWindow? { windows.values.first }

    static func show(_ draft: OutgoingMail, model: AppModel) {
        let id = UUID()
        let state = ComposeWindowState(draft: draft, model: model) { close(id) }
        let hosting = NSHostingView(rootView: ComposeWindowView(state: state).environmentObject(model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = draft.subject.isEmpty ? String(localized: "Новое письмо") : draft.subject
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 520, height: 480)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // Первое — где оставили в прошлый раз, следующие — лесенкой от него.
        if let last = windows.values.first {
            window.setFrame(last.frame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else if !window.setFrameUsingName(frameName) {
            window.center()
        }
        windows[id] = window
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { closed(id) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func close(_ id: UUID) {
        windows[id]?.close()
    }

    private static func closed(_ id: UUID) {
        windows[id]?.saveFrame(usingName: frameName)
        windows[id] = nil
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Черновик окна и его отправка.
@MainActor
final class ComposeWindowState: ObservableObject {
    @Published var draft: OutgoingMail? {
        // «Отмена» и отправка обнуляют черновик — окно закрывается.
        didSet { if draft == nil { onClose() } }
    }
    @Published private(set) var isSending = false
    @Published var problem: String?
    private weak var model: AppModel?
    private let onClose: () -> Void

    init(draft: OutgoingMail, model: AppModel, onClose: @escaping () -> Void) {
        self.draft = draft
        self.model = model
        self.onClose = onClose
    }

    func send() {
        guard let draft, let model, !isSending else { return }
        isSending = true
        problem = nil
        Task {
            let failure = await model.send(draft)
            isSending = false
            if let failure {
                problem = failure
            } else {
                self.draft = nil
            }
        }
    }
}

private struct ComposeWindowView: View {
    @ObservedObject var state: ComposeWindowState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Полоса заголовка — кнопкам окна, содержимое под ней.
            Color.clear.frame(height: 8)
            if let problem = state.problem {
                InlineNotice(problem)
                    .font(.callout)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.md)
            }
            ComposerView(item: nil, draft: $state.draft, isSending: state.isSending,
                         onSend: state.send, onCancel: { state.draft = nil })
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
