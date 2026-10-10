import SwiftUI
import WebKit
import UniformTypeIdentifiers
import TrudaybookCore

/// Правая панель: выбранное письмо, встреча или напоминание — или ответ.
/// Чат с ассистентом — отдельной карточкой над ней (`MainView.rightColumn`).
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.draft != nil {
                // Ответ на выбранное или новое письмо.
                ComposerView(item: model.draftItem, draft: $model.draft, isSending: model.isSending,
                             onSend: model.sendDraft, onCancel: model.cancelDraft)
            } else if model.multiSelection.count > 1 {
                SelectionSummary()
            } else if let item = model.selectedItem {
                switch item.kind {
                case .mail: MailDetail(item: item)
                // Своя `id`: разрешение «Загрузить картинки» и высота описания —
                // у каждой встречи свои, на следующую не переходят.
                case .event: EventDetail(item: item).id(item.id)
                case .reminder: ReminderDetail(item: item)
                }
            } else {
                EmptyState(symbol: "sidebar.right", text: String(localized: "Выберите письмо или событие на таймлайне"),
                           tint: Color(nsColor: .tertiaryLabelColor), large: true)
            }
        }
        // Стекло, как у остальных панелей; на старых системах — фон текста.
        .background(GlassPanelBackground(fallback: Color(nsColor: .textBackgroundColor)))
    }
}

// MARK: - Общие части

/// Вид элемента, статус и «Вернуть в работу»; справа — свои значки
/// (у письма — приоритет, «Сохранить» и «В окне»).
private struct InspectorHeader<Accessories: View>: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewBuilder var accessories: Accessories

    private var kindTitle: String {
        switch item.kind {
        case .mail: return String(localized: "Письмо")
        case .event: return String(localized: "Встреча")
        case .reminder: return String(localized: "Напоминание")
        }
    }

    var body: some View {
        let status = model.status(of: item)
        HStack(spacing: Space.md) {
            // Письмо в панели открыто — и значок открытого конверта.
            Label(kindTitle, systemImage: item.kind == .mail ? "envelope.open" : item.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            StatusTag(status: status)
            Spacer()
            // Снять можно только то, что отметило само приложение: «отвечено»
            // с сервера или прошедшую встречу не вернуть.
            if model.states[item.id] != nil {
                Button("Вернуть в работу") { model.reopen(item.id) }
                    .buttonStyle(.link)
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize()
            }
            accessories
        }
    }
}

extension InspectorHeader where Accessories == EmptyView {
    init(item: TimelineItem) {
        self.init(item: item) { EmptyView() }
    }
}

private struct StatusTag: View {
    let status: ItemStatus

    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .open: return (String(localized: "Ждёт действия"), Palette.warning)
            case .upcoming: return (String(localized: "Впереди"), Palette.info)
            case .snoozed(let until): return (String(localized: "Отложено до \(Format.time(until))"), Palette.warning)
            case .done(let reason): return (reason.title, Palette.success)
            }
        }()
        Tag(text: text, tint: color)
    }
}

/// Строка «поле — значение», как на макете: Тема, Участники, Время…
private struct Field<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.lg) {
                InspectorHeader(item: item) {
                    HStack(spacing: Space.xs) {
                        PriorityMenu(item: item)
                        if let body = model.body {
                            LetterFileButton(item: item, letter: body)
                        }
                        OpenInWindowButton { LetterWindow.show(item, model: model) }
                    }
                }
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                LetterFields(item: item, account: model.accountName(of: item))

                if let invitation = model.invitation {
                    InvitationCard(item: item, invitation: invitation)
                        .id(item.id)
                }

                if let attachments = model.body?.attachments, !attachments.isEmpty {
                    ReceivedAttachments(files: attachments)
                        .id(item.id)
                }

                HStack(spacing: Space.sm) {
                    ActionButtons(item: item, titles: [.reschedule: String(localized: "Отложить"), .replyAll: String(localized: "Ответить всем")])
                    HoverIconButton(title: String(localized: "Встреча"), symbol: "calendar.badge.plus",
                                    help: String(localized: "Назначить встречу с участниками письма")) {
                        model.startMeeting(with: item)
                    }
                }

                if let body = model.body, !showRemote {
                    RemoteImagesNotice(letter: body) { showRemote = true }
                }

                // Пересказ — когда ИИ включён; почему модель не ответит, скажет сама плашка.
                if model.aiEnabled {
                    SummaryPlaque(item: item)
                        .id(item.id)
                }
            }
            .padding(Space.xxl)

            Divider()

            if let body = model.body {
                LetterBodyPane(letter: body, allowRemote: showRemote, paper: $paper)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(item.id)
    }
}

/// Значок «в окне» — те же стрелки, что у заметки под календарём.
struct OpenInWindowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Основным цветом, и именно `Color.primary`: у `.borderless`
            // иерархическое `.primary` — вторичное, значок казался выключенным.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.app(.text, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Открыть письмо в отдельном окне · ⌘O"))
    }
}

/// Выделено несколько строк списка: что с ними сделать разом.
private struct SelectionSummary: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.selectionItems
        let letters = items.filter { $0.kind == .mail }
        let archivable = items.filter { model.availability(of: .archive, for: $0).isEnabled }
        VStack(spacing: Space.xl) {
            Image(systemName: "envelope.stack")
                .font(.app(.hero))
                .foregroundStyle(.secondary)
            Text(Self.title(items.count, letters: letters.count))
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(items.prefix(6)) { item in
                    Text("\(item.subtitle) — \(item.title)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if items.count > 6 {
                    Text("и ещё \(items.count - 6)").font(.callout).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            HStack(spacing: Space.md) {
                Button { model.archiveSelection() } label: {
                    Label(archivable.count == items.count ? String(localized: "В архив")
                                                          : String(localized: "В архив: \(archivable.count)"),
                          systemImage: "archivebox")
                }
                .disabled(archivable.isEmpty)
                .help("В архив всё выделенное · ⌘E")
                Button(role: .destructive) { model.trash(letters.map(\.id)) } label: {
                    Label(letters.count == items.count ? String(localized: "В корзину")
                                                       : String(localized: "Письма в корзину: \(letters.count)"),
                          systemImage: "trash")
                }
                .disabled(letters.isEmpty)
                .help("В «Корзину» ящика — вернуть можно оттуда же · ⌫")
            }
            .controlSize(.large)
            Button("Снять выделение") { model.clearMultiSelection() }
                .buttonStyle(.link)
            Text("⇧ — выделить подряд, ⌘ — добавить или убрать одно")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// «Выбрано 3 письма», а если в выделении и встречи — «Выбрано 4».
    static func title(_ count: Int, letters: Int) -> String {
        letters == count ? String(localized: "Выбрано писем: \(count)") : String(localized: "Выбрано: \(count)")
    }
}

/// От кого, кому, копия, время и ящик. Только имена; адрес — при
/// наведении. Длинные списки свёрнуты в строку с «ещё N».
struct LetterFields: View {
    let item: TimelineItem
    /// Ящик — когда их несколько; у письма из файла — имя файла.
    var account: String?
    var accountTitle = String(localized: "Ящик")

    var body: some View {
        let info = item.mail!
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.xs) {
            GridRow {
                Text("От").foregroundStyle(.secondary)
                PeopleLine(people: [info.from])
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !info.to.isEmpty {
                GridRow {
                    Text("Кому").foregroundStyle(.secondary)
                    PeopleLine(people: info.to)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            if let account {
                GridRow {
                    Text(accountTitle).foregroundStyle(.secondary)
                    Text(account)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.callout)
    }
}

/// Картинки из сети в письме не загружены — и кнопка «Загрузить».
struct RemoteImagesNotice: View {
    let letter: MailBody
    let load: () -> Void

    var body: some View {
        if let html = letter.html, html.range(of: "src=\"http", options: .caseInsensitive) != nil {
            HStack {
                Image(systemName: "photo.badge.exclamationmark")
                Text("Картинки из сети не загружены — так отправитель не узнает, что письмо открыто.")
                    .font(.caption)
                Spacer()
                Button("Загрузить", action: load)
                    .controlSize(.small)
            }
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.notice.opacity(0.15)))
        }
    }
}

/// Тело письма с переключателем «на листе / тёмным» в тёмной теме.
struct LetterBodyPane: View {
    let letter: MailBody
    let allowRemote: Bool
    /// Письмо «на бумаге» (свои цвета) или тёмным; `nil` — само.
    @Binding var paper: Bool?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MailBodyView(body: letter, allowRemote: allowRemote, paper: paper)
            .overlay(alignment: .topTrailing) {
                // Тёмная тема: письмо в своих цветах на листе или тёмным.
                if colorScheme == .dark, letter.html != nil {
                    let current = paper ?? MailBodyView.hasOwnColors(letter.html)
                    Button { paper = !current } label: {
                        Image(systemName: current ? "moon" : "doc.richtext")
                            .padding(Space.sm)
                            .background(Circle().fill(Fill.hover))
                    }
                    .buttonStyle(.plain)
                    .padding(Space.lg)
                    .labelHelp(current ? String(localized: "Показать в тёмной теме") : String(localized: "Показать в цветах письма (таблицы, выделения)"))
                }
            }
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
    /// Высота документа после загрузки — где просмотр стоит внутри прокрутки
    /// (описание встречи) и своей высоты ему не дано.
    var onHeight: ((CGFloat) -> Void)?
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
        // Без памяти между письмами: куки и кэш удалённых картинок иначе
        // связывали бы одно письмо с другим (трекинг рассылок).
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
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
        var onHeight: ((CGFloat) -> Void)?

        /// Скрипты письма выключены; высоту спрашивает само приложение — в своём
        /// мире (`defaultClient`), письму этот вызов не виден.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let onHeight else { return }
            webView.evaluateJavaScript("document.documentElement.scrollHeight", in: nil, in: .defaultClient) { result in
                if case .success(let value) = result, let height = value as? Double {
                    MainActor.assumeIsolated { onHeight(CGFloat(height)) }
                }
            }
        }

        /// Письмо — чужой документ. Разрешено только показать его самого:
        /// переходы (в том числе `<meta refresh>`) и отправка форм — нет,
        /// иначе фишинговая форма «введите пароль» работала бы прямо здесь.
        /// Ссылку, по которой щёлкнули, открывает система — см. `MailLinks`.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            switch action.navigationType {
            case .linkActivated:
                if let url { MailLinks.open(url) }
                decisionHandler(.cancel)
            case .formSubmitted, .formResubmitted:
                DebugLog.write("письмо: отправка формы из письма заблокирована")
                decisionHandler(.cancel)
            default:
                // Своя загрузка (`loadHTMLString`) — это about:blank; картинки
                // `cid:` и `data:` — не переходы. Всё прочее — мимо.
                let scheme = url?.scheme?.lowercased() ?? "about"
                decisionHandler(scheme == "about" || scheme == "data" ? .allow : .cancel)
            }
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
    /// Картинки из сети в описании — по нажатию, как в письме.
    @ViewState private var showRemote = false
    @ViewState private var descriptionHeight: CGFloat = 120

    /// Встреча отменена организатором — убрать её из календаря одной кнопкой
    /// (письмо об отмене, если оно есть, уйдёт в архив).
    private var cancelledBanner: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: "calendar.badge.minus").foregroundStyle(Palette.danger)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Встреча отменена").font(.callout.weight(.semibold))
                Text("Организатор её отменил — в календаре она осталась.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.removeCancelledEvent(item)
            } label: {
                if model.removingCancelled == item.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Удалить из календаря", systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.danger)
            .disabled(model.removingCancelled != nil || !canDelete)
        }
        .padding(Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Palette.danger.opacity(0.08)))
    }

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
            VStack(alignment: .leading, spacing: Space.xl) {
                InspectorHeader(item: item)

                if info.isCancelled { cancelledBanner }

                Field(title: String(localized: "Тема")) {
                    Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                        .strikethrough(info.isCancelled)
                }

                Field(title: String(localized: "Время")) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
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
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Button {
                                MeetingOpener.open(link)
                            } label: {
                                Label("Подключиться · \(link.provider.rawValue)", systemImage: "video.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .help(link.url.absoluteString)
                            autoJoinToggle(item)
                        }
                    }
                } else if let location = info.location, !location.isEmpty {
                    Field(title: String(localized: "Место")) { Text(location).textSelection(.enabled) }
                }

                Field(title: String(localized: "Участники")) {
                    if info.attendees.isEmpty {
                        Text("Только вы").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(info.attendees, id: \.self) { attendee in
                                let response = info.response(of: attendee)
                                HStack(spacing: Space.sm) {
                                    Image(systemName: icon(response))
                                        .foregroundStyle(color(response))
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

                HStack(spacing: Space.sm) {
                    ActionButtons(item: item, titles: [.archive: String(localized: "Разобрано"), .reply: String(localized: "Организатору"),
                                                       .replyAll: String(localized: "Всем участникам"),
                                                       .decline: info.canEdit ? String(localized: "Отменить") : String(localized: "Отклонить")])
                    HoverIconButton(title: String(localized: "Изменить…"), symbol: "pencil",
                                    help: info.canEdit ? String(localized: "Время, повтор, участники, описание")
                                                       : String(localized: "Изменить встречу может только организатор")) {
                        model.startEditing(item)
                    }
                    .disabled(!info.canEdit)
                    HoverIconButton(title: String(localized: "Удалить…"), symbol: "trash", tint: Palette.danger) {
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

                if let rich = model.eventBody {
                    if !rich.attachments.isEmpty {
                        ReceivedAttachments(files: rich.attachments)
                            .id(item.id)
                    }
                    if rich.html != nil {
                        Field(title: String(localized: "Описание")) {
                            VStack(alignment: .leading, spacing: Space.sm) {
                                if !showRemote {
                                    RemoteImagesNotice(letter: rich) { showRemote = true }
                                }
                                MailBodyView(body: rich, allowRemote: showRemote, onHeight: { height in
                                    descriptionHeight = min(max(height, 40), 4000)
                                })
                                .frame(height: descriptionHeight)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            }
                        }
                    }
                }
                if model.eventBody?.html == nil, let notes = info.notes, !notes.isEmpty {
                    Field(title: String(localized: "Описание")) {
                        Text(notes).textSelection(.enabled)
                    }
                }
            }
            .padding(Space.xxl)
        }
    }

    /// Подключиться само — у любой встречи со ссылкой, и у чужой: окна
    /// правки у неё нет, а отметка всё равно только своя, на этом Mac.
    @ViewBuilder
    private func autoJoinToggle(_ item: TimelineItem) -> some View {
        let possible = AutoJoinRules.canAutoJoin(item)
        Toggle(isOn: Binding(get: { possible && model.autoJoins(item) },
                             set: { model.setAutoJoin($0, for: item) })) {
            Text("Автоподключение")
        }
        .toggleStyle(.checkbox)
        .disabled(!possible)
        .help(possible
              ? String(localized: "Ссылка откроется сама, когда встреча начнётся. Для всех встреч — в Настройках → Календари.")
              : String(localized: "Сама открывается только ссылка Zoom, Teams, Google Meet, Телемоста, Webex или Whereby у неотменённой и неотклонённой встречи."))
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
        case .accepted: return Palette.success
        case .declined: return Palette.danger
        case .tentative: return Palette.warning
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
            VStack(alignment: .leading, spacing: Space.xl) {
                InspectorHeader(item: item)
                Field(title: String(localized: "Напоминание")) {
                    Text(item.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                }
                Field(title: String(localized: "Срок")) {
                    Text(info.hasTime ? "\(Format.dayTitle(item.time)), \(Format.time(item.time))"
                                      : Format.dayTitle(item.time))
                }
                Field(title: String(localized: "Список")) { Text(info.listTitle) }
                HStack(spacing: Space.sm) {
                    ActionButtons(item: item, titles: [.archive: String(localized: "Выполнено"), .decline: String(localized: "Удалить")])
                }
                if let notes = info.notes, !notes.isEmpty {
                    Field(title: String(localized: "Заметки")) { Text(notes).textSelection(.enabled) }
                }
            }
            .padding(Space.xxl)
        }
    }
}

// MARK: - Ответ

/// Редактор ответа: свой текст с оформлением сверху, исходное письмо —
/// под чертой со своим оформлением, как в Mail. Символов «>» здесь нет:
/// они появляются только в текстовой копии уходящего письма.
struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    /// Исходное письмо или встреча; `nil` — новое письмо.
    let item: TimelineItem?
    /// Черновик: у правой панели — модели (`draft`), у отдельного
    /// окна — свой (`ComposeWindow`).
    @Binding var draft: OutgoingMail?
    var isSending: Bool
    var onSend: () -> Void
    var onCancel: () -> Void
    @StateObject private var editor = RichTextController()
    @ViewState private var to: [Person] = []
    @ViewState private var cc: [Person] = []
    @ViewState private var bcc: [Person] = []
    /// Строка скрытой копии свёрнута, пока её не раскроют (или пока в ней нет адресов).
    @ViewState private var showBcc = false
    /// Набранное в полях адресов и ещё не ставшее плашкой.
    @ViewState private var toText = ""
    @ViewState private var ccText = ""
    @ViewState private var bccText = ""
    @ViewState private var subject = ""
    @ViewState private var includeQuote = true
    @ViewState private var linkAddress = ""
    /// Подпись, которая сейчас стоит в тексте, — чтобы заменить её при смене ящика.
    @ViewState private var appliedSignature: String?
    @ViewState private var showLink = false
    /// Шаблон ответа от Trunook: готовится, не вышел или ещё не просили.
    @ViewState private var assist: ReplyAssist = .idle
    /// Высота цитаты под ручкой — одна на все ответы.
    @AppStorage("composerQuoteHeight") private var quoteHeight = ComposerView.defaultQuoteHeight

    enum ReplyAssist: Equatable {
        case idle
        case loading
        case failed(code: String, message: String)
    }

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
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Кнопки — наверху, у заголовка: внизу их съедала цитата,
                // а в узком окне приходилось листать до них.
                sendButtons
                    .padding(.leading, Space.sm)
            }
            .padding([.horizontal, .top], Space.xxl)
            .padding(.bottom, Space.lg)

            if model.accounts.isEmpty || model.options.demo {
                Text("Отправка тестовая: письмо никуда не уйдёт")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.md)
            }

            // Получатели — плашками с поиском, как участники встречи.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.md) {
                GridRow {
                    Text("Кому").foregroundStyle(.secondary)
                    PeopleField(people: $to, text: $toText, placeholder: String(localized: "имя или адрес"))
                }
                GridRow {
                    Text("Копия").foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        PeopleField(people: $cc, text: $ccText, placeholder: String(localized: "имя или адрес"))
                        if !showBcc {
                            Button("Скрытая") { withAnimation(HoverMotion.animation) { showBcc = true } }
                                .buttonStyle(.link)
                                .font(.caption)
                                .help("Добавить скрытую копию: эти получатели не видны остальным")
                        }
                    }
                }
                if showBcc {
                    GridRow {
                        Text("Скрытая").foregroundStyle(.secondary)
                        PeopleField(people: $bcc, text: $bccText, placeholder: String(localized: "имя или адрес — другим не видно"))
                    }
                }
                GridRow {
                    Text("Тема").foregroundStyle(.secondary)
                    TextField("", text: $subject)
                        .textFieldStyle(.plain)
                        .editorField()
                }
            }
            .padding(.horizontal, Space.xxl)

            formatBar
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.lg)

            if let item, item.kind == .mail, model.aiEnabled {
                templateBar(item)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.sm)
            }

            // Текст и цитата делят место ручкой: в узком окне иногда важнее
            // перечитать, на что отвечаешь, чем видеть всё поле ввода.
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 0) {
                    RichTextEditorView(controller: editor)
                        .frame(minHeight: Self.minEditorHeight, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Fill.faint))
                        .padding(.horizontal, Space.xxl)
                        .padding(.vertical, Space.md)

                    AttachmentChips(files: attachments)
                        .padding(.horizontal, Space.xxl)
                        .padding(.bottom, Space.sm)

                    if let quote = draft?.quote {
                        quoteSection(quote, available: geometry.size.height)
                    }
                }
            }
            .padding(.bottom, Space.xl)
        }
        .onAppear {
            load()
            if model.options.template, model.options.snapshotPath != nil, let item, item.kind == .mail {
                requestTemplate(item)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            AttachmentFiles.dropped(providers) { addAttachments($0) }
        }
    }

    /// Вложения живут в черновике: переживают перерисовку редактора.
    private var attachments: Binding<[MailBody.Attachment]> {
        Binding(get: { draft?.attachments ?? [] }, set: { draft?.attachments = $0 })
    }

    private func addAttachments(_ files: [MailBody.Attachment]) {
        guard !files.isEmpty else { return }
        draft?.attachments.append(contentsOf: files)
    }

    /// Ящик отправителя. Хранится в черновике, чтобы выбор пережил
    /// перерисовку редактора.
    private var sender: Binding<String?> {
        Binding(
            get: { draft?.accountID },
            set: { account in
                draft?.accountID = account
                applySignature()
            }
        )
    }

    /// Подпись ящика «от» в конце текста; сменили ящик — меняется и она.
    private func applySignature() {
        let signature = model.signatureForDraft(accountID: draft?.accountID, isReply: item != nil)
        editor.setSignature(signature, replacing: appliedSignature)
        appliedSignature = signature
    }

    private var sendButtons: some View {
        HStack(spacing: Space.sm) {
            Button("Отмена") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button {
                commit()
                onSend()
            } label: {
                if isSending { ProgressView().controlSize(.small) } else { Text("Отправить") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
            .help("Отправить · ⌘↩")
        }
        .fixedSize()
    }

    /// Полю ввода всегда остаётся столько — даже если цитату вытянули вверх.
    static let minEditorHeight: Double = 120
    static let defaultQuoteHeight: Double = 200

    /// Цитата под ручкой: высота — сколько человек вытянул, но не больше,
    /// чем оставляет полю ввода его минимум.
    @ViewBuilder
    private func quoteSection(_ quote: OutgoingMail.Quote, available: Double) -> some View {
        // Ручка, галочка и подпись цитаты, поля и вложения над ней.
        let reserved = Self.minEditorHeight + 120
        let upper = max(60, available - reserved)
        let height = min(max(quoteHeight, 60), upper)
        VStack(alignment: .leading, spacing: Space.sm) {
            if includeQuote {
                ResizeHandle(value: $quoteHeight, current: height, range: 60...upper, dimension: .height,
                             growsTowardStart: true, reset: Self.defaultQuoteHeight,
                             name: String(localized: "высота цитаты"), alwaysVisible: true, thickness: Space.xl)
            }
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
                .frame(height: height)
                .opacity(0.85)
            }
        }
        .padding(.horizontal, Space.xxl)
    }

    /// Кнопки оформления, вложения и ссылка.
    private var formatBar: some View {
        HStack(spacing: Space.xxs) {
            RichFormatControls(editor: editor)
            Divider().frame(height: 16).padding(.horizontal, Space.xs)
            RichFormatButton(symbol: "paperclip", help: String(localized: "Прикрепить файлы (или перетащите их сюда)")) {
                addAttachments(AttachmentFiles.choose())
            }
            Divider().frame(height: 16).padding(.horizontal, Space.xs)
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
                .padding(Space.lg)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
    }

    /// «Подготовить шаблон ответа»: только с включённой связью с Trunook.
    /// Модель пишет черновик, где отвечено на каждый вопрос письма; решения,
    /// сроки и суммы она оставляет пометками в скобках — их вписывает человек.
    @ViewBuilder
    private func templateBar(_ item: TimelineItem) -> some View {
        HStack(spacing: Space.md) {
            Button {
                requestTemplate(item)
            } label: {
                Label("Подготовить шаблон ответа", systemImage: "sparkles")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(assist == .loading)
            .help("Модель прочтёт письмо и прошлую переписку и подготовит черновик, где отвечено на каждый вопрос. Решений за вас она не принимает — на их месте пометки в [скобках]. Модель — только на этом Mac.")
            switch assist {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Модель читает переписку…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(code, message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(SummaryPlaque.advice(code) ?? message)
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private func requestTemplate(_ item: TimelineItem) {
        assist = .loading
        Task {
            switch await model.prepareReplyTemplate(for: item) {
            case .success(let text):
                editor.insertTemplate(text)
                assist = .idle
            case .failure(let error):
                assist = .failed(code: error.code, message: error.message)
            }
        }
    }

    private func applyLink() {
        showLink = false
        editor.applyLink(linkAddress)
        editor.focus()
    }

    private func load() {
        guard let draft else { return }
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        showBcc = !draft.bcc.isEmpty
        subject = draft.subject
        // Поле текста появляется чуть позже — текст и подпись после него.
        let text = draft.text
        DispatchQueue.main.async {
            editor.prefill(text)
            applySignature()
        }
    }

    private func commit() {
        guard var updated = draft else { return }
        let text = editor.attributed
        updated.to = PeopleField.merged(to, typed: toText)
        updated.cc = PeopleField.merged(cc, typed: ccText)
        updated.bcc = PeopleField.merged(bcc, typed: bccText)
        updated.subject = subject
        updated.text = text.string
        updated.html = RichTextHTML.html(from: text)
        if !includeQuote { updated.quote = nil }
        draft = updated
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

/// Письмо файлом `.eml`: нажатие — сохранить куда скажут, перетаскивание —
/// на полку Trunook или в Finder. Не `Button` — у кнопки перетаскивание
/// не начинается, поэтому вид кнопки нарисован, а нажатие — жестом.
struct LetterFileButton: View {
    let item: TimelineItem
    let letter: MailBody
    /// Исходный файл письма (открытого из `.eml`) — сохраняется как есть.
    var raw: Data?
    @ViewState private var hovered = false

    var body: some View {
        HoverLabel(title: String(localized: "Сохранить"), symbol: "square.and.arrow.down", expanded: hovered)
            .background(HoverChrome(hovered: hovered, dashed: true))
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(HoverMotion.animation) { hovered = inside } }
            .help(String(localized: "Сохранить письмо файлом · ⇧⌘S. Можно и перетащить — на полку Trunook или в Finder"))
            .onTapGesture { Self.save(item, letter, raw: raw) }
            .actsAsButton(String(localized: "Сохранить")) { Self.save(item, letter, raw: raw) }
            .onDrag {
                guard let url = Self.file(item, letter, raw: raw) else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
    }

    /// «Сохранить как…»: имя — по теме письма, файл — с карантинной
    /// меткой, как вложение: внутри чужие файлы.
    static func save(_ item: TimelineItem, _ letter: MailBody, raw: Data? = nil) {
        guard let data = raw ?? MessageBuilder.export(item, body: letter) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MessageBuilder.exportFileName(item.title)
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let window = NSApp.keyWindow
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try AttachmentSaver.write(data, to: url)
                DebugLog.write("письмо сохранено файлом")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Файл во временной папке: своя подпапка на письмо, чтобы одинаковые
    /// темы не затирали друг друга.
    static func file(_ item: TimelineItem, _ body: MailBody, raw: Data? = nil) -> URL? {
        guard let data = raw ?? MessageBuilder.export(item, body: body) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trudaybook-letters/\(abs(item.id.hashValue))", isDirectory: true)
        let url = folder.appendingPathComponent(MessageBuilder.exportFileName(item.title))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // С карантинной меткой: внутри — вложения чужого человека.
            try AttachmentSaver.write(data, to: url)
            return url
        } catch {
            return nil
        }
    }
}

