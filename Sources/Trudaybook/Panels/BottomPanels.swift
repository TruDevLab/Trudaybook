import SwiftUI
import TrudaybookCore

/// Строка элемента — в «Не разобрано» и в раскрытой пачке писем.
struct ItemRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    var onSelect: (() -> Void)?

    var body: some View {
        let status = model.status(of: item)
        let selected = model.isSelected(item.id)
        let unread = item.kind == .mail && !model.isRead(item)
        let priority = model.priority(of: item)

        HStack(spacing: 8) {
            // Прочитанное — открытый конверт, новое — закрытый.
            Image(systemName: item.kind == .mail && !unread ? "envelope.open" : item.symbol)
                .foregroundStyle(item.kind == .reminder ? Color.orange : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: unread ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(model.subtitle(of: item)) · \(Format.relative(model.effectiveTime(of: item), now: model.now))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let label = model.label(of: item) {
                LabelChip(label: label, source: model.labelSource(of: item))
            }
            // Приоритет — справа, в одном столбце у всех строк: так его видно,
            // пробегая список глазами, и тема не сдвигается.
            PriorityMark(priority: priority)
            switch status {
            case .done(let reason):
                Text(reason.title).font(.caption).foregroundStyle(.green)
            case .snoozed(let until):
                Label(Format.relative(until, now: model.now), systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange)
            case .open, .upcoming:
                if model.isInvitation(item) {
                    Image(systemName: "calendar.badge.clock").font(.caption).foregroundStyle(Color.accentColor)
                        .help("Приглашение на встречу")
                }
                if item.mail?.hasAttachments == true {
                    Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Двойное нажатие: письмо — в отдельное окно, встреча и
            // напоминание — к их дню на таймлайне.
            model.selectedID = item.id
            if item.kind == .mail {
                LetterWindow.show(item, model: model)
            } else {
                model.show(day: model.effectiveTime(of: item))
            }
            onSelect?()
        }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.click(item, extend: flags.contains(.shift), toggle: flags.contains(.command))
            onSelect?()
        }
        .itemDraggable(item)
        .contextMenu { ItemContextMenu(item: item) }
    }
}

extension View {
    /// Строка системного списка без его отступов, разделителей и фона —
    /// выглядит, как прежняя стопка строк.
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0.5, leading: 0, bottom: 0.5, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Значок приоритета справа в строке: ⌃⌃ красный, = оранжевый, ⌄ синий.
struct PriorityMark: View {
    let priority: Priority

    var body: some View {
        if priority != .none {
            Image(systemName: priority.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(priority.color)
                .frame(width: 16)
                .help("Приоритет: \(priority.title.lowercased())")
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .none: .secondary
        case .high: .red
        case .medium: .orange
        case .low: .blue
        }
    }
}

/// Выбор приоритета — в меню правой кнопки и в правой панели.
struct PriorityPicker: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    let current: Priority

    var body: some View {
        Section("Приоритет") {
            ForEach([Priority.high, .medium, .low, .none]) { priority in
                Toggle(isOn: Binding(get: { current == priority },
                                     set: { if $0 { model.setPriority(priority, for: id) } })) {
                    Label("\(priority.title)  ⌘\(priority.key)", systemImage: priority.symbol)
                }
            }
        }
    }
}

/// Нижний список: «Не разобрано», Входящие, Отправленные, Архив и прочие
/// папки ящика, с поиском.
///
/// Набор в поле поиска фильтрует список сразу — по теме и людям. Return
/// ищет и в тексте писем на сервере: это дольше, поэтому только по просьбе.
struct MailListPanel: View {
    @EnvironmentObject private var model: AppModel

    /// Папки на вкладках — в порядке и выборе из настроек; остальные — в меню «Ещё».
    private var primary: [MailFolder] {
        model.orderedFolders.filter(model.isTab)
    }

    private var others: [MailFolder] {
        model.orderedFolders.filter { !model.isTab($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                // Вкладки прокручиваются: их столько, сколько выбрано в
                // настройках, и раздвигать панель они не должны.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        tab(String(localized: "Не разобрано"), count: model.unresolved.count, mode: .unresolved)
                        ForEach(primary) { folder in
                            tab(folder.name, count: nil, mode: .folder(folder.id))
                        }
                    }
                }
                .layoutPriority(1)
                if !others.isEmpty {
                    Menu {
                        // Когда ящиков несколько — папки каждого под его адресом.
                        ForEach(otherGroups, id: \.name) { group in
                            if let name = group.name {
                                Section(name) {
                                    ForEach(group.folders) { folder in
                                        Button(folder.path) { model.show(list: .folder(folder.id)) }
                                    }
                                }
                            } else {
                                ForEach(group.folders) { folder in
                                    Button(folder.path) { model.show(list: .folder(folder.id)) }
                                }
                            }
                        }
                    } label: {
                        Text(currentOtherName ?? String(localized: "Ещё"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 170)
                    .fixedSize(horizontal: currentOtherName == nil, vertical: false)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(currentOtherName == nil ? .clear : Color.accentColor.opacity(0.18)))
                }
                Spacer(minLength: 8)
                if model.isLoadingList { ProgressView().controlSize(.small) }
                // Стрелки сортировки, а не воронка: воронка — это фильтр
                // (она же у «скрыть разобранные»), а здесь меняется порядок.
                // Включено — рядом флажок: «по приоритету».
                Button { model.sortByPriority.toggle() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.arrow.down")
                        if model.sortByPriority {
                            Image(systemName: "flag.fill").font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(model.sortByPriority ? Color.accentColor : .secondary)
                    .padding(.horizontal, model.sortByPriority ? 6 : 4)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(model.sortByPriority ? Color.accentColor.opacity(0.18) : .clear))
                }
                .buttonStyle(.borderless)
                .help(model.sortByPriority
                      ? "Сейчас сначала важное. Нажмите — по времени"
                      : "Сортировать по приоритету: сначала высокий, потом средний и низкий")
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { model.searchOnServer() }
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .frame(minWidth: 80, maxWidth: 210)
                .help("Набор ищет по теме и людям, Return — ещё и в тексте писем на сервере")
            }

            if model.listMode == .unresolved, model.searchResults == nil, !model.unresolved.isEmpty {
                LabelFilterBar()
            }

            if let results = model.searchResults {
                HStack {
                    Text("В тексте писем найдено: \(results.count)")
                    Spacer()
                    Button("Сбросить") { model.searchText = "" }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            } else if !model.searchText.isEmpty {
                Button("Искать «\(model.searchText)» в тексте писем на сервере  ⏎") { model.searchOnServer() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.horizontal, 6)
            }

            let items = model.listItems
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: emptySymbol)
                        .font(.system(size: 26))
                        .foregroundStyle(model.listMode == .unresolved && model.searchText.isEmpty ? .green : .secondary)
                    Text(emptyText).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    // Системный список, а не стопка строк: только в нём
                    // работают свайпы двумя пальцами по трекпаду.
                    List {
                        if let sections = model.listSections {
                            ForEach(sections, id: \.section) { group in
                                let collapsed = model.collapsedSections.contains(group.section.key)
                                SectionHeader(title: title(of: group.section), count: group.items.count,
                                              collapsed: collapsed) { model.toggleSection(group.section) }
                                    .plainListRow()
                                if !collapsed {
                                    ForEach(group.items) { item in
                                        row(item)
                                    }
                                }
                            }
                        } else {
                            ForEach(items) { item in
                                row(item)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 1)
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    // Стрелками ушли к письму за краем — список следует за выбором.
                    .onChange(of: model.selectedID) { _, id in
                        guard let id, items.contains(where: { $0.id == id }) else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Panel())
    }

    /// Строка со свайпами: влево — действие справа, вправо — слева.
    private func row(_ item: TimelineItem) -> some View {
        ItemRow(item: item)
            .id(item.id)
            .plainListRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { swipeButton(model.swipeLeft, item) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { swipeButton(model.swipeRight, item) }
    }

    @ViewBuilder
    private func swipeButton(_ action: SwipeAction, _ item: TimelineItem) -> some View {
        if model.canSwipe(action, on: item) {
            Button { model.performSwipe(action, on: item) } label: {
                Label(model.swipeTitle(action, on: item), systemImage: action.symbol)
            }
            .tint(action.tint)
        }
    }

    private func title(of section: DateSection) -> String {
        switch section {
        case .today: String(localized: "Сегодня")
        case .yesterday: String(localized: "Вчера")
        case .day(let date): Format.dayTitle(date)
        case .olderThanWeek: String(localized: "Старше 7 дней")
        case .olderThanMonth: String(localized: "Старше 30 дней")
        }
    }

    /// Прочие папки по ящикам, в порядке подключения.
    private var otherGroups: [(name: String?, folders: [MailFolder])] {
        var groups: [(name: String?, folders: [MailFolder])] = []
        for folder in others {
            if let last = groups.indices.last, groups[last].name == folder.accountName {
                groups[last].folders.append(folder)
            } else {
                groups.append((folder.accountName, [folder]))
            }
        }
        return groups
    }

    /// Выбранная папка из «Ещё»: её имя и, если ящиков несколько, чья она.
    private var currentOtherName: String? {
        guard case .folder(let id) = model.listMode, let folder = others.first(where: { $0.id == id }) else { return nil }
        guard let box = folder.accountName else { return folder.name }
        return "\(folder.name) · \(box.split(separator: "@").first.map(String.init) ?? box)"
    }

    private var emptySymbol: String {
        if !model.searchText.isEmpty { return "magnifyingglass" }
        return model.listMode == .unresolved ? "checkmark.seal" : "tray"
    }

    private var emptyText: String {
        if !model.searchText.isEmpty { return String(localized: "Ничего не нашлось") }
        if model.isLoadingList { return String(localized: "Загружаю…") }
        return model.listMode == .unresolved ? String(localized: "Всё разобрано") : String(localized: "Папка пуста")
    }

    private func tab(_ title: String, count: Int?, mode: AppModel.ListMode) -> some View {
        let selected = model.listMode == mode
        return Button {
            model.show(list: mode)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(count == 0 ? Color.green.opacity(0.2) : Color.orange.opacity(0.25)))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Календарь месяца: выбор дня переключает таймлайн, точка — есть встречи.
struct MonthCalendarView: View {
    @EnvironmentObject private var model: AppModel

    private var days: [Date?] {
        let calendar = model.calendar
        guard let interval = calendar.dateInterval(of: .month, for: model.monthAnchor) else { return [] }
        // Неделя с понедельника, как принято в России, независимо от настроек.
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday + 5) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        var day = interval.start
        while day < interval.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { model.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(Format.month(model.monthAnchor)).font(.headline)
                Spacer()
                Button { model.showWeekNumbers.toggle() } label: {
                    Image(systemName: "number")
                        .foregroundStyle(model.showWeekNumbers ? Color.accentColor : .secondary)
                }
                .help(model.showWeekNumbers ? String(localized: "Скрыть номера недель") : String(localized: "Показать номера недель"))
                Button { model.shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            let weeks = model.showWeekNumbers
            let columns = (weeks ? [GridItem(.fixed(26), spacing: 2)] : [])
                + Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                if weeks {
                    Text("Нед").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach([String(localized: "Пн"), String(localized: "Вт"), String(localized: "Ср"), String(localized: "Чт"), String(localized: "Пт"), String(localized: "Сб"), String(localized: "Вс")], id: \.self) { name in
                    Text(name).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    if weeks, index % 7 == 0 {
                        WeekNumberCell(week: Array(days[index..<min(index + 7, days.count)]).compactMap { $0 })
                    }
                    if let day {
                        DayCell(day: day)
                    } else {
                        Color.clear.frame(height: 26)
                    }
                }
            }
        }
        .padding(10)
        .background(Panel())
    }
}

private struct DayCell: View {
    @EnvironmentObject private var model: AppModel
    let day: Date

    var body: some View {
        let calendar = model.calendar
        let selected = calendar.isDate(day, inSameDayAs: model.day)
        let today = calendar.isDate(day, inSameDayAs: model.now)
        let weekend = calendar.isDateInWeekend(day)

        Button {
            model.show(day: day)
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : (weekend ? Color.secondary : Color.primary))
                HStack(spacing: 2) {
                    Circle()
                        .fill(model.busyDays.contains(day) ? (selected ? Color.white : Color.accentColor) : .clear)
                        .frame(width: 4, height: 4)
                    // Есть заметка на день — вторая точка, янтарная.
                    if model.hasNote(day) {
                        Circle()
                            .fill(selected ? Color.white : Palette.amber)
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(today && !selected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// «Перенести»: быстрые варианты и своё время.
struct RescheduleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    @ViewState private var custom = Date()

    private var options: [RescheduleOption] {
        RescheduleOptions.options(for: item, now: model.now)
    }

    private var heading: String {
        switch item.kind {
        case .mail: return String(localized: "Отложить письмо")
        case .event: return String(localized: "Перенести встречу")
        case .reminder: return String(localized: "Перенести напоминание")
        }
    }

    private var explanation: String {
        switch item.kind {
        case .mail:
            return String(localized: "Письмо уйдёт с глаз и вернётся на таймлайн в выбранное время.")
        case .event:
            let recurring = item.event?.isRecurring == true ? String(localized: " Переносится только это вхождение повторяющейся встречи.") : ""
            return String(localized: "Сейчас: \(Format.range(item.time, item.end)). Длительность сохранится.\(recurring)")
        case .reminder:
            return String(localized: "Срок напоминания изменится в «Напоминаниях».")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.title3.weight(.semibold))
                Text("«\(item.title)»").lineLimit(2)
                Text(explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(options) { option in
                    Button {
                        model.reschedule(item, to: option.date)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(.body.weight(.medium))
                            Text(Format.relative(option.date, now: model.now))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                DatePicker("Своё время", selection: $custom, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Перенести") {
                    model.reschedule(item, to: custom)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            custom = options.first?.date ?? item.time.addingTimeInterval(3600)
        }
    }
}

/// Номер недели по ISO 8601 — как в российских календарях: неделя
/// с понедельника, первая — та, где первый четверг года. Щелчок — к понедельнику.
struct WeekNumberCell: View {
    @EnvironmentObject private var model: AppModel
    let week: [Date]

    static let iso = Calendar(identifier: .iso8601)

    var body: some View {
        if let first = week.first {
            let number = Self.iso.component(.weekOfYear, from: first)
            let current = week.contains { model.calendar.isDate($0, inSameDayAs: model.day) }
            Button { model.show(day: first) } label: {
                Text("\(number)")
                    .font(.caption2.monospacedDigit().weight(current ? .semibold : .regular))
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.plain)
            .help("Неделя \(number)")
        } else {
            Color.clear.frame(height: 26)
        }
    }
}

/// Заметка на выбранный день — под календарём месяца. Хранится только на
/// этом Mac (`ItemStateStore`, таблица `day_notes`), в журнал не пишется.
/// Оформление — то же, что в окне заметки; кнопки оформления и повестка —
/// там, здесь для них мало места.
struct DayNotePanel: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var session = NoteSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                Text("Заметка · \(Format.dayTitle(model.day))")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { NoteWindow.show(model: model, period: .day) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Открыть заметку в окне: оформление, списки, повестка дня")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if session.isEmpty {
                    Text("Что важно в этот день…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                NoteEditorView(controller: session.editor, inset: NSSize(width: 0, height: 1), onAttach: session.attached)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Panel())
        .onAppear(perform: open)
        .onChange(of: model.day) { _, _ in open() }
        .onChange(of: model.noteRevision) { _, _ in session.reload() }
    }

    private func open() {
        session.open(model.noteKey(.day, for: model.day), model: model)
    }
}

/// Заголовок раздела «Не разобрано»: стрелка, название, число писем.
/// Щелчок сворачивает и разворачивает раздел.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(collapsed ? String(localized: "Развернуть") : String(localized: "Свернуть"))
    }
}
