import AppKit
import WebKit
import TrudaybookCore

/// Стрелки вверх-вниз без модификаторов — к соседнему письму или событию;
/// цифры 0–3 — приоритет выбранного.
///
/// Через перехват клавиш окна, а не фокус SwiftUI: список писем и таймлайн
/// — не поля ввода, фокуса у них нет, а переходить хочется сразу после
/// щелчка по письму. Стрелки не трогаются, когда их ждёт кто-то другой:
/// поле ввода, текст письма, открытый лист или ответ.
@MainActor
enum KeyNavigation {
    static let up: UInt16 = 126
    static let down: UInt16 = 125

    /// `true` — клавиша обработана и дальше не идёт.
    static func handle(_ event: NSEvent, window: NSWindow?, model: AppModel) -> Bool {
        let arrow = event.keyCode == up || event.keyCode == down
        // Цифры 0–3 — приоритет выбранного письма (как ⌘0…⌘3 в меню).
        let priority = event.charactersIgnoringModifiers.flatMap(Int.init).flatMap(Priority.init(rawValue:))
        guard event.type == .keyDown, arrow || priority != nil,
              let window, event.window === window, window.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              model.draft == nil
        else { return false }
        if let responder = window.firstResponder, isTextOrWeb(responder) { return false }
        if let priority {
            guard let id = model.selectedID else { return false }
            model.setPriority(priority, for: id)
        } else {
            model.moveSelection(by: event.keyCode == down ? 1 : -1)
        }
        return true
    }

    private static func isTextOrWeb(_ responder: NSResponder) -> Bool {
        if responder is NSText { return true }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView || current is NSTextView || current is NSTextField { return true }
            view = current.superview
        }
        return false
    }
}
