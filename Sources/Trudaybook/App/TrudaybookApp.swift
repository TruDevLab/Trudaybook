import SwiftUI
import AppKit
import Combine
import TrudaybookCore

/// Точка входа на AppKit, а не на `SwiftUI.App`.
///
/// Со сборкой без Xcode сцена `WindowGroup` не создаёт ни одного окна:
/// приложение запускается и молча ждёт событий (проверено журналом —
/// `NSApp.windows` пуст и через три секунды). Trunook по той же причине
/// держит окна в `NSHostingView`. Здесь так же: окно и меню собираются
/// руками, а всё содержимое — SwiftUI.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var model: AppModel?
    private var pendingURLs: [URL] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(options: LaunchOptions.parse(CommandLine.arguments))
        self.model = model
        NSApp.mainMenu = MainMenu.build(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Trudaybook"
        // Без полосы заголовка: окно одного цвета сверху донизу, панель
        // действий — на месте заголовка, кнопки окна — в её левом краю.
        // Пустая панель инструментов делает заголовок выше (52 вместо 28),
        // и кнопки окна встают по центру панели действий.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "TrudaybookMain")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // Таймлайну — 900, правой панели — 380 (см. `MainView`).
        window.minSize = NSSize(width: 1300, height: 780)
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
        window.center()
        window.setFrameAutosaveName("TrudaybookMain")
        if let size = model.options.windowSize { window.setContentSize(size) }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        // Стрелки — к соседнему письму (см. `KeyNavigation`). Монитор зовётся
        // на главном потоке; событие дальше него не уходит.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let model = self.model else { return false }
                return KeyNavigation.handle(incoming, window: self.window, model: model)
            }
            return handled ? nil : event
        }

        DebugLog.write("запуск: демо=\(model.options.demo)")
        // Обновления — у настоящего приложения; в тестовом режиме только
        // по `--update-probe`, чтобы снимки не ходили в сеть.
        if !model.options.demo || model.options.updateProbe { model.updates.start() }
        // Проба — как по кнопке: мимо суточного срока.
        if model.options.updateProbe { model.updates.check(manual: true) }
        if let version = model.options.updatePreview { model.updates.preview(version: version) }
        Task {
            await model.start()
            if !pendingURLs.isEmpty {
                model.open(urls: pendingURLs)
                pendingURLs = []
            }
            DebugLog.write("данные: на дне \(model.dayItems.count), не разобрано \(model.unresolved.count)")
            if model.options.labelMail { model.labelUnresolved(manual: true) }
            if let path = model.options.snapshotPath {
                model.applyDebugSelection()
                // Дать окну дорисоваться: тело письма и раскладка приходят асинхронно.
                try? await Task.sleep(for: .seconds(2.5))
                // Пересказ и разметка — ждём ответа Trunook, а не снимаем «читает…».
                if model.options.summary || model.options.labelMail {
                    let deadline = Date().addingTimeInterval(300)
                    while Date() < deadline {
                        let summaryBusy = model.options.summary
                            && model.selectedID.map { model.summaries[$0] == .loading } == true
                        var labelBusy = false
                        if case .running = model.labeling { labelBusy = true }
                        if !summaryBusy && !labelBusy { break }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    try? await Task.sleep(for: .seconds(0.5))
                }
                if let tab = model.options.settings {
                    SettingsWindow.show(model: model, tab: SettingsWindow.Tab(rawValue: tab.replacingOccurrences(of: "-bottom", with: "")) ?? .mail)
                    try? await Task.sleep(for: .seconds(1))
                }
                if let period = model.options.note {
                    await Self.prepareNoteWindow(model: model, period: period)
                }
                // Открытый лист (редактор встречи) — отдельное окно поверх главного.
                WindowSnapshot.write(NoteWindow.current ?? SettingsWindow.current ?? window.attachedSheet ?? window, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// Окно заметки для снимка: `--note day|week|month`, с повесткой
    /// (`--agenda`, `--agenda-offline`) или итогами (`--digest`) — ждём
    /// ответа Trunook, а не снимаем «готовит…».
    private static func prepareNoteWindow(model: AppModel, period: NotePeriod) async {
        if model.options.demo, period != .day { model.seedDemoNotes() }
        NoteWindow.show(model: model, period: period)
        try? await Task.sleep(for: .seconds(1))
        let state = NoteWindow.state
        if model.options.agenda || model.options.agendaOffline {
            state.assistant.agenda(model: model, day: model.day, session: state.session, offline: model.options.agendaOffline)
        } else if model.options.digest, period != .day {
            let title = NoteWindow.title(period, day: model.day, calendar: model.calendar)
            state.assistant.digest(model: model, period: period, date: model.day, title: title, session: state.session)
        }
        let deadline = Date().addingTimeInterval(300)
        while state.assistant.isWorking, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(0.8))
    }

    /// Ссылки `mailto:` и файлы `.ics` — когда Trudaybook почта или календарь
    /// по умолчанию. Приходят и при запуске ими, уже после `didFinishLaunching`.
    ///
    /// Запуск ради ссылки: macOS присылает её раньше `didFinishLaunching`,
    /// когда модели ещё нет, — такие ждут в очереди, иначе письмо по ссылке
    /// «написать» при закрытом Trudaybook терялось бы.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else {
            pendingURLs += urls
            return
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Главное меню. «Правка» обязательна: без неё в полях ввода не работают
/// ⌘C, ⌘V и ⌘A — AppKit раздаёт их через пункты меню.
@MainActor
enum MainMenu {
    static func build(model: AppModel) -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Trudaybook", [
            item(String(localized: "О программе Trudaybook"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            ClosureItem(String(localized: "Проверить обновления…"), key: "") { UpdateActions.checkFromMenu(model: model) },
            .separator(),
            ClosureItem(String(localized: "Настройки…"), key: ",") { SettingsWindow.show(model: model) },
            .separator(),
            item(String(localized: "Скрыть Trudaybook"), #selector(NSApplication.hide(_:)), key: "h"),
            item(String(localized: "Скрыть остальные"), #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]),
            .separator(),
            item(String(localized: "Завершить Trudaybook"), #selector(NSApplication.terminate(_:)), key: "q"),
        ]))

        main.addItem(submenu(String(localized: "Создать"), [
            ClosureItem(String(localized: "Новое письмо"), key: "n") { model.startNewMail() },
            ClosureItem(String(localized: "Новая встреча"), key: "n", modifiers: [.command, .shift]) { model.startNewEvent() },
            ClosureItem(String(localized: "Новое напоминание"), key: "n", modifiers: [.command, .option]) { model.startNewReminder() },
        ]))

        main.addItem(submenu(String(localized: "Правка"), [
            item(String(localized: "menu.undo", defaultValue: "Отменить"), Selector(("undo:")), key: "z"),
            item(String(localized: "Повторить"), Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item(String(localized: "Вырезать"), #selector(NSText.cut(_:)), key: "x"),
            item(String(localized: "Копировать"), #selector(NSText.copy(_:)), key: "c"),
            item(String(localized: "Вставить"), #selector(NSText.paste(_:)), key: "v"),
            item(String(localized: "Выделить всё"), #selector(NSText.selectAll(_:)), key: "a"),
        ]))

        // Заглавная буква в клавише — это ⇧: «Ответить всем» — ⇧⌘R.
        let actions: [NSMenuItem] = ItemAction.allCases.map { action in
            ClosureItem(action.title, key: String(action.key)) {
                if let id = model.selectedID { model.perform(action, on: id) }
            }
        }
        // Приоритет — ⌘1…⌘3, ⌘0 снимает (и просто 1…3, 0 — см. `KeyNavigation`).
        let priorityItems: [NSMenuItem] = [Priority.high, .medium, .low, .none].map { priority in
            ClosureItem(priority.title, key: priority.key) {
                if let id = model.selectedID { model.setPriority(priority, for: id) }
            }
        }
        main.addItem(submenu(String(localized: "Действия"), actions + [.separator(), submenu(String(localized: "Приоритет"), priorityItems),
            ClosureItem(String(localized: "Сортировать по приоритету"), key: "") { model.sortByPriority.toggle() }]))

        main.addItem(submenu(String(localized: "День"), [
            ClosureItem(String(localized: "Сегодня"), key: "t") { model.showToday() },
            ClosureItem(String(localized: "Предыдущий день"), key: "[") { model.shiftDay(-1) },
            ClosureItem(String(localized: "Следующий день"), key: "]") { model.shiftDay(1) },
            ClosureItem(String(localized: "Заметка в окне"), key: "j") { NoteWindow.show(model: model) },
            .separator(),
            ClosureItem(String(localized: "Крупнее"), key: "=") { model.zoom(by: 1.25) },
            ClosureItem(String(localized: "Мельче"), key: "-") { model.zoom(by: 0.8) },
            .separator(),
            ClosureItem(String(localized: "Номера недель"), key: "") { model.showWeekNumbers.toggle() },
            ClosureItem(String(localized: "Вертикальный таймлайн"), key: "l", modifiers: [.command, .option]) {
                withAnimation(HoverMotion.animation) { model.timelineVertical.toggle() }
            },
            ClosureItem(String(localized: "День"), key: "1", modifiers: [.command, .option]) { model.timelineSpan = .day },
            ClosureItem(String(localized: "Неделя"), key: "2", modifiers: [.command, .option]) {
                model.timelineVertical = false
                model.timelineSpan = .week
            },
        ]))

        let windowMenu = submenu(String(localized: "Окно"), [
            item(String(localized: "Свернуть"), #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item(String(localized: "Закрыть"), #selector(NSWindow.performClose(_:)), key: "w"),
        ])
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

/// Пункт меню с замыканием вместо селектора.
final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    @objc private func run() { handler() }
}

extension WindowSnapshot {
    /// `CGWindowListCreateImage` — через `dlsym`: в SDK 15+ функция помечена
    /// недоступной, но в системе есть и для своего окна работает.
    static func systemImage(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3 (imageOption)
        let image = capture(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
        guard let image, image.width > 10 else { return nil }
        return image
    }

    /// Кто получает щелчок в бывшей полосе заголовка: наше содержимое или
    /// сама полоса. Щелчок на кнопках действий должен доходить до них.
    static func logTitlebarHits(_ window: NSWindow?) {
        guard let window, let frame = window.contentView?.superview, let content = window.contentView else { return }
        let height = frame.bounds.height
        for (x, y) in [(20.0, 26.0), (130.0, 26.0), (130.0, 10.0), (700.0, 26.0), (1100.0, 20.0)] {
            let point = NSPoint(x: x, y: frame.isFlipped ? y : height - y)
            let hit = frame.hitTest(point)
            let inside = hit.map { $0.isDescendant(of: content) } ?? false
            DebugLog.write("щелчок (\(Int(x)), \(Int(y))): \(hit.map { String(describing: type(of: $0)) } ?? "—") содержимое=\(inside)")
        }
    }
}

/// Журнал для отладки: stderr и `~/Library/Logs/Trudaybook.log`.
///
/// Паролей и текста писем в нём нет, но есть адреса ящиков и ответы
/// серверов — поэтому файл только для владельца (0600), а больше 5 МБ он
/// уезжает в `Trudaybook.1.log` (прежний такой — удаляется).
enum DebugLog {
    static let maxSize = 5 * 1024 * 1024

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Trudaybook.log")
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            manager.createFile(atPath: url.path, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o600])
        }
        // Журнал мог остаться от прежних версий открытым на чтение всем.
        if !checkedPermissions {
            checkedPermissions = true
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    nonisolated(unsafe) private static var checkedPermissions = false
}

/// Снимок окна в PNG — чтобы вёрстку можно было проверить без человека.
///
/// Разрешения на запись экрана у приложения нет, но собственный слой оно
/// нарисовать может (тот же приём, что в Trunook). Содержимое веб-вида
/// в снимок не попадает: его рисует отдельный процесс.
@MainActor
enum WindowSnapshot {
    static func write(_ window: NSWindow?, to path: String) {
        logTitlebarHits(window)
        // Сначала — снимок окна системой: только он показывает стекло
        // (Liquid Glass рисует WindowServer, в слоях приложения его нет).
        // Своё окно система отдаёт без разрешения на запись экрана.
        if let window, let image = systemImage(of: window) {
            let rep = NSBitmapImageRep(cgImage: image)
            if (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil {
                DebugLog.write("снимок: записан системой \(path)")
                return
            }
        }
        guard let window, let view = window.contentView, let layer = view.layer else {
            DebugLog.write("снимок: окно не открыто или без слоя")
            return
        }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        // Фон окна: слой содержимого сам по себе прозрачный.
        context.setFillColor(window.backgroundColor.usingColorSpace(.sRGB)?.cgColor ?? .white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if view.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.scaleBy(x: scale, y: scale)
        }
        layer.render(in: context)

        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            DebugLog.write("снимок: записан \(path)")
        } catch {
            DebugLog.write("снимок: не записан — \(error.localizedDescription)")
        }
    }
}
