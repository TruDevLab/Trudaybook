import SwiftUI
import TrudaybookCore

/// Стеклянная карточка окна создания — как карточки настроек, без заголовка.
struct EditorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xl)
            .background(GlassPanelBackground(cornerRadius: Panel.radius))
    }
}

extension View {
    /// Поле ввода на стекле: лёгкая заливка вместо системной рамки.
    func editorField(padding: CGFloat = 6) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Fill.subtle))
    }
}

/// Состояние редактора: черновик и занятость участников.
@MainActor
final class EventEditorState: ObservableObject {
    @Published var draft: EventDraft
    @Published var availability: [String: PersonAvailability] = [:]
    @Published var loadedKey: String?
    @Published var askScope = false
    @Published var askDelete = false
    @Published var kind: EventEditorRequest.Kind
    /// Напоминание: список, есть ли срок и точное время.
    @Published var listID: String?
    @Published var hasDue = true
    @Published var dueHasTime = true
    /// Набранный в «Участники», но не подтверждённый адрес.
    @Published var attendeeText = ""
    /// Открыть ссылку в начале встречи; `nil` — ещё не взято из модели
    /// (общая настройка или своя отметка встречи).
    @Published var autoJoin: Bool?
    var autoJoinInitial: Bool?
    /// Выбор ссылки на созвон под «Местом» (`MeetingLinkPicker`).
    @Published var showLinkPicker = false
    let original: EventDraft

    init(request: EventEditorRequest) {
        draft = request.draft
        original = request.draft
        kind = request.kind
        listID = request.reminderListID
    }
}

/// Новая встреча или правка: название, календарь, время, повтор,
/// участники с планировщиком, место и описание.
struct EventEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: EventEditorRequest
    @StateObject private var state: EventEditorState
    @FocusState private var locationFocused: Bool

    init(request: EventEditorRequest) {
        self.request = request
        _state = StateObject(wrappedValue: EventEditorState(request: request))
    }

    private var calendarInfo: CalendarSourceInfo? {
        model.calendarSources.first { $0.id == state.draft.calendarID }
    }

    private var canInvite: Bool { calendarInfo?.supportsAttendees == true }
    private var hasGuests: Bool { !state.draft.attendees.isEmpty || !state.draft.optionalAttendees.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if request.editing == nil {
                        // Тема и описание общие — при переключении не теряются.
                        Picker("", selection: $state.kind) {
                            Label("Встреча", systemImage: "calendar").tag(EventEditorRequest.Kind.meeting)
                            Label("Напоминание", systemImage: "bell").tag(EventEditorRequest.Kind.reminder)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                        .frame(maxWidth: .infinity)
                    }
                    titleCard
                    if state.kind == .reminder {
                        reminderFields
                    } else {
                        meetingFields
                    }
                }
                .padding(Space.xxl)
            }
            footer
        }
        .frame(width: 720, height: sheetHeight)
        .animation(Motion.move, value: showsPlanner)
        // Фон — тот же, что у главного окна; поля — стеклянными карточками.
        // Под прозрачным заголовком окна — тоже фон: за него окно и тянут.
        .background { AppBackgroundView().ignoresSafeArea() }
        .onAppear {
            EventEditorWindow.fit(height: sheetHeight, model: model)
            if model.options.demo, model.options.linkPicker { state.showLinkPicker = true }
        }
        .onChange(of: sheetHeight) { _, height in EventEditorWindow.fit(height: height, model: model) }
        .environment(\.auroraTheme, model.customBackground)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard state.kind == .meeting, canInvite || model.options.demo else { return false }
            return AttachmentFiles.dropped(providers) { state.draft.attachments += $0 }
        }
        .confirmationDialog("Изменить повторяющуюся встречу", isPresented: $state.askScope) {
            ForEach(scopes(forSaving: true), id: \.self) { scope in
                Button(scope.title) { save(scope) }
            }
        } message: {
            Text(hasGuests ? "Участники получат обновлённое приглашение." : "")
        }
        .confirmationDialog(deleteTitle, isPresented: $state.askDelete) {
            if request.editing?.event?.isRecurring == true {
                ForEach(scopes(forSaving: false), id: \.self) { scope in
                    Button(scope.title, role: .destructive) { remove(scope) }
                }
            } else {
                Button("Удалить", role: .destructive) { remove(.thisEvent) }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    /// Планировщик — только когда есть кого звать.
    private var showsPlanner: Bool {
        state.kind == .meeting && hasGuests && canInvite && model.scheduling != nil && !state.draft.isAllDay
    }

    private var sheetHeight: CGFloat {
        if state.kind == .reminder { return 370 }
        return showsPlanner ? 820 : 550
    }

    // MARK: - Части

    /// 1. Тема и справа от неё — календарь (или список напоминаний).
    private var titleCard: some View {
        EditorCard {
            HStack(spacing: Space.xl) {
                TextField(state.kind == .reminder ? String(localized: "Что сделать") : String(localized: "Тема встречи"), text: $state.draft.title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                if state.kind == .reminder {
                    if !model.reminderLists.isEmpty {
                        CompactCalendarPicker(sources: model.reminderLists, selection: $state.listID)
                    }
                } else {
                    CompactCalendarPicker(sources: model.eventCalendars, selection: $state.draft.calendarID)
                }
            }
        }
    }

    /// 2–8 по порядку заполнения: когда, повтор, участники, место,
    /// планировщик (когда есть участники), описание, вложения.
    @ViewBuilder
    private var meetingFields: some View {
        EditorCard {
            timeRow
            Divider()
            labeled(String(localized: "Повтор"), systemImage: "repeat") {
                RecurrenceEditor(rule: $state.draft.recurrence, start: state.draft.start,
                                 unsupported: state.draft.hasUnsupportedRecurrence)
            }
        }
        EditorCard {
            attendeesSection
            Divider()
            labeled(String(localized: "Место"), systemImage: "mappin.and.ellipse") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        TextField("переговорная или ссылка на созвон", text: $state.draft.location)
                            .textFieldStyle(.plain)
                            .focused($locationFocused)
                            .editorField()
                        Button {
                            withAnimation(Motion.quick) { state.showLinkPicker.toggle() }
                        } label: {
                            Image(systemName: "link.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .labelHelp(String(localized: "Ссылка на созвон: свои, из прошлых встреч или новая"))
                    }
                    if state.showLinkPicker {
                        MeetingLinkPicker(location: $state.draft.location) {
                            withAnimation(Motion.quick) { state.showLinkPicker = false }
                        }
                        .transition(.opacity)
                    }
                }
                // Встали в пустое «Место» (или без ссылки) — сразу предложить
                // ссылку. Прячется выбором или крестиком, а не потерей фокуса:
                // иначе щелчок по строке списка сначала убрал бы сам список.
                .onChange(of: locationFocused) { _, focused in
                    if focused, MeetingLinkHistory.parse(state.draft.location) == nil {
                        withAnimation(Motion.quick) { state.showLinkPicker = true }
                    }
                }
            }
            Divider()
            autoJoinRow
        }
        if showsPlanner {
            EditorCard { planner }
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        EditorCard {
            notesRow(String(localized: "Описание"))
            Divider()
            labeled(String(localized: "Вложения"), systemImage: "paperclip") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    AttachmentChips(files: $state.draft.attachments)
                    if canInvite || model.options.demo {
                        Button {
                            state.draft.attachments += AttachmentFiles.choose()
                        } label: {
                            Label("Прикрепить файлы…", systemImage: "paperclip")
                        }
                        .help("Или перетащите файлы в это окно — участники получат их с приглашением")
                    } else {
                        Text("Файлы прикрепляются только ко встречам календаря Exchange.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Напоминание: срок (день или день со временем) и заметки; список — у темы.
    @ViewBuilder
    private var reminderFields: some View {
        EditorCard {
            labeled(String(localized: "Срок"), systemImage: "calendar.badge.clock") {
                HStack(spacing: Space.lg) {
                    Toggle("есть", isOn: $state.hasDue).toggleStyle(.checkbox)
                    if state.hasDue {
                        DatePicker("", selection: dayBinding, displayedComponents: .date)
                            .labelsHidden()
                            .fixedSize()
                        if state.dueHasTime {
                            DatePicker("", selection: startBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .fixedSize()
                        }
                        Toggle("со временем", isOn: $state.dueHasTime).toggleStyle(.checkbox)
                    }
                }
            }
        }
        EditorCard { notesRow(String(localized: "Заметки")) }
    }

    private func notesRow(_ title: String) -> some View {
        labeled(title, systemImage: "text.alignleft") {
            TextEditor(text: $state.draft.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: 70)
                .editorField(padding: 4)
        }
    }

    private func labeled<Content: View>(_ title: String, systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            // Значки — в своём столбце одной ширины: подписи начинаются ровно.
            HStack(spacing: Space.sm) {
                Image(systemName: systemImage).frame(width: 20)
                Text(title)
            }
            .foregroundStyle(.secondary)
            .frame(width: 112, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Подключиться самому в начале встречи: по умолчанию — как в настройках.
    private var autoJoinRow: some View {
        let link = MeetingLink.extract(url: nil, location: state.draft.location, notes: state.draft.notes)
            ?? request.editing?.event?.link
        let enabled = state.autoJoin ?? (request.editing.map(model.autoJoins) ?? model.autoJoinMeetings)
        return labeled(String(localized: "Созвон"), systemImage: "video") {
            VStack(alignment: .leading, spacing: Space.xs) {
                Toggle("Открыть ссылку на встречу в момент начала", isOn: Binding(
                    get: { enabled },
                    set: { state.autoJoin = $0 }))
                    .toggleStyle(.checkbox)
                Group {
                    if let link, link.provider != .other {
                        Text(enabled ? String(localized: "\(link.provider.rawValue) откроется сам, когда встреча начнётся.")
                                     : String(localized: "Ссылка \(link.provider.rawValue) — откроется кнопкой «Подключиться»."))
                    } else if link != nil {
                        Text("Сервис ссылки не узнан — сам он не откроется: только кнопкой «Подключиться».")
                    } else {
                        Text("Ссылки на созвон пока нет — вставьте её в «Место» или в описание.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if state.autoJoinInitial == nil { state.autoJoinInitial = enabled }
        }
    }

    /// День, начало, конец; «весь день».
    private var timeRow: some View {
        labeled(String(localized: "Когда"), systemImage: "clock") {
            HStack(spacing: Space.md) {
                DatePicker("", selection: dayBinding, displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
                if !state.draft.isAllDay {
                    DatePicker("", selection: startBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                    Text("–")
                    DatePicker("", selection: endBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                    Menu(durationTitle) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                            Button(Self.duration(minutes)) {
                                state.draft.end = state.draft.start.addingTimeInterval(Double(minutes) * 60)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Toggle("весь день", isOn: allDayBinding)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private static func duration(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: return String(localized: "\(minutes) мин")
        case 60: return String(localized: "1 час")
        case 90: return String(localized: "1,5 часа")
        default: return minutes % 60 == 0 ? String(localized: "\(minutes / 60) часа") : String(localized: "\(minutes / 60) ч \(minutes % 60) мин")
        }
    }

    private var durationTitle: String {
        Self.duration(Int(state.draft.duration / 60))
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { state.draft.start },
            set: { newDay in
                let calendar = Calendar.current
                let time = calendar.dateComponents([.hour, .minute], from: state.draft.start)
                let duration = state.draft.duration
                let start = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0,
                                          of: newDay) ?? newDay
                state.draft.start = start
                state.draft.end = start.addingTimeInterval(duration)
            }
        )
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { state.draft.start },
            set: { start in
                let duration = state.draft.duration
                state.draft.start = start
                state.draft.end = start.addingTimeInterval(duration)
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { state.draft.end },
            set: { end in
                let calendar = Calendar.current
                let time = calendar.dateComponents([.hour, .minute], from: end)
                let fixed = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0,
                                          of: state.draft.start) ?? end
                state.draft.end = fixed > state.draft.start ? fixed : state.draft.start.addingTimeInterval(15 * 60)
            }
        )
    }

    private var allDayBinding: Binding<Bool> {
        Binding(
            get: { state.draft.isAllDay },
            set: { allDay in
                let calendar = Calendar.current
                state.draft.isAllDay = allDay
                if allDay {
                    let day = calendar.startOfDay(for: state.draft.start)
                    state.draft.start = day
                    state.draft.end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                } else {
                    let start = calendar.startOfDay(for: state.draft.start).addingTimeInterval(10 * 3600)
                    state.draft.start = start
                    state.draft.end = start.addingTimeInterval(30 * 60)
                }
            }
        )
    }

    private var attendeesSection: some View {
        labeled(String(localized: "Участники"), systemImage: "person.2") {
            VStack(alignment: .leading, spacing: Space.sm) {
                if canInvite || model.options.demo {
                    PeopleField(people: $state.draft.attendees, text: $state.attendeeText)
                } else if hasGuests {
                    PersonChips(people: $state.draft.attendees)
                    InlineNotice(String(localized: "Участников можно пригласить только во встречу календаря Exchange — выберите его у темы"))
                        .font(.caption)
                } else {
                    Text("Приглашения рассылает календарь Exchange — выберите его у темы.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Планировщик

    private var myAddress: String? { model.myAddress(forCalendar: state.draft.calendarID) }

    private var plannerKey: String {
        let addresses = ([myAddress] + state.draft.attendees.map(\.address)).compactMap { $0?.lowercased() }
        return "\(EWSDay.key(state.draft.start))|\(addresses.joined(separator: ","))"
    }

    private var rows: [ScheduleRow] {
        let loaded = state.loadedKey == plannerKey
        func availability(_ address: String?) -> PersonAvailability? {
            guard loaded, let address = address?.lowercased() else { return nil }
            return state.availability[address] ?? PersonAvailability(problem: String(localized: "занятость недоступна"))
        }
        var people: [ScheduleRow] = [
            ScheduleRow(id: "me", title: String(localized: "Вы"), detail: myAddress ?? "", availability: availability(myAddress)),
        ]
        people += state.draft.attendees.enumerated().map { index, person in
            ScheduleRow(id: "p\(index)-\(person.address ?? "")", title: person.name ?? person.address ?? "",
                        detail: person.address ?? "", availability: availability(person.address))
        }
        let merged = people.compactMap(\.availability).flatMap(\.busy).filter { $0.kind != .elsewhere }
        let summary = ScheduleRow(id: "all", title: String(localized: "Все"), detail: String(localized: "Заняты хоть кто-то из участников"),
                                  availability: loaded ? PersonAvailability(busy: merged) : nil, isSummary: true)
        return [summary] + people
    }

    private var planner: some View {
        let grid = SchedulingGrid(rows: rows, day: state.draft.start, start: startBinding, duration: state.draft.duration)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Label("Планировщик", systemImage: "calendar.day.timeline.left").font(.headline)
                Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .labelHelp(String(localized: "Предыдущий день"))
                Text(Format.dayTitle(state.draft.start)).font(.callout)
                Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .labelHelp(String(localized: "Следующий день"))
                Spacer()
                Button("Ближайшее свободное время", action: findFreeSlot)
                    .disabled(state.loadedKey != plannerKey)
            }
            grid
            HStack(spacing: Space.sm) {
                if state.loadedKey != plannerKey {
                    ProgressView().controlSize(.small)
                    Text("Загружаю занятость…")
                } else if grid.busyPeople.isEmpty, !grid.hasUnknown {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                    Text("\(Format.range(state.draft.start, state.draft.end)) — все свободны")
                } else if grid.busyPeople.isEmpty {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(Palette.warning)
                    Text("\(Format.range(state.draft.start, state.draft.end)) — занятость известна не у всех")
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.danger)
                    Text("\(Format.range(state.draft.start, state.draft.end)) заняты: \(grid.busyPeople.joined(separator: ", "))")
                        .lineLimit(2)
                }
                Spacer()
                Text("Щёлкните по сетке, чтобы выбрать время")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .task(id: plannerKey) { await loadAvailability() }
    }

    private func loadAvailability() async {
        let key = plannerKey
        let found = await model.availability(for: state.draft.attendees, me: myAddress, day: state.draft.start)
        guard key == plannerKey else { return }
        state.availability = found
        state.loadedKey = key
    }

    private func shiftDay(_ offset: Int) {
        guard let moved = Calendar.current.date(byAdding: .day, value: offset, to: state.draft.start) else { return }
        let duration = state.draft.duration
        state.draft.start = moved
        state.draft.end = moved.addingTimeInterval(duration)
    }

    /// Первое время, когда свободны все, — не раньше выбранного (и не в прошлом).
    private func findFreeSlot() {
        let busy = rows.filter { !$0.isSummary }.compactMap(\.availability).filter { $0.problem == nil }.map(\.busy)
        let workdays = rows.compactMap(\.availability?.workday)
        let workday = workdays.isEmpty ? 9 * 60...19 * 60
            : (workdays.map(\.lowerBound).max() ?? 540)...(workdays.map(\.upperBound).min() ?? 1140)
        let from = max(state.draft.start, model.now)
        guard let slot = SchedulingMath.firstFreeSlot(busy: busy, from: from, duration: state.draft.duration,
                                                      workday: workday.lowerBound < workday.upperBound ? workday : 540...1140)
        else { return }
        // Нашлось в другой день — занятость того дня ещё не загружена;
        // после загрузки проверим снова.
        let sameDay = Calendar.current.isDate(slot, inSameDayAs: state.draft.start)
        startBinding.wrappedValue = slot
        if !sameDay { state.loadedKey = nil }
    }

    // MARK: - Сохранение и удаление

    private var footer: some View {
        HStack {
            if request.editing != nil {
                Button("Удалить…", role: .destructive) { state.askDelete = true }
            }
            Spacer()
            if model.isSavingEvent { ProgressView().controlSize(.small) }
            Button("Отмена") { model.eventEditor = nil }
                .keyboardShortcut(.cancelAction)
            Button(saveTitle) {
                if state.kind == .reminder {
                    saveReminder()
                } else if request.editing != nil, state.original.isRecurringSeries {
                    state.askScope = true
                } else {
                    save(.thisEvent)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(model.isSavingEvent || (state.kind == .meeting && !canInvite && hasGuests)
                      || (state.kind == .reminder && state.draft.title.trimmingCharacters(in: .whitespaces).isEmpty))
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.xl)
        .background(GlassPanelBackground(cornerRadius: 0))
    }

    private var saveTitle: String {
        if state.kind == .reminder { return String(localized: "Создать напоминание") }
        guard hasGuests, canInvite else { return String(localized: "Сохранить") }
        return request.editing == nil ? String(localized: "Отправить приглашения") : String(localized: "Сохранить и разослать")
    }

    /// «Только это» не годится, если меняли сам повтор — он есть только у серии.
    private func scopes(forSaving: Bool) -> [RecurrenceScope] {
        let recurrenceChanged = state.draft.recurrence != state.original.recurrence
        return RecurrenceScope.allCases.filter { !(forSaving && recurrenceChanged && $0 == .thisEvent) }
    }

    private func saveReminder() {
        let reminder = ReminderDraft(title: state.draft.title, due: state.hasDue ? state.draft.start : nil,
                                     hasTime: state.dueHasTime, notes: state.draft.notes, listID: state.listID)
        Task { _ = await model.saveReminder(reminder) }
    }

    private func save(_ scope: RecurrenceScope) {
        var draft = state.draft
        draft.attendees = PeopleField.merged(draft.attendees, typed: state.attendeeText)
        // Отметку встречи — только если её меняли: иначе встреча и дальше
        // следует общей настройке.
        let autoJoin = state.autoJoin.flatMap { $0 == state.autoJoinInitial ? nil : $0 }
        Task { _ = await model.saveEvent(request, draft: draft, scope: scope, autoJoin: autoJoin) }
    }

    private var deleteTitle: String {
        request.editing?.event?.isRecurring == true ? String(localized: "Удалить повторяющуюся встречу") : String(localized: "Удалить встречу?")
    }

    private var deleteMessage: String {
        guard let info = request.editing?.event else { return "" }
        if info.attendees.contains(where: { !$0.isMe }) {
            return info.canEdit ? String(localized: "Участники получат отмену встречи.") : String(localized: "Встреча удалится только из вашего календаря.")
        }
        return ""
    }

    private func remove(_ scope: RecurrenceScope) {
        guard let item = request.editing else { return }
        model.eventEditor = nil
        model.deleteEvent(item, scope: scope)
    }
}

/// Ключ дня для перезагрузки занятости.
enum EWSDay {
    static func key(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

/// Участники плашками: имя, адрес при наведении, крестик — убрать.
struct PersonChips: View {
    @Binding var people: [Person]

    var body: some View {
        CollapsingFlow(expanded: true) {
            ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                HStack(spacing: Space.xs) {
                    Text(person.name ?? person.address ?? "")
                        .lineLimit(1)
                    Button {
                        people.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .labelHelp(String(localized: "Убрать"))
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.xxs)
                .background(Capsule().fill(Fill.accentSoft))
                .help(person.address ?? "")
                .layoutValue(key: FlowRole.self, value: .item)
            }
        }
    }
}

/// Люди плашками и поле поиска под ними — участники встречи, «Кому» и
/// «Копия» письма. Набранный, но не подтверждённый адрес лежит в `text`:
/// при сохранении его забирает `PeopleField.merged`, чтобы он не потерялся.
struct PeopleField: View {
    @Binding var people: [Person]
    @Binding var text: String
    var placeholder = String(localized: "Добавить: имя или адрес")

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !people.isEmpty {
                PersonChips(people: $people)
            }
            AttendeeSearch(placeholder: placeholder, text: $text, exclude: people) { person in
                Self.add(person, to: &people)
            }
        }
    }

    static func add(_ person: Person, to people: inout [Person]) {
        guard !people.contains(where: { $0.normalizedAddress == person.normalizedAddress }) else { return }
        people.append(person)
    }

    /// Плашки плюс адреса, набранные в поле и не подтверждённые Return.
    static func merged(_ people: [Person], typed text: String) -> [Person] {
        var result = people
        for person in Person.parseList(text) where person.address?.contains("@") == true {
            add(person, to: &result)
        }
        return result
    }
}

/// Поиск человека: имя из переписки, Контактов и адресной книги Exchange
/// или адрес целиком. Return, запятая или точка с запятой — в плашку;
/// вставленный список адресов разбирается на плашки сразу.
struct AttendeeSearch: View {
    @EnvironmentObject private var model: AppModel
    var placeholder = String(localized: "Добавить: имя или адрес")
    @Binding var text: String
    /// Уже выбранные — в подсказках не нужны.
    var exclude: [Person] = []
    let add: (Person) -> Void
    @ViewState private var suggestions: [Person] = []
    @ViewState private var highlighted = 0
    @ViewState private var search: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .editorField()
                .onSubmit(submit)
                .onChange(of: text) { _, _ in
                    splitTyped()
                    lookup()
                }
                .suggestionKeys(count: suggestions.count, highlighted: $highlighted) { suggestions = [] }
            if !suggestions.isEmpty {
                SuggestionList(people: suggestions, highlighted: highlighted) { person in
                    add(person)
                    text = ""
                    suggestions = []
                }
            }
        }
    }

    private func submit() {
        if suggestions.indices.contains(highlighted) {
            add(suggestions[highlighted])
        } else {
            let typed = Person.parseList(text).filter { $0.address?.contains("@") == true }
            guard !typed.isEmpty else { return }
            typed.forEach(add)
        }
        text = ""
        suggestions = []
    }

    /// Запятая или точка с запятой после адреса — адрес уходит в плашку.
    private func splitTyped() {
        guard text.contains(",") || text.contains(";") else { return }
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ";" })
        let done = parts.dropLast().joined(separator: ",")
        let people = Person.parseList(done).filter { $0.address?.contains("@") == true }
        // Запятая внутри кавычек («"Петров, Иван"») — ещё не конец адреса.
        let quotes = done.filter { $0 == "\"" }.count
        guard !people.isEmpty, quotes % 2 == 0 else { return }
        people.forEach(add)
        text = String(parts.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func lookup() {
        search?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            suggestions = []
            return
        }
        let chosen = Set(exclude.compactMap(\.normalizedAddress))
        search = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.suggestions(for: query)
            guard !Task.isCancelled, text.trimmingCharacters(in: .whitespaces) == query else { return }
            suggestions = found.filter { !chosen.contains($0.normalizedAddress ?? "") }
            highlighted = 0
        }
    }
}
