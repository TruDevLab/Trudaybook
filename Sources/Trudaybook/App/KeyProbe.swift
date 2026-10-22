import AppKit

/// `--key-probe "привет,esc,cmd+z"` (только с `--demo`) — нажатия клавиш
/// по очереди, через полсекунды; после каждого в журнале «проба клавиш: …» —
/// кто в фокусе и что выбрано. Так без человека проверяются сочетания:
/// ⌘Z после закрытого ответа, Esc, стрелки, пункты меню.
///
/// Шаг — сочетание (`cmd+shift+z`), имя клавиши (`esc`, `return`, `delete`,
/// `tab`, `space`, `up`, `down`, `left`, `right`) или текст: каждая буква —
/// отдельное нажатие; `wait` — пропустить шаг (подождать, пока откроется
/// окно или поле). Нажатия идут в очередь событий, как настоящие, —
/// через меню и мониторы клавиш.
@MainActor
enum KeyProbe {
    private static let named: [String: (code: UInt16, text: String)] = [
        "esc": (53, "\u{1b}"), "return": (36, "\r"), "delete": (51, "\u{7f}"),
        "tab": (48, "\t"), "space": (49, " "),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
        "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
    ]
    /// Коды клавиш ANSI: AppKit сверяет сочетания с ⇧ и по коду клавиши.
    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]
    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "shift": .shift, "opt": .option, "ctrl": .control,
    ]

    static func run(_ script: String, model: AppModel) {
        let steps = script.split(separator: ",").map(String.init)
        // Запущенная из оболочки копия не на переднем плане, и клавишам
        // некуда идти: окно должно стать ключевым.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Без `ignoringOtherApps` система не отдаёт фокус копии,
            // запущенной из оболочки, пока впереди терминал.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            DebugLog.write("проба клавиш: активно \(NSApp.isActive), ключевое окно \(NSApp.keyWindow != nil)")
            // Какие сочетания на самом деле в меню — после того, как AppKit
            // добавил свои пункты («Во весь экран» и другие).
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                let items = menu.items.filter { !$0.isSeparatorItem }.map { item in
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue >> 17):\(item.keyEquivalent)]"
                    return item.title + key
                }
                DebugLog.write("проба клавиш: меню «\(menu.title)»: \(items.joined(separator: " · "))")
            }
        }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(index) * 0.6) {
                press(step)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let window = NSApp.keyWindow
                    let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "—"
                    DebugLog.write("проба клавиш: «\(step)» — окно «\(window?.title ?? "—")», фокус \(responder), выбрано \(model.selectedItem.map { "\($0.kind) «\($0.title.prefix(24))»" } ?? "ничего"), не разобрано \(model.unresolved.count), плашка «\(model.undoNotice?.text ?? "—")», ответ \(model.draft == nil ? "закрыт" : "открыт"), поиск «\(model.searchText)», главное окно \(NSApp.windows.first { $0 is MainWindow }?.isVisible == true ? "видно" : "спрятано"), лист \(window?.attachedSheet.map { String(describing: type(of: $0)) } ?? "—"), встреча \(model.eventEditor == nil ? "—" : "открыта"), чат \(model.assistantOpen ? "открыт" : "свёрнут"), вопросов \(model.assistant.dialogs.reduce(0) { $0 + $1.entries.filter { $0.role == .user }.count }), разговоров \(model.assistant.dialogs.filter { !$0.entries.isEmpty }.count), текст \((window?.firstResponder as? NSTextView).map { "\($0.string.count)" } ?? "—"), отменить: \(model.undo.canUndo ? model.undo.undoMenuItemTitle : "—"), повторить: \(model.undo.canRedo ? model.undo.redoMenuItemTitle : "—")")
                }
            }
        }
    }

    private static func press(_ step: String) {
        guard step != "wait" else { return }
        var parts = step.lowercased().split(separator: "+").map(String.init)
        var flags: NSEvent.ModifierFlags = []
        while parts.count > 1, let flag = modifierNames[parts[0]] {
            flags.insert(flag)
            parts.removeFirst()
        }
        let key = parts.joined(separator: "+")
        if let named = named[key] {
            post(named.text, code: named.code, flags: flags)
        } else if !flags.isEmpty {
            // Как у настоящей клавиатуры: с ⇧ буква заглавная и без учёта модификаторов.
            post(flags.contains(.shift) ? key.uppercased() : key, code: key.first.flatMap { codes[$0] } ?? 0, flags: flags)
        } else {
            // Текст — с исходным регистром.
            step.forEach { post(String($0), code: codes[Character($0.lowercased())] ?? 0, flags: []) }
        }
    }

    private static func post(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: text, charactersIgnoringModifiers: text,
                                               isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
