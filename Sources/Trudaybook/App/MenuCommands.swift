import AppKit
import WebKit

/// «Найти» (⌘F), «Найти далее» (⌘G), «Найти ранее» (⇧⌘G).
///
/// В поле с текстом (заметка, ответ) и в теле письма — системная строка
/// поиска по нему. В главном окне вне них ⌘F ставит курсор в поиск по
/// почте; в окне письма — ищет в самом письме.
@MainActor
final class FindMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = FindMenuTarget()
    /// Курсор в поиск по почте — у главного окна (`AppModel.focusSearch`).
    /// `false` — у этого окна такого поиска нет.
    var focusSearch: (NSWindow) -> Bool = { _ in false }

    static func items() -> [NSMenuItem] {
        [item(String(localized: "Найти…"), "f", .showFindInterface),
         item(String(localized: "Найти далее"), "g", .nextMatch),
         item(String(localized: "Найти ранее"), "G", .previousMatch)]
    }

    private static func item(_ title: String, _ key: String, _ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(find(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.tag = action.rawValue
        item.target = shared
        return item
    }

    @objc func find(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow else { return }
        if let target = Self.findable(in: window) {
            target.performTextFinderAction(sender)
        } else if sender.tag == NSTextFinder.Action.showFindInterface.rawValue {
            _ = focusSearch(window)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        if Self.findable(in: window) != nil { return true }
        // Поиск по почте — только «Найти»; листать в нём нечего.
        return item.tag == NSTextFinder.Action.showFindInterface.rawValue
    }

    /// Где искать: поле с текстом в фокусе, тело письма в фокусе — или
    /// единственное тело письма в окне, где нет поиска по почте.
    private static func findable(in window: NSWindow) -> NSResponder? {
        if let text = window.firstResponder as? NSTextView, !text.isFieldEditor {
            return text.usesFindBar ? text : nil
        }
        var view = window.firstResponder as? NSView
        while let current = view {
            if current is WKWebView { return current }
            view = current.superview
        }
        if LetterWindow.key != nil, let content = window.contentView { return LetterPrint.letterView(in: content) }
        return nil
    }
}

/// «Напечатать…» (⌘P): письмо в окне письма или выбранное в главном.
@MainActor
enum LetterPrint {
    static func run() {
        guard let window = NSApp.keyWindow, let content = window.contentView,
              let view = letterView(in: content) else {
            NSSound.beep()
            return
        }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let operation = view.printOperation(with: info)
        // Без размера WebKit отдаёт печати пустой лист.
        operation.view?.frame = view.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Тело письма в окне: в фокусе — оно, иначе первое видимое письмо
    /// (описание встречи — тоже `MailWebView`, но оно листается с панелью).
    static func letterView(in root: NSView) -> MailWebView? {
        if let focused = root.window?.firstResponder as? NSView {
            var view: NSView? = focused
            while let current = view {
                if let web = current as? MailWebView { return web }
                view = current.superview
            }
        }
        var queue = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let web = view as? MailWebView, !web.forwardsScroll, !web.isHiddenOrHasHiddenAncestor { return web }
            queue += view.subviews
        }
        return nil
    }
}

/// Главное окно: ⌘W и красная кнопка его прячут, а не закрывают.
/// Почта, напоминания и значок в строке меню продолжают работать;
/// вернуть окно — щелчок по значку в Dock или «Окно → Trudaybook».
final class MainWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        orderOut(sender)
    }
}
