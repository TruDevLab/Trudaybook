import SwiftUI
import WebKit
import TrudaybookCore

/// Правая панель: выбранное письмо, встреча или напоминание — или ответ.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.draft != nil {
                // Ответ на выбранное или новое письмо.
                ComposerView(item: model.draftItem)
            } else if let item = model.selectedItem {
                switch item.kind {
                case .mail: MailDetail(item: item)
                case .event: EventDetail(item: item)
                case .reminder: ReminderDetail(item: item)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("Выберите письмо или событие на таймлайне")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Стекло, как у остальных панелей; на старых системах — фон текста.
        .background(GlassPanelBackground(fallback: Color(nsColor: .textBackgroundColor)))
    }
}

// MARK: - Общие части

/// Вид элемента, статус и «Вернуть в работу».
private struct InspectorHeader: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    private var kindTitle: String {
        switch item.kind {
        case .mail: return String(localized: "Письмо")
        case .event: return String(localized: "Встреча")
        case .reminder: return String(localized: "Напоминание")
        }
    }

    var body: some View {
        let status = model.status(of: item)
        HStack(spacing: 8) {
            Label(kindTitle, systemImage: item.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            StatusPill(status: status)
            Spacer()
            // Снять можно только то, что отметило само приложение: «отвечено»
            // с сервера или прошедшую встречу не вернуть.
            if model.states[item.id] != nil {
                Button("Вернуть в работу") { model.reopen(item.id) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

private struct StatusPill: View {
    let status: ItemStatus

    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .open: return (String(localized: "Ждёт действия"), .orange)
            case .upcoming: return (String(localized: "Впереди"), .blue)
            case .snoozed(let until): return (String(localized: "Отложено до \(Format.time(until))"), .orange)
            case .done(let reason): return (reason.title, .green)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Строка «поле — значение», как на макете: Тема, Участники, Время…
private struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActionButtons: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    var titles: [ItemAction: String] = [:]

    var body: some View {
        // Значки в одну строку, как в панели действий: подпись — под курсором.
        ForEach(ItemAction.allCases.filter { $0.applies(to: item.kind) }) { action in
            let availability = model.availability(of: action, for: item)
            let title = titles[action] ?? action.title
            HoverIconButton(title: title, symbol: action.symbol,
                            help: { if case .disabled(let reason) = availability { return reason }
                                    return "\(title) · ⌘\(String(action.key).uppercased())" }()) {
                model.perform(action, on: item.id)
            }
            .disabled(!availability.isEnabled)
        }
    }
}

// MARK: - Письмо

private struct MailDetail: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewState private var showRemote = false
    /// Письмо «на бумаге» (свои цвета) или тёмным; `nil` — само.
    @ViewState private var paper: Bool?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let info = item.mail!
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader(item: item)
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    // Только имена; адрес — при наведении. Длинные списки
                    // свёрнуты в строку с «ещё N».
                    GridRow {
                        Text("От").foregroundStyle(.secondary)
                        PeopleLine(people: [info.from])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("Кому").foregroundStyle(.secondary)
                        PeopleLine(people: info.to)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !info.cc.isEmpty {
                        GridRow {
                            Text("Копия").foregroundStyle(.secondary)
                            PeopleLine(people: info.cc)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GridRow {
                        Text("Время").foregroundStyle(.secondary)
                        Text("\(Format.dayTitle(item.time)), \(Format.time(item.time))")
                    }
                    if let box = model.accountName(of: item) {
                        GridRow {
                            Text("Ящик").foregroundStyle(.secondary)
                            Text(box)
                        }
                    }
                }
                .font(.callout)

                if let invitation = model.invitation {
                    InvitationCard(item: item, invitation: invitation)
                        .id(item.id)
                }

                if let attachments = model.body?.attachments, !attachments.isEmpty {
                    ReceivedAttachments(files: attachments)
                        .id(item.id)
                }

                HStack(spacing: 6) {
                    ActionButtons(item: item, titles: [.reschedule: String(localized: "Отложить"), .replyAll: String(localized: "Ответить всем")])
                    HoverIconButton(title: String(localized: "Встреча"), symbol: "calendar.badge.plus",
                                    help: String(localized: "Назначить встречу с участниками письма")) {
                        model.startMeeting(with: item)
                    }
                    PriorityMenu(item: item)
                    if let body = model.body {
                        LetterFileChip(item: item, letter: body)
                    }
                }

                if let html = model.body?.html, !showRemote, html.range(of: "src=\"http", options: .caseInsensitive) != nil {
                    HStack {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Картинки из сети не загружены — так отправитель не узнает, что письмо открыто.")
                            .font(.caption)
                        Spacer()
                        Button("Загрузить") { showRemote = true }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
                }

                // Пересказ — только когда есть кому пересказывать.
                if TrunookLink.appURL != nil || model.options.demo {
                    SummaryPlaque(item: item)
                        .id(item.id)
                }
            }
            .padding(16)

            Divider()

            if let body = model.body {
                MailBodyView(body: body, allowRemote: showRemote, paper: paper)
                    .overlay(alignment: .topTrailing) {
                        // Тёмная тема: письмо в своих цветах на листе или тёмным.
                        if colorScheme == .dark, body.html != nil {
                            let current = paper ?? MailBodyView.hasOwnColors(body.html)
                            Button { paper = !current } label: {
                                Image(systemName: current ? "moon" : "doc.richtext")
                                    .padding(6)
                                    .background(Circle().fill(Color.primary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .help(current ? String(localized: "Показать в тёмной теме") : String(localized: "Показать в цветах письма (таблицы, выделения)"))
                        }
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(item.id)
    }
}

/// Тело письма в WebKit: без JavaScript, внешние загрузки заблокированы,
/// ссылки открываются в браузере.
struct MailBodyView: NSViewRepresentable {
    let body: MailBody
    let allowRemote: Bool
    /// Тёмная тема: показать письмо «на бумаге» — в его собственных цветах
    /// на светлом листе. `nil` — решить самим (`hasOwnColors`).
    var paper: Bool?
    @Environment(\.colorScheme) private var colorScheme

    /// В письме свои цвета: цветной текст, выделение, заливка ячеек таблиц.
    /// Тёмный стиль стёр бы их — такое письмо показываем как есть, на листе.
    static func hasOwnColors(_ html: String?) -> Bool {
        guard let html else { return false }
        let patterns = [#"(?i)[^-]color\s*:\s*(?!inherit|currentcolor)"#, #"(?i)<font[^>]+color\s*="#,
                        #"(?i)bgcolor\s*="#, #"(?i)background(-color)?\s*:\s*(?!transparent|none|inherit)"#]
        return patterns.contains { html.range(of: $0, options: .regularExpression) != nil }
    }

    /// Лист бумаги: свои цвета письма, светлый фон, скруглённые края.
    static let paperStyle = """
        <style>
        :root { color-scheme: light; }
        html { background: transparent !important; }
        body { background: #FFFFFF !important; color: #1D1D1F; border-radius: 10px;
               padding: 14px !important; margin: 10px !important; }
        </style>
        """

    /// Письма из Outlook и рассылок красят текст в чёрный прямо в разметке —
    /// на тёмной теме его не прочесть. Поверх письма кладётся стиль: текст
    /// светлый, фоны прозрачные, ссылки голубые; картинки не трогаются.
    /// Стиль в конце документа и с `!important` — перебивает стили письма.
    static let darkStyle = """
        <style>
        :root { color-scheme: dark; }
        html, body { background: transparent !important; color: #E6E6E6 !important; }
        body *:not(img):not(svg):not(video):not(picture) {
            color: #E6E6E6 !important;
            background-color: transparent !important;
            border-color: rgba(255,255,255,0.18) !important;
        }
        a, a * { color: #6CB6FF !important; }
        </style>
        """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let dark = colorScheme == .dark
        let onPaper = dark && (paper ?? Self.hasOwnColors(body.html))
        let html = document() + (dark ? (onPaper ? Self.paperStyle : Self.darkStyle) : "")
        let key = "\(allowRemote)|\(dark)|\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key

        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        if allowRemote {
            view.loadHTMLString(html, baseURL: nil)
        } else {
            RemoteBlocker.list { list in
                if let list { controller.add(list) }
                view.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    private func document() -> String {
        if let html = body.html { return html }
        let escaped = (body.text ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; }
            body { font: 13px -apple-system, sans-serif; margin: 16px; line-height: 1.45; }
            pre { white-space: pre-wrap; font: inherit; margin: 0; }
            </style></head><body><pre>\(escaped)</pre></body></html>
            """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Правило WebKit, запрещающее любые загрузки из сети. Компилируется один раз.
@MainActor
private enum RemoteBlocker {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []

    static func list(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return completion(compiled) }
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "trudaybook-block-remote", encodedContentRuleList: rules
        ) { list, _ in
            MainActor.assumeIsolated {
                compiled = list
                let callbacks = waiting
                waiting = []
                callbacks.forEach { $0(list) }
            }
        }
    }
}

// MARK: - Встреча

private struct EventDetail: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewState private var askDelete = false

    /// Удалить можно из календаря, который разрешает правку, — и чужую
    /// встречу тоже: она уйдёт только из своего календаря.
    private var canDelete: Bool {
        guard let info = item.event else { return false }
        let calendar = model.calendarSources.first { $0.id == info.calendarID }
        return calendar?.isWritable ?? info.canEdit
    }

    var body: some View {
        let info = item.event!
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorHeader(item: item)

                Field(title: String(localized: "Тема")) {
                    Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                }

                Field(title: String(localized: "Время")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.isAllDay ? "\(Format.dayTitle(item.time)), весь день"
                                           : "\(Format.dayTitle(item.time)), \(Format.range(item.time, item.end))")
                        if info.isRecurring {
                            Label(info.recurrenceSummary ?? String(localized: "Повторяющаяся встреча"), systemImage: "repeat")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(info.calendarTitle).font(.caption).foregroundStyle(item.swiftUIColor)
                    }
                }

                if let link = info.link {
                    Field(title: String(localized: "Ссылка")) {
                        Button {
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            Label("Подключиться · \(link.provider.rawValue)", systemImage: "video.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .help(link.url.absoluteString)
                    }
                } else if let location = info.location, !location.isEmpty {
                    Field(title: String(localized: "Место")) { Text(location).textSelection(.enabled) }
                }

                Field(title: String(localized: "Участники")) {
                    if info.attendees.isEmpty {
                        Text("Только вы").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(info.attendees, id: \.self) { attendee in
                                HStack(spacing: 6) {
                                    Image(systemName: icon(attendee.response))
                                        .foregroundStyle(color(attendee.response))
                                        .frame(width: 16)
                                    Text(attendee.isMe ? String(localized: "Вы") : attendee.person.display)
                                        .help(attendee.person.address ?? "")
                                    if attendee.person == info.organizer {
                                        Text("организатор").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    ActionButtons(item: item, titles: [.archive: String(localized: "Разобрано"), .reply: String(localized: "Организатору"),
                                                       .replyAll: String(localized: "Всем участникам"),
                                                       .decline: info.canEdit ? String(localized: "Отменить") : String(localized: "Отклонить")])
                    HoverIconButton(title: String(localized: "Изменить…"), symbol: "pencil",
                                    help: info.canEdit ? String(localized: "Время, повтор, участники, описание")
                                                       : String(localized: "Изменить встречу может только организатор")) {
                        model.startEditing(item)
                    }
                    .disabled(!info.canEdit)
                    HoverIconButton(title: String(localized: "Удалить…"), symbol: "trash", tint: .red) {
                        askDelete = true
                    }
                    .disabled(!canDelete)
                }
                .confirmationDialog(info.isRecurring ? String(localized: "Удалить повторяющуюся встречу") : String(localized: "Удалить встречу «\(item.title)»?"),
                                    isPresented: $askDelete) {
                    if info.isRecurring {
                        ForEach(RecurrenceScope.allCases, id: \.self) { scope in
                            Button(scope.title, role: .destructive) { model.deleteEvent(item, scope: scope) }
                        }
                    } else {
                        Button("Удалить", role: .destructive) { model.deleteEvent(item, scope: .thisEvent) }
                    }
                } message: {
                    if info.attendees.contains(where: { !$0.isMe }) {
                        Text(info.canEdit ? String(localized: "Участники получат отмену встречи.") : String(localized: "Встреча удалится только из вашего календаря."))
                    }
                }

                if !info.canReschedule {
                    Label("Встречу назначил другой человек — перенести её может только организатор.",
                          systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let notes = info.notes, !notes.isEmpty {
                    Field(title: String(localized: "Описание")) {
                        Text(notes).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
    }

    private func icon(_ response: Attendee.Response) -> String {
        switch response {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        case .tentative: return "questionmark.circle.fill"
        case .pending, .unknown: return "circle"
        }
    }

    private func color(_ response: Attendee.Response) -> Color {
        switch response {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        case .pending, .unknown: return .secondary
        }
    }
}

// MARK: - Напоминание

private struct ReminderDetail: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        let info = item.reminder!
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorHeader(item: item)
                Field(title: String(localized: "Напоминание")) {
                    Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                }
                Field(title: String(localized: "Срок")) {
                    Text(info.hasTime ? "\(Format.dayTitle(item.time)), \(Format.time(item.time))"
                                      : Format.dayTitle(item.time))
                }
                Field(title: String(localized: "Список")) { Text(info.listTitle) }
                HStack(spacing: 6) {
                    ActionButtons(item: item, titles: [.archive: String(localized: "Выполнено"), .decline: String(localized: "Удалить")])
                }
                if let notes = info.notes, !notes.isEmpty {
                    Field(title: String(localized: "Заметки")) { Text(notes).textSelection(.enabled) }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Ответ

/// Редактор ответа: свой текст с оформлением сверху, исходное письмо —
/// под чертой со своим оформлением, как в Mail. Символов «>» здесь нет:
/// они появляются только в текстовой копии уходящего письма.
private struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    /// Исходное письмо или встреча; `nil` — новое письмо.
    let item: TimelineItem?
    @StateObject private var editor = RichTextController()
    @ViewState private var to: [Person] = []
    @ViewState private var cc: [Person] = []
    /// Набранное в полях адресов и ещё не ставшее плашкой.
    @ViewState private var toText = ""
    @ViewState private var ccText = ""
    @ViewState private var subject = ""
    @ViewState private var includeQuote = true
    @ViewState private var linkAddress = ""
    /// Подпись, которая сейчас стоит в тексте, — чтобы заменить её при смене ящика.
    @ViewState private var appliedSignature: String?
    @ViewState private var showLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(item == nil ? String(localized: "Новое письмо") : item?.kind == .mail ? String(localized: "Ответ") : String(localized: "Письмо участникам"),
                      systemImage: item == nil ? "square.and.pencil" : "arrowshape.turn.up.left")
                    .font(.headline)
                Spacer()
                if model.accounts.count > 1 {
                    Text("от").font(.caption).foregroundStyle(.secondary)
                    Picker("От", selection: sender) {
                        ForEach(model.accounts) { Text($0.email).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("С какого ящика отправить")
                } else {
                    Text(model.accounts.first.map { String(localized: "от \($0.email)") } ?? model.mailName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            // Получатели — плашками с поиском, как участники встречи.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Кому").foregroundStyle(.secondary)
                    PeopleField(people: $to, text: $toText, placeholder: String(localized: "имя или адрес"))
                }
                GridRow {
                    Text("Копия").foregroundStyle(.secondary)
                    PeopleField(people: $cc, text: $ccText, placeholder: String(localized: "имя или адрес"))
                }
                GridRow {
                    Text("Тема").foregroundStyle(.secondary)
                    TextField("", text: $subject)
                        .textFieldStyle(.plain)
                        .editorField()
                }
            }
            .padding(.horizontal, 16)

            formatBar
                .padding(.horizontal, 16)
                .padding(.top, 10)

            RichTextEditorView(controller: editor)
                .frame(minHeight: 150, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            AttachmentChips(files: attachments)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            if let quote = model.draft?.quote {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Цитировать исходное письмо", isOn: $includeQuote)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    if includeQuote {
                        Text(quote.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
                            MailBodyView(body: MailBody(html: quote.html, text: quote.text), allowRemote: false)
                        }
                        .frame(height: 200)
                        .opacity(0.85)
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack {
                Text(model.accounts.isEmpty || model.options.demo ? "Отправка тестовая: письмо никуда не уйдёт" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { model.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    commit()
                    model.sendDraft()
                } label: {
                    if model.isSending { ProgressView().controlSize(.small) } else { Text("Отправить") }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.isSending)
            }
            .padding(16)
        }
        .onAppear(perform: load)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            AttachmentFiles.dropped(providers) { addAttachments($0) }
        }
    }

    /// Вложения живут в черновике: переживают перерисовку редактора.
    private var attachments: Binding<[MailBody.Attachment]> {
        Binding(get: { model.draft?.attachments ?? [] }, set: { model.draft?.attachments = $0 })
    }

    private func addAttachments(_ files: [MailBody.Attachment]) {
        guard !files.isEmpty else { return }
        model.draft?.attachments.append(contentsOf: files)
    }

    /// Ящик отправителя. Хранится в черновике, чтобы выбор пережил
    /// перерисовку редактора.
    private var sender: Binding<String?> {
        Binding(
            get: { model.draft?.accountID },
            set: { account in
                model.draft?.accountID = account
                applySignature()
            }
        )
    }

    /// Подпись ящика «от» в конце текста; сменили ящик — меняется и она.
    private func applySignature() {
        let signature = model.signatureForDraft(accountID: model.draft?.accountID, isReply: item != nil)
        editor.setSignature(signature, replacing: appliedSignature)
        appliedSignature = signature
    }

    /// Кнопки оформления, вложения и ссылка.
    private var formatBar: some View {
        HStack(spacing: 2) {
            RichFormatControls(editor: editor)
            Divider().frame(height: 16).padding(.horizontal, 4)
            RichFormatButton(symbol: "paperclip", help: String(localized: "Прикрепить файлы (или перетащите их сюда)")) {
                addAttachments(AttachmentFiles.choose())
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            RichFormatButton(symbol: "link", help: String(localized: "Ссылка на выделенном тексте")) {
                linkAddress = ""
                showLink = true
            }
            .popover(isPresented: $showLink, arrowEdge: .bottom) {
                HStack {
                    TextField("https://…", text: $linkAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(applyLink)
                    Button("Готово", action: applyLink)
                }
                .padding(10)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    private func applyLink() {
        showLink = false
        editor.applyLink(linkAddress)
        editor.focus()
    }

    private func load() {
        guard let draft = model.draft else { return }
        to = draft.to
        cc = draft.cc
        subject = draft.subject
        // Поле текста появляется чуть позже — текст и подпись после него.
        let text = draft.text
        DispatchQueue.main.async {
            editor.prefill(text)
            applySignature()
        }
    }

    private func commit() {
        guard var draft = model.draft else { return }
        let text = editor.attributed
        draft.to = PeopleField.merged(to, typed: toText)
        draft.cc = PeopleField.merged(cc, typed: ccText)
        draft.subject = subject
        draft.text = text.string
        draft.html = RichTextHTML.html(from: text)
        if !includeQuote { draft.quote = nil }
        model.draft = draft
    }
}

/// Приоритет выбранного: значок уровня и меню уровней.
struct PriorityMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        let current = model.priority(of: item)
        HoverMenu(title: current == .none ? String(localized: "Приоритет") : String(localized: "Приоритет: \(current.title.lowercased())"),
                  symbol: current == .none ? "flag" : current.symbol,
                  tint: current == .none ? nil : current.color,
                  help: String(localized: "Приоритет: ⌘1 высокий, ⌘2 средний, ⌘3 низкий, ⌘0 снять")) {
            PriorityPicker(id: item.id, current: current)
            if current != .none, model.priorities[item.id] == nil {
                Text("Важность указал отправитель")
            }
        }
    }
}

/// Цвета для текста письма: насыщенные — читаются и на белом, и на тёмном;
/// выделения — светлые, как маркер.
enum TextPalette {
    struct Choice {
        let name: String
        let rgb: RGB
        var color: NSColor { NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
    }

    struct TableSize: Hashable {
        let columns: Int
        let rows: Int
    }

    static let text: [Choice] = [
        Choice(name: String(localized: "Красный"), rgb: RGB(0.85, 0.16, 0.16)),
        Choice(name: String(localized: "Оранжевый"), rgb: RGB(0.93, 0.47, 0.05)),
        Choice(name: String(localized: "Зелёный"), rgb: RGB(0.13, 0.55, 0.2)),
        Choice(name: String(localized: "Синий"), rgb: RGB(0.1, 0.4, 0.85)),
        Choice(name: String(localized: "Фиолетовый"), rgb: RGB(0.5, 0.25, 0.8)),
        Choice(name: String(localized: "Серый"), rgb: RGB(0.45, 0.45, 0.48)),
    ]

    static let highlight: [Choice] = [
        Choice(name: String(localized: "Жёлтый"), rgb: RGB(1.0, 0.93, 0.35)),
        Choice(name: String(localized: "Зелёный"), rgb: RGB(0.7, 0.93, 0.6)),
        Choice(name: String(localized: "Голубой"), rgb: RGB(0.62, 0.85, 1.0)),
        Choice(name: String(localized: "Розовый"), rgb: RGB(1.0, 0.72, 0.82)),
        Choice(name: String(localized: "Оранжевый"), rgb: RGB(1.0, 0.8, 0.55)),
    ]

    static let tableSizes: [TableSize] = [
        TableSize(columns: 2, rows: 2), TableSize(columns: 3, rows: 2), TableSize(columns: 3, rows: 3),
        TableSize(columns: 4, rows: 3), TableSize(columns: 4, rows: 4), TableSize(columns: 5, rows: 4),
    ]
}

/// Письмо файлом: значок, который тащат на полку Trunook или в Finder.
/// Не кнопка — у кнопки перетаскивание не начинается.
private struct LetterFileChip: View {
    let item: TimelineItem
    let letter: MailBody

    var body: some View {
        Image(systemName: "envelope.open")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 26)
            .background(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
            .help(String(localized: "Перетащите письмо файлом — на полку Trunook или в Finder"))
            .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }
            .onDrag {
                guard let url = Self.file(item, letter) else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
    }

    /// Файл во временной папке: своя подпапка на письмо, чтобы одинаковые
    /// темы не затирали друг друга.
    static func file(_ item: TimelineItem, _ body: MailBody) -> URL? {
        guard let data = MessageBuilder.export(item, body: body) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trudaybook-letters/\(abs(item.id.hashValue))", isDirectory: true)
        let url = folder.appendingPathComponent(MessageBuilder.exportFileName(item.title))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

