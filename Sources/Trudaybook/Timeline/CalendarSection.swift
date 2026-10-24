import SwiftUI
import TrudaybookCore

/// Раздел «Календарь»: календарь на всё окно — год, месяц, неделя или день.
/// Выбранная встреча открывается стеклянной панелью справа; Esc или щелчок
/// по пустому дню её закрывают.
struct CalendarSectionView: View {
    @EnvironmentObject private var model: AppModel
    /// Справа — список календарей вместо встречи.
    @ViewState private var calendarsOpen = false

    static let inspectorWidth: CGFloat = 460
    static let calendarsWidth: CGFloat = 320

    var body: some View {
        SectionPage(.calendar, capsule: capsule) {
            CalendarNavigator()
            CalendarTools(calendarsOpen: $calendarsOpen)
        } content: {
            HStack(spacing: MainView.gap) {
                ZStack {
                    switch model.calendarSpan {
                    case .year: YearGridView().transition(.opacity)
                    case .month: MonthGridView().transition(.opacity)
                    case .week: WeekView().transition(.opacity)
                    case .day: VerticalTimelineView(showsMail: false).transition(.opacity)
                    }
                }
                // Сетка часов — до самого низа окна, и под капсулой тоже:
                // отступ прокрутки оставил бы внизу полосу без линий.
                .contentMargins(.bottom, 0, for: .scrollContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if calendarsOpen {
                    CalendarListPanel { calendarsOpen = false }
                        .frame(width: Self.calendarsWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if model.inspectorHasContent {
                    InspectorView()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
                        .frame(width: Self.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.move, value: model.inspectorHasContent)
            .animation(Motion.move, value: calendarsOpen)
            // Выбрали встречу — справа она, а не список календарей.
            .onChange(of: model.selectedID) { _, id in
                if id != nil { calendarsOpen = false }
            }
        }
        .onAppear {
            // Неделя и день — общие с домашней: там могли переключить.
            if model.calendarSpan == .week, !model.showsWeek { model.timelineSpan = .week }
            if model.calendarSpan == .day, model.showsWeek { model.timelineSpan = .day }
        }
    }

    private var capsule: SectionCapsule {
        let span = model.calendarSpan
        func item(_ value: AppModel.CalendarSpan, _ title: String, _ help: String) -> CapsuleItem {
            CapsuleItem(id: value.rawValue, title: title, selected: span == value, help: help) {
                model.showCalendar(value)
            }
        }
        return SectionCapsule(
            leading: [item(.year, String(localized: "Год"), String(localized: "Весь год")),
                      item(.month, String(localized: "Месяц"), String(localized: "Месяц со встречами"))],
            trailing: [item(.week, String(localized: "Неделя"), String(localized: "Неделя по часам")),
                       item(.day, String(localized: "День"), String(localized: "День по часам"))],
            plusHelp: String(localized: "Новая встреча (⇧⌘N)"),
            plusDraggable: true
        ) {
            model.startNewEvent(at: newEventStart)
        }
    }

    /// В месяце и годе встреча — на выбранный день с начала рабочего дня;
    /// сегодня и в неделе с днём — как у «Создать» (ближайшее время).
    private var newEventStart: Date? {
        guard model.calendarSpan == .month || model.calendarSpan == .year, !model.isToday else { return nil }
        return model.calendar.date(bySettingHour: model.workHours.lowerBound, minute: 0, second: 0, of: model.day)
    }
}

/// Что сейчас на экране и «‹ Сегодня ›» — шаг по виду: год, месяц, неделя, день.
private struct CalendarNavigator: View {
    @EnvironmentObject private var model: AppModel

    private var title: String {
        switch model.calendarSpan {
        case .year: "\(model.calendar.component(.year, from: model.day))"
        case .month: Format.month(model.day)
        // С номерами недель — «Неделя 39 · 21 – 27 сентября».
        case .week: model.showWeekNumbers ? NoteWindow.title(.week, day: model.day, calendar: model.calendar)
                                          : Format.weekTitle(model.weekDays)
        case .day: Format.dayTitle(model.day)
        }
    }

    private var step: (back: String, forward: String) {
        switch model.calendarSpan {
        case .year: (String(localized: "Предыдущий год"), String(localized: "Следующий год"))
        case .month: (String(localized: "Предыдущий месяц"), String(localized: "Следующий месяц"))
        case .week: (String(localized: "Предыдущая неделя (⌘[)"), String(localized: "Следующая неделя (⌘])"))
        case .day: (String(localized: "Предыдущий день (⌘[)"), String(localized: "Следующий день (⌘])"))
        }
    }

    var body: some View {
        HStack(spacing: Space.lg) {
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            HStack(spacing: 0) {
                BarIconButton(symbol: "chevron.left", help: step.back) { model.shiftCalendar(-1) }
                BarTextButton(title: String(localized: "Сегодня"), help: String(localized: "К сегодняшнему дню (⌘T)")) {
                    model.showToday()
                }
                BarIconButton(symbol: "chevron.right", help: step.forward) { model.shiftCalendar(1) }
            }
            .glassBar()
        }
    }
}

/// Кнопки над календарём: разобранные письма, номера недель и какие
/// календари показывать (список — панелью справа).
private struct CalendarTools: View {
    @EnvironmentObject private var model: AppModel
    @Binding var calendarsOpen: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Разобранные письма — прятать или показывать с галочкой
            // (письма — в неделе, вид «Письма»).
            BarIconButton(symbol: model.hideResolvedMail ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                          tint: model.hideResolvedMail ? Color.accentColor : nil,
                          help: model.hideResolvedMail
                            ? String(localized: "Разобранные письма скрыты — показать (⇧⌘H)")
                            : String(localized: "Скрыть разобранные письма с таймлайна (⇧⌘H)")) {
                withAnimation(HoverMotion.animation) { model.hideResolvedMail.toggle() }
            }
            BarIconButton(symbol: "number", tint: model.showWeekNumbers ? Color.accentColor : nil,
                          help: model.showWeekNumbers ? String(localized: "Номера недель показаны — скрыть")
                                                      : String(localized: "Показать номера недель")) {
                withAnimation(Motion.quick) { model.showWeekNumbers.toggle() }
            }
            BarIconButton(symbol: "calendar.badge.checkmark", tint: calendarsOpen ? Color.accentColor : nil,
                          help: String(localized: "Какие календари показывать")) {
                calendarsOpen.toggle()
            }
        }
        .glassBar()
    }
}

/// Список календарей справа: галочка — показывать, кружок — цвет. Те же
/// галочки, что в Настройках → Календари.
private struct CalendarListPanel: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Календари").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .labelHelp(String(localized: "Закрыть"))
            }
            .padding(.horizontal, Space.lg)
            .frame(height: 44)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    CalendarCheckboxes(kind: .events)
                    Text("Напоминания")
                        .font(.headline)
                        .padding(.top, Space.lg)
                    CalendarCheckboxes(kind: .reminders)
                    SettingsHint(String(localized: "Кружок с цветом — сменить цвет календаря. Только в Trudaybook: в самом календаре и у других людей цвет прежний."))
                        .padding(.top, Space.md)
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Panel())
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
        .onAppear { model.loadCalendarSources() }
    }
}

/// Короткие названия дней недели с понедельника — ключи те же, что
/// у мини-календаря.
enum WeekdayNames {
    static var short: [String] {
        [String(localized: "Пн"), String(localized: "Вт"), String(localized: "Ср"), String(localized: "Чт"),
         String(localized: "Пт"), String(localized: "Сб"), String(localized: "Вс")]
    }
}

// MARK: - Месяц

/// Месяц сеткой: в клетке дня — его встречи и напоминания, сколько влезает,
/// остальное — «ещё N». Щелчок по дню — выбрать день, двойной — открыть его.
struct MonthGridView: View {
    @EnvironmentObject private var model: AppModel
    /// Под парящей капсулой раздела — пусто: она не ложится на последнюю неделю.
    @Environment(\.capsuleInset) private var capsuleInset

    /// Строка встречи в клетке.
    static let chipHeight: CGFloat = 18
    /// Число дня над встречами.
    static let numberHeight: CGFloat = 22
    /// Колонка номеров недель.
    static let weekColumn: CGFloat = 36

    private struct LoadKey: Equatable {
        let month: Date
        let revision: Int
    }

    var body: some View {
        let calendar = model.calendar
        let days = MonthGrid.days(of: model.day, calendar: calendar)
        let rows = max(days.count / 7, 1)
        let month = calendar.dateInterval(of: .month, for: model.day)
        let numbers = model.showWeekNumbers
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if numbers {
                    Text("Нед")
                        .font(.app(.label, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: Self.weekColumn)
                }
                ForEach(Array(WeekdayNames.short.enumerated()), id: \.offset) { index, name in
                    Text(name)
                        .font(.app(.label, weight: .semibold))
                        .foregroundStyle(index >= 5 ? .tertiary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 28)
            Divider()
            GeometryReader { geometry in
                let height = geometry.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            if numbers {
                                MonthWeekNumber(week: days[(row * 7)..<min(row * 7 + 7, days.count)].compactMap { $0 })
                                    .frame(width: Self.weekColumn)
                                    .frame(maxHeight: .infinity, alignment: .top)
                            }
                            ForEach(0..<7, id: \.self) { column in
                                let index = row * 7 + column
                                Group {
                                    if index < days.count, let day = days[index] {
                                        MonthDayCell(day: day, items: items(on: day), height: height)
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(column >= 5 ? Fill.faint : .clear)
                                .overlay(alignment: .trailing) {
                                    if column < 6 { Rectangle().fill(Fill.subtle).frame(width: Space.hairline) }
                                }
                            }
                        }
                        .frame(height: height)
                        .overlay(alignment: .bottom) {
                            if row < rows - 1 { Rectangle().fill(Fill.subtle).frame(height: Space.hairline) }
                        }
                    }
                }
            }
            .padding(.bottom, capsuleInset)
        }
        .background(Panel())
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
        .task(id: LoadKey(month: month?.start ?? model.day, revision: model.calendarRevision)) {
            guard let month else { return }
            await model.loadMonthItems(from: month.start, to: month.end)
        }
    }

    /// Встречи дня: сначала на весь день, потом по времени.
    private func items(on day: Date) -> [TimelineItem] {
        let end = model.calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        return model.monthItems
            .filter { $0.overlaps(from: day, to: end) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.time) < ($1.isAllDay ? 0 : 1, $1.time) }
    }
}

private struct MonthDayCell: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let items: [TimelineItem]
    let height: CGFloat
    @ViewState private var targeted = false

    var body: some View {
        let calendar = model.calendar
        let today = calendar.isDate(day, inSameDayAs: model.now)
        let chosen = calendar.isDate(day, inSameDayAs: model.day)
        // Сколько строк помещается под числом; не влезают все — последняя
        // строка уходит под «ещё N».
        let room = max(Int((height - MonthGridView.numberHeight - Space.xs) / (MonthGridView.chipHeight + Space.xxs)), 0)
        let shown = items.count > room ? max(room - 1, 0) : items.count
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Spacer(minLength: 0)
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.app(.text, weight: today || chosen ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(today ? .white : .primary)
                    .frame(minWidth: 20, minHeight: 20)
                    .background {
                        if today {
                            Circle().fill(Color.accentColor)
                        } else if chosen {
                            Circle().fill(Fill.accentSoft)
                        }
                    }
            }
            .frame(height: MonthGridView.numberHeight)
            ForEach(items.prefix(shown)) { item in
                MonthEventChip(item: item, day: day)
            }
            if items.count > shown {
                Text("ещё \(items.count - shown)")
                    .font(.app(.small, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Space.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.show(day: day)
            model.showCalendar(.day)
        }
        .onTapGesture {
            model.showDayOverview()
            model.show(day: day)
        }
        .actsAsRow(Format.dayTitle(day)) { model.show(day: day) }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(Fill.accentFaint)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                    .padding(Space.xxs)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.url, .plainText], delegate: MonthDayDrop(model: model, day: day) { targeted = $0 })
    }
}

/// Клетка дня принимает «+» капсулы (встреча на этот день с начала рабочего
/// дня) и встречу или напоминание (переезжают на этот день в то же время).
private struct MonthDayDrop: DropDelegate {
    let model: AppModel
    let day: Date
    let setTargeted: (Bool) -> Void

    private func isNewItem(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.url]) }

    func validateDrop(info: DropInfo) -> Bool { isNewItem(info) || info.hasItemsConforming(to: [.plainText]) }

    func dropEntered(info: DropInfo) { setTargeted(true) }

    func dropExited(info: DropInfo) { setTargeted(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isNewItem(info) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        let model = model, day = day
        if isNewItem(info) {
            guard let provider = info.itemProviders(for: [.url]).first else { return false }
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                // Только своя ссылка: ссылку из браузера за встречу не считаем.
                guard let url = object as? NSURL, url.absoluteString == AppModel.newItemURL.absoluteString else { return }
                Task { @MainActor in
                    DebugLog.write("бросок в день месяца: новая встреча")
                    model.startNewEvent(at: model.calendar.date(bySettingHour: model.workHours.lowerBound, minute: 0, second: 0, of: day))
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? NSString else { return }
            let text = id as String
            Task { @MainActor in
                model.dragging = nil
                model.drop(text, onDay: day)
            }
        }
        return true
    }
}

/// Номер недели ISO слева от её строки; щелчок — эта неделя по часам.
private struct MonthWeekNumber: View {
    @EnvironmentObject private var model: AppModel
    let week: [Date]
    @ViewState private var hovered = false

    var body: some View {
        if let first = week.first {
            let number = NoteKeys.isoCalendar(timeZone: model.calendar.timeZone).component(.weekOfYear, from: first)
            let current = week.contains { model.calendar.isDate($0, inSameDayAs: model.now) }
            Button {
                model.show(day: first)
                model.showCalendar(.week)
            } label: {
                Text(verbatim: "\(number)")
                    .font(.app(.label, weight: current ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(current ? Color.primary : .secondary)
                    .padding(.horizontal, Space.sm)
                    .frame(height: 20)
                    .background(Capsule().fill(current ? Fill.accentSoft : hovered ? Fill.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Space.xs)
            .onHover { hovered = $0 }
            .help(String(localized: "Неделя \(number)"))
        }
    }
}

/// Строка встречи в клетке месяца: на весь день — плашкой цвета календаря,
/// со временем — точкой, временем и названием.
private struct MonthEventChip: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    let day: Date
    @ViewState private var hovered = false

    var body: some View {
        let selected = model.selectedID == item.id
        let color = item.event?.isCancelled == true ? Color.gray : item.swiftUIColor
        let band = item.isAllDayBand
        let done = model.status(of: item).isDone
        HStack(spacing: Space.xs) {
            if item.kind == .reminder {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .white : color)
            } else if !band {
                Circle().fill(selected ? .white : color).frame(width: Space.sm, height: Space.sm)
            }
            if !band, !item.isAllDay, model.calendar.isDate(item.time, inSameDayAs: day) {
                Text(Format.time(item.time))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(Alpha.edge) : .secondary)
            }
            Text(item.title)
                .strikethrough(item.event?.isCancelled == true || (item.kind == .reminder && done))
                .foregroundStyle(selected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.app(.label, weight: band ? .semibold : .regular))
        .padding(.horizontal, Space.xs)
        .frame(height: MonthGridView.chipHeight)
        .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            .fill(selected ? color : band ? color.opacity(Alpha.cardStrong) : hovered ? Fill.hover : .clear))
        .opacity(done && !selected ? Alpha.done + 0.1 : 1)
        .onHover { hovered = $0 }
        .help("\(item.title)\n\(Format.when(item))")
        .timelineItem(item, model: model)
    }
}

// MARK: - Год

/// Год целиком, как в Календаре macOS: двенадцать месяцев сеткой 4 × 3 на
/// всё окно, без прокрутки; точки под днями со встречами. Название месяца —
/// открыть месяц, день — открыть день.
struct YearGridView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.capsuleInset) private var capsuleInset

    static let columns = 4
    static let rows = 3

    var body: some View {
        let calendar = model.calendar
        let year = calendar.component(.year, from: model.day)
        let months = (1...12).compactMap { calendar.date(from: DateComponents(year: year, month: $0, day: 1)) }
        VStack(spacing: Space.lg) {
            ForEach(0..<Self.rows, id: \.self) { row in
                HStack(spacing: Space.lg) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        if index < months.count {
                            YearMonthView(month: months[index])
                        }
                    }
                }
            }
        }
        .padding(Space.xl)
        .padding(.bottom, capsuleInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Panel())
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
        .task(id: year) { await model.loadYearBusy(year) }
    }
}

/// Месяц года: название, дни недели и шесть недель — размер чисел от
/// места, которое досталось месяцу.
private struct YearMonthView: View {
    @EnvironmentObject private var model: AppModel
    let month: Date

    var body: some View {
        let calendar = model.calendar
        let current = calendar.isDate(month, equalTo: model.now, toGranularity: .month)
        let numbers = model.showWeekNumbers
        // Всегда шесть недель: месяцы в ряду одной высоты.
        let days = MonthGrid.days(of: month, calendar: calendar)
        let padded = days + Array(repeating: nil, count: max(42 - days.count, 0))
        GeometryReader { geometry in
            // Название, строка дней недели и шесть недель — восемь строк.
            let columns = CGFloat(numbers ? 8 : 7)
            let cell = max(min(geometry.size.width / columns, (geometry.size.height - 4) / 8), 12)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    model.show(day: month)
                    model.showCalendar(.month)
                } label: {
                    Text(Format.monthName(month))
                        .font(.system(size: max(cell * 0.5, 12), weight: .semibold))
                        .foregroundStyle(current ? Palette.now : .primary)
                        .frame(maxWidth: .infinity, minHeight: cell, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Открыть месяц"))
                HStack(spacing: 0) {
                    if numbers { Color.clear.frame(width: geometry.size.width / columns) }
                    ForEach(Array(WeekdayNames.short.enumerated()), id: \.offset) { index, name in
                        Text(name)
                            .font(.system(size: max(cell * 0.3, 9)))
                            .foregroundStyle(index >= 5 ? .tertiary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: cell)
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        if numbers {
                            let week = padded[(row * 7)..<(row * 7 + 7)].compactMap { $0 }
                            Text(week.first.map { "\(NoteKeys.isoCalendar(timeZone: calendar.timeZone).component(.weekOfYear, from: $0))" } ?? "")
                                .font(.system(size: max(cell * 0.3, 9)).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: geometry.size.width / columns)
                        }
                        ForEach(0..<7, id: \.self) { column in
                            if let day = padded[row * 7 + column] {
                                YearDay(day: day, size: cell)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: cell)
                }
            }
        }
        .padding(Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(current ? Fill.accentFaint : .clear))
    }
}

private struct YearDay: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let size: CGFloat
    @ViewState private var hovered = false

    var body: some View {
        let calendar = model.calendar
        let today = calendar.isDate(day, inSameDayAs: model.now)
        let busy = model.yearBusy?.days.contains(calendar.startOfDay(for: day)) == true
        let weekend = (calendar.component(.weekday, from: day) + 5) % 7 >= 5
        Button {
            model.show(day: day)
            model.showCalendar(.day)
        } label: {
            ZStack(alignment: .bottom) {
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.system(size: max(size * 0.36, 9), weight: today ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(today ? .white : weekend ? .secondary : .primary)
                    .frame(width: size * 0.82, height: size * 0.82)
                    .background(Circle().fill(today ? Palette.now : hovered ? Fill.hover : .clear))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if busy, !today {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: Space.xs, height: Space.xs)
                        .padding(.bottom, Space.hairline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Format.dayTitle(day))
    }
}
