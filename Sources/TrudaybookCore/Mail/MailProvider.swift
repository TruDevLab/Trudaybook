import Foundation

/// Тело письма для правой панели.
public struct MailBody: Hashable, Sendable {
    public var html: String?
    public var text: String?
    public var attachments: [Attachment]
    /// Приглашение на встречу — текст `text/calendar` (или вложения `.ics`).
    public var calendar: String?

    public struct Attachment: Hashable, Sendable {
        public var name: String
        public var size: Int
        public var mimeType: String
        /// Содержимое — чтобы вложение можно было открыть и сохранить.
        public var data: Data?

        public init(name: String, size: Int, mimeType: String, data: Data? = nil) {
            self.name = name
            self.size = size
            self.mimeType = mimeType
            self.data = data
        }
    }

    public init(html: String? = nil, text: String? = nil, attachments: [Attachment] = [], calendar: String? = nil) {
        self.html = html
        self.text = text
        self.attachments = attachments
        self.calendar = calendar
    }

    /// Текст для цитаты в ответе: простой текст, а если его нет — HTML без тегов.
    public var plainText: String {
        if let text, !text.isEmpty { return text }
        guard let html else { return "" }
        return HTMLText.strip(html)
    }
}

/// Исходящее письмо.
public struct OutgoingMail: Hashable, Sendable {
    /// Цитата исходного письма — как в Mail: под своим текстом, со своим
    /// оформлением, без «>» в редакторе.
    public struct Quote: Hashable, Sendable {
        /// «23 сентября 2026, 07:48, Анна пишет:»
        public var attribution: String
        public var html: String?
        public var text: String

        public init(attribution: String, html: String?, text: String) {
            self.attribution = attribution
            self.html = html
            self.text = text
        }
    }

    public var to: [Person]
    public var cc: [Person]
    public var subject: String
    /// Свой текст простым текстом — для текстовой копии письма.
    public var text: String
    /// Свой текст с оформлением. `nil` — без оформления, из `text`.
    public var html: String?
    public var quote: Quote?
    /// `Message-ID` письма, на которое отвечаем.
    public var inReplyTo: String?
    public var references: [String]
    /// С какого ящика отправить. `nil` — с того, куда пришло исходное
    /// письмо, а если его нет — с первого.
    public var accountID: String?
    /// Прикреплённые файлы (с содержимым).
    public var attachments: [MailBody.Attachment]

    public init(to: [Person], cc: [Person] = [], subject: String, text: String, html: String? = nil,
                quote: Quote? = nil, inReplyTo: String? = nil, references: [String] = [],
                accountID: String? = nil, attachments: [MailBody.Attachment] = []) {
        self.attachments = attachments
        self.to = to
        self.cc = cc
        self.subject = subject
        self.text = text
        self.html = html
        self.quote = quote
        self.inReplyTo = inReplyTo
        self.references = references
        self.accountID = accountID
    }
}

/// Папка почтового ящика.
public struct MailFolder: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable, CaseIterable {
        case inbox, sent, archive, drafts, trash, junk, other
    }

    /// Имя на сервере — по нему папку и выбирают.
    public var id: String
    /// Имя для человека.
    public var name: String
    public var role: Role
    /// Полный путь для человека: «Работа / Проекты».
    public var path: String
    /// Чья папка, когда ящиков несколько: адрес для заголовка в меню.
    /// `nil` — у папок одного ящика и у общих («Входящие» всех ящиков).
    public var accountName: String?

    public init(id: String, name: String, role: Role, path: String? = nil, accountName: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.path = path ?? name
        self.accountName = accountName
    }
}

/// Идентификатор письма: `mail:<ящик>:<остальное>`. Остальное каждый
/// источник устраивает по-своему, а ящик нужен, чтобы отправить действие
/// с письмом туда, откуда оно пришло.
public enum MailItemID {
    public static func account(of id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "mail", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }
}

/// Источник почты: тестовые письма, IMAP или Exchange.
///
/// Интерфейс работает только через этот протокол и не знает, откуда
/// пришло письмо.
public protocol MailProvider: AnyObject, Sendable {
    /// Подпись в интерфейсе: «Тестовая почта», адрес аккаунта.
    var displayName: String { get }
    /// Мои адреса — чтобы не отвечать самому себе при «Ответить всем».
    var ownAddresses: Set<String> { get }

    /// Письма Входящих, полученные в промежутке `[from, to)`.
    func messages(from: Date, to: Date) async throws -> [TimelineItem]
    func body(of itemID: String) async throws -> MailBody
    func archive(_ itemID: String) async throws
    /// Отправить. Если это ответ, `itemID` — исходное письмо: сервер
    /// пометит его отвеченным.
    func send(_ mail: OutgoingMail, replyingTo itemID: String?) async throws

    /// Папки ящика, Входящие первыми.
    func folders() async throws -> [MailFolder]
    /// Последние письма папки, новые первыми.
    func messages(inFolder folderID: String, limit: Int) async throws -> [TimelineItem]
    /// Поиск в папке (или во всех, если `nil`). `fullText` — искать и в тексте
    /// писем на сервере, а не только в теме и отправителе.
    func search(_ text: String, inFolder folderID: String?, fullText: Bool) async throws -> [TimelineItem]
    /// Сходить на сервер за новым прямо сейчас.
    func refresh() async throws
    /// Кого звать, когда почта поменялась сама (пришло письмо, ответили с телефона).
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async
    /// Ответ на приглашение из письма `itemID`: Exchange — своими командами
    /// (и календарь обновит сам), остальные — письмом iTIP организатору.
    func respond(to itemID: String, invitation: Invitation, response: InvitationResponse, comment: String?) async throws
}

public extension MailProvider {
    func respond(to itemID: String, invitation: Invitation, response: InvitationResponse, comment: String?) async throws {
        throw InvitationError.unsupported
    }
}

public enum InvitationError: LocalizedError {
    case unsupported
    case noOrganizer

    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Этот ящик не умеет отвечать на приглашения")
        case .noOrganizer: String(localized: "В приглашении нет адреса организатора — ответить некому")
        }
    }
}

public enum ReplyBuilder {
    /// Черновик ответа на письмо.
    ///
    /// «Ответить всем» добавляет в копию всех получателей исходного письма,
    /// кроме меня и того, кому отвечаем. Цитата — простым текстом с `>`.
    public static func reply(
        to item: TimelineItem,
        body: MailBody?,
        all: Bool,
        ownAddresses: Set<String>,
        calendar: Calendar = .current
    ) -> OutgoingMail? {
        switch item.detail {
        case .mail(let info):
            let recipient = info.replyTo ?? info.from
            var cc: [Person] = []
            if all {
                let skip = ownAddresses.union([recipient.normalizedAddress].compactMap { $0 })
                cc = unique((info.to + info.cc).filter { person in
                    guard let address = person.normalizedAddress else { return false }
                    return !skip.contains(address)
                })
            }
            let quote = body.map { body in
                OutgoingMail.Quote(
                    attribution: attribution(author: info.from, date: item.time, calendar: calendar),
                    html: body.html,
                    text: body.plainText
                )
            }
            return OutgoingMail(
                to: [recipient],
                cc: cc,
                subject: replySubject(item.title),
                text: "",
                quote: quote,
                inReplyTo: info.messageID,
                references: info.references + [info.messageID].compactMap { $0 }
            )

        case .event(let info):
            // Ответ на встречу — письмо организатору и участникам.
            let people = ([info.organizer].compactMap { $0 } + info.attendees.filter { !$0.isMe }.map(\.person))
                .filter { person in
                    guard let address = person.normalizedAddress else { return false }
                    return !ownAddresses.contains(address)
                }
            let recipients = unique(people)
            guard let first = recipients.first else { return nil }
            return OutgoingMail(
                to: [first],
                cc: all ? Array(recipients.dropFirst()) : [],
                subject: replySubject(item.title),
                text: ""
            )

        case .reminder:
            return nil
        }
    }

    /// «Re: » в начале темы, если его там ещё нет. Учитываются и русские
    /// приставки, которые ставит Outlook.
    public static func replySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for prefix in ["re:", "отв:", "ответ:"] where lower.hasPrefix(prefix) {
            return trimmed
        }
        return "Re: " + trimmed
    }

    static func attribution(author: Person, date: Date, calendar: Calendar) -> String {
        let formatter = AppLanguage.formatter(ru: "d MMMM yyyy, HH:mm", template: "dMMMMyyyyHHmm", timeZone: calendar.timeZone)
        formatter.calendar = calendar
        return String(localized: "\(formatter.string(from: date)), \(author.display) пишет:")
    }

    /// Цитата для текстовой копии письма — с «>» в начале строк. В HTML-части
    /// и в редакторе её нет: там цитата оформлена полосой слева.
    public static func quotedLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    private static func unique(_ people: [Person]) -> [Person] {
        var seen: Set<String> = []
        return people.filter { person in
            let key = person.normalizedAddress ?? person.display
            return seen.insert(key).inserted
        }
    }
}

/// Грубое превращение HTML в текст — для цитаты и краткого содержания.
/// Точность тут не нужна: письмо целиком показывает браузерный движок.
public enum HTMLText {
    public static func strip(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<(script|style|head)[^>]*>.*?</\\1>", "(?i)<br\\s*/?>", "(?i)</(p|div|tr|li|h[1-6])>"] {
            let replacement = pattern.contains("script") ? "" : "\n"
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&laquo;": "«", "&raquo;": "»", "&mdash;": "—"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
