import SwiftUI
import TrudaybookCore

/// Чат с ассистентом — в правой панели вместо выбранного письма или встречи.
///
/// Сверху — вкладки разговоров и «закрыть», посередине — разговор (прижат
/// к низу: новое появляется над полем ввода и уходит вверх), внизу — поле
/// вопроса, справа от него приложить, модель, голос и «отправить».
/// Предложенные ассистентом действия — карточками под его ответом: без
/// нажатия ничего не делается.
struct AssistantChatView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: AssistantSession
    @ObservedObject var ai: LocalAI
    @StateObject private var voice = VoiceInput()
    @ViewState private var question = ""
    /// Что было в поле до голоса: распознанное дописывается после него.
    @ViewState private var beforeVoice = ""
    @FocusState private var focused: Bool
    /// Размер текста в чате — кнопками в шапке.
    @AppStorage("assistantTextSize") private var textSize = Double(ChatTextSize.standard)
    /// Подсвеченная строка списка под `/mail` и `/cal`.
    @ViewState private var highlight = 0
    /// Список закрыли (Esc) — до следующей правки поля.
    @ViewState private var popupClosed = false
    /// Встречи для `/cal`: месяц назад — три вперёд, загружаются при первой команде.
    @ViewState private var eventPool: [TimelineItem]?
    /// Плитка ждёт выбора письма или встречи — выбор сразу отправит её вопрос.
    @ViewState private var pendingTile: AssistantTile?

    static let tabsHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            // Место под вкладки; сами вкладки — поверх (`overlay` ниже).
            // Прокрутка разговора на macOS 26 растягивает свою рамку до верха
            // окна и забирает щелчки у всего, что над ней в той же стопке:
            // кнопки шапки не нажимались. Нарисованное позже — выше неё.
            Color.clear.frame(height: Self.tabsHeight)
            Divider()
            conversation
            Divider()
            input
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                tabs.frame(height: Self.tabsHeight)
                if let problem = ai.problem {
                    Divider()
                    HStack(spacing: Space.md) {
                        InlineNotice(problem).font(.callout)
                        Spacer(minLength: Space.md)
                        Button("Настройки") { SettingsWindow.show(model: model, tab: .ai) }
                            .controlSize(.small)
                    }
                    .padding(Space.lg)
                    .background(GlassPanelBackground(fallback: Color(nsColor: .textBackgroundColor)))
                }
            }
        }
        .environment(\.chatTextSize, CGFloat(textSize))
        .task {
            await ai.refresh()
            session.refreshCapabilities()
        }
        .onAppear {
            focused = true
            if let id = model.options.tile, session.entries.isEmpty, let tile = AssistantTile.all.first(where: { $0.id == id }) {
                // Снимок: дать окну дорисоваться — плитка ждёт открытого письма.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(tile) }
            }
            if let text = model.options.chatInput, question.isEmpty { question = text.replacingOccurrences(of: "\\n", with: "\n") }
            voice.onText = { text in
                question = beforeVoice.isEmpty ? text : beforeVoice + " " + text
            }
        }
        .onDisappear { voice.stop() }
    }

    // MARK: - Вкладки

    private var tabs: some View {
        HStack(spacing: Space.sm) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.xs) {
                        ForEach(session.dialogs) { dialog in
                            DialogTab(dialog: dialog, session: session).id(dialog.id)
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .onChange(of: session.currentID) { _, id in
                    withAnimation(Motion.quick) { proxy.scrollTo(id) }
                }
            }
            HStack(spacing: 0) {
                Button { textSize = Double(ChatTextSize.step(CGFloat(textSize), by: -1)) } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(CGFloat(textSize) <= ChatTextSize.steps[0])
                .labelHelp(String(localized: "Уменьшить текст в чате"))
                Button { textSize = Double(ChatTextSize.step(CGFloat(textSize), by: 1)) } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(CGFloat(textSize) >= ChatTextSize.steps[ChatTextSize.steps.count - 1])
                .labelHelp(String(localized: "Увеличить текст в чате"))
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 16)
            Button { session.newDialog() } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("t", modifiers: .command)
            .labelHelp(String(localized: "Новый разговор (⌘T)"))
            Button { withAnimation(Motion.move) { model.assistantOpen = false } } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .labelHelp(String(localized: "Закрыть чат (⌥⌘A)"))
        }
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Разговор

    private var conversation: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if session.entries.isEmpty {
                            intro
                        }
                        ForEach(session.entries) { entry in
                            ChatBubble(entry: entry, session: session)
                                .id(entry.id)
                        }
                    }
                    .padding(Space.xxl)
                    // Прижато к низу: короткий разговор стоит над полем ввода,
                    // длинный уходит вверх.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottomLeading)
                }
                // Пустой разговор — плитки сверху (в половину окна они не всегда
                // влезают), разговор — с последней реплики.
                .defaultScrollAnchor(session.entries.isEmpty ? .top : .bottom)
                .onChange(of: session.entries.last?.text) { _, _ in
                    if let last = session.entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: session.entries.count) { _, _ in
                    if let last = session.entries.last?.id {
                        withAnimation(Motion.quick) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        // Прокрутка на macOS 26 рисует содержимое и выше своей рамки — под
        // вкладками проступал прокрученный вверх ответ. Обрезать по рамке.
        .clipped()
        // Своя прокрутка у каждой вкладки: переключились — и внизу.
        .id(session.currentID)
    }

    /// Начало разговора: плитки готовых просьб — нажали, и дальше минимум.
    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("Выберите, с чего начать, или спросите сами. Отвечает модель на этом Mac; письмо, встречу и запись в заметку вы подтверждаете сами. Приложить письмо или встречу — /mail или /cal и слова из темы.")
                .font(.chat(CGFloat(textSize), -2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AssistantTilesView(openLetter: model.selectedItem.flatMap { $0.kind == .mail ? $0.title : nil },
                               openEvent: model.selectedItem.flatMap { $0.kind == .event ? $0.title : nil },
                               disabled: ai.problem != nil || session.busy,
                               run: run)
        }
    }

    // MARK: - Плитки

    /// Нажали плитку. Всё, что можно взять само, берётся само; не хватает
    /// письма или встречи — команда в поле, и после выбора вопрос уходит сам.
    private func run(_ tile: AssistantTile) {
        guard !session.busy else { return }
        let selected = model.selectedItem
        switch tile.run {
        case .ask(let prompt):
            session.send(prompt, title: tile.title)
        case .letter(let prompt):
            if let item = selected, item.kind == .mail {
                session.attachLetter(item)
                session.send(prompt, title: tile.title)
            } else {
                choose(.mail, for: tile)
            }
        case .event(let prompt):
            if let item = selected, item.kind == .event {
                session.attachEvent(item)
                session.send(prompt, title: tile.title)
                return
            }
            Task {
                if let next = await nextMeeting() {
                    session.attachEvent(next)
                    session.send(prompt, title: tile.title)
                } else {
                    choose(.cal, for: tile)
                }
            }
        case .template(let text):
            question = text
            focused = true
        }
    }

    /// Ближайшая встреча: идущая сейчас или следующая в ближайшую неделю.
    private func nextMeeting() async -> TimelineItem? {
        let now = model.now
        let items = await model.calendarItems(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(7 * 86_400))
        return items
            .filter { $0.kind == .event && !$0.isAllDay && $0.event?.isCancelled != true && ($0.end ?? $0.time) > now }
            .min { $0.time < $1.time }
    }

    /// Письма или встречи для плитки нет — выбрать: команда в поле, список
    /// подходящих сразу открыт, выбор отправит вопрос плитки.
    private func choose(_ kind: ChatCommand.Kind, for tile: AssistantTile) {
        pendingTile = tile
        question = "/" + kind.names[0] + " "
        if kind == .cal, eventPool == nil { loadEvents() }
        focused = true
    }

    // MARK: - Ввод

    private var input: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(session.attachments) { attachment in
                            AttachmentChip(attachment: attachment) { session.detach(attachment.id) }
                        }
                    }
                }
            }
            if case .failed(let problem) = voice.state {
                HStack(alignment: .top, spacing: Space.sm) {
                    InlineNotice(problem).font(.caption)
                    Spacer(minLength: 0)
                    Button { voice.dismissProblem() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .labelHelp(String(localized: "Скрыть"))
                }
            }
            if let tile = pendingTile {
                HStack(spacing: Space.sm) {
                    Label(tile.title, systemImage: tile.symbol)
                        .font(.chat(CGFloat(textSize), -2, weight: .semibold))
                    Text(command?.kind == .cal ? String(localized: "выберите встречу — вопрос уйдёт сам")
                                               : String(localized: "выберите письмо — вопрос уйдёт сам"))
                        .font(.chat(CGFloat(textSize), -2))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        pendingTile = nil
                        question = ""
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .labelHelp(String(localized: "Отменить"))
                }
            }
            if !suggestions.isEmpty {
                CommandList(suggestions: suggestions, highlight: min(highlight, suggestions.count - 1), pick: pick)
            }
            HStack(alignment: .bottom, spacing: Space.sm) {
                TextField(voice.state == .listening ? String(localized: "Говорите…") : String(localized: "Спросите ассистента…"),
                          text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focused)
                    .font(.chat(CGFloat(textSize)))
                    .onSubmit(send)
                    .onKeyPress(phases: .down, action: key)
                    .onChange(of: question) { _, _ in
                        popupClosed = false
                        highlight = 0
                        // Команду стёрли — плитка больше не ждёт выбора.
                        if pendingTile != nil, command == nil { pendingTile = nil }
                        if command?.kind == .cal, eventPool == nil { loadEvents() }
                    }
                    .editorField(padding: Space.md)
                    .help("↩ — отправить, ⇧↩ — новая строка, /mail и /cal — приложить письмо или встречу")
                controls
            }
        }
        .padding(Space.lg)
    }

    private var controls: some View {
        HStack(spacing: Space.xxs) {
            attachMenu
            modelMenu
            if session.busy {
                Button { session.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(".", modifiers: .command)
                .labelHelp(String(localized: "Остановить ответ (⌘.)"))
            } else {
                SendVoiceButton(voice: voice, canSend: canSend,
                                onStartVoice: { beforeVoice = question.trimmingCharacters(in: .whitespacesAndNewlines) },
                                onSend: send)
                    // ⌘↩ — как раньше: жест кнопке сочетаний не даёт.
                    .background {
                        Button("", action: send)
                            .keyboardShortcut(.return, modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
            }
        }
        .fixedSize()
    }

    /// «+»: открытое письмо или встреча, письмо из почты, встреча из
    /// календаря, файл. Картинки — только если модель их видит.
    private var attachMenu: some View {
        Menu {
            if let item = model.selectedItem, item.kind != .reminder {
                Button(item.kind == .mail ? String(localized: "Открытое письмо «\(item.title)»")
                                          : String(localized: "Открытая встреча «\(item.title)»")) {
                    if item.kind == .mail { session.attachLetter(item) } else { session.attachEvent(item) }
                }
                Divider()
            }
            // Не список, а команда в поле: дальше — слова из темы и выбор
            // из подходящих (`CommandList`).
            Button("Письмо — /mail") { insert(.mail) }
            Button("Встреча — /cal") { insert(.cal) }
            Divider()
            Button(session.seesImages ? String(localized: "Файл или картинка…") : String(localized: "Файл…")) {
                session.chooseFiles()
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(session.seesImages
                   ? String(localized: "Приложить письмо, встречу, файл или картинку")
                   : String(localized: "Приложить письмо, встречу или файл. Картинки эта модель не видит — нужна модель с пометкой «видит картинки»."))
    }

    // MARK: - Команды /mail и /cal

    private var command: ChatCommand.Found? { ChatCommand.find(in: question) }

    /// Что предложить под набранной командой: сами команды, пока имя
    /// не дописано, иначе — письма или встречи по словам темы.
    private var suggestions: [CommandSuggestion] {
        guard !popupClosed, let command else { return [] }
        switch command.kind {
        case nil:
            return ChatCommand.commands(matching: command.query).map(CommandSuggestion.command)
        case .mail?:
            return model.searchLetters(command.query, limit: 6).map(CommandSuggestion.letter)
        case .cal?:
            guard let pool = eventPool else { return [] }
            let now = model.now
            let found = pool.filter { ChatCommand.matches(command.query, in: [$0.title, $0.event?.location ?? ""]) }
            // Сначала предстоящие — по порядку, потом прошедшие — от недавних.
            // От повторяющейся — ближайшая и последняя прошедшая: иначе одна
            // серия «Созвон с подрядчиком» занимала весь список.
            var upcomingTitles = Set<String>()
            var pastTitles = Set<String>()
            let upcoming = found.filter { ($0.end ?? $0.time) >= now }.sorted { $0.time < $1.time }
                .filter { upcomingTitles.insert($0.title).inserted }
            let past = found.filter { ($0.end ?? $0.time) < now }.sorted { $0.time > $1.time }
                .filter { pastTitles.insert($0.title).inserted }
            return (upcoming + past).prefix(6).map(CommandSuggestion.event)
        }
    }

    private func loadEvents() {
        eventPool = []
        let calendar = model.calendar
        let today = calendar.startOfDay(for: model.now)
        let from = calendar.date(byAdding: .month, value: -1, to: today) ?? today
        let until = calendar.date(byAdding: .month, value: 3, to: today) ?? today
        Task {
            var seen = Set<String>()
            eventPool = await model.calendarItems(from: from, to: until)
                .filter { $0.kind == .event && $0.event?.isCancelled != true && seen.insert($0.id).inserted }
        }
    }

    /// ↑↓ — по списку, ↩ и Tab — выбрать, Esc — закрыть; ⇧↩ — новая строка
    /// (⌥↩ — тоже, это умеет само поле).
    private func key(_ press: KeyPress) -> KeyPress.Result {
        let list = suggestions
        if !list.isEmpty {
            switch press.key {
            case .upArrow:
                highlight = max(0, min(highlight, list.count - 1) - 1)
                return .handled
            case .downArrow:
                highlight = min(list.count - 1, highlight + 1)
                return .handled
            case .return, .tab:
                pick(list[min(highlight, list.count - 1)])
                return .handled
            case .escape:
                popupClosed = true
                pendingTile = nil
                return .handled
            default:
                break
            }
        }
        if press.key == .return, press.modifiers.contains(.shift) {
            question += "\n"
            return .handled
        }
        return .ignored
    }

    /// Кнопка «+» → «Письмо»: команда в конец поля, дальше — слова темы.
    private func insert(_ kind: ChatCommand.Kind) {
        let text = question.trimmingCharacters(in: .whitespaces)
        question = (text.isEmpty ? "" : text + " ") + "/" + kind.names[0] + " "
        focused = true
    }

    /// Выбрали из списка: письмо или встреча — плашкой, команда из поля уходит.
    private func pick(_ suggestion: CommandSuggestion) {
        guard let command else { return }
        let before = command.before.trimmingCharacters(in: .whitespaces)
        switch suggestion {
        case .command(let kind):
            question = (before.isEmpty ? "" : before + " ") + "/" + kind.names[0] + " "
            return
        case .letter(let item):
            session.attachLetter(item)
        case .event(let item):
            session.attachEvent(item)
        }
        question = before.isEmpty ? "" : before + " "
        focused = true
        // Выбор для плитки — и сразу её вопрос.
        if let tile = pendingTile {
            pendingTile = nil
            switch tile.run {
            case .letter(let prompt), .event(let prompt):
                question = ""
                session.send(prompt, title: tile.title)
            case .ask, .template:
                break
            }
        }
    }

    /// Модель чата — коротким названием; выбор — среди местных моделей.
    private var modelMenu: some View {
        Menu {
            Picker("Модель", selection: $session.model) {
                Text(ai.activeModel.map { String(localized: "Как везде · \($0)") } ?? String(localized: "Как везде"))
                    .tag(String?.none)
                ForEach(ai.localModels) { item in
                    Text(item.name).tag(Optional(item.name))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Настройки ИИ…") { SettingsWindow.show(model: model, tab: .ai) }
        } label: {
            Text(Self.shortName(session.model ?? ai.activeModel))
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 96)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Модель для чата — только на этом Mac") + (session.seesImages ? " · " + String(localized: "видит картинки") : ""))
    }

    /// «qwen3:8b» — как есть; длинное «hf.co/автор/модель:метка» — без пути.
    static func shortName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return String(localized: "Модель") }
        return name.split(separator: "/").last.map(String.init) ?? name
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.attachments.isEmpty
    }

    private func send() {
        guard !session.busy else { return }
        voice.stop()
        session.send(question)
        question = ""
        beforeVoice = ""
    }
}

/// Вкладка разговора: название и «закрыть».
private struct DialogTab: View {
    let dialog: ChatDialog
    @ObservedObject var session: AssistantSession

    var body: some View {
        let selected = dialog.id == session.currentID
        HStack(spacing: Space.xxs) {
            Button { session.select(dialog.id) } label: {
                HStack(spacing: Space.xs) {
                    if session.answeringID == dialog.id {
                        ProgressView().controlSize(.mini)
                    }
                    Text(dialog.title.isEmpty ? String(localized: "Новый разговор") : dialog.title)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.leading, Space.md)
                .padding(.vertical, Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(dialog.title.isEmpty ? String(localized: "Новый разговор") : dialog.title)
            if session.dialogs.count > 1 || !dialog.entries.isEmpty {
                Button { session.close(dialog.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .labelHelp(String(localized: "Закрыть разговор"))
            }
        }
        .padding(.trailing, Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(selected ? Fill.accentSoft : Fill.subtle))
    }
}

/// Приложенное — плашкой с «убрать».
private struct AttachmentChip: View {
    @Environment(\.chatTextSize) private var size
    let attachment: ChatAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: attachment.symbol).foregroundStyle(.secondary)
            Text(attachment.title.isEmpty ? String(localized: "Без темы") : attachment.title)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .labelHelp(String(localized: "Убрать"))
            }
        }
        .font(.chat(size, -3))
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(Capsule().fill(Fill.subtle))
    }
}

/// Реплика: вопрос — справа на подложке, ответ — слева, с карточками действий.
private struct ChatBubble: View {
    @Environment(\.chatTextSize) private var size
    let entry: ChatEntry
    @ObservedObject var session: AssistantSession

    var body: some View {
        if entry.role == .user {
            VStack(alignment: .trailing, spacing: Space.xs) {
                if !entry.attachments.isEmpty {
                    HStack(spacing: Space.xs) {
                        ForEach(entry.attachments) { AttachmentChip(attachment: $0) }
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.chat(size))
                        .textSelection(.enabled)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Fill.accentSoft))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Space.page * 2)
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                if entry.text.isEmpty && entry.streaming {
                    HStack(spacing: Space.md) {
                        ProgressView().controlSize(.small)
                        Text("Думает… Местной модели нужно до минуты.").font(.chat(size, -1)).foregroundStyle(.secondary)
                    }
                } else if !entry.text.isEmpty {
                    Text(Self.markdown(entry.text))
                        .font(.chat(size))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.stopped {
                    Label("Остановлено", systemImage: "stop.circle").font(.chat(size, -2)).foregroundStyle(.secondary)
                }
                if let failure = entry.failure {
                    InlineNotice(failure).font(.chat(size, -1))
                }
                ForEach(entry.actions) { card in
                    if card.state != .dismissed {
                        ActionCardView(card: card, session: session)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Ответ модели — облегчённым Markdown: жирное, списки, ссылки.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Карточка предложенного действия: что именно будет сделано — и кнопка.
private struct ActionCardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.chatTextSize) private var size
    let card: ActionCard
    @ObservedObject var session: AssistantSession

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(title, systemImage: symbol).font(.chat(size, -1, weight: .semibold))
            ForEach(details, id: \.self) { line in
                Text(line).font(.chat(size, -2)).foregroundStyle(.secondary).lineLimit(4)
            }
            switch card.state {
            case .pending:
                HStack(spacing: Space.md) {
                    Button(button) { session.perform(card) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Не нужно") { session.dismiss(card) }
                        .controlSize(.small)
                }
            case .done(let note):
                Label(note, systemImage: "checkmark.circle.fill").font(.chat(size, -2)).foregroundStyle(Palette.success)
            case .dismissed:
                EmptyView()
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Fill.subtle))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Fill.stroke))
    }

    private var title: String {
        switch card.action {
        case .reminder(let title, _): String(localized: "Напоминание: \(title)")
        case .event(let title, _, _, _, _): String(localized: "Встреча: \(title)")
        case .mail(_, let subject, _): subject.isEmpty ? String(localized: "Письмо") : String(localized: "Письмо: \(subject)")
        case .note(_, let day):
            day.map { String(localized: "Заметка на \(Format.dayTitle($0))") } ?? String(localized: "Заметка дня")
        }
    }

    private var symbol: String {
        switch card.action {
        case .reminder: "bell"
        case .event: "calendar.badge.plus"
        case .mail: "envelope"
        case .note: "note.text.badge.plus"
        }
    }

    private var button: String {
        switch card.action {
        case .reminder: String(localized: "Создать")
        case .event: String(localized: "Открыть встречу")
        case .mail: String(localized: "Открыть письмо")
        case .note: String(localized: "Дописать")
        }
    }

    /// Что будет сделано — словами, до нажатия: кому письмо, когда встреча.
    /// Адреса, которых нет среди известных, видно сразу.
    private var details: [String] {
        switch card.action {
        case let .reminder(_, due):
            return [due.map(when) ?? String(localized: "Без срока")]
        case let .event(_, start, end, attendees, location):
            var lines = [relativeDay(start) + ", " + Format.range(start, end)]
            if !attendees.isEmpty { lines.append(String(localized: "Участники: \(names(attendees))")) }
            if !location.isEmpty { lines.append(location) }
            return lines
        case let .mail(to, _, body):
            var lines: [String] = []
            if !to.isEmpty { lines.append(String(localized: "Кому: \(names(to))")) }
            if !body.isEmpty { lines.append(String(body.prefix(240))) }
            lines.append(String(localized: "Откроется в отдельном окне — отправите сами"))
            return lines
        case let .note(text, _):
            return [String(text.prefix(400))]
        }
    }

    private func when(_ date: Date) -> String {
        relativeDay(date) + ", " + Format.time(date)
    }

    /// «Сегодня» и «завтра» словами: так видно, что «в 9:00» уехало на завтра.
    private func relativeDay(_ date: Date) -> String {
        let calendar = model.calendar
        // После «Сегодня, » по-русски день недели — со строчной.
        let title = Format.dayTitle(date)
        let rest = AppLanguage.code == "ru" ? title.prefix(1).lowercased() + title.dropFirst() : title
        if calendar.isDate(date, inSameDayAs: model.now) {
            return String(localized: "Сегодня") + ", " + rest
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: model.now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Завтра") + ", " + rest
        }
        return title
    }

    private func names(_ people: [String]) -> String {
        people.map { text in
            model.person(matching: text)?.formatted ?? String(localized: "\(text) (адрес не найден)")
        }.joined(separator: ", ")
    }
}

/// Размер текста чата — всем репликам, карточкам и плашкам сразу.
/// Ключом, а не `@Entry`: макросы SwiftUI без Xcode недоступны.
private struct ChatTextSizeKey: EnvironmentKey {
    static let defaultValue = ChatTextSize.standard
}

extension EnvironmentValues {
    var chatTextSize: CGFloat {
        get { self[ChatTextSizeKey.self] }
        set { self[ChatTextSizeKey.self] = newValue }
    }
}

/// Строка списка под `/mail` и `/cal`.
enum CommandSuggestion: Identifiable {
    case command(ChatCommand.Kind)
    case letter(TimelineItem)
    case event(TimelineItem)

    var id: String {
        switch self {
        case .command(let kind): "command:" + kind.rawValue
        case .letter(let item), .event(let item): item.id
        }
    }
}

/// Подходящие письма или встречи — над полем ввода; щелчок или ↩ — приложить.
private struct CommandList: View {
    @Environment(\.chatTextSize) private var size
    let suggestions: [CommandSuggestion]
    let highlight: Int
    let pick: (CommandSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    row(suggestion)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .fill(index == highlight ? Fill.accentSoft : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Fill.subtle))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Fill.stroke))
    }

    @ViewBuilder
    private func row(_ suggestion: CommandSuggestion) -> some View {
        switch suggestion {
        case .command(let kind):
            Label {
                HStack(spacing: Space.sm) {
                    Text("/" + kind.names[0]).font(.chat(size, -1, weight: .semibold).monospaced())
                    Text(kind == .mail ? String(localized: "приложить письмо по словам темы")
                                       : String(localized: "приложить встречу по словам названия"))
                        .font(.chat(size, -2)).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: kind == .mail ? "envelope" : "calendar")
            }
            .foregroundStyle(Color.primary)
        case .letter(let item):
            line(symbol: "envelope", title: item.title,
                 detail: [item.mail?.from.formatted, Format.dayTitle(item.time) + ", " + Format.time(item.time)]
                    .compactMap { $0 }.joined(separator: " · "))
        case .event(let item):
            line(symbol: "calendar", title: item.title,
                 detail: Format.dayTitle(item.time) + ", " + (item.isAllDay ? String(localized: "весь день") : Format.range(item.time, item.end)))
        }
    }

    private func line(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title.isEmpty ? String(localized: "Без темы") : title)
                    .font(.chat(size, -1))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.chat(size, -3))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// «Отправить» и голос в одной кнопке. Щелчок — отправить. Зажать — говорить,
/// отпустить — отправить сказанное. Зажать и потянуть вверх — запись без рук:
/// кнопка становится «стоп», а остановка ничего не отправляет — текст
/// остаётся в поле, кнопка снова «отправить».
private struct SendVoiceButton: View {
    @ObservedObject var voice: VoiceInput
    let canSend: Bool
    /// Запомнить набранное до голоса: распознанное допишется после него.
    let onStartVoice: () -> Void
    let onSend: () -> Void

    private enum Phase {
        case idle
        /// Нажали, ещё не ясно — щелчок или зажатие.
        case pressing
        /// Зажали: идёт запись, отпустят — отправится.
        case holding
        /// Потянули вверх, пока держат: отпустят — запись продолжится.
        case locking
        /// Запись без рук: кнопка — «стоп».
        case locked
        /// Нажали «стоп».
        case stopping
    }

    @ViewState private var phase: Phase = .idle
    @ViewState private var holdTimer: Task<Void, Never>?

    /// Дольше этого — уже не щелчок, а «говорю».
    static let holdDelay = 0.35
    /// На столько вверх — запись без рук.
    static let lockDistance = 40.0

    var body: some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: phase == .holding && voice.state == .listening)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                // Пока держат — подсказка, куда тянуть, чтобы не держать.
                if phase == .holding || phase == .locking {
                    Image(systemName: phase == .locking ? "lock.fill" : "lock.open")
                        .font(.app(.text, weight: .semibold))
                        .foregroundStyle(phase == .locking ? Palette.danger : Color.secondary)
                        .padding(Space.sm)
                        .background(Circle().fill(Fill.subtle))
                        .offset(y: -38)
                        .transition(.opacity)
                }
            }
            .gesture(press)
            .animation(Motion.quick, value: phase)
            .onChange(of: voice.isActive) { _, active in
                // Запись кончилась сама (минута, ошибка) — кнопка снова «отправить».
                if !active, phase == .locked { phase = .idle }
            }
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(phase == .locked ? String(localized: "Остановить запись") : String(localized: "Отправить вопрос"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .accessibilityAction(named: Text("Голосовой ввод")) {
                if voice.isActive { stopRecording() } else { startRecording(locked: true) }
            }
    }

    private var symbol: String {
        switch phase {
        case .holding, .locking: "mic.circle.fill"
        case .locked, .stopping: "stop.circle.fill"
        case .idle, .pressing: "arrow.up.circle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .holding, .locking, .locked, .stopping: Palette.danger
        case .idle, .pressing: canSend ? Color.accentColor : Color.secondary
        }
    }

    private var help: String {
        phase == .locked
            ? String(localized: "Идёт запись — нажмите, чтобы остановить. Ничего не отправится")
            : String(localized: "Отправить (↩). Зажмите — говорите, отпустите — отправится; потяните вверх — запись без рук. Речь распознаётся на этом Mac")
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch phase {
                case .idle:
                    phase = .pressing
                    holdTimer = Task {
                        try? await Task.sleep(for: .seconds(Self.holdDelay))
                        guard !Task.isCancelled, phase == .pressing else { return }
                        startRecording(locked: false)
                    }
                case .locked:
                    phase = .stopping
                case .holding where value.translation.height < -Self.lockDistance:
                    phase = .locking
                case .locking where value.translation.height > -Self.lockDistance / 2:
                    // Передумали тянуть — снова «держу».
                    phase = .holding
                default:
                    break
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                switch phase {
                case .pressing:
                    phase = .idle
                    tap()
                case .holding:
                    phase = .idle
                    let failed: Bool = { if case .failed = voice.state { true } else { false } }()
                    // Не записалось — не отправлять то, что было набрано раньше.
                    voice.stop { if !failed { onSend() } }
                case .locking:
                    phase = .locked
                case .stopping:
                    stopRecording()
                case .idle, .locked:
                    break
                }
            }
    }

    private func tap() {
        if phase == .locked {
            stopRecording()
        } else if canSend {
            onSend()
        }
    }

    private func startRecording(locked: Bool) {
        onStartVoice()
        voice.start()
        phase = locked ? .locked : .holding
    }

    private func stopRecording() {
        voice.stop()
        phase = .idle
    }
}
