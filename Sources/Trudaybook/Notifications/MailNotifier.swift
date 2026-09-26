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
    /// Кнопки «Ответить» и «В архив» на плашке Trunook.
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
                        skipTrunook: ownPlaque.contains(letter.id))
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
                         skipTrunook: Bool = false) {
        if toTrunook, !skipTrunook {
            let text = body.isEmpty ? title : "\(title): \(body)"
            let source = subtitle ?? String(localized: "Почта")
            if trunookButtons, let itemID, !id.hasPrefix("batch"), !id.hasPrefix("test") {
                TrunookLink.shared.send(source: source, title: text, buttons: [
                    .init(id: "reply", title: String(localized: "Ответить"), positive: true, icon: "message"),
                    .init(id: "archive", title: String(localized: "В архив"), icon: "check"),
                ]) { [weak self] answer in
                    switch answer {
                    case "reply":
                        NSApp.activate()
                        self?.onReplyInApp?(itemID)
                    case "archive":
                        self?.onArchive?(itemID)
                    default:
                        break
                    }
                }
            } else {
                TrunookLink.shared.send(source: source, title: text)
            }
        }
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
