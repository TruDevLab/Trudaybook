import AppKit
import SwiftUI
import TrudaybookCore

/// «Справка → Сочетания клавиш» (⌘/).
///
/// Меню — из самого меню: список не разойдётся с тем, что на деле работает.
/// Ниже — клавиши, которых в меню нет: список, ответ, чат.
@MainActor
enum ShortcutsWindow {
    private static var window: NSWindow?

    struct Row: Identifiable {
        let id = UUID()
        let keys: String
        let title: String
    }

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let rows: [Row]
    }

    static func show() {
        let hosting = NSHostingController(rootView: ShortcutsView(sections: menuSections() + extraSections))
        // Размер окна — свой, а не наименьший у SwiftUI: иначе названия переносятся.
        hosting.sizingOptions = []
        if let window {
            window.contentViewController = hosting
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = String(localized: "Сочетания клавиш")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Открытое окно — для отладочного снимка.
    static var current: NSWindow? { window?.isVisible == true ? window : nil }

    /// Пункты меню с сочетаниями, по меню. Системные (диктовка, эмодзи)
    /// и скрытые запасные пункты — не наши, их не показываем.
    static func menuSections() -> [Section] {
        (NSApp.mainMenu?.items ?? []).compactMap { holder in
            guard let menu = holder.submenu else { return nil }
            let rows = items(in: menu).compactMap { item -> Row? in
                guard let combo = KeyCombo(item) else { return nil }
                return Row(keys: combo.display, title: item.title)
            }
            return rows.isEmpty ? nil : Section(title: menu.title, rows: rows)
        }
    }

    /// Пункты меню вместе с вложенными (приоритет, «Найти»).
    static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu { return items(in: submenu) }
            guard !item.isSeparatorItem, !item.isAlternate, !item.isHidden,
                  !item.keyEquivalentModifierMask.contains(.function), item.keyEquivalent != " " else { return [] }
            return [item]
        }
    }

    /// Клавиши без пункта в меню — где они работают.
    static var extraSections: [Section] {
        [
            Section(title: String(localized: "Список и таймлайн"), rows: [
                Row(keys: "↑ ↓", title: String(localized: "Соседнее письмо или событие")),
                Row(keys: "⇧↑ ⇧↓", title: String(localized: "Выделить несколько")),
                Row(keys: "↩", title: String(localized: "Открыть письмо в окне")),
                Row(keys: "Esc", title: String(localized: "Снять выбор — к сводке дня")),
                Row(keys: "⌫  ⌘⌫", title: String(localized: "В «Корзину»")),
                Row(keys: "1 2 3 0", title: String(localized: "Приоритет: высокий, средний, низкий, без")),
            ]),
            Section(title: String(localized: "Ответ и заметка"), rows: [
                Row(keys: "⌘↩", title: String(localized: "Отправить")),
                Row(keys: "Esc", title: String(localized: "Отмена")),
                Row(keys: "⌘B ⌘I ⌘U", title: String(localized: "Жирный, курсив, подчёркнутый")),
            ]),
            Section(title: String(localized: "Чат с ассистентом"), rows: [
                Row(keys: "⌘↩", title: String(localized: "Отправить вопрос")),
                Row(keys: "⌘K", title: String(localized: "Новый разговор")),
                Row(keys: "⌘.", title: String(localized: "Остановить ответ")),
            ]),
        ]
    }

    /// Сочетания, которые ловят не меню, а кнопки в окне: с меню они
    /// не должны совпадать.
    static let windowCombos: [(combo: KeyCombo, title: String)] = [
        (KeyCombo("\r"), String(localized: "Отправить")),
        (KeyCombo("k"), String(localized: "Новый разговор")),
        (KeyCombo("."), String(localized: "Остановить ответ")),
        (KeyCombo("b"), String(localized: "Жирный")),
        (KeyCombo("i"), String(localized: "Курсив")),
        (KeyCombo("u"), String(localized: "Подчёркнутый")),
    ]

    /// В журнал при запуске: занято ли какое-то сочетание дважды.
    static func logDuplicates() {
        let menu = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(items(in:))
            .compactMap { item in KeyCombo(item).map { (combo: $0, title: item.title) } }
        let duplicates = KeyCombo.duplicates(menu + windowCombos)
        if duplicates.isEmpty {
            DebugLog.write("сочетания: \(menu.count) в меню, повторов нет")
        } else {
            for (combo, titles) in duplicates {
                DebugLog.write("сочетания: \(combo.display) занято дважды — \(titles.joined(separator: ", "))")
            }
        }
    }
}

private struct ShortcutsView: View {
    let sections: [ShortcutsWindow.Section]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                      alignment: .leading, spacing: Space.section) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(section.title).font(.headline)
                        ForEach(section.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                                Text(row.keys)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 72, alignment: .trailing)
                                Text(row.title)
                                Spacer(minLength: 0)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(Space.page)
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}
