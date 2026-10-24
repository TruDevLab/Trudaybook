import SwiftUI
import TrudaybookCore

/// Что открыто в разделе «Заметки» — живёт, пока открыто окно: вернулись
/// в раздел — та же заметка и тот же список.
@MainActor
final class NotesSectionModel: ObservableObject {
    /// Список слева: заметки дней, свободные, недель или месяцев.
    enum Mode: String {
        case day, free, week, month

        var period: NotePeriod? {
            switch self {
            case .day: .day
            case .week: .week
            case .month: .month
            case .free: nil
            }
        }
    }

    @Published var mode: Mode = .day
    @Published var selectedKey: String?
    @Published var search = ""
    @Published private(set) var notes: [StoredNote] = []
    /// Только что созданная свободная заметка: в базе её нет, пока в ней
    /// ничего не написали, а в списке она должна быть сразу.
    @Published private(set) var pendingKey: String?
    let session = NoteSession()
    /// Повестка дня и итоги недели или месяца — как в окне заметки.
    let assistant = NoteAssistant()

    func reload(model: AppModel) {
        notes = model.allNotes()
        if let pendingKey, notes.contains(where: { $0.key == pendingKey }) { self.pendingKey = nil }
    }

    func open(_ key: String, model: AppModel) {
        if let pendingKey, pendingKey != key { self.pendingKey = nil }
        selectedKey = key
        session.open(key, model: model)
    }

    func newNote(model: AppModel) {
        let key = NoteKeys.newFreeKey()
        mode = .free
        search = ""
        pendingKey = key
        open(key, model: model)
        session.editor.focus()
    }
}

/// Раздел «Заметки»: слева список — по датам (дни, недели, месяцы) или
/// свои, с названием; справа — та же заметка, что в окне заметки.
struct NotesSectionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var state: NotesSectionModel
    @ObservedObject private var session: NoteSession
    @ObservedObject private var assistant: NoteAssistant
    @AppStorage("noteOnWhite") private var paper = false
    @FocusState private var searchFocused: Bool
    @ViewState private var deleting: String?

    static let state = NotesSectionModel()
    static let listWidth: CGFloat = 300

    init() {
        _state = ObservedObject(wrappedValue: Self.state)
        _session = ObservedObject(wrappedValue: Self.state.session)
        _assistant = ObservedObject(wrappedValue: Self.state.assistant)
    }

    var body: some View {
        SectionPage(.notes, capsule: capsule) {
            HStack(spacing: MainView.gap) {
                list.frame(width: Self.listWidth)
                editor
            }
        }
        .onAppear {
            model.seedDemoNotes()
            state.reload(model: model)
            // Первый раз — заметка на сегодня: с неё обычно и начинают.
            if state.selectedKey == nil { state.open(model.noteKey(.day, for: model.now), model: model) }
            // Курсор — в заметку: иначе окно отдаёт его первому полю, поиску.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { session.editor.focus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .noteEdited)) { _ in state.reload(model: model) }
        .onChange(of: model.noteRevision) { _, _ in
            state.reload(model: model)
            session.reload()
        }
        .confirmationDialog(String(localized: "Удалить заметку?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { key in
            Button("Удалить", role: .destructive) { delete(key) }
        } message: { _ in
            Text("Заметка хранится только на этом Mac — вернуть её будет нельзя.")
        }
    }

    // MARK: - Список

    private struct Row: Identifiable {
        let key: String
        let title: String
        let detail: String
        let updated: Date?
        var id: String { key }
    }

    private var rows: [Row] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        let matching = state.notes.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        if let period = state.mode.period {
            // Заметки периода — свежие сверху.
            let dated = matching.compactMap { note -> (StoredNote, Date)? in
                guard let parsed = NoteKeys.parse(note.key, calendar: model.calendar), parsed.period == period else { return nil }
                return (note, parsed.date)
            }
            var result = dated
                .sorted { $0.1 > $1.1 }
                .map { note, date in
                    Row(key: note.key, title: NoteWindow.title(period, day: date, calendar: model.calendar),
                        detail: Self.snippet(note.text, skippingTitle: false), updated: note.updated)
                }
            // Заметки на этот день, неделю или месяц ещё нет — строка для
            // неё всё равно первая.
            let current = model.noteKey(period, for: model.now)
            if query.isEmpty, !result.contains(where: { $0.key == current }) {
                result.insert(Row(key: current, title: NoteWindow.title(period, day: model.now, calendar: model.calendar),
                                  detail: Self.placeholder(period), updated: nil), at: 0)
            }
            return result
        }
        switch state.mode {
        case .day, .week, .month:
            return []
        case .free:
            var result = matching.filter { NoteKeys.isFreeKey($0.key) }.map { note in
                Row(key: note.key, title: NoteKeys.title(of: note.text) ?? String(localized: "Новая заметка"),
                    detail: Self.snippet(note.text, skippingTitle: true), updated: note.updated)
            }
            if let pending = state.pendingKey, !result.contains(where: { $0.key == pending }) {
                result.insert(Row(key: pending, title: String(localized: "Новая заметка"), detail: "", updated: nil), at: 0)
            }
            return result
        }
    }

    static func placeholder(_ period: NotePeriod) -> String {
        switch period {
        case .day: String(localized: "Что важно в этот день…")
        case .week: String(localized: "Планы и итоги недели…")
        case .month: String(localized: "Планы и итоги месяца…")
        }
    }

    /// Другой список — и заметка из него: текущего дня, недели, месяца или
    /// последняя своя (своих нет — новая).
    private func choose(_ mode: NotesSectionModel.Mode) {
        state.mode = mode
        if let period = mode.period {
            state.open(model.noteKey(period, for: model.now), model: model)
        } else if let last = state.notes.first(where: { NoteKeys.isFreeKey($0.key) }) {
            state.open(last.key, model: model)
        } else {
            state.newNote(model: model)
        }
    }

    /// Вторая строка: начало текста (у своих заметок — после названия).
    static func snippet(_ text: String, skippingTitle: Bool) -> String {
        let markers = [NoteMarkers.bullet, NoteMarkers.unchecked, NoteMarkers.checked]
        let lines = text.split(whereSeparator: \.isNewline)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                for marker in markers where line.hasPrefix(marker) { line.removeFirst(marker.count) }
                return line
            }
            .filter { !$0.isEmpty }
        return lines.dropFirst(skippingTitle ? 1 : 0).prefix(2).joined(separator: " · ")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в заметках", text: $state.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !state.search.isEmpty {
                    Button { state.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .labelHelp(String(localized: "Очистить поиск"))
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Fill.subtle))
            let rows = rows
            if rows.isEmpty {
                EmptyState(symbol: state.search.isEmpty ? "note.text" : "magnifyingglass",
                           text: state.search.isEmpty ? String(localized: "Заметок пока нет") : String(localized: "Ничего не нашлось"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Space.xxs) {
                        ForEach(rows) { row in
                            // Время правки — у своих: у заметок по датам дата уже в названии.
                            NoteRow(title: row.title, detail: row.detail,
                                    updated: state.mode == .free ? row.updated : nil, now: model.now,
                                    selected: state.selectedKey == row.key) {
                                state.open(row.key, model: model)
                            }
                            .contextMenu {
                                if row.updated != nil {
                                    Button("Удалить…", role: .destructive) { deleting = row.key }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Panel())
        // Прокрутка на macOS 26 рисует за своей рамкой — обрезать по панели.
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
    }

    // MARK: - Редактор

    /// Период открытой заметки; у своей — `nil` (собирать нечего).
    private var period: (period: NotePeriod, date: Date)? {
        state.selectedKey.flatMap { NoteKeys.parse($0, calendar: model.calendar) }
    }

    private var generateTitle: String? {
        switch period?.period {
        case .day: String(localized: "Повестка дня")
        case .week: String(localized: "Итоги недели")
        case .month: String(localized: "Итоги месяца")
        case nil: nil
        }
    }

    private var generateHelp: String {
        switch period?.period {
        case .week: String(localized: "Модель подведёт итоги недели по заметкам дней")
        case .month: String(localized: "Модель подведёт итоги месяца по заметкам дней")
        default: String(localized: "Модель соберёт повестку: главное на день, встречи с местом для протокола, напоминания и важные письма")
        }
    }

    private func generate() {
        guard let period else { return }
        if period.period == .day {
            assistant.agenda(model: model, day: period.date, session: session)
        } else {
            assistant.digest(model: model, period: period.period, date: period.date,
                             title: NoteWindow.title(period.period, day: period.date, calendar: model.calendar), session: session)
        }
    }

    @ViewBuilder private var assistantLine: some View {
        switch assistant.state {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: Space.md) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.sm)
        case let .failed(message, offline):
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                InlineNotice(message).font(.callout)
                Spacer(minLength: Space.md)
                if offline {
                    Button("Вставить без модели") { assistant.insertAgendaWithoutModel(session: session) }
                }
                Button("Ещё раз", action: generate)
                Button { assistant.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .labelHelp(String(localized: "Закрыть"))
            }
            .controlSize(.small)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.md)
            .background(Palette.warning.opacity(Alpha.wash))
        }
    }

    private var editorTitle: String {
        guard let key = state.selectedKey else { return "" }
        if let parsed = NoteKeys.parse(key, calendar: model.calendar) {
            return NoteWindow.title(parsed.period, day: parsed.date, calendar: model.calendar)
        }
        return NoteKeys.title(of: model.noteContent(key).text) ?? String(localized: "Новая заметка")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xxs) {
                Text(editorTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.trailing, Space.md)
                RichFormatControls(editor: session.editor, noteTools: true)
                Spacer(minLength: Space.md)
                // Модель — у заметок по датам; у своей собирать нечего.
                if let generateTitle {
                    Button { if !assistant.isWorking { generate() } } label: {
                        Label(generateTitle, systemImage: "sparkles")
                    }
                    .disabled(assistant.isWorking)
                    .help(generateHelp)
                }
                Button { paper.toggle() } label: {
                    Image(systemName: paper ? "doc.fill" : "doc")
                        .foregroundStyle(paper ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .labelHelp(paper ? String(localized: "Белый лист включён — показать без него")
                                 : String(localized: "Заметка на белом листе и в тёмной теме"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            Divider().opacity(0.5)
            assistantLine
            ZStack(alignment: .topLeading) {
                if paper { Color.white }
                if session.isEmpty {
                    Text(period.map { Self.placeholder($0.period) } ?? String(localized: "Первая строка станет названием…"))
                        .foregroundStyle(paper ? Color.black.opacity(Alpha.disabled) : Color.secondary)
                        .padding(.horizontal, Space.xxl)
                        .padding(.vertical, Space.lg)
                        .allowsHitTesting(false)
                }
                NoteEditorView(controller: session.editor, inset: NSSize(width: 12, height: 10),
                               onAttach: session.attached, paper: paper)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Panel())
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
    }

    // MARK: - Капсула

    private var capsule: SectionCapsule {
        func item(_ mode: NotesSectionModel.Mode, _ title: String, _ symbol: String) -> CapsuleItem {
            CapsuleItem(id: mode.rawValue, title: title, symbol: symbol, selected: state.mode == mode) { choose(mode) }
        }
        return SectionCapsule(
            leading: [item(.day, String(localized: "Ежедневные"), "sun.max"),
                      item(.free, String(localized: "Свободная"), "note.text")],
            trailing: [item(.week, String(localized: "Недельная"), "calendar.day.timeline.left"),
                       item(.month, String(localized: "Месячная"), "calendar")],
            plusHelp: plusHelp
        ) {
            if let period = state.mode.period {
                state.open(model.noteKey(period, for: model.now), model: model)
                session.editor.focus()
            } else {
                state.newNote(model: model)
            }
        }
    }

    /// «+» — новая своя заметка или заметка текущего периода.
    private var plusHelp: String {
        switch state.mode {
        case .day: String(localized: "Заметка на сегодня")
        case .week: String(localized: "Заметка на эту неделю")
        case .month: String(localized: "Заметка на этот месяц")
        case .free: String(localized: "Новая заметка")
        }
    }

    private func delete(_ key: String) {
        model.saveNote("", rich: nil, key: key)
        if state.selectedKey == key {
            state.open(model.noteKey(.day, for: model.now), model: model)
        }
        state.reload(model: model)
    }
}

private struct NoteRow: View {
    let title: String
    let detail: String
    let updated: Date?
    let now: Date
    let selected: Bool
    let action: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                HStack(spacing: Space.sm) {
                    if let updated {
                        Text(Format.relative(updated, now: now))
                            .foregroundStyle(.secondary)
                    }
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(selected ? Fill.accentSoft : hovered ? Fill.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
