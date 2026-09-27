import Foundation

/// Метка письма для разбора «Не разобрано»: что это за письмо по сути.
///
/// Четыре вида, а не десяток: метка нужна, чтобы отделить то, что ждёт
/// человека, от того, что можно пролистать пачкой. Больше видов — больше
/// ошибок модели на границах и больше кнопок в фильтре.
public enum MailLabel: String, CaseIterable, Identifiable, Sendable {
    /// Ждёт решения или ответа, есть срок.
    case important
    /// Живая переписка с людьми, но без спешки.
    case conversation
    /// Сообщения систем и сервисов: Jira, банк, доставка, календарь.
    case notification
    /// Рассылки, новости, реклама.
    case newsletter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .important: String(localized: "Важное")
        case .conversation: String(localized: "Переписка")
        case .notification: String(localized: "Уведомления")
        case .newsletter: String(localized: "Рассылки")
        }
    }

    /// Одно письмо: «Рассылка», а не «Рассылки».
    public var singular: String {
        switch self {
        case .important: String(localized: "Важное")
        case .conversation: String(localized: "Переписка")
        case .notification: String(localized: "Уведомление")
        case .newsletter: String(localized: "Рассылка")
        }
    }

    public var symbol: String {
        switch self {
        case .important: "exclamationmark.circle.fill"
        case .conversation: "bubble.left.and.bubble.right.fill"
        case .notification: "bell.fill"
        case .newsletter: "newspaper.fill"
        }
    }

    /// Разбор ответа модели: английское имя, русское слово или близкое.
    /// Модель пишет как хочет, и строгий разбор терял бы половину меток.
    public init?(loose raw: String) {
        let word = raw.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        if let exact = MailLabel(rawValue: word) { self = exact; return }
        let table: [(MailLabel, [String])] = [
            (.important, ["важн", "срочн", "urgent", "priority", "action"]),
            (.conversation, ["перепис", "личн", "conversation", "personal", "people", "reply"]),
            (.notification, ["уведомл", "notif", "system", "service", "automated", "alert"]),
            (.newsletter, ["рассыл", "реклам", "новост", "newsletter", "promo", "marketing", "digest", "news"]),
        ]
        for (label, stems) in table where stems.contains(where: word.hasPrefix) {
            self = label
            return
        }
        return nil
    }
}

/// Кто поставил метку. Человек главнее всех: его метку ни Trunook,
/// ни правило не переписывают.
public enum MailLabelSource: String, Sendable {
    case user
    case trunook
    case rule
}

public struct StoredLabel: Hashable, Sendable {
    public var label: MailLabel
    public var source: MailLabelSource

    public init(label: MailLabel, source: MailLabelSource) {
        self.label = label
        self.source = source
    }
}

/// Метки без модели — по заголовкам и адресу отправителя.
///
/// Только то, в чём ошибиться трудно: у рассылки есть `List-Unsubscribe`
/// или `Precedence: bulk`, у робота — `Auto-Submitted` или адрес вида
/// `noreply@`. Всё прочее — «важное» или «переписка» — решает модель:
/// по заголовкам этого не понять.
public enum MailLabelRules {
    public static func guess(_ mail: MailInfo) -> MailLabel? {
        if mail.isBulk { return .newsletter }
        if mail.isAutomatic || isRobot(mail.from.address) { return .notification }
        return nil
    }

    /// Адрес, на который не отвечают люди.
    public static func isRobot(_ address: String?) -> Bool {
        guard let local = address?.lowercased().split(separator: "@").first else { return false }
        let name = local.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        let robots = ["noreply", "donotreply", "notifications", "notification", "notify", "mailer",
                      "mailerdaemon", "postmaster", "bounce", "alerts", "robot", "system", "automailer"]
        return robots.contains { name == $0 || name.hasPrefix($0) }
    }

    /// Какая метка видна: поставленная (человеком или Trunook), иначе — правило.
    public static func effective(stored: StoredLabel?, mail: MailInfo?) -> MailLabel? {
        if let stored { return stored.label }
        return mail.flatMap(guess)
    }

    /// Можно ли Trunook поставить метку поверх имеющейся.
    public static func trunookMayWrite(over stored: StoredLabel?) -> Bool {
        stored?.source != .user
    }
}
