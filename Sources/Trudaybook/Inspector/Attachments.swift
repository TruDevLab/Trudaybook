import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TrudaybookCore

/// Файлы для письма и встречи: выбор, перетаскивание, плашки.
enum AttachmentFiles {
    /// Больше этого почтовые серверы обычно не принимают.
    static let warnSize = 20 * 1024 * 1024

    static func load(_ url: URL) -> MailBody.Attachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return MailBody.Attachment(name: url.lastPathComponent, size: data.count, mimeType: type, data: data)
    }

    /// Окно выбора файлов.
    @MainActor
    static func choose() -> [MailBody.Attachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Прикрепить")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(load)
    }

    /// Файлы, брошенные мышью.
    static func dropped(_ providers: [NSItemProvider], add: @escaping @MainActor ([MailBody.Attachment]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let attachment = load(url) else { return }
                Task { @MainActor in add([attachment]) }
            }
        }
        return true
    }
}

/// Прикреплённые файлы плашками: имя, размер, крестик.
struct AttachmentChips: View {
    @Binding var files: [MailBody.Attachment]

    private var total: Int { files.reduce(0) { $0 + $1.size } }

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                CollapsingFlow(expanded: true, spacing: Space.sm, lineSpacing: Space.sm) {
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: Space.xs) {
                            Image(systemName: "paperclip")
                            Text("\(file.name) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                .lineLimit(1)
                            Button { files.remove(at: index) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .labelHelp(String(localized: "Убрать"))
                        }
                        .font(.caption)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.xs)
                        .background(Capsule().fill(Fill.subtle))
                    }
                }
                if total > AttachmentFiles.warnSize {
                    InlineNotice(String(localized: "Вместе больше 20 МБ — почтовый сервер может не принять"))
                        .font(.caption)
                }
            }
        }
    }
}

/// Вложения полученного письма: открыть, сохранить, вытащить мышью.
@MainActor
enum AttachmentSaver {
    /// Запись вложения с карантинной меткой, как у скачанного браузером или
    /// Mail: без неё Gatekeeper не проверит скачанное из письма, и `.command`
    /// или `.pkg` откроются без единого вопроса.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Trudaybook",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
        ]
        var marked = url
        try? marked.setResourceValues(values)
    }

    /// Временная копия — для «Открыть» и перетаскивания в Finder.
    /// Своя папка на каждый файл: у двух вложений бывает одно имя.
    static func temporaryCopy(of file: MailBody.Attachment) -> URL? {
        guard let data = file.data else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trudaybook-вложения", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(safeName(file.name))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(data, to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Открыть вложение. Исполняемое — скрипт, установщик, программу —
    /// только после вопроса: вложение прислал чужой человек.
    /// `url` — уже сохранённая копия (иначе — временная), `app` — чем открыть.
    static func open(_ file: MailBody.Attachment, at url: URL? = nil, with app: URL? = nil) {
        guard confirmOpening(file), let url = url ?? temporaryCopy(of: file) else { return }
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func confirmOpening(_ file: MailBody.Attachment) -> Bool {
        guard AttachmentRisk.isExecutable(name: file.name) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Открыть «\(safeName(file.name))»?")
        alert.informativeText = String(localized: "Это не документ, а файл, который запускает программу или команды. Открывайте, только если ждали его от этого отправителя.")
        alert.addButton(withTitle: String(localized: "Не открывать"))
        alert.addButton(withTitle: String(localized: "Открыть"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Тип файла — по расширению очищенного имени, иначе по MIME из письма.
    static func contentType(of file: MailBody.Attachment) -> UTType {
        let ext = (safeName(file.name) as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? UTType(mimeType: file.mimeType) ?? .data
    }

    /// Программы, которые открывают такой файл: первой — та, что по умолчанию.
    static func applications(for file: MailBody.Attachment) -> [URL] {
        let type = contentType(of: file)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: type) {
            apps.removeAll { $0.standardizedFileURL == preferred.standardizedFileURL }
            apps.insert(preferred, at: 0)
        }
        // Одна программа бывает в нескольких местах (копия в «Загрузках»,
        // старая версия) — показываем первую по имени.
        var seen = Set<String>()
        return apps.filter { seen.insert(FileManager.default.displayName(atPath: $0.path)).inserted }
    }

    /// «Другая программа…» — выбор в «Программах».
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Открыть")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// В «Загрузки»; занятое имя получает номер: «Отчёт 2.pdf».
    @discardableResult
    static func saveToDownloads(_ files: [MailBody.Attachment]) throws -> [URL] {
        let folder = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return try files.compactMap { file in
            guard let data = file.data else { return nil }
            let url = freeURL(in: folder, name: safeName(file.name))
            try write(data, to: url)
            return url
        }
    }

    /// Окно «Сохранить как…».
    static func saveAs(_ file: MailBody.Attachment) throws -> URL? {
        guard let data = file.data else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName(file.name)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try write(data, to: url)
        return url
    }

    /// Все вложения — в выбранную папку.
    static func saveAll(_ files: [MailBody.Attachment]) throws -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Сохранить сюда")
        guard panel.runModal() == .OK, let folder = panel.url else { return [] }
        return try files.compactMap { file in
            guard let data = file.data else { return nil }
            let url = freeURL(in: folder, name: safeName(file.name))
            try write(data, to: url)
            return url
        }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Имя из письма — его задаёт отправитель. Очистка — `AttachmentRisk.safeName`.
    static func safeName(_ name: String) -> String {
        AttachmentRisk.safeName(name) ?? String(localized: "Вложение")
    }

    static func freeURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            url = folder.appendingPathComponent(candidate)
            number += 1
        }
        return url
    }
}

/// Вложения полученного письма плашками. Щелчок — меню: открыть, открыть
/// с помощью, скачать; двойной щелчок — открыть временную копию.
/// Плашку можно вытащить мышью в Finder.
struct ReceivedAttachments: View {
    let files: [MailBody.Attachment]
    @ViewState private var saved: [URL] = []
    @ViewState private var problem: String?
    /// Плашка под курсором — по имени файла.
    @ViewState private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CollapsingFlow(expanded: true, spacing: Space.sm, lineSpacing: Space.sm) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    chip(file)
                }
                if files.count > 1 {
                    Menu {
                        Button("В «Загрузки»") { run { try AttachmentSaver.saveToDownloads(files) } }
                        Button("В папку…") { run { try AttachmentSaver.saveAll(files) } }
                    } label: {
                        Label("Сохранить все", systemImage: "square.and.arrow.down.on.square")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if !saved.isEmpty {
                HStack(spacing: Space.sm) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                    Text(saved.count == 1
                         ? "Сохранено: \(saved[0].deletingLastPathComponent().lastPathComponent)/\(saved[0].lastPathComponent)"
                         : "Сохранено файлов: \(saved.count) — \(saved[0].deletingLastPathComponent().lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Показать в Finder") { AttachmentSaver.reveal(saved) }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
            if let problem {
                InlineNotice(problem)
                    .font(.caption)
            }
        }
    }

    private func chip(_ file: MailBody.Attachment) -> some View {
        let available = file.data != nil
        return HStack(spacing: Space.xs) {
            Image(systemName: icon(for: file))
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.down")
                .font(.app(.micro, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(Capsule().fill(Color.primary.opacity(hovered == file.name ? 0.12 : 0.07)))
        .contentShape(Capsule())
        .opacity(available ? 1 : Alpha.disabled)
        .onHover { inside in hovered = inside ? file.name : (hovered == file.name ? nil : hovered) }
        .help(available
              ? "Щелчок — меню: открыть, открыть с помощью, скачать. Двойной щелчок — сразу открыть. Можно вытащить в Finder."
              : "Содержимое не загрузилось")
        // Двойной — первым: одиночный ждёт, не будет ли второго щелчка.
        .onTapGesture(count: 2) { if available { AttachmentSaver.open(file) } }
        .onTapGesture { if available { menu(for: file).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } }
        .actsAsButton { if available { menu(for: file).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } }
        .accessibilityAction(named: Text("Открыть")) { if available { AttachmentSaver.open(file) } }
        .accessibilityAction(named: Text("Скачать в «Загрузки»")) { if available { download(file) } }
        .onDrag {
            guard let url = AttachmentSaver.temporaryCopy(of: file) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            if available {
                Button("Открыть") { AttachmentSaver.open(file) }
                Menu("Открыть с помощью") {
                    ForEach(AttachmentSaver.applications(for: file), id: \.self) { app in
                        Button(Self.appTitle(app, isDefault: app == AttachmentSaver.applications(for: file).first)) {
                            AttachmentSaver.open(file, with: app)
                        }
                    }
                    Divider()
                    Button("Другая программа…") { openWithChosenApp(file) }
                }
                Divider()
                Button("Скачать в «Загрузки»") { download(file) }
                Button("Скачать и открыть") { download(file, then: .open) }
                Button("Скачать и показать в Finder") { download(file, then: .reveal) }
                Button("Сохранить как…") { run { try AttachmentSaver.saveAs(file).map { [$0] } ?? [] } }
            }
        }
    }

    /// Меню по щелчку — `NSMenu` под курсором: у SwiftUI `Menu` нет
    /// двойного щелчка, он раскрывается уже на нажатии.
    private func menu(for file: MailBody.Attachment) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureItem(String(localized: "Открыть"), key: "") { AttachmentSaver.open(file) })
        let withItem = NSMenuItem(title: String(localized: "Открыть с помощью"), action: nil, keyEquivalent: "")
        let apps = NSMenu()
        for (index, app) in AttachmentSaver.applications(for: file).enumerated() {
            let item = ClosureItem(Self.appTitle(app, isDefault: index == 0), key: "") { AttachmentSaver.open(file, with: app) }
            let image = NSWorkspace.shared.icon(forFile: app.path)
            image.size = NSSize(width: 16, height: 16)
            item.image = image
            apps.addItem(item)
        }
        if !apps.items.isEmpty { apps.addItem(.separator()) }
        apps.addItem(ClosureItem(String(localized: "Другая программа…"), key: "") { openWithChosenApp(file) })
        withItem.submenu = apps
        menu.addItem(withItem)
        menu.addItem(.separator())
        menu.addItem(ClosureItem(String(localized: "Скачать в «Загрузки»"), key: "") { download(file) })
        menu.addItem(ClosureItem(String(localized: "Скачать и открыть"), key: "") { download(file, then: .open) })
        menu.addItem(ClosureItem(String(localized: "Скачать и показать в Finder"), key: "") { download(file, then: .reveal) })
        menu.addItem(ClosureItem(String(localized: "Сохранить как…"), key: "") {
            run { try AttachmentSaver.saveAs(file).map { [$0] } ?? [] }
        })
        return menu
    }

    private static func appTitle(_ app: URL, isDefault: Bool) -> String {
        let name = (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
        return isDefault ? String(localized: "\(name) (по умолчанию)") : name
    }

    private func openWithChosenApp(_ file: MailBody.Attachment) {
        guard let app = AttachmentSaver.chooseApplication() else { return }
        AttachmentSaver.open(file, with: app)
    }

    private enum AfterDownload { case nothing, open, reveal }

    private func download(_ file: MailBody.Attachment, then next: AfterDownload = .nothing) {
        let url: URL
        do {
            guard let written = try AttachmentSaver.saveToDownloads([file]).first else { return }
            url = written
            saved = [written]
            problem = nil
        } catch {
            problem = String(localized: "Не сохранилось: \(error.localizedDescription)")
            return
        }
        switch next {
        case .nothing: break
        case .open: AttachmentSaver.open(file, at: url)
        case .reveal: AttachmentSaver.reveal([url])
        }
    }

    private func icon(for file: MailBody.Attachment) -> String {
        let type = file.mimeType.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type.contains("sheet") || type.contains("excel") { return "tablecells" }
        if type == "message/rfc822" { return "envelope" }
        return "doc"
    }

    private func run(_ action: () throws -> [URL]) {
        do {
            let urls = try action()
            if !urls.isEmpty { saved = urls; problem = nil }
        } catch {
            problem = String(localized: "Не сохранилось: \(error.localizedDescription)")
        }
    }
}
