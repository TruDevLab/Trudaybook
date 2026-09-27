import AppKit
import TrudaybookCore

/// Команды помощника Trunook: файл в своей папке — ответ файлом туда,
/// куда просили.
///
/// Исполняется только закрытый список `TrunookCommand` — всё обратимое
/// и видное в Trudaybook. Письма отсюда не уходят: «ответь Андрею»
/// открывает черновик, а отправляет человек. Выключено по умолчанию.
@MainActor
final class TrunookCommandInbox {
    weak var model: AppModel?

    var folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Trudaybook/commands", isDirectory: true)

    private var source: DispatchSourceFileSystemObject?
    /// Когда исполнялись последние команды: не больше 30 в минуту —
    /// помощник, застрявший в цикле, не должен перебрать всю почту.
    private var recent: [Date] = []

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            DebugLog.write("Trunook: папка команд не создана — \(error.localizedDescription)")
            return
        }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        DebugLog.write("Trunook: принимаю команды помощника")
        drain()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Разобрать всё, что лежит. Скрытые файлы — недописанные.
    func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            guard let data, data.count <= TrunookCommand.maxFileSize,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                DebugLog.write("Trunook: команда не разобралась — пропущена")
                continue
            }
            let reply = (json["reply"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardized }
            let now = Date()
            recent = recent.filter { now.timeIntervalSince($0) < 60 }
            guard recent.count < 30 else {
                answer(reply, ["ok": false, "error": String(localized: "Слишком много команд подряд — подождите минуту.")])
                continue
            }
            recent.append(now)
            switch TrunookCommand.parse(json) {
            case .success(let command):
                answer(reply, execute(command))
            case .failure(let error):
                DebugLog.write("Trunook: команда отклонена — \(error)")
                answer(reply, ["ok": false, "error": String(localized: "Такой команды Trudaybook не знает.")])
            }
        }
    }

    // MARK: - Исполнение

    private func execute(_ command: TrunookCommand) -> [String: Any] {
        guard let model else { return ["ok": false, "error": String(localized: "Trudaybook не готов")] }
        // Неразобранное и сегодняшнее — о них и спрашивают.
        var seen = Set<String>()
        let pool = (model.unresolved + model.mail(onDayOf: model.now))
            .filter { $0.kind == .mail && seen.insert($0.id).inserted }

        func withLetter(_ query: String, _ act: (TimelineItem) -> String) -> [String: Any] {
            switch TrunookCommand.resolve(query, in: pool) {
            case .found(let item):
                return ["ok": true, "text": act(item)]
            case .none:
                return ["ok": false, "error": String(localized: "Такого письма среди неразобранных и сегодняшних нет.")]
            case .ambiguous(let items):
                let list = items.map { "«\($0.title)» (\($0.mail?.from.display ?? ""))" }.joined(separator: ", ")
                return ["ok": false, "error": String(localized: "Подходит несколько писем: \(list). Уточните, какое.")]
            }
        }

        switch command {
        case let .list(from, importantOnly, limit, label):
            let letters = model.unresolved.filter { $0.kind == .mail }
            let listed = TrunookCommand.listing(letters, from: from, importantOnly: importantOnly, limit: limit,
                                                label: label, priority: model.priority(of:),
                                                labelOf: model.label(of:))
            DebugLog.write("Trunook: команда — список писем (\(listed.count))")
            return ["ok": true, "total": letters.count, "letters": listed]
        case .open(let query):
            return withLetter(query) { item in
                NSApp.activate()
                model.open(itemID: item.id)
                return String(localized: "Открыто в Trudaybook: «\(item.title)»")
            }
        case let .snooze(query, until):
            guard until > model.now else {
                return ["ok": false, "error": String(localized: "Это время уже прошло.")]
            }
            return withLetter(query) { item in
                model.reschedule(item, to: until)
                let when = AppLanguage.formatter(ru: "d MMMM, HH:mm", template: "dMMMMjmm").string(from: until)
                return String(localized: "Отложено до \(when): «\(item.title)»")
            }
        case let .priority(query, level):
            return withLetter(query) { item in
                model.setPriority(level, for: item.id)
                return String(localized: "Приоритет «\(level.title)»: «\(item.title)»")
            }
        case .done(let query):
            return withLetter(query) { item in
                model.markDone(item.id)
                return String(localized: "Отмечено разобранным: «\(item.title)»")
            }
        case let .label(query, label):
            return withLetter(query) { item in
                // Метку человека помощник не переписывает — её выбрали руками.
                guard MailLabelRules.trunookMayWrite(over: model.labels[item.id]) else {
                    return String(localized: "Метку этому письму поставил человек — оставлена как есть: «\(item.title)»")
                }
                model.setLabel(label, for: item.id, source: .trunook)
                return label.map { String(localized: "Метка «\($0.singular)»: «\(item.title)»") }
                    ?? String(localized: "Метка снята: «\(item.title)»")
            }
        case let .draft(query, text):
            return withLetter(query) { item in
                NSApp.activate()
                model.open(itemID: item.id, reply: true, prefill: text)
                return String(localized: "Черновик ответа открыт в Trudaybook, отправит его человек: «\(item.title)»")
            }
        }
    }

    // MARK: - Ответ

    private func answer(_ url: URL?, _ payload: [String: Any]) {
        guard let url else { return }
        guard Self.mayWrite(to: url) else {
            DebugLog.write("Trunook: ответ мимо домашней папки — отказ")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Писать ответ — только в свою домашнюю и во временную папку: путь
    /// пришёл снаружи, и писать по нему куда угодно нельзя.
    static func mayWrite(to url: URL) -> Bool {
        let path = url.standardized.path
        let allowed = [
            FileManager.default.homeDirectoryForCurrentUser.standardized.path,
            FileManager.default.temporaryDirectory.standardized.path,
            "/tmp", "/private/tmp",
        ]
        return allowed.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
