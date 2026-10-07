import AppKit
import TrudaybookCore

/// Связь с вырезом Trunook — файлами, а не сетью.
///
/// Туда: плашка — JSON-файл во входящей папке Trunook. Обратно: нажатая
/// кнопка — одно слово в файле, путь к которому мы назвали сами. Trunook
/// не исполняет присланного, а мы исполняем только свои кнопки: ответ
/// сверяется со списком кнопок этой же плашки.
@MainActor
final class TrunookLink {
    static let shared = TrunookLink()

    static let bundleID = "com.trunook.Trunook"
    /// Последний выпуск Trunook — там образ диска для установки.
    static let download = URL(string: "https://github.com/TruDevLab/Trunook/releases/latest")!

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Разрешено ли в Trunook показывать уведомления от других программ.
    static var acceptsNotices: Bool {
        UserDefaults(suiteName: bundleID)?.bool(forKey: "inboxEnabled") == true
    }

    static var defaultInbox: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Trunook/inbox", isDirectory: true)
    }

    /// Куда класть плашки. В тестовом режиме — своя папка: проверки
    /// не должны появляться в настоящем вырезе.
    var inbox = TrunookLink.defaultInbox

    /// Куда Trunook пишет нажатую кнопку. В домашней папке — Trunook пишет
    /// только туда (и во временную).
    static var repliesFolder: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Trudaybook/trunook-replies", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    struct Button {
        let id: String
        let title: String
        var positive = false
        var icon: String?
        /// Кнопка открывает окно Trudaybook — Trunook выведет его вперёд.
        var opens = false
    }

    /// Плашки, ждущие нажатия: файл ответа → что с ним делать.
    private var pending: [URL: (buttons: Set<String>, until: Date, handler: (String) -> Void)] = [:]
    private var timer: Timer?

    /// Показать плашку. Кнопок не больше двух — больше Trunook не рисует.
    /// `optional` — кнопки предлагают, а не спрашивают: плашка уйдёт сама
    /// через `hold`. `celebrate` — залп конфетти из чёлки.
    func send(source: String, title: String, icon: String = "message", hold: TimeInterval? = nil,
              buttons: [Button] = [], optional: Bool = true, celebrate: Bool = false,
              event: (title: String, start: Date)? = nil,
              preview: [String: String]? = nil,
              previewFull: [String: Any]? = nil,
              previewActions: [Button] = [],
              onAnswer: ((String) -> Void)? = nil) {
        let buttons = Array(buttons.prefix(2))
        var notice: [String: Any] = [
            "source": source, "title": title, "icon": icon,
            "hold": hold ?? (buttons.isEmpty ? 8 : 12),
        ]
        if celebrate { notice["celebrate"] = true }
        // О какой встрече плашка: Trunook сверит со своим календарём и не
        // покажет вторую, если напоминает о ней сам.
        if let event {
            notice["event"] = ["title": event.title, "start": ISO8601DateFormatter().string(from: event.start)]
        }
        // Письмо для превью в вырезе (`from`, `subject`, `text`, `date`):
        // кнопка «preview» открывает его там, а не отвечает нам.
        // Быстрые действия превью («Ответить всем», «В архив»…) уходят
        // внутри него и исполняются так же, как кнопки плашки.
        if let preview = previewFull ?? preview {
            var full: [String: Any] = preview
            if !previewActions.isEmpty {
                full["actions"] = previewActions.map(Self.json(of:))
            }
            notice["preview"] = full
        }
        if !buttons.isEmpty, let onAnswer {
            let reply = Self.repliesFolder.appendingPathComponent("\(UUID().uuidString).reply")
            notice["actions"] = buttons.map(Self.json(of:))
            notice["optional"] = optional
            notice["reply"] = reply.path
            // Не нажали, пока плашка жила, и ещё пять минут сверху, — ждать нечего.
            let wait = optional ? (hold ?? 12) + 300 : 3600
            pending[reply] = (Set((buttons + previewActions).map(\.id)), Date().addingTimeInterval(wait), onAnswer)
            watchReplies()
        }
        write(notice)
    }

    private static func json(of button: Button) -> [String: Any] {
        var action: [String: Any] = ["id": button.id, "title": button.title, "positive": button.positive]
        if let icon = button.icon { action["icon"] = icon }
        if button.opens { action["opens"] = true }
        return action
    }

    /// Файл пишется во временный и переносится — иначе Trunook может
    /// прочитать недописанный.
    private func write(_ notice: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: notice, options: [.sortedKeys]) else { return }
        let id = "trudaybook-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            // Не `.json`: прежний Trunook забирал и скрытые файлы с этим расширением.
            let temporary = inbox.appendingPathComponent(".\(id).tmp")
            try data.write(to: temporary)
            try FileManager.default.moveItem(at: temporary, to: inbox.appendingPathComponent("\(id).json"))
        } catch {
            DebugLog.write("Trunook: плашка не легла — \(error.localizedDescription)")
        }
    }

    /// Проверять файлы ответов раз в секунду, пока есть кого ждать.
    private func watchReplies() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReplies() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkReplies() {
        for (file, entry) in pending {
            if let answer = try? String(contentsOf: file, encoding: .utf8) {
                pending[file] = nil
                try? FileManager.default.removeItem(at: file)
                let word = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                // Исполняем только свои кнопки: чужое слово в файле — не команда.
                guard entry.buttons.contains(word) else {
                    DebugLog.write("Trunook: ответ «\(word.prefix(20))» не из кнопок плашки — пропущен")
                    continue
                }
                entry.handler(word)
            } else if Date() > entry.until {
                pending[file] = nil
            }
        }
        if pending.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
