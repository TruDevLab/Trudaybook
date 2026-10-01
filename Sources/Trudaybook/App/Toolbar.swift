import SwiftUI
import TrudaybookCore

/// Кнопка верхней панели. Какие показывать и в каком порядке — в настройках
/// («Оформление → Кнопки панели»); «Создать» стоит отдельно, справа.
enum ToolbarButton: String, CaseIterable, Identifiable {
    // Действия над выбранным — на них же бросают письмо перетаскиванием.
    case archive, reply, replyAll, reschedule, decline
    // Остальное — только нажатием.
    case meeting, openWindow, saveLetter, trash, priority, today, note

    var id: String { rawValue }

    /// Действие над элементом: у таких кнопок есть ещё и перетаскивание.
    var action: ItemAction? { ItemAction(rawValue: rawValue) }

    var title: String {
        if let action { return action.title }
        switch self {
        case .meeting: return String(localized: "Встреча по письму")
        case .openWindow: return String(localized: "В окне")
        case .saveLetter: return String(localized: "Сохранить письмо")
        case .trash: return String(localized: "В корзину")
        case .priority: return String(localized: "Приоритет")
        case .today: return String(localized: "Сегодня")
        case .note: return String(localized: "Заметка")
        default: return rawValue
        }
    }

    var symbol: String {
        if let action { return action.symbol }
        switch self {
        case .meeting: return "calendar.badge.plus"
        case .openWindow: return "arrow.up.left.and.arrow.down.right"
        case .saveLetter: return "square.and.arrow.down"
        case .trash: return "trash"
        case .priority: return "flag"
        case .today: return "calendar.circle"
        case .note: return "note.text"
        default: return "questionmark"
        }
    }

    /// Как было до настройки — пять действий над выбранным.
    static let defaults: [ToolbarButton] = [.archive, .reply, .replyAll, .reschedule, .decline]

    static let orderKey = "toolbarOrder"
    static let hiddenKey = "toolbarHidden"

    /// Порядок из настроек; кнопки, которых тогда ещё не было, — в конце.
    static func savedOrder() -> [ToolbarButton] {
        let saved = (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).compactMap(ToolbarButton.init(rawValue:))
        let base = saved.isEmpty ? defaults : saved
        return base + allCases.filter { !base.contains($0) }
    }

    /// Скрытые; по умолчанию — всё, чего не было в панели раньше.
    static func savedHidden() -> Set<ToolbarButton> {
        guard let saved = UserDefaults.standard.stringArray(forKey: hiddenKey) else {
            return Set(allCases.filter { !defaults.contains($0) })
        }
        return Set(saved.compactMap(ToolbarButton.init(rawValue:)))
    }
}

extension AppModel {
    /// Кнопки панели — видимые, в выбранном порядке.
    var toolbarButtons: [ToolbarButton] {
        toolbarOrder.filter { !toolbarHidden.contains($0) }
    }

    func isShown(_ button: ToolbarButton) -> Bool { !toolbarHidden.contains(button) }

    func setShown(_ button: ToolbarButton, _ shown: Bool) {
        if shown { toolbarHidden.remove(button) } else { toolbarHidden.insert(button) }
    }

    func moveToolbarButtons(from source: IndexSet, to destination: Int) {
        toolbarOrder.move(fromOffsets: source, toOffset: destination)
    }

    func resetToolbar() {
        toolbarOrder = ToolbarButton.defaults + ToolbarButton.allCases.filter { !ToolbarButton.defaults.contains($0) }
        toolbarHidden = Set(ToolbarButton.allCases.filter { !ToolbarButton.defaults.contains($0) })
    }

    /// Выбранное письмо — для кнопок «про письмо».
    var selectedLetter: TimelineItem? {
        guard multiSelection.isEmpty, let item = selectedItem, item.kind == .mail else { return nil }
        return item
    }
}

// MARK: - Кнопки

/// Кнопка панели, которая не действие над элементом: нажатие, без
/// перетаскивания. Неприменимая к выбранному — бледная, с причиной.
struct ToolbarExtraButton: View {
    @EnvironmentObject private var model: AppModel
    let button: ToolbarButton
    var compact = true
    @ViewState private var isHovered = false

    var body: some View {
        if button == .priority {
            priorityMenu
        } else {
            Button(action: perform) {
                HoverLabel(title: button.title, symbol: button.symbol, expanded: !compact || isHovered)
                    .modifier(GlassButtonSurface(hovered: isHovered))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { inside in withAnimation(HoverMotion.animation) { isHovered = inside } }
            .opacity(problem == nil ? 1 : 0.45)
            .help(problem ?? help)
        }
    }

    /// Приоритет — меню выбора у выбранного элемента.
    private var priorityMenu: some View {
        let current = model.selectedItem.map { model.priority(of: $0) } ?? .none
        return Menu {
            if let item = model.selectedItem, model.multiSelection.isEmpty {
                PriorityPicker(id: item.id, current: current)
            } else {
                Text("Сначала выберите письмо или событие")
            }
        } label: {
            HoverLabel(title: button.title, symbol: current == .none ? "flag" : current.symbol,
                       expanded: !compact || isHovered, tint: current == .none ? nil : current.color)
                .modifier(GlassButtonSurface(hovered: isHovered))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in withAnimation(HoverMotion.animation) { isHovered = inside } }
        .help(String(localized: "Приоритет выбранного: ⌘1 высокий, ⌘2 средний, ⌘3 низкий, ⌘0 снять"))
    }

    /// Почему кнопка сейчас ничего не сделает; `nil` — сделает.
    private var problem: String? {
        switch button {
        case .meeting, .openWindow:
            return model.selectedLetter == nil ? String(localized: "Сначала выберите письмо") : nil
        case .saveLetter:
            if model.selectedLetter == nil { return String(localized: "Сначала выберите письмо") }
            return model.body == nil ? String(localized: "Письмо ещё загружается") : nil
        case .trash:
            return model.trashTargets.isEmpty ? String(localized: "Сначала выберите письмо") : nil
        default:
            return nil
        }
    }

    private var help: String {
        switch button {
        case .meeting: String(localized: "Назначить встречу с участниками выбранного письма")
        case .openWindow: String(localized: "Открыть выбранное письмо в отдельном окне · ⌘O")
        case .saveLetter: String(localized: "Сохранить выбранное письмо файлом · ⇧⌘S")
        case .trash: String(localized: "Выбранные письма — в «Корзину» ящика · ⌫")
        case .today: String(localized: "К сегодняшнему дню · ⌘T")
        case .note: String(localized: "Заметка дня в окне · ⌘J")
        default: button.title
        }
    }

    private func perform() {
        guard problem == nil else { return }
        switch button {
        case .meeting: if let item = model.selectedLetter { model.startMeeting(with: item) }
        case .openWindow: if let item = model.selectedLetter { LetterWindow.show(item, model: model) }
        case .saveLetter:
            if let item = model.selectedLetter, let body = model.body { LetterFileButton.save(item, body) }
        case .trash: model.trash(model.trashTargets)
        case .today: model.showToday()
        case .note: NoteWindow.show(model: model)
        default: break
        }
    }
}

/// «Создать» — главная кнопка панели: справа, с подписью и в цвете акцента.
///
/// Нажатие — меню (письмо, встреча, напоминание). Кнопку можно утащить на
/// таймлайн: на дорожку писем — новое письмо, на дорожку встреч — встреча
/// с того времени, где отпустили. Вернули на место — ничего не создаётся.
/// Не `Menu` и не `Button`: у них мышь уходит в нажатие, и потащить нельзя.
struct CreateButton: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var isHovered = false
    /// Кнопку несут обратно — отпустить здесь значит передумать.
    @ViewState private var returning = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: returning ? "xmark" : "plus")
            Text(returning ? String(localized: "Отмена") : String(localized: "Создать")).lineLimit(1).fixedSize()
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .modifier(ProminentSurface(hovered: isHovered, returning: returning))
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(HoverMotion.animation) { isHovered = inside }
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture(perform: showMenu)
        .draggable(AppModel.newItemURL) { NewItemDragPreview() }
        // Место возврата — чуть шире самой кнопки, чтобы попасть было легко.
        .background(
            Color.clear
                .frame(width: 140, height: 44)
                .contentShape(Rectangle())
                .onDrop(of: [.url], isTargeted: $returning) { _ in true }
        )
        .animation(.easeOut(duration: 0.15), value: returning)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(String(localized: "Создать"))
        .help(returning ? String(localized: "Отпустите здесь — ничего не создастся")
                        : String(localized: "Нажмите — письмо, встреча или напоминание. Или потяните на таймлайн: на почту — новое письмо, на встречи — встреча с того времени, где отпустите"))
    }

    /// Меню под курсором — как у обычной кнопки-меню.
    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureItem(String(localized: "Письмо"), key: "n") { model.startNewMail() })
        menu.addItem(ClosureItem(String(localized: "Встреча"), key: "n", modifiers: [.command, .shift]) { model.startNewEvent() })
        menu.addItem(ClosureItem(String(localized: "Напоминание"), key: "n", modifiers: [.command, .option]) { model.startNewReminder() })
        menu.addItem(.separator())
        menu.addItem(ClosureItem(String(localized: "Открыть файл…"), key: "o", modifiers: [.command, .shift]) {
            LetterWindow.chooseFile(model: model)
        })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Стекло в цвете акцента (на старых системах — заливка).
private struct ProminentSurface: ViewModifier {
    var hovered: Bool
    /// Несут обратно — красная: «отпустите, и ничего не будет».
    var returning = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let tint = returning ? Color.red : Color.accentColor
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint.opacity(hovered || returning ? 1 : 0.85)).interactive(), in: shape)
        } else {
            content.background(shape.fill(tint.opacity(hovered || returning ? 1 : 0.9)))
        }
    }
}

// MARK: - Настройки

/// «Кнопки панели»: какие показывать и в каком порядке.
struct ToolbarSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Свёрнута: настраивают её редко, а список длинный.
        CollapsibleSettingsCard(title: String(localized: "Кнопки панели"), icon: "rectangle.topthird.inset.filled",
                                summary: String(localized: "видно: \(model.toolbarButtons.count) из \(model.toolbarOrder.count)")) {
            List {
                ForEach(model.toolbarOrder) { button in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Toggle(isOn: Binding(get: { model.isShown(button) }, set: { model.setShown(button, $0) })) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        Image(systemName: button.symbol).foregroundStyle(.secondary).frame(width: 18)
                        Text(button.title)
                        Spacer()
                        if button.action != nil {
                            Text("можно бросить письмо").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onMove(perform: model.moveToolbarButtons)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: CGFloat(model.toolbarOrder.count) * 30 + 8)
            HStack {
                SettingsHint(String(localized: "Галочка — кнопка в панели над таймлайном; перетащите строку, чтобы поменять порядок. «Создать» всегда справа."))
                Button("Как было") { model.resetToolbar() }
                    .controlSize(.small)
            }
        }
    }
}
