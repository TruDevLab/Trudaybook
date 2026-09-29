import AppKit
import SwiftUI
import TrudaybookCore

/// Состояние окна заметки: какой период открыт, редактор и помощник.
/// Живёт дольше вида: повестка, которую Trunook готовит минуту, должна
/// дойти до заметки, даже если окно успели перерисовать.
@MainActor
final class NoteWindowModel: ObservableObject {
    @Published var period: NotePeriod = .day
    let session = NoteSession()
    let assistant = NoteAssistant()
}

/// Отдельное окно заметки — дня, недели или месяца.
///
/// День — тот же, что выбран в главном окне: листая заметку, человек
/// листает и таймлайн, и заметка под календарём всегда про тот же день.
@MainActor
enum NoteWindow {
    private static var window: NSWindow?
    static let state = NoteWindowModel()

    /// Открытое окно — для отладочного снимка.
    static var current: NSWindow? { window?.isVisible == true ? window : nil }

    /// «Суббота, 27 сентября», «Неделя 39 · 21 – 27 сентября», «Сентябрь 2026».
    static func title(_ period: NotePeriod, day: Date, calendar: Calendar) -> String {
        switch period {
        case .day:
            return Format.dayTitle(day)
        case .week:
            let number = NoteKeys.isoCalendar(timeZone: calendar.timeZone).component(.weekOfYear, from: day)
            let days = NoteKeys.days(.week, containing: day, calendar: calendar)
            return String(localized: "Неделя \(number) · \(Format.weekTitle(days))")
        case .month:
            return Format.month(day)
        }
    }

    static func show(model: AppModel, period: NotePeriod? = nil) {
        let model = TourWindow.owner(model)
        if let period { state.period = period }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingView(rootView: NoteWindowView(state: state).environmentObject(model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = String(localized: "Заметка")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Пустая панель инструментов — заголовок высотой 52: кнопки окна
        // встают по центру строки периода, как в главном окне.
        window.toolbar = NSToolbar(identifier: "TrudaybookNote")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 620, height: 460)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TrudaybookNote")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

struct NoteWindowView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: NoteWindowModel
    @ObservedObject private var session: NoteSession
    @ObservedObject private var assistant: NoteAssistant

    init(state: NoteWindowModel) {
        self.state = state
        _session = ObservedObject(wrappedValue: state.session)
        _assistant = ObservedObject(wrappedValue: state.assistant)
    }

    private static let gap: CGFloat = 8

    var body: some View {
        VStack(spacing: Self.gap) {
            header
            VStack(alignment: .leading, spacing: 0) {
                if case let .failed(message, offline) = assistant.state {
                    failure(message, offline: offline)
                }
                HStack(spacing: 2) {
                    RichFormatControls(editor: session.editor, noteTools: true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider().opacity(0.5)
                ZStack(alignment: .topLeading) {
                    if session.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    NoteEditorView(controller: session.editor, autofocus: true,
                                   inset: NSSize(width: 12, height: 10), onAttach: session.attached)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
            .background(GlassPanelBackground(cornerRadius: Panel.radius))
        }
        .padding(.horizontal, Self.gap)
        .padding(.bottom, Self.gap)
        .padding(.top, 8)
        .frame(minWidth: 600, minHeight: 440)
        .ignoresSafeArea(edges: .top)
        .background {
            AppBackgroundView()
                .background(WindowAppearanceSetter(appearance: model.windowAppearance))
        }
        .environment(\.auroraTheme, model.customBackground)
        .onAppear(perform: open)
        .onChange(of: state.period) { _, _ in open() }
        .onChange(of: model.day) { _, _ in open() }
        .onChange(of: model.noteRevision) { _, _ in session.reload() }
    }

    // MARK: - Строка периода

    /// Слева — место под кнопки окна, затем период и дата; справа — Trunook.
    private var header: some View {
        HStack(spacing: 10) {
            Picker("Период", selection: $state.period) {
                Text("День").tag(NotePeriod.day)
                Text("Неделя").tag(NotePeriod.week)
                Text("Месяц").tag(NotePeriod.month)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22) }
                    .help(previousHelp)
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22) }
                    .help(nextHelp)
            }
            .buttonStyle(.borderless)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            generateButton
        }
        // Кнопки окна кончаются на 78 pt.
        .padding(.leading, 84)
        .padding(.trailing, 6)
        .frame(height: 36)
    }

    @ViewBuilder
    private var generateButton: some View {
        if case .working(let text) = assistant.state {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .glassCapsule()
        } else {
            Button(action: generate) {
                Label(generateTitle, systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .help(generateHelp)
        }
    }

    private func failure(_ message: String, offline: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if offline {
                Button("Вставить без Trunook") { assistant.insertAgendaWithoutTrunook(session: session) }
                    .help("Встречи с разделом «Протокол», напоминания и важные письма — без главного на день")
            }
            Button("Ещё раз", action: generate)
            Button { assistant.dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Закрыть")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Период

    private var title: String { NoteWindow.title(state.period, day: model.day, calendar: model.calendar) }

    private var placeholder: String {
        switch state.period {
        case .day: String(localized: "Что важно в этот день…")
        case .week: String(localized: "Планы и итоги недели…")
        case .month: String(localized: "Планы и итоги месяца…")
        }
    }

    private var generateTitle: String {
        switch state.period {
        case .day: String(localized: "Повестка дня")
        case .week: String(localized: "Итоги недели")
        case .month: String(localized: "Итоги месяца")
        }
    }

    private var generateHelp: String {
        switch state.period {
        case .day: String(localized: "Trunook соберёт повестку: главное на день, встречи с местом для протокола, напоминания и важные письма")
        case .week: String(localized: "Trunook подведёт итоги недели по заметкам дней")
        case .month: String(localized: "Trunook подведёт итоги месяца по заметкам дней")
        }
    }

    private var previousHelp: String {
        switch state.period {
        case .day: String(localized: "Предыдущий день")
        case .week: String(localized: "Предыдущая неделя")
        case .month: String(localized: "Предыдущий месяц")
        }
    }

    private var nextHelp: String {
        switch state.period {
        case .day: String(localized: "Следующий день")
        case .week: String(localized: "Следующая неделя")
        case .month: String(localized: "Следующий месяц")
        }
    }

    private func step(_ direction: Int) {
        model.show(day: NoteKeys.shift(model.day, by: direction, state.period, calendar: model.calendar))
    }

    private func open() {
        session.open(model.noteKey(state.period, for: model.day), model: model)
    }

    private func generate() {
        if state.period == .day {
            assistant.agenda(model: model, day: model.day, session: session)
        } else {
            assistant.digest(model: model, period: state.period, date: model.day, title: title, session: session)
        }
    }
}
