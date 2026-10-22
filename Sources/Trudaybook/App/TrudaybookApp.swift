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
    private var menuBar: MenuBarCalendar?
    private var hotKey: MeetingHotKey?
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
        // AppKit дописывает свои пункты при первом показе меню — проверять после.
        DispatchQueue.main.async { ShortcutsWindow.logDuplicates() }

        let window = MainWindow(
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
        // Нажатие в неактивном окне — сразу и нажатие: письмо или встречу из
        // фонового окна иначе удавалось выбрать или утащить только со второго раза.
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model).allowsWindowActivationEvents(true))
        window.center()
        window.setFrameAutosaveName("TrudaybookMain")
        if let size = model.options.windowSize { window.setContentSize(size) }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        EventEditorWindow.attach(model: model) { [weak self] in self?.window }
        // Значок в строке меню — у настоящего приложения; в тестовом режиме
        // только для снимка (`--menubar`), чтобы копии не плодили значков.
        if !model.options.demo || model.options.menubar { menuBar = MenuBarCalendar(model: model) }
        // ⌘Z в главном окне — архив, корзина, перенос (`AppModel.undo`).
        UndoMenuTarget.shared.history = { [weak self, weak model] window in
            window === self?.window ? model?.undo : nil
        }
        // ⌘F в главном окне вне текста — в поиск по почте.
        FindMenuTarget.shared.focusSearch = { [weak self, weak model] window in
            guard window === self?.window, let model else { return false }
            model.focusSearch()
            return true
        }
        // Сочетание для всей системы — только у настоящего приложения: копия
        // для снимков перехватила бы его у установленного.
        if !model.options.demo {
            let hotKey = MeetingHotKey(model: model) { [weak self] in
                self?.menuBar?.show()
            }
            self.hotKey = hotKey
            MainMenu.joinMeeting = { hotKey.join() }
        }
        // Стрелки — к соседнему письму (см. `KeyNavigation`). Монитор зовётся
        // на главном потоке; событие дальше него не уходит.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let model = self.model else { return false }
                // В окне обучения — его тестовые данные.
                if let tour = TourWindow.active, incoming.window === tour.window {
                    return KeyNavigation.handle(incoming, window: tour.window, model: tour.model)
                }
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
            if let path = model.options.openFile { model.open(urls: [URL(fileURLWithPath: path)]) }
            // Обучение — при первом запуске; пропустить можно, повторить — из настроек.
            if !model.options.demo, !UserDefaults.standard.bool(forKey: TourWindow.shownKey) {
                TourWindow.show(main: model)
            }
            DebugLog.write("данные: на дне \(model.dayItems.count), не разобрано \(model.unresolved.count)")
            if model.options.labelMail { model.labelUnresolved(manual: true) }
            if model.options.dragProbe != nil || model.options.clickProbe != nil || model.options.keyProbe != nil, model.options.snapshotPath == nil { model.applyDebugSelection() }
            if model.options.assistant { model.assistantOpen = true }
            if model.options.phone { model.phoneOpen = true }
            if model.options.phoneCall { model.phone.simulateActive() }
            if model.options.incomingCall { model.phone.simulateIncoming() }
            if let question = model.options.ask { model.assistant.send(question) }
            if let path = model.options.snapshotPath {
                model.applyDebugSelection()
                // Дать окну дорисоваться: тело письма и раскладка приходят асинхронно.
                try? await Task.sleep(for: .seconds(2.5))
                // Пересказ и разметка — ждём ответа Trunook, а не снимаем «читает…».
                if model.options.summary || model.options.labelMail || model.options.ask != nil || model.options.tile != nil {
                    let deadline = Date().addingTimeInterval(300)
                    while Date() < deadline {
                        let summaryBusy = model.options.summary
                            && model.selectedID.map { model.summaries[$0] == .loading } == true
                        var labelBusy = false
                        if case .running = model.labeling { labelBusy = true }
                        if !summaryBusy && !labelBusy && !model.assistant.busy { break }
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
                if model.options.letter, let item = model.selectedItem {
                    LetterWindow.show(item, model: model)
                    try? await Task.sleep(for: .seconds(1.5))
                }
                if model.options.composeWindow {
                    let letter = Demo.assistantLetter
                    ComposeWindow.show(model.newDraft(to: letter.to, subject: letter.subject, text: letter.text), model: model)
                    try? await Task.sleep(for: .seconds(1.5))
                }
                if let step = model.options.tourStep {
                    TourWindow.show(main: model, step: step)
                    try? await Task.sleep(for: .seconds(3))
                }
                if model.options.shortcuts {
                    ShortcutsWindow.show()
                    try? await Task.sleep(for: .seconds(1))
                }
                if model.options.menubar {
                    menuBar?.show()
                    try? await Task.sleep(for: .seconds(1.5))
                }
                // Редактор встречи — отдельное окно поверх главного.
                WindowSnapshot.write(IncomingCallWindow.current ?? menuBar?.popoverWindow ?? EventEditorWindow.current ?? TourWindow.current
                                     ?? LetterWindow.current ?? ComposeWindow.current ?? NoteWindow.current ?? SettingsWindow.current
                                     ?? ShortcutsWindow.current
                                     ?? window, to: path)
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

    /// Главное окно ⌘W прячет (`MainWindow`), и последнее закрытое окно
    /// письма не должно выключать почту и напоминания.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Щелчок по значку в Dock — вернуть спрятанное главное окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Архив и корзина ждут секунды отмены; выходят раньше — сначала
    /// отправить их на сервер, иначе письма вернулись бы во Входящие.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasPendingServer else { return .terminateNow }
        // Сервер не отвечает — не держать выход дольше нескольких секунд.
        var replied = false
        let finish = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            await model.flushServer()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.phone.shutdown()
    }
}

/// Главное меню. «Правка» обязательна: без неё в полях ввода не работают
/// ⌘C, ⌘V и ⌘A — AppKit раздаёт их через пункты меню.
@MainActor
enum MainMenu {
    /// Подключение к ближайшей встрече — у настоящего приложения.
    static var joinMeeting: (() -> Void)?

    static func build(model primary: AppModel) -> NSMenu {
        // Пока впереди окно обучения — команды относятся к его тестовым данным.
        var model: AppModel { TourWindow.keyModel ?? primary }
        let main = NSMenu()

        main.addItem(submenu("Trudaybook", [
            item(String(localized: "О программе Trudaybook"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            ClosureItem(String(localized: "Проверить обновления…"), key: "") { UpdateActions.checkFromMenu(model: primary) },
            .separator(),
            ClosureItem(String(localized: "Настройки…"), key: ",") { SettingsWindow.show(model: primary) },
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
            .separator(),
            ClosureItem(String(localized: "Открыть файл…"), key: "o", modifiers: [.command, .shift]) { LetterWindow.chooseFile(model: model) },
        ]))

        main.addItem(submenu(String(localized: "Правка"), [
            UndoMenuTarget.item(redo: false),
            UndoMenuTarget.item(redo: true),
            .separator(),
            item(String(localized: "Вырезать"), #selector(NSText.cut(_:)), key: "x"),
            item(String(localized: "Копировать"), #selector(NSText.copy(_:)), key: "c"),
            item(String(localized: "Вставить"), #selector(NSText.paste(_:)), key: "v"),
            // Текст из чужого письма или страницы — в оформление того места,
            // куда вставляют: шрифт, цвет и размер письма не рассыпаются.
            item(String(localized: "Вставить без оформления"), #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .shift]),
            item(String(localized: "Выделить всё"), #selector(NSText.selectAll(_:)), key: "a"),
            .separator(),
            submenu(String(localized: "Найти"), FindMenuTarget.items()),
        ]))

        // Заглавная буква в клавише — это ⇧: «Ответить всем» — ⇧⌘R.
        let actions: [NSMenuItem] = ItemAction.allCases.map { action in
            ClosureItem(action.title, key: String(action.key), enabled: {
                // Открыт ответ — письмо под ним не трогать: архив закрыл бы ответ.
                guard !typing, model.draft == nil else { return false }
                if !model.multiSelection.isEmpty {
                    return action == .archive && model.selectionItems.contains { model.availability(of: .archive, for: $0).isEnabled }
                }
                return model.selectedItem.map { model.availability(of: action, for: $0).isEnabled } ?? false
            }) {
                // Выделено несколько — пачкой только архив; остальное — про одно письмо.
                if !model.multiSelection.isEmpty {
                    if action == .archive { model.archiveSelection() }
                } else if let id = model.selectedID {
                    model.perform(action, on: id)
                }
            }
        }
        // Приоритет — ⌘1…⌘3, ⌘0 снимает (и просто 1…3, 0 — см. `KeyNavigation`).
        let priorityItems: [NSMenuItem] = [Priority.high, .medium, .low, .none].map { priority in
            ClosureItem(priority.title, key: priority.key,
                        enabled: { !typing && model.draft == nil && model.selectedItem != nil },
                        on: { model.selectedItem.map { model.priority(of: $0) == priority } ?? false }) {
                if let id = model.selectedID { model.setPriority(priority, for: id) }
            }
        }
        // Письмо в окне и файлом: ⌘S в окне письма сохраняет его, в главном — выбранное.
        let letterItems: [NSMenuItem] = [
            // Из окна письма — его, из главного — выбранное.
            ClosureItem(String(localized: "Переслать"), key: "f", modifiers: [.command, .shift],
                        enabled: { LetterWindow.key != nil || model.selectedLetter != nil }) {
                if let document = LetterWindow.key {
                    model.startForward(fromWindow: document.item, body: document.body)
                    LetterWindow.showMainWindow()
                } else if let item = model.selectedLetter {
                    model.startForward(of: item)
                }
            },
            ClosureItem(String(localized: "Напечатать письмо…"), key: "p",
                        enabled: { LetterWindow.key != nil || model.selectedItem?.kind == .mail }) { LetterPrint.run() },
            ClosureItem(String(localized: "Открыть письмо в окне"), key: "o",
                        enabled: { model.selectedItem?.kind == .mail }) {
                if let item = model.selectedItem, item.kind == .mail { LetterWindow.show(item, model: model) }
            },
            // ⌘S занят «Отложить» — сохранение, как «Сохранить как…», с ⇧.
            ClosureItem(String(localized: "Сохранить письмо…"), key: "s", modifiers: [.command, .shift],
                        enabled: { LetterWindow.key?.body != nil || (model.selectedItem?.kind == .mail && model.body != nil) }) {
                if let document = LetterWindow.key, let body = document.body {
                    LetterFileButton.save(document.item, body, raw: document.raw)
                } else if let item = model.selectedItem, item.kind == .mail, let body = model.body {
                    LetterFileButton.save(item, body)
                }
            },
            // Клавиша — ⌫ в списке (`KeyNavigation`): в меню ⌘⌫ отнимал бы
            // у полей ввода «стереть до начала строки».
            ClosureItem(String(localized: "В корзину  ⌫"), key: "", enabled: { !model.trashTargets.isEmpty }) {
                model.trash(model.trashTargets)
            },
        ]
        main.addItem(submenu(String(localized: "Действия"), actions + [.separator()] + letterItems + [.separator(), submenu(String(localized: "Приоритет"), priorityItems),
            ClosureItem(String(localized: "Сортировать по приоритету"), key: "", on: { model.sortByPriority }) { model.sortByPriority.toggle() }]))

        main.addItem(submenu(String(localized: "День"), [
            ClosureItem(String(localized: "Сегодня"), key: "t") { model.showToday() },
            ClosureItem(String(localized: "Предыдущий день"), key: "[") { model.shiftDay(-1) },
            ClosureItem(String(localized: "Следующий день"), key: "]") { model.shiftDay(1) },
            ClosureItem(String(localized: "Заметка в окне"), key: "j") { NoteWindow.show(model: model) },
            // Работает и из других программ (`MeetingHotKey`); здесь — чтобы его было видно.
            ClosureItem(String(localized: "Подключиться к ближайшей встрече"), key: MeetingHotKey.menuKey,
                        modifiers: MeetingHotKey.menuModifiers) { joinMeeting?() },
            .separator(),
            ClosureItem(String(localized: "Крупнее"), key: "=") { model.zoom(by: 1.25) },
            ClosureItem(String(localized: "Мельче"), key: "-") { model.zoom(by: 0.8) },
            .separator(),
            ClosureItem(String(localized: "Номера недель"), key: "", on: { model.showWeekNumbers }) { model.showWeekNumbers.toggle() },
            ClosureItem(String(localized: "Скрывать разобранные письма"), key: "h", modifiers: [.command, .shift],
                        on: { model.hideResolvedMail }) {
                withAnimation(HoverMotion.animation) { model.hideResolvedMail.toggle() }
            },
            ClosureItem(String(localized: "Чат с ИИ-ассистентом"), key: "a", modifiers: [.command, .option],
                        on: { model.assistantOpen }) {
                withAnimation(Motion.move) { model.assistantOpen.toggle() }
            },
            ClosureItem(String(localized: "Телефон"), key: "p", modifiers: [.command, .option],
                        on: { model.phoneOpen }) {
                withAnimation(Motion.quick) { model.phoneOpen.toggle() }
            },
            ClosureItem(String(localized: "Таймлайн внизу окна"), key: "b", modifiers: [.command, .option],
                        on: { model.timelineAtBottom }) {
                withAnimation(HoverMotion.animation) { model.timelineAtBottom.toggle() }
            },
            ClosureItem(String(localized: "День"), key: "1", modifiers: [.command, .option],
                        on: { model.timelineSpan == .day }) { model.timelineSpan = .day },
            ClosureItem(String(localized: "Неделя"), key: "2", modifiers: [.command, .option],
                        on: { model.timelineSpan == .week }) { model.timelineSpan = .week },
        ]))

        let windowMenu = submenu(String(localized: "Окно"), [
            item(String(localized: "Свернуть"), #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item(String(localized: "Масштаб"), #selector(NSWindow.performZoom(_:))),
            item(String(localized: "Во весь экран"), #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]),
            item(String(localized: "Закрыть"), #selector(NSWindow.performClose(_:)), key: "w"),
            .separator(),
            // Спрятанное ⌘W главное окно — обратно. Список окон AppKit
            // дописывает сам, но спрятанного в нём не видно.
            ClosureItem(String(localized: "Главное окно"), key: "") {
                NSApp.windows.first { $0 is MainWindow }?.makeKeyAndOrderFront(nil)
            },
            .separator(),
            item(String(localized: "Все окна — на передний план"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)

        let helpMenu = submenu(String(localized: "Справка"), [
            ClosureItem(String(localized: "Обучение Trudaybook"), key: "") { TourWindow.show(main: primary) },
            ClosureItem(String(localized: "Сочетания клавиш"), key: "/") { ShortcutsWindow.show() },
        ])
        NSApp.helpMenu = helpMenu.submenu
        main.addItem(helpMenu)
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
        let (key, modifiers) = keyEquivalent(key, modifiers)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    /// ⇧ с буквой — заглавной буквой (`KeyCombo`): строчная с маской ⇧
    /// до пункта не доходила, ⇧⌘N, ⇧⌘F, ⇧⌘H молча не работали.
    nonisolated static func keyEquivalent(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> (String, NSEvent.ModifierFlags) {
        let combo = KeyCombo(key, KeyCombo.Modifiers(modifiers))
        var flags = modifiers
        if !combo.modifiers.contains(.shift) { flags.remove(.shift) }
        return (combo.key, flags)
    }

    /// Фокус в поле ввода: буквенные сочетания действий — его, а не списка.
    static var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }
}

/// «Отменить» и «Повторить». В поле ввода — его правка, иначе — история
/// окна: в главном это архив, корзина, перенос (`AppModel.undo`).
///
/// Через свою цель, а не по цепочке ответчиков: после щелчка по списку
/// фокус у служебного ответчика SwiftUI, он не отдаёт историю окна,
/// и ⌘Z молча ничего не делал.
@MainActor
final class UndoMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = UndoMenuTarget()
    /// История окна, если она не своя у окна: главное — `AppModel.undo`.
    var history: (NSWindow) -> UndoManager? = { _ in nil }

    static func item(redo: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: redo ? String(localized: "Повторить") : String(localized: "menu.undo", defaultValue: "Отменить"),
                              action: redo ? #selector(redo(_:)) : #selector(undo(_:)), keyEquivalent: redo ? "Z" : "z")
        // ⇧ — заглавной буквой, как в стандартном меню AppKit: «z» с маской ⇧
        // меню показывало, но нажатие ⇧⌘Z до пункта не доходило.
        item.keyEquivalentModifierMask = .command
        item.target = shared
        return item
    }

    /// Поле ввода в фокусе (и поле поиска, и ответ) — оно и отменяет.
    private var text: NSResponder? {
        guard let responder = NSApp.keyWindow?.firstResponder, responder is NSText else { return nil }
        return responder
    }

    private var manager: UndoManager? {
        if let text { return text.undoManager }
        guard let window = NSApp.keyWindow else { return nil }
        return history(window) ?? window.undoManager
    }

    @objc func undo(_ sender: Any?) { run(redo: false, sender) }
    @objc func redo(_ sender: Any?) { run(redo: true, sender) }

    private func run(redo: Bool, _ sender: Any?) {
        // Поле — своим путём: `NSTextView` сам закрывает набор и группу.
        if let text {
            NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: text, from: sender)
            return
        }
        guard let manager else { return }
        Self.perform(redo: redo, on: manager)
    }

    /// Группа шагов закрывается в конце прохода цикла событий; пока она
    /// открыта, `undo()` бросает исключение — тогда на следующем проходе.
    static func perform(redo: Bool, on manager: UndoManager) {
        guard manager.groupingLevel == 0 else {
            DispatchQueue.main.async { perform(redo: redo, on: manager) }
            return
        }
        if redo {
            if manager.canRedo { manager.redo() }
        } else if manager.canUndo {
            manager.undo()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let redo = item.action == #selector(redo(_:))
        guard let manager else {
            item.title = redo ? String(localized: "Повторить") : String(localized: "menu.undo", defaultValue: "Отменить")
            return false
        }
        item.title = redo ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
        return redo ? manager.canRedo : manager.canUndo
    }
}

/// Пункт меню с замыканием вместо селектора.
///
/// `enabled` — можно ли сейчас: пункт сереет, и сочетание не срабатывает
/// (⌘E при наборе ответа не уносит письмо в архив). `on` — галочка
/// у переключателя.
final class ClosureItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    private let availability: (() -> Bool)?
    private let checked: (() -> Bool)?

    init(_ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command,
         enabled: (() -> Bool)? = nil, on: (() -> Bool)? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        self.availability = enabled
        self.checked = on
        let (key, modifiers) = MainMenu.keyEquivalent(key, modifiers)
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    @objc private func run() { handler() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let checked { state = checked() ? .on : .off }
        return availability?() ?? true
    }
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
        // Справа — шапка правой панели (у чата там свои кнопки).
        let right = frame.bounds.width
        for (x, y) in [(20.0, 26.0), (130.0, 26.0), (130.0, 10.0), (700.0, 26.0), (1100.0, 20.0),
                       (right - 40, 30.0), (right - 70, 30.0), (right - 40, height - 40),
                       (right - 200, 250.0), (right - 40, height / 2 - 30), (right - 200, height * 0.75)] {
            let point = NSPoint(x: x, y: frame.isFlipped ? y : height - y)
            let hit = frame.hitTest(point)
            let inside = hit.map { $0.isDescendant(of: content) } ?? false
            let place = hit.map { frame.convert($0.bounds, from: $0) }.map { " \(Int($0.minX)),\(Int(frame.isFlipped ? $0.minY : height - $0.maxY)) \(Int($0.width))×\(Int($0.height))" } ?? ""
            DebugLog.write("щелчок (\(Int(x)), \(Int(y))): \(hit.map { String(describing: type(of: $0)) } ?? "—")\(place) содержимое=\(inside)")
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

extension KeyCombo.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

extension KeyCombo {
    /// Сочетание пункта меню; `nil` — у пункта его нет.
    init?(_ item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        self.init(item.keyEquivalent, Modifiers(item.keyEquivalentModifierMask))
    }
}
