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
            VStack(alignment: .leading, spacing: 4) {
                CollapsingFlow(expanded: true, spacing: 6, lineSpacing: 6) {
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text("\(file.name) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                .lineLimit(1)
                            Button { files.remove(at: index) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Убрать")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                if total > AttachmentFiles.warnSize {
                    Label("Вместе больше 20 МБ — почтовый сервер может не принять", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
    static func open(_ file: MailBody.Attachment) {
        if AttachmentRisk.isExecutable(name: file.name) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Открыть «\(safeName(file.name))»?")
            alert.informativeText = String(localized: "Это не документ, а файл, который запускает программу или команды. Открывайте, только если ждали его от этого отправителя.")
            alert.addButton(withTitle: String(localized: "Не открывать"))
            alert.addButton(withTitle: String(localized: "Открыть"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        guard let url = temporaryCopy(of: file) else { return }
        NSWorkspace.shared.open(url)
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

/// Вложения полученного письма плашками. Щелчок — меню: открыть, сохранить
/// в «Загрузки», сохранить как… Плашку можно вытащить мышью в Finder.
struct ReceivedAttachments: View {
    let files: [MailBody.Attachment]
    @ViewState private var saved: [URL] = []
    @ViewState private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CollapsingFlow(expanded: true, spacing: 6, lineSpacing: 6) {
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
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func chip(_ file: MailBody.Attachment) -> some View {
        let available = file.data != nil
        return Menu {
            Button("Открыть") { AttachmentSaver.open(file) }
            Button("Сохранить в «Загрузки»") { run { try AttachmentSaver.saveToDownloads([file]) } }
            Button("Сохранить как…") { run { try AttachmentSaver.saveAs(file).map { [$0] } ?? [] } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(for: file))
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        } primaryAction: {
            run { try AttachmentSaver.saveToDownloads([file]) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!available)
        .help(available
              ? "Щелчок — сохранить в «Загрузки». Долгое нажатие или правая кнопка — открыть, сохранить как… Можно вытащить в Finder."
              : "Содержимое не загрузилось")
        .onDrag {
            guard let url = AttachmentSaver.temporaryCopy(of: file) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Открыть") { AttachmentSaver.open(file) }
            Button("Сохранить в «Загрузки»") { run { try AttachmentSaver.saveToDownloads([file]) } }
            Button("Сохранить как…") { run { try AttachmentSaver.saveAs(file).map { [$0] } ?? [] } }
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
