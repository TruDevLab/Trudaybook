import AppKit
import UserNotifications
import TrudaybookCore

/// Уведомления о новых письмах: в Центре уведомлений macOS и/или в вырезе
/// Trunook. Какие — выбирается в настройках, выбор хранится в UserDefaults.
@MainActor
final class MailNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var isEnabled: Bool { didSet { save(isEnabled, "notifyEnabled") } }
    @Published var toMac: Bool { didSet { save(toMac, "notifyMac") } }
    @Published var toTrunook: Bool { didSet { save(toTrunook, "notifyTrunook") } }
    /// Отправитель и тема в тексте. Выключено — просто «Новое письмо».
    @Published var showPreview: Bool { didSet { save(showPreview, "notifyPreview") } }
    @Published var playSound: Bool { didSet { save(playSound, "notifySound") } }
    /// Кнопки «Открыть в Trudaybook» и «Показать превью» на плашке Trunook.
    /// Прежде были «Ответить» и «В архив» — решение о письме, которого
    /// человек ещё не видел.
    @Published var trunookButtons: Bool { didSet { save(trunookButtons, "notifyTrunookButtons") } }
    /// Разрешение macOS: `nil` — ещё не узнавали.
    @Published private(set) var macStatus: UNAuthorizationStatus?

    /// Щелчок по уведомлению — открыть письмо.
    var onOpen: ((String) -> Void)?
    /// «Ответить» с текстом прямо в уведомлении macOS — отправить сразу.
    var onQuickReply: ((String, String) -> Void)?
    /// «Ответить» без текста (плашка Trunook) — открыть ответ в окне.
    var onReplyInApp: ((String) -> Void)?
    var onArchive: ((String) -> Void)?
    /// Текст письма для превью в вырезе Trunook — начало тела письма.
    var loadText: ((String) async -> String?)?
    /// Быстрые действия превью в Trunook: ответить всем, переслать,
    /// напомнить через час (архив — `onArchive`).
    var onReplyAll: ((String) -> Void)?
    var onForward: ((String) -> Void)?
    var onSnooze: ((String, TimeInterval) -> Void)?
    /// В тестовом режиме настройки не записываются.
    var persists = true

    private let defaults = UserDefaults.standard

    override init() {
        let defaults = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        isEnabled = flag("notifyEnabled", false)
        toMac = flag("notifyMac", true)
        toTrunook = flag("notifyTrunook", false)
        showPreview = flag("notifyPreview", true)
        playSound = flag("notifySound", true)
        trunookButtons = flag("notifyTrunookButtons", true)
        super.init()
    }

    private func save(_ value: Bool, _ key: String) {
        if persists { defaults.set(value, forKey: key) }
    }

    /// Центр уведомлений есть только у приложения с бандлом — в тестах его нет.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func activate() {
        center?.delegate = self
        // Кнопки под уведомлением о письме. «Ответить» — с полем ввода:
        // короткий ответ уходит, не открывая окна.
        let reply = UNTextInputNotificationAction(identifier: "reply", title: String(localized: "Ответить"), options: [],
                                                  textInputButtonTitle: String(localized: "Отправить"), textInputPlaceholder: String(localized: "Ответ"))
        let archive = UNNotificationAction(identifier: "archive", title: String(localized: "В архив"), options: [])
        center?.setNotificationCategories([
            UNNotificationCategory(identifier: "mail", actions: [reply, archive], intentIdentifiers: []),
        ])
        Task { await refreshMacStatus() }
    }

    func refreshMacStatus() async {
        guard let center else { return }
        macStatus = await center.notificationSettings().authorizationStatus
    }

    /// Спросить разрешение macOS — когда уведомления включают в настройках.
    func requestMacPermission() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshMacStatus()
    }

    // MARK: - Trunook

    static var trunookURL: URL? { TrunookLink.appURL }
    static var trunookDownload: URL { TrunookLink.download }
    static var trunookAcceptsNotices: Bool { TrunookLink.acceptsNotices }

    // MARK: - Письма

    /// Сообщить о новых письмах. Больше трёх сразу — одним уведомлением.
    /// `ownPlaque` — письма, о которых вырез Trunook узнает своей плашкой
    /// (приглашения с «Принять»), — в него второй раз не шлём.
    func notify(_ letters: [TimelineItem], ownPlaque: Set<String> = [], account: (TimelineItem) -> String?) {
        guard isEnabled, !letters.isEmpty else { return }
        let newest = letters.sorted { $0.time > $1.time }
        if newest.count > 3 {
            let senders = Array(NSOrderedSet(array: newest.compactMap { $0.mail?.from.display })) as? [String] ?? []
            let title = String(localized: "\(newest.count) \(RecurrenceRule.plural(newest.count, String(localized: "новое письмо"), String(localized: "новых письма"), String(localized: "новых писем")))")
            let body = showPreview ? String(localized: "От: ") + senders.prefix(3).joined(separator: ", ") + (senders.count > 3 ? "…" : "") : ""
            deliver(id: "batch-\(UUID().uuidString)", title: title, subtitle: nil, body: body, itemID: newest.first?.id)
            return
        }
        for letter in newest {
            let sender = letter.mail?.from.display ?? String(localized: "Новое письмо")
            if showPreview {
                deliver(id: letter.id, title: sender, subtitle: account(letter), body: letter.title, itemID: letter.id,
                        skipTrunook: ownPlaque.contains(letter.id), letter: letter)
            } else {
                deliver(id: letter.id, title: String(localized: "Новое письмо"), subtitle: account(letter), body: "", itemID: letter.id,
                        skipTrunook: ownPlaque.contains(letter.id))
            }
        }
    }

    /// Пока в Trunook шёл фокус, уведомления ждали, — теперь одно общее.
    func notifyAfterFocus(_ letters: [TimelineItem], important: Int) {
        guard isEnabled, !letters.isEmpty else { return }
        let count = letters.count
        let title = String(localized: "Пока вы работали — \(count) \(RecurrenceRule.plural(count, String(localized: "письмо"), String(localized: "письма"), String(localized: "писем")))")
        let body = important > 0 ? String(localized: "Важных: \(important)") : ""
        let newest = letters.max { $0.time < $1.time }
        deliver(id: "batch-focus-\(UUID().uuidString)", title: title, subtitle: nil, body: body, itemID: newest?.id)
    }

    /// Пробное уведомление — из настроек, чтобы увидеть, как выглядит.
    func sendTest() {
        let was = isEnabled
        isEnabled = true
        deliver(id: "test-\(UUID().uuidString)", title: showPreview ? String(localized: "Анна Смирнова") : String(localized: "Новое письмо"), subtitle: nil,
                body: showPreview ? String(localized: "Так будет выглядеть уведомление о новом письме") : "", itemID: nil)
        isEnabled = was
    }

    private func deliver(id: String, title: String, subtitle: String?, body: String, itemID: String?,
                         skipTrunook: Bool = false, letter: TimelineItem? = nil) {
        if toTrunook, !skipTrunook {
            let text = body.isEmpty ? title : "\(title): \(body)"
            let source = subtitle ?? String(localized: "Почта")
            if trunookButtons, let itemID, !id.hasPrefix("batch"), !id.hasPrefix("test") {
                // Решать, отвечать ли и в архив ли, можно только прочитав
                // письмо: на плашке — открыть его здесь или прочитать
                // превью прямо в вырезе. Превью — только когда разрешено
                // показывать отправителя и тему.
                var buttons: [TrunookLink.Button] = [
                    .init(id: "open", title: String(localized: "Открыть в Trudaybook"), positive: true, icon: "open", opens: true),
                ]
                // Под текстом превью — быстрые действия: решать их можно,
                // уже прочитав письмо.
                let quick: [TrunookLink.Button] = [
                    .init(id: "replyAll", title: String(localized: "Ответить всем"), icon: "replyAll", opens: true),
                    .init(id: "archive", title: String(localized: "В архив"), icon: "archive"),
                    .init(id: "forward", title: String(localized: "Переслать"), icon: "forward", opens: true),
                    .init(id: "snooze1h", title: String(localized: "Через 1 час"), icon: "snooze"),
                ]
                if showPreview, letter != nil {
                    buttons.append(.init(id: "preview", title: String(localized: "Показать превью"), icon: "eye"))
                }
                let handler: (String) -> Void = { [weak self] answer in
                    switch answer {
                    // «preview» приходит от прежнего Trunook, который превью
                    // показывать не умеет, — тогда письмо открывается здесь.
                    case "open", "preview":
                        NSApp.activate()
                        self?.onOpen?(itemID)
                    case "replyAll":
                        NSApp.activate()
                        self?.onReplyAll?(itemID)
                    case "forward":
                        NSApp.activate()
                        self?.onForward?(itemID)
                    case "archive":
                        self?.onArchive?(itemID)
                    case "snooze1h":
                        self?.onSnooze?(itemID, 3600)
                    default:
                        break
                    }
                }
                guard showPreview, let letter else {
                    TrunookLink.shared.send(source: source, title: text, buttons: buttons, onAnswer: handler)
                    return deliverMac(id: id, title: title, subtitle: subtitle, body: body, itemID: itemID)
                }
                // Текст письма — тело с сервера, но не дольше трёх секунд:
                // плашка о новом письме не должна опаздывать. Не успело —
                // начало письма из списка.
                Task { [weak self] in
                    let loaded = await self?.previewText(of: itemID)
                    let preview = Self.preview(of: letter, text: loaded)
                    TrunookLink.shared.send(source: source, title: text, buttons: buttons, preview: preview,
                                            previewActions: quick, onAnswer: handler)
                }
            } else {
                TrunookLink.shared.send(source: source, title: text)
            }
        }
        deliverMac(id: id, title: title, subtitle: subtitle, body: body, itemID: itemID)
    }

    /// Начало тела письма, не дольше трёх секунд.
    private func previewText(of itemID: String) async -> String? {
        guard let loadText else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await loadText(itemID) }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Поле `preview` плашки: от кого, тема, текст, когда пришло.
    static func preview(of letter: TimelineItem, text: String?) -> [String: String] {
        let date = DateFormatter()
        date.dateStyle = .short
        date.timeStyle = .short
        date.doesRelativeDateFormatting = true
        let body = (text?.isEmpty == false ? text : letter.mail?.snippet) ?? ""
        return [
            "from": letter.mail?.from.formatted ?? "",
            "subject": letter.title,
            "text": String(body.prefix(3000)),
            "date": date.string(from: letter.time),
        ]
    }

    /// Текст тела для превью: абзацы сохраняются, пустые строки — не больше
    /// одной подряд.
    static func previewText(_ body: MailBody) -> String {
        let text = body.plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(3000))
    }

    private func deliverMac(id: String, title: String, subtitle: String?, body: String, itemID: String?) {
        guard toMac, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.threadIdentifier = "mail"
        if itemID != nil { content.categoryIdentifier = "mail" }
        if playSound { content.sound = .default }
        if let itemID { content.userInfo = ["itemID": itemID] }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { DebugLog.write("уведомления: macOS не принял — \(error.localizedDescription)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Показывать и тогда, когда Trudaybook на переднем плане: письмо пришло,
    /// а окно смотрит на другой день.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let itemID = response.notification.request.content.userInfo["itemID"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard let itemID else { return NSApp.activate() }
            switch action {
            case "reply":
                let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    NSApp.activate()
                    self.onReplyInApp?(itemID)
                } else {
                    self.onQuickReply?(itemID, text)
                }
            case "archive":
                self.onArchive?(itemID)
            default:
                NSApp.activate()
                self.onOpen?(itemID)
            }
        }
    }
}
