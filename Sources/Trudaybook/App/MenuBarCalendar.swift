import AppKit
import Combine
import SwiftUI
import TrudaybookCore

/// Значок в строке меню: число сегодняшнего дня, по нажатию — окошко
/// с месяцем и встречами выбранного дня; у онлайн-встреч — «Подключиться».
///
/// Встречи берутся теми же календарями, что и таймлайн (скрытые в настройках
/// не показываются). Выключается в Настройках → Оформление.
@MainActor
final class MenuBarCalendar: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let state = MenuBarCalendarState()
    private var watches: [AnyCancellable] = []
    /// Какой день нарисован на значке: сменился — перерисовать.
    private var drawnDay: Date?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        let content = NSHostingController(rootView: MenuBarCalendarView(state: state) { [weak self] in
            self?.popover.performClose(nil)
        }.environmentObject(model))
        // Окошко само подстраивается под число встреч.
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        watches.append(model.$menuBarIcon.sink { [weak self] visible in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setVisible(visible) } }
        })
        // Полночь — на значке новое число.
        watches.append(model.$now.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.redrawIcon() } }
        })
    }

    private func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggle)
            item.button?.toolTip = String(localized: "Trudaybook — календарь и встречи")
            item.button?.setAccessibilityLabel(String(localized: "Календарь Trudaybook"))
            self.item = item
            drawnDay = nil
            redrawIcon()
        } else if !visible, let item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func redrawIcon() {
        guard let button = item?.button else { return }
        let today = model.calendar.startOfDay(for: model.now)
        guard today != drawnDay else { return }
        drawnDay = today
        button.image = Self.icon(day: model.calendar.component(.day, from: today))
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show()
        }
    }

    /// Открыть окошко: всегда с сегодняшнего дня.
    func show() {
        guard let button = item?.button else { return }
        state.reset(to: model.now, model: model)
        // Снимок снимает окошко активного приложения — как его видит человек.
        if model.options.snapshotPath != nil { NSApp.activate() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Без кольца фокуса на первой кнопке (стрелке месяца).
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }

    /// Окошко — для отладочного снимка.
    var popoverWindow: NSWindow? { popover.contentViewController?.view.window }

    /// Листок календаря с числом — шаблоном, чтобы строка меню сама красила
    /// его под светлую и тёмную тему.
    static func icon(day: Int) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let sheet = rect.insetBy(dx: 1, dy: 0.75)
            let outline = NSBezierPath(roundedRect: sheet, xRadius: 3, yRadius: 3)
            NSColor.black.setStroke()
            outline.lineWidth = 1.3
            outline.stroke()
            // Верхняя полоса листка — сплошная.
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.black.setFill()
            NSRect(x: sheet.minX, y: sheet.maxY - 3.6, width: sheet.width, height: 3.6).fill()
            NSGraphicsContext.restoreGraphicsState()
            let text = "\(day)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let textSize = text.size(withAttributes: attributes)
            let body = NSRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: sheet.height - 3.6)
            text.draw(at: NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2 + 0.3),
                      withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Что показано в окошке: месяц, выбранный день и его встречи.
@MainActor
final class MenuBarCalendarState: ObservableObject {
    @Published var month = Date()
    @Published var selected = Date()
    @Published var events: [TimelineItem] = []
    @Published var busyDays: Set<Date> = []
    @Published var loaded = false
    /// Текущая или ближайшая встреча сегодня — на ней фокус (`NearestMeeting`).
    @Published var focusID: String?
    private var loadingDay: Date?

    func reset(to now: Date, model: AppModel) {
        focusID = nil
        let today = model.calendar.startOfDay(for: now)
        let monthChanged = !model.calendar.isDate(today, equalTo: month, toGranularity: .month)
        month = today
        select(today, model: model)
        if monthChanged || busyDays.isEmpty { loadMonth(model: model) }
    }

    func select(_ day: Date, model: AppModel) {
        let day = model.calendar.startOfDay(for: day)
        selected = day
        if !model.calendar.isDate(day, equalTo: month, toGranularity: .month) {
            month = day
            loadMonth(model: model)
        }
        loadingDay = day
        Task {
            let found = await model.menuBarEvents(on: day)
            guard loadingDay == day else { return }
            events = found
            loaded = true
            // В другой день «текущей» встречи нет — фокус только сегодня.
            focusID = model.calendar.isDate(day, inSameDayAs: model.now)
                ? NearestMeeting.pick(found, now: model.now, needsLink: false)?.id : nil
        }
    }

    func shiftMonth(_ offset: Int, model: AppModel) {
        guard let target = model.calendar.date(byAdding: .month, value: offset, to: month) else { return }
        month = target
        loadMonth(model: model)
    }

    private func loadMonth(model: AppModel) {
        let anchor = month
        Task {
            let days = await model.eventDays(inMonthOf: anchor)
            guard model.calendar.isDate(anchor, equalTo: month, toGranularity: .month) else { return }
            busyDays = days
        }
    }
}

/// Содержимое окошка. Окошко системное (на macOS 26 — уже стекло),
/// поэтому внутри кнопки и строки без своего стекла.
struct MenuBarCalendarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: MenuBarCalendarState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            monthHeader
            monthGrid
            Divider()
            dayTitle
            eventList
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 330)
        // Окошко открывается без кольца фокуса на первой кнопке.
        .focusEffectDisabled()
    }

    // MARK: Месяц

    private var monthHeader: some View {
        HStack {
            Text(Format.month(state.month)).font(.headline)
            Spacer()
            Button { state.shiftMonth(-1, model: model) } label: { Image(systemName: "chevron.left") }
                .help("Предыдущий месяц")
            Button("Сегодня") { state.reset(to: model.now, model: model) }
                .disabled(model.calendar.isDate(state.selected, inSameDayAs: model.now))
            Button { state.shiftMonth(1, model: model) } label: { Image(systemName: "chevron.right") }
                .help("Следующий месяц")
        }
        .buttonStyle(.borderless)
    }

    private var days: [Date?] {
        let calendar = model.calendar
        guard let interval = calendar.dateInterval(of: .month, for: state.month) else { return [] }
        // Неделя с понедельника — как в календаре главного окна.
        let leading = (calendar.component(.weekday, from: interval.start) + 5) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        var day = interval.start
        while day < interval.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    private var monthGrid: some View {
        // Первая колонка — номер недели ISO 8601, как в календаре главного окна.
        let columns = [GridItem(.fixed(22), spacing: 2)] + Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let cells = days
        return LazyVGrid(columns: columns, spacing: 2) {
            Text("Нед").font(.caption2).foregroundStyle(.tertiary)
            ForEach([String(localized: "Пн"), String(localized: "Вт"), String(localized: "Ср"), String(localized: "Чт"),
                     String(localized: "Пт"), String(localized: "Сб"), String(localized: "Вс")], id: \.self) { name in
                Text(name).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { index, day in
                if index % 7 == 0 {
                    weekCell(Array(cells[index..<min(index + 7, cells.count)]).compactMap { $0 })
                }
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 30)
                }
            }
        }
    }

    /// Номер недели; щелчок — её понедельник (или первый день месяца в ней).
    @ViewBuilder
    private func weekCell(_ week: [Date]) -> some View {
        if let first = week.first {
            let number = WeekNumberCell.iso.component(.weekOfYear, from: first)
            let current = week.contains { model.calendar.isDate($0, inSameDayAs: model.now) }
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(current ? .semibold : .regular))
                .foregroundStyle(current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(maxWidth: .infinity)
                .frame(height: 30, alignment: .top)
                .padding(.top, 5)
                .contentShape(Rectangle())
                .onTapGesture { state.select(first, model: model) }
                .help("Неделя \(number)")
        } else {
            Color.clear.frame(height: 30)
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = model.calendar
        let isToday = calendar.isDate(day, inSameDayAs: model.now)
        let isSelected = calendar.isDate(day, inSameDayAs: state.selected)
        let weekend = calendar.isDateInWeekend(day)
        // Цвета — иерархические (`.primary`, а не `Color.primary`): только
        // их окошко строки меню красит как свои подписи.
        let digits: AnyShapeStyle = isToday ? AnyShapeStyle(.white) : weekend ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(digits)
                .frame(width: 24, height: 20)
                .background(Circle().fill(isToday ? Color.accentColor : .clear).frame(width: 22, height: 22))
            Circle()
                .fill(state.busyDays.contains(calendar.startOfDay(for: day)) ? Color.secondary : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected && !isToday ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.select(day, model: model) }
    }

    // MARK: Встречи дня

    private var dayTitle: some View {
        HStack {
            Text(Format.dayTitle(state.selected)).font(.subheadline.weight(.semibold))
            Spacer()
            if !state.events.isEmpty {
                Text(String(localized: "встреч: \(state.events.count)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var eventList: some View {
        if state.events.isEmpty {
            Text(state.loaded ? String(localized: "Встреч нет") : String(localized: "Загружаю…"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.events) { item in
                            MenuBarEventRow(item: item, now: model.now, focused: item.id == state.focusID) { open(item) }
                                .id(item.id)
                        }
                    }
                }
                // Длинный день прокручивается, окошко не вылезает за экран.
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: state.events.count <= 6)
                // Открыли — текущая или ближайшая встреча сразу на виду.
                .onChange(of: state.focusID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                }
                .onAppear {
                    if let id = state.focusID { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                close()
                model.startNewEvent()
                showMainWindow()
            } label: {
                Label("Новая встреча", systemImage: "plus")
            }
            Spacer()
            Button("Открыть Trudaybook") {
                close()
                model.show(day: state.selected)
                showMainWindow()
            }
        }
        .buttonStyle(.borderless)
    }

    private func open(_ item: TimelineItem) {
        close()
        model.show(day: item.time)
        model.selectedID = item.id
        showMainWindow()
    }

    private func showMainWindow() {
        LetterWindow.showMainWindow()
    }
}

/// Встреча в окошке: время, название, место; у онлайн-встречи — «Подключиться».
private struct MenuBarEventRow: View {
    let item: TimelineItem
    let now: Date
    /// Текущая или ближайшая: подсвечена, Return подключает к ней.
    var focused = false
    let open: () -> Void
    @ViewState private var hovered = false

    private var ended: Bool { (item.end ?? item.time) < now && !item.isAllDay }
    /// Идёт или начнётся в ближайшие 10 минут — кнопку выделить.
    private var soon: Bool {
        guard !item.isAllDay else { return false }
        return item.time.timeIntervalSince(now) < 600 && (item.end ?? item.time) > now
    }
    private var cancelled: Bool { item.event?.isCancelled == true }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.swiftUIColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.isAllDay ? String(localized: "весь день") : Format.range(item.time, item.end))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(soon ? Color.accentColor : .secondary)
                    if focused {
                        Text(item.time <= now ? String(localized: "идёт") : soon ? String(localized: "скоро") : String(localized: "далее"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(cancelled)
                    .lineLimit(2)
                if let location = item.event?.location, !location.isEmpty, item.event?.link == nil {
                    Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let link = item.event?.link, !ended, !cancelled {
                // Идёт или вот-вот начнётся — кнопка акцентная, остальные спокойнее.
                let join = Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    Label("Подключиться", systemImage: "video.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                }
                .controlSize(.small)
                .help(String(localized: "Подключиться · \(link.provider.rawValue)"))
                if focused {
                    // Return в окошке — подключиться к ней.
                    join.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else if soon {
                    join.buttonStyle(.borderedProminent)
                } else {
                    join.buttonStyle(.bordered)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(focused ? Color.accentColor.opacity(hovered ? 0.18 : 0.12) : Color.primary.opacity(hovered ? 0.07 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        .opacity(ended || cancelled ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .help("Открыть в Trudaybook")
    }
}
