import AppKit
import Combine
import SwiftUI

/// Редактор встречи — отдельным окном, а не листом главного.
///
/// Лист (`.sheet`) прибит к заголовку окна и не двигается, а под ним
/// остаётся таймлайн, на который хочется посмотреть, выбирая время.
/// Окно — дочернее у главного: всегда над ним и не теряется за ним,
/// но тянется за заголовок куда угодно.
///
/// Показ по-прежнему ведёт `AppModel.eventEditor`: запрос появился —
/// окно открылось, стал `nil` (сохранили, отменили) — закрылось.
/// У каждой модели своё окно: у окна обучения — тестовая модель.
@MainActor
enum EventEditorWindow {
    @MainActor private final class Entry {
        var window: NSWindow?
        var requestID: UUID?
        var watch: AnyCancellable?
        var closeObserver: NSObjectProtocol?
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static let frameName = "TrudaybookEventEditor"
    /// Высота строки заголовка: окно без полосы, содержимое начинается ниже.
    static let titlebarHeight: CGFloat = 28

    /// Открытое окно — для отладочного снимка.
    static var current: NSWindow? {
        entries.values.compactMap(\.window).first { $0.isVisible }
    }

    /// Следить за запросами редактора этой модели; `parent` — окно, над
    /// которым встаёт редактор.
    static func attach(model: AppModel, parent: @escaping () -> NSWindow?) {
        let entry = Entry()
        entries[ObjectIdentifier(model)] = entry
        // Запрос правят сразу после создания (тема встречи по письму, список
        // напоминаний) — окно строится уже по итоговому, в следующем такте.
        entry.watch = model.$eventEditor.sink { [weak model] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let model else { return }
                    sync(model: model, entry: entry, parent: parent())
                }
            }
        }
    }

    static func detach(model: AppModel) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(model)) else { return }
        entry.watch = nil
        close(entry)
    }

    private static func sync(model: AppModel, entry: Entry, parent: NSWindow?) {
        guard let request = model.eventEditor else {
            close(entry)
            return
        }
        guard request.id != entry.requestID else { return }
        entry.requestID = request.id
        let content = NSHostingView(rootView: EventEditorSheet(request: request).environmentObject(model))
        // Высоту окна задаёт редактор (`fit`), а не SwiftUI: иначе окно
        // растёт вниз от нижнего края, а не от заголовка.
        content.sizingOptions = []
        if let window = entry.window {
            // Новый запрос при открытом окне (другая встреча, ⇧⌘N) — то же окно.
            window.contentView = content
            window.title = title(request)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 550 + titlebarHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title(request)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.appearance = parent?.appearance
        if let parent {
            // Где оставили в прошлый раз; впервые — по центру главного окна.
            if !window.setFrameUsingName(frameName) {
                let frame = parent.frame
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                              y: frame.midY - window.frame.height / 2))
            }
            parent.addChildWindow(window, ordered: .above)
        } else {
            window.center()
        }
        entry.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                // Закрыли кнопкой окна — как «Отмена».
                window.saveFrame(usingName: frameName)
                entry.window = nil
                entry.requestID = nil
                if let observer = entry.closeObserver { NotificationCenter.default.removeObserver(observer) }
                entry.closeObserver = nil
                if model?.eventEditor != nil { model?.eventEditor = nil }
            }
        }
        entry.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func close(_ entry: Entry) {
        guard let window = entry.window else { return }
        entry.requestID = nil
        window.parent?.removeChildWindow(window)
        window.close()
    }

    private static func title(_ request: EventEditorRequest) -> String {
        if let item = request.editing { return item.title }
        return request.kind == .reminder ? String(localized: "Новое напоминание") : String(localized: "Новая встреча")
    }

    /// Окно — под высоту редактора; верхний край стоит на месте.
    static func fit(height: CGFloat, model: AppModel) {
        guard let window = entries[ObjectIdentifier(model)]?.window else { return }
        var frame = window.frame
        let target = height + titlebarHeight
        guard abs(frame.height - target) > 0.5 else { return }
        frame.origin.y += frame.height - target
        frame.size.height = target
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
