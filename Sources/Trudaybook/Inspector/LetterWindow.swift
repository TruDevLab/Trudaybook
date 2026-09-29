import AppKit
import SwiftUI
import TrudaybookCore

/// Письмо в отдельном окне — из ящика или из файла `.eml`.
@MainActor
final class LetterDocument: ObservableObject {
    let item: TimelineItem
    /// Файл, из которого письмо открыто; `nil` — письмо из ящика.
    let fileURL: URL?
    /// Байты файла: «Сохранить» кладёт письмо как было, а не пересобирает.
    let raw: Data?
    @Published var body: MailBody?
    @Published var failed = false

    init(item: TimelineItem, fileURL: URL? = nil, raw: Data? = nil, body: MailBody? = nil) {
        self.item = item
        self.fileURL = fileURL
        self.raw = raw
        self.body = body
    }
}

/// Окна писем. Своё окно на каждое письмо: два письма рядом — сравнить,
/// переписать из одного в другое. Второй раз то же письмо (или тот же файл)
/// не открывает второе окно, а поднимает первое.
@MainActor
enum LetterWindow {
    private static var windows: [String: NSWindow] = [:]
    private static var documents: [String: LetterDocument] = [:]
    private static var closeObservers: [String: NSObjectProtocol] = [:]
    /// Откуда встанет следующее окно: каждое — лесенкой от предыдущего.
    private static var cascadePoint = NSPoint.zero
    private static let frameName = "TrudaybookLetter"

    /// Окно письма в фокусе — для ⌘S.
    static var key: LetterDocument? {
        guard let window = NSApp.keyWindow else { return nil }
        return windows.first { $0.value === window }.flatMap { documents[$0.key] }
    }

    /// Открытое окно — для отладочного снимка.
    static var current: NSWindow? { windows.values.first { $0.isVisible } }

    /// Письмо из ящика: тело подгружается уже в окне.
    static func show(_ item: TimelineItem, model: AppModel) {
        guard item.kind == .mail, !raise(item.id) else { return }
        let document = LetterDocument(item: item)
        // Выбранное письмо уже загружено — не просить его у сервера второй раз.
        if model.selectedID == item.id, let body = model.body {
            document.body = body
        } else {
            Task {
                let body = await model.letterBody(of: item.id)
                document.body = body
                document.failed = body == nil
            }
        }
        present(document, model: model)
    }

    /// Файл `.eml` — открыли в Finder, бросили на значок или через
    /// «Открыть файл…». Содержимое файла в журнал не пишется.
    static func open(file url: URL, model: AppModel) {
        let id = EmailFile.itemID(for: url)
        guard !raise(id) else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard (values?.fileSize ?? 0) <= EmailFile.maxSize,
              let data = try? Data(contentsOf: url),
              let letter = EmailFile.letter(from: data, id: id, fallbackDate: values?.contentModificationDate ?? model.now)
        else {
            model.errorMessage = String(localized: "В файле нет письма, которое можно открыть.")
            return
        }
        DebugLog.write("открыт файл письма")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        present(LetterDocument(item: letter.item, fileURL: url, raw: data, body: letter.body), model: model)
    }

    /// «Открыть файл…»: письмо `.eml` или встреча `.ics`.
    static func chooseFile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "eml"), .init(filenameExtension: "ics")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        model.open(urls: panel.urls)
    }

    private static func raise(_ id: String) -> Bool {
        guard let window = windows[id] else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    private static func present(_ document: LetterDocument, model: AppModel) {
        let id = document.item.id
        let hosting = NSHostingView(rootView: LetterWindowView(document: document).environmentObject(model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = document.item.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Пустая панель инструментов — заголовок высотой 52, как у заметки.
        window.toolbar = NSToolbar(identifier: "TrudaybookLetter")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 560, height: 420)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        if let url = document.fileURL { window.representedURL = url }
        // Первое окно — где его оставили в прошлый раз, следующие — лесенкой.
        if windows.isEmpty {
            if !window.setFrameUsingName(frameName) { window.center() }
            cascadePoint = window.cascadeTopLeft(from: .zero)
        } else {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        windows[id] = window
        documents[id] = document
        closeObservers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { closed(id) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func closed(_ id: String) {
        windows[id]?.saveFrame(usingName: frameName)
        windows[id] = nil
        documents[id] = nil
        if let observer = closeObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Главное окно — туда уходит черновик ответа.
    static func showMainWindow() {
        NSApp.windows.first { $0.frameAutosaveName == "TrudaybookMain" }?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct LetterWindowView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var document: LetterDocument
    @ViewState private var showRemote = false
    @ViewState private var paper: Bool?

    private var item: TimelineItem { document.item }
    private var fromFile: Bool { document.fileURL != nil }
    /// Письмо из ящика, которое модель знает, — его можно разобрать отсюда.
    private var known: TimelineItem? { fromFile ? nil : model.item(item.id) }

    var body: some View {
        VStack(spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    LetterFields(item: item, account: source,
                                 accountTitle: fromFile ? String(localized: "Файл") : String(localized: "Ящик"))
                    if let attachments = document.body?.attachments, !attachments.isEmpty {
                        ReceivedAttachments(files: attachments)
                    }
                    if item.mail?.isInvitation == true || document.body?.calendar != nil {
                        invitationNote
                    }
                    if let body = document.body, !showRemote {
                        RemoteImagesNotice(letter: body) { showRemote = true }
                    }
                }
                .padding(16)
                Divider()
                if let body = document.body {
                    LetterBodyPane(letter: body, allowRemote: showRemote, paper: $paper)
                } else if document.failed {
                    Text("Письмо не загрузилось — проверьте подключение к почте.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
            .background(GlassPanelBackground(cornerRadius: Panel.radius))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 8)
        .frame(minWidth: 540, minHeight: 400)
        .ignoresSafeArea(edges: .top)
        .background {
            AppBackgroundView()
                .background(WindowAppearanceSetter(appearance: model.windowAppearance))
        }
        .environment(\.auroraTheme, model.customBackground)
    }

    /// Ящик (когда их несколько) или имя файла.
    private var source: String? {
        if let url = document.fileURL { return url.lastPathComponent }
        return model.accountName(of: item)
    }

    // MARK: - Строка действий

    /// Слева — место под кнопки окна и отправитель; справа — действия.
    private var header: some View {
        HStack(spacing: 6) {
            Label(item.mail?.from.display ?? "", systemImage: "envelope.open")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HoverIconButton(title: ItemAction.reply.title, symbol: ItemAction.reply.symbol,
                            help: String(localized: "Ответить — черновик откроется в главном окне")) { reply(all: false) }
            HoverIconButton(title: String(localized: "Ответить всем"), symbol: ItemAction.replyAll.symbol,
                            help: String(localized: "Ответить всем — черновик откроется в главном окне")) { reply(all: true) }
            HoverIconButton(title: String(localized: "Встреча"), symbol: "calendar.badge.plus",
                            help: String(localized: "Назначить встречу с участниками письма — откроется в главном окне")) {
                model.startMeeting(with: item)
                LetterWindow.showMainWindow()
            }
            if let known {
                let availability = model.availability(of: .archive, for: known)
                HoverIconButton(title: ItemAction.archive.title, symbol: ItemAction.archive.symbol,
                                help: { if case .disabled(let reason) = availability { return reason }
                                        return ItemAction.archive.title }()) {
                    model.perform(.archive, on: known.id)
                }
                .disabled(!availability.isEnabled)
                HoverIconButton(title: String(localized: "На таймлайне"), symbol: "calendar.day.timeline.left",
                                help: String(localized: "Показать письмо в главном окне")) {
                    model.open(itemID: known.id)
                    LetterWindow.showMainWindow()
                }
            }
            if known != nil {
                PriorityMenu(item: item)
            }
            if let body = document.body {
                LetterFileButton(item: item, letter: body, raw: document.raw)
            }
        }
        // Кольцо фокуса на первой кнопке в только что открытом окне — лишнее.
        .focusEffectDisabled()
        // Кнопки окна кончаются на 78 pt.
        .padding(.leading, 84)
        .padding(.trailing, 6)
        .frame(height: 36)
    }

    /// Приглашение отвечается из главного окна: там календарь дня рядом.
    private var invitationNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(Color.accentColor)
            Text(fromFile
                 ? String(localized: "В письме приглашение на встречу. Ответить на него можно из письма в ящике.")
                 : String(localized: "В письме приглашение на встречу — ответить можно в главном окне."))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }

    private func reply(all: Bool) {
        model.startReply(fromWindow: item, body: document.body, all: all)
        LetterWindow.showMainWindow()
    }
}
