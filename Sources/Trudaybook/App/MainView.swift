import SwiftUI
import TrudaybookCore
import TrudaybookMail

/// Окно по макету: слева панель действий, таймлайн и нижняя полоса
/// («Не разобрано» + месяц), справа — выбранное письмо или событие.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    /// Ширина правой панели. Запоминается: растянули — так и останется.
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = MainView.defaultInspectorWidth
    /// Насколько таймлайн выше обычного — тянется ручкой под ним.
    @AppStorage("timelineExtra") private var timelineExtra: Double = 0
    /// Ширина вертикального таймлайна — тянется ручкой справа от него.
    @AppStorage("verticalTimelineWidth") private var verticalWidth: Double = 440

    static let defaultInspectorWidth: Double = 640
    static let minInspectorWidth: Double = 380
    /// Таймлайну и нижнему ряду («Не разобрано» + месяц) нужно не меньше.
    static let minTimelineWidth: Double = 900
    /// Промежуток между панелями и от панелей до края окна — везде один.
    static let gap: Double = 8
    /// Панель действий — вровень с кнопками окна: заголовок высотой 52,
    /// кнопки по его центру (26), значит панель при отступе 8 — высотой 36.
    static let barHeight: Double = 36
    /// Слева в панели действий — место для кнопок окна (закрыть, свернуть, во весь экран).
    static let windowButtonsWidth: Double = 70

    var body: some View {
        GeometryReader { geometry in
            // Правой панели — сколько просили, но таймлайну оставить его минимум.
            let limit = max(Self.minInspectorWidth, geometry.size.width - Self.minTimelineWidth - Self.gap)
            let width = min(max(inspectorWidth, Self.minInspectorWidth), limit)
            HStack(spacing: 0) {
                // Ширина колонки — ровно остаток окна: содержимое (вкладки
                // папок, строка состояния) не может её раздвинуть и сдвинуть
                // панели, даже если после загрузки писем стало шире.
                let columnWidth = max(0, geometry.size.width - width - Self.gap)
                timelineColumn(height: geometry.size.height, width: columnWidth)
                    .frame(width: columnWidth)
                PanelDivider(width: $inspectorWidth, current: width, range: Self.minInspectorWidth...limit)
                // Правая панель — такая же карточка, как остальные: те же
                // скругления и те же промежутки до соседей и до края окна.
                InspectorView()
                    .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
                    .frame(width: width - Self.gap)
                    .frame(maxHeight: .infinity)
                    .padding([.top, .trailing, .bottom], Self.gap)
            }
        }
        // Место заголовка окна — тоже наше (см. `applicationDidFinishLaunching`).
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: Self.minTimelineWidth + Self.minInspectorWidth + Self.gap)
        // Свой фон (цвет, градиент, картинка, сияние) и под него — светлое
        // или тёмное окно.
        .background {
            AppBackgroundView()
                .background(WindowAppearanceSetter(appearance: model.windowAppearance))
        }
        .environment(\.auroraTheme, model.customBackground)
        .sheet(item: $model.rescheduleTarget) { item in
            RescheduleSheet(item: item)
        }
        .confirmationDialog(model.declineTarget.map { model.declineDescription($0).title } ?? "",
                            isPresented: Binding(get: { model.declineTarget != nil },
                                                 set: { if !$0 { model.declineTarget = nil } }),
                            presenting: model.declineTarget) { item in
            Button(model.declineDescription(item).button, role: .destructive) { model.confirmDecline(item) }
        } message: { item in
            Text(model.declineDescription(item).message)
        }
        .sheet(item: $model.eventEditor) { request in
            EventEditorSheet(request: request).environmentObject(model)
        }
        .alert("Не получилось", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Нижнему ряду (список, месяц, заметка) нужно не меньше — иначе
    /// календарь месяца обрезается.
    static let minBottomHeight: Double = 300
    /// Строка дня над таймлайном.
    static let dayHeaderHeight: Double = 30

    /// Сколько можно прибавить таймлайну при этой высоте окна.
    private func maxTimelineExtra(_ height: Double) -> Double {
        let fixed = Self.gap * 5 + Self.barHeight + Self.dayHeaderHeight
            + Double(TimelineMetrics.standard.panelHeight) + Self.minBottomHeight
        return max(0, height - fixed)
    }

    /// Левая часть: действия, день, таймлайн, «Не разобрано», месяц и заметка.
    @ViewBuilder
    private func timelineColumn(height: Double, width: Double) -> some View {
        if model.timelineVertical {
            verticalColumn(width: width)
        } else {
            horizontalColumn(height: height)
        }
    }

    /// Вертикальный таймлайн колонкой слева, справа — список писем,
    /// под ним месяц и заметка.
    private func verticalColumn(width: Double) -> some View {
        // Справе нужно место под месяц (290) и хоть сколько-то под заметку.
        let range = 360.0...max(360, width - Self.gap * 2 - 290 - 140 - Self.gap)
        let timelineWidth = min(max(verticalWidth, range.lowerBound), range.upperBound)
        return VStack(spacing: Self.gap) {
            ActionBar()
            DayHeader()
                .frame(height: Self.dayHeaderHeight)
            HStack(spacing: 0) {
                VerticalTimelineView()
                    .frame(width: timelineWidth)
                PanelDivider(width: $verticalWidth, current: timelineWidth, range: range, grows: .right,
                             defaultWidth: 440)
                VStack(spacing: Self.gap) {
                    MailListPanel()
                    HStack(alignment: .top, spacing: Self.gap) {
                        MonthCalendarView()
                            .frame(width: model.showWeekNumbers ? 290 : 270)
                        DayNotePanel()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding([.leading, .top, .bottom], Self.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func horizontalColumn(height: Double) -> some View {
        let limit = maxTimelineExtra(height)
        let metrics = TimelineMetrics(extra: CGFloat(min(timelineExtra, limit)))
        return VStack(spacing: Self.gap) {
            ActionBar()
            DayHeader()
                .frame(height: Self.dayHeaderHeight)
            VStack(spacing: 0) {
                Group {
                    if model.showsWeek {
                        WeekView()
                    } else {
                        TimelineView()
                    }
                }
                .frame(height: metrics.panelHeight)
                .environment(\.timelineMetrics, metrics)
                RowDivider(extra: $timelineExtra, current: Double(metrics.extra), range: 0...limit)
                // Нижняя полоса забирает всё оставшееся по высоте место.
                HStack(alignment: .top, spacing: Self.gap) {
                    MailListPanel()
                    VStack(spacing: Self.gap) {
                        MonthCalendarView()
                            .fixedSize(horizontal: false, vertical: true)
                        DayNotePanel()
                    }
                    .frame(width: model.showWeekNumbers ? 290 : 270)
                }
                .frame(minHeight: Self.minBottomHeight, maxHeight: .infinity)
            }
        }
        .padding([.leading, .top, .bottom], Self.gap)
        .frame(minWidth: Self.minTimelineWidth, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Ручка между таймлайном и нижним рядом: тянется вниз — таймлайн выше,
/// дорожки и карточки писем растут; двойной щелчок — обычная высота.
struct RowDivider: View {
    @Binding var extra: Double
    let current: Double
    let range: ClosedRange<Double>
    @ViewState private var dragStart: Double?
    @ViewState private var hovering = false

    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(hovering || dragStart != nil ? 0.6 : 0))
            .frame(width: 60, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: MainView.gap)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? current
                    if dragStart == nil { dragStart = start }
                    extra = min(max(start + value.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { extra = 0 }
            .help("Потяните, чтобы изменить высоту таймлайна; двойной щелчок — обычная высота")
    }
}

/// Разделитель между таймлайном и правой панелью: тянется мышью,
/// ширина запоминается, двойной щелчок возвращает ширину по умолчанию.
struct PanelDivider: View {
    @Binding var width: Double
    /// Ширина, которая сейчас на экране (с учётом пределов окна).
    let current: Double
    let range: ClosedRange<Double>
    /// С какой стороны панель: правая растёт, когда ручку тянут влево,
    /// левая (вертикальный таймлайн) — когда вправо.
    enum Side { case left, right }
    var grows: Side = .left
    var defaultWidth: Double = MainView.defaultInspectorWidth
    @ViewState private var dragStart: Double?

    @ViewState private var hovering = false

    var body: some View {
        // Сам промежуток между карточками и есть ручка: линия видна
        // только под курсором.
        Capsule()
            .fill(Color.accentColor.opacity(hovering || dragStart != nil ? 0.6 : 0))
            .frame(width: 3)
            .padding(.vertical, 40)
            .frame(width: MainView.gap)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? current
                    if dragStart == nil { dragStart = start }
                    let delta = grows == .left ? -value.translation.width : value.translation.width
                    width = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { width = defaultWidth }
            .help("Потяните, чтобы изменить ширину панели; двойной щелчок — ширина по умолчанию")
    }
}

/// Панель действий. Кнопки работают и как цели перетаскивания: элемент
/// с таймлайна или из списка бросают прямо на «В архив» или «Перенести».
struct ActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            // Только значки: подпись — при наведении. Кнопки — стеклянные
            // капсулы на фоне окна, как панель инструментов macOS 26.
            GlassGroup {
                buttons(compact: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if let problem = model.accessProblem, !model.options.demo {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .help("Разрешите доступ в Системных настройках → Конфиденциальность и безопасность")
            }
            UpdateCapsule(updates: model.updates)
            MailStatus()
                .glassCapsule()
        }
        .padding(.horizontal, 6)
        .padding(.leading, MainView.windowButtonsWidth)
        .frame(height: MainView.barHeight)
        // Пустые места панели двигают окно — как заголовок, которого больше нет.
        .background(Color.clear.windowDragArea())
    }

    private func buttons(compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(ItemAction.allCases) { action in
                ActionDropButton(action: action, compact: compact)
            }
            CreateMenu(compact: compact)
        }
        .fixedSize()
    }
}

/// «Создать»: письмо, встречу, напоминание.
struct CreateMenu: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @ViewState private var isHovered = false

    var body: some View {
        Menu {
            Button("Письмо  ⌘N") { model.startNewMail() }
            Button("Встреча  ⇧⌘N") { model.startNewEvent() }
            Button("Напоминание  ⌥⌘N") { model.startNewReminder() }
        } label: {
            HoverLabel(title: String(localized: "Создать"), symbol: "plus", expanded: !compact || isHovered)
                .modifier(GlassButtonSurface(hovered: isHovered))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in withAnimation(HoverMotion.animation) { isHovered = inside } }
        .help("Новое письмо, встреча или напоминание")
    }
}

/// Какая почта и как у неё дела: адрес (или число ящиков), время
/// обновления или ошибка.
private struct MailStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // `--showcase` — снимки для README: тестовые данные без таблички.
        if model.options.demo, model.accounts.isEmpty, model.options.showcase {
            EmptyView()
        } else if model.options.demo, model.accounts.isEmpty {
            Label("Тестовый режим", systemImage: "testtube.2")
                .lineLimit(1)
                .fixedSize()
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !model.accounts.isEmpty {
            let status = model.mailStatus
            let icon = model.accounts.count > 1 ? "tray.2" : "tray"
            let details = [model.mailName, status?.error ?? status?.lastSync.map { String(localized: "обновлено в \(Format.time($0))") }]
                .compactMap { $0 }.joined(separator: " · ")
            // Места мало — сначала уходит «обновлено в …», потом адрес;
            // всё это остаётся в подсказке. Переносов по буквам не бывает.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label(model.mailName, systemImage: icon).fixedSize()
                    SyncStatusText(status: status).lineLimit(1).fixedSize()
                    refreshButton(status)
                }
                HStack(spacing: 8) {
                    Label(model.mailName, systemImage: icon).fixedSize()
                    if status?.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    refreshButton(status)
                }
                HStack(spacing: 6) {
                    Image(systemName: status?.error != nil ? "exclamationmark.triangle.fill" : icon)
                        .foregroundStyle(status?.error != nil ? Color.orange : .secondary)
                    refreshButton(status)
                }
            }
            .help(boxesHelp.isEmpty ? details : boxesHelp)
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text("Письма тестовые")
                    .lineLimit(1)
                    .fixedSize()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Подключить почту…") { SettingsWindow.show(model: model) }
            }
        }
    }

    private func refreshButton(_ status: MailSyncStatus?) -> some View {
        Button { model.refreshMail() } label: {
            if status?.isSyncing == true {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .help("Проверить почту сейчас")
        .disabled(status?.isSyncing == true)
    }

    /// Подсказка со списком ящиков — когда их несколько.
    private var boxesHelp: String {
        guard model.accounts.count > 1 else { return "" }
        return model.accounts.map { account in
            let status = model.syncStatuses[account.id]
            let state = status?.error ?? status?.lastSync.map { String(localized: "обновлено в \(Format.time($0))") } ?? String(localized: "ещё не обновлялось")
            return "\(account.email) — \(state)"
        }.joined(separator: "\n")
    }
}

struct ActionDropButton: View {
    @EnvironmentObject private var model: AppModel
    let action: ItemAction
    /// Только значок — когда подписи не помещаются.
    var compact = false
    @ViewState private var isTargeted = false
    /// Под курсором — кнопка раздвигается и показывает подпись.
    @ViewState private var isHovered = false

    private var expanded: Bool {
        !compact || isHovered || isTargeted || model.options.hoverAction == action.rawValue
    }

    private var availability: Availability? {
        model.selectedItem.map { model.availability(of: action, for: $0) }
    }

    var body: some View {
        Button {
            if let id = model.selectedID { model.perform(action, on: id) }
        } label: {
            // Пунктир — знак, что сюда можно бросить письмо.
            HoverLabel(title: action.title, symbol: action.symbol, expanded: expanded)
                .modifier(GlassButtonSurface(hovered: isHovered, targeted: isTargeted, dashed: true))
                .scaleEffect(isTargeted ? 1.05 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in withAnimation(HoverMotion.animation) { isHovered = inside } }
        .opacity(availability?.isEnabled == false ? 0.45 : 1)
        .help(helpText)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.perform(action, on: id)
            return true
        } isTargeted: { inside in withAnimation(HoverMotion.animation) { isTargeted = inside } }
    }

    private var helpText: String {
        if case .disabled(let reason) = availability { return reason }
        return String(localized: "\(action.title) — перетащите сюда элемент или нажмите ⌘\(String(action.key).uppercased())")
    }
}

/// Дата, листание дней, события на весь день и масштаб.
struct DayHeader: View {
    @EnvironmentObject private var model: AppModel

    private var allDay: [TimelineItem] {
        model.dayItems.filter { $0.isAllDay }.sorted { $0.title < $1.title }
    }

    var body: some View {
        let week = model.showsWeek
        HStack(spacing: 8) {
            Button { model.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help(week ? String(localized: "Предыдущая неделя (⌘[)") : String(localized: "Предыдущий день (⌘[)"))
            HStack(spacing: 8) {
                Text(week ? Format.weekTitle(model.weekDays) : Format.dayTitle(model.day))
                    .font(.title3.weight(.semibold))
                    .fixedSize()
                if !week { WeatherChip(day: model.day) }
            }
            // Своя ширина снаружи рамки: `frame(minWidth:)` сам по себе даёт
            // шапке сжать заголовок до 210, и погода наезжала на «›» и «Сегодня».
            .frame(minWidth: 210, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            Button { model.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help(week ? String(localized: "Следующая неделя (⌘])") : String(localized: "Следующий день (⌘])"))
            Button("Сегодня") { model.showToday() }
                .disabled(model.showsToday)

            // В неделе события на весь день — в шапках дней.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if !week {
                        ForEach(allDay) { item in
                            AllDayChip(item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if !model.timelineVertical {
                Picker("", selection: $model.timelineSpan) {
                    Text("День").tag(AppModel.TimelineSpan.day)
                    Text("Неделя").tag(AppModel.TimelineSpan.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("День или неделя (⌥⌘1 / ⌥⌘2)")
            }

            Button {
                withAnimation(HoverMotion.animation) { model.timelineVertical.toggle() }
            } label: {
                Image(systemName: model.timelineVertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }
            .help(model.timelineVertical ? String(localized: "Таймлайн слева направо (⌥⌘L)") : String(localized: "Таймлайн сверху вниз (⌥⌘L)"))
            Button { SettingsWindow.show(model: model, tab: .calendars) } label: { Image(systemName: "calendar.badge.checkmark") }
                .help("Какие календари показывать")
            Button { model.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Мельче (⌘−)")
            Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Крупнее (⌘=)")
        }
        .buttonStyle(.borderless)
    }
}

struct AllDayChip: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        let done = model.status(of: item).isDone
        HStack(spacing: 4) {
            // Напоминание на весь день отмечается тут же, кружком.
            if item.kind == .reminder {
                ReminderCheckbox(item: item, size: 12)
            } else {
                Image(systemName: "sun.max")
            }
            Text(item.title).strikethrough(done && item.kind == .reminder)
        }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(item.swiftUIColor.opacity(0.18)))
            .overlay(Capsule().strokeBorder(model.selectedID == item.id ? Color.accentColor : .clear, lineWidth: 2))
            .opacity(done ? 0.5 : 1)
            .contentShape(Capsule())
            .onTapGesture { model.selectedID = item.id }
            .draggable(item.id)
    }
}

/// Подложка блоков окна.
extension View {
    /// Взялся за пустое место — тянешь окно.
    func windowDragArea() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

/// Фон окна — «сияние»: панели полупрозрачные, чтобы его было видно.
/// Ключом, а не `@Entry`: макросы SwiftUI без Xcode недоступны.
private struct AuroraThemeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var auroraTheme: Bool {
        get { self[AuroraThemeKey.self] }
        set { self[AuroraThemeKey.self] = newValue }
    }
}

struct Panel: View {
    /// Одно скругление на все панели окна.
    static let radius: CGFloat = 12
    @Environment(\.auroraTheme) private var aurora

    var body: some View {
        // Liquid Glass на macOS 26+, прежняя подложка — на старых системах.
        GlassPanelBackground(cornerRadius: Self.radius)
    }
}

extension TimelineItem {
    var swiftUIColor: Color {
        guard let color else {
            switch kind {
            case .mail: return .accentColor
            case .event: return .blue
            case .reminder: return .orange
            }
        }
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    var symbol: String {
        switch kind {
        case .mail: return "envelope"
        case .event: return "calendar"
        case .reminder: return "bell"
        }
    }
}

enum Format {
    /// По-русски — заданный формат, на других языках — системный шаблон.
    private static func formatter(_ format: String, _ template: String) -> DateFormatter {
        AppLanguage.formatter(ru: format, template: template)
    }

    private static let day = formatter("EEEE, d MMMM", "EEEEdMMMM")
    private static let dayYear = formatter("EEEE, d MMMM yyyy", "EEEEdMMMMyyyy")
    private static let time = formatter("HH:mm", "HHmm")
    private static let short = formatter("d MMM, HH:mm", "dMMMHHmm")
    private static let weekdayTime = formatter("EE, HH:mm", "EEHHmm")
    private static let month = formatter("LLLL yyyy", "LLLLyyyy")

    static func dayTitle(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let text = (sameYear ? day : dayYear).string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func time(_ date: Date) -> String { time.string(from: date) }

    private static let dayMonth = formatter("d MMMM", "dMMMM")
    private static let dayOnly = formatter("d", "d")

    /// «21 – 27 сентября», «28 сентября – 4 октября».
    static func weekTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        return "\((sameMonth ? dayOnly : dayMonth).string(from: first)) – \(dayMonth.string(from: last))"
    }

    static func month(_ date: Date) -> String {
        let text = month.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// «14:02», «вчера, 14:02», «пн, 14:02», «3 сент., 14:02».
    static func relative(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "вчера, ") + time.string(from: date)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "завтра, ") + time.string(from: date)
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 { return weekdayTime.string(from: date) }
        return short.string(from: date)
    }

    static func range(_ start: Date, _ end: Date?) -> String {
        guard let end else { return time(start) }
        return "\(time(start))–\(time(end))"
    }
}
