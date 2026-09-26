import Foundation
import Security
import TrudaybookCore

/// Почтовый ящик: где сервер и под каким именем входить. Без пароля —
/// пароль живёт в Связке ключей (`Keychain`).
///
/// У ящика Exchange сервер — `imapHost` (для подписи), адрес EWS —
/// `ewsURL`, имя входа — `imapUser`; поля SMTP не нужны.
public struct MailAccount: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case imap
        /// Exchange через EWS (свой сервер компании).
        case exchange
    }

    public enum SMTPSecurity: String, Codable, Sendable, CaseIterable {
        /// TLS с первого байта, обычно порт 465.
        case tls
        /// Открытое соединение и `STARTTLS`, обычно порт 587.
        case startTLS
    }

    public var id: String
    public var email: String
    public var displayName: String
    public var imapHost: String
    public var imapPort: Int
    public var imapUser: String
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: SMTPSecurity
    public var smtpUser: String
    public var kind: Kind
    /// `https://сервер/EWS/Exchange.asmx` — только у Exchange.
    public var ewsURL: String?
    /// Папка, куда кнопка «В архив» переносит письма (id папки на сервере).
    /// `nil` — найти архив самим: флаг `\Archive`, «Архив», «Archive».
    public var archiveFolder: String?

    public init(id: String = UUID().uuidString, email: String, displayName: String,
                imapHost: String, imapPort: Int = 993, imapUser: String,
                smtpHost: String, smtpPort: Int, smtpSecurity: SMTPSecurity, smtpUser: String,
                kind: Kind = .imap, ewsURL: String? = nil) {
        self.kind = kind
        self.ewsURL = ewsURL
        self.id = id
        self.email = email
        self.displayName = displayName
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapUser = imapUser
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.smtpUser = smtpUser
    }

    public var me: Person { Person(name: displayName.isEmpty ? nil : displayName, address: email) }

    /// Ящик Exchange. Имя входа по умолчанию — адрес: NTLM его принимает;
    /// если нет — «ДОМЕН\имя».
    public static func exchange(email: String, name: String, server: String, login: String) -> MailAccount? {
        guard let url = EWSClient.endpoint(for: server), let host = url.host else { return nil }
        let user = login.trimmingCharacters(in: .whitespaces)
        return MailAccount(email: email, displayName: name, imapHost: host, imapPort: url.port ?? 443,
                           imapUser: user.isEmpty ? email : user,
                           smtpHost: "", smtpPort: 0, smtpSecurity: .tls, smtpUser: "",
                           kind: .exchange, ewsURL: url.absoluteString)
    }

    /// Как ящик устроен — для списка в настройках.
    public var serverSummary: String {
        switch kind {
        case .exchange:
            return "Exchange · \(imapHost) · \(imapUser)"
        case .imap:
            return "\(imapHost):\(imapPort) · \(imapUser)   ↑ \(smtpHost):\(smtpPort) · \(smtpSecurity == .tls ? "TLS" : "STARTTLS")"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, email, displayName, imapHost, imapPort, imapUser, smtpHost, smtpPort, smtpSecurity, smtpUser, kind, ewsURL
        case archiveFolder
    }

    /// Ящики, сохранённые до появления Exchange, вида не знают — это IMAP.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        email = try values.decode(String.self, forKey: .email)
        displayName = try values.decode(String.self, forKey: .displayName)
        imapHost = try values.decode(String.self, forKey: .imapHost)
        imapPort = try values.decode(Int.self, forKey: .imapPort)
        imapUser = try values.decode(String.self, forKey: .imapUser)
        smtpHost = try values.decode(String.self, forKey: .smtpHost)
        smtpPort = try values.decode(Int.self, forKey: .smtpPort)
        smtpSecurity = try values.decode(SMTPSecurity.self, forKey: .smtpSecurity)
        smtpUser = try values.decode(String.self, forKey: .smtpUser)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .imap
        ewsURL = try values.decodeIfPresent(String.self, forKey: .ewsURL)
        archiveFolder = try values.decodeIfPresent(String.self, forKey: .archiveFolder)
    }
}

/// Готовые настройки популярных ящиков.
public enum MailPreset: String, CaseIterable, Identifiable, Sendable {
    case iCloud, yandex, mailRu, gmail, exchange, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iCloud: return "iCloud"
        case .yandex: return String(localized: "Яндекс")
        case .mailRu: return "Mail.ru"
        case .gmail: return "Gmail"
        case .exchange: return "Exchange"
        case .custom: return String(localized: "Другой")
        }
    }

    /// Где взять пароль приложения: обычный пароль эти сервисы по IMAP не пускают.
    public var passwordHint: String {
        switch self {
        case .iCloud:
            return String(localized: "Нужен пароль приложения: account.apple.com → Вход и безопасность → Пароли приложений.")
        case .yandex:
            return String(localized: "Нужен пароль приложения (id.yandex.ru → Безопасность) и включённый IMAP в настройках Почты.")
        case .mailRu:
            return String(localized: "Нужен пароль для внешнего приложения: настройки Mail.ru → Безопасность.")
        case .gmail:
            return String(localized: "Нужен пароль приложения: myaccount.google.com → Безопасность (при включённой двухэтапной проверке).")
        case .exchange:
            return String(localized: "Обычный пароль рабочей учётной записи — тот же, что для Outlook и веб-почты.")
        case .custom:
            return String(localized: "Адреса серверов и порты даст администратор почты.")
        }
    }

    /// Настройки по адресу. Для iCloud имя входа — часть адреса до «@»:
    /// так советует Apple; полный адрес пробуется запасным вариантом.
    public func account(email: String, name: String) -> MailAccount {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        switch self {
        case .iCloud:
            return MailAccount(email: email, displayName: name, imapHost: "imap.mail.me.com", imapUser: local,
                               smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS, smtpUser: email)
        case .yandex:
            return MailAccount(email: email, displayName: name, imapHost: "imap.yandex.ru", imapUser: email,
                               smtpHost: "smtp.yandex.ru", smtpPort: 465, smtpSecurity: .tls, smtpUser: email)
        case .mailRu:
            return MailAccount(email: email, displayName: name, imapHost: "imap.mail.ru", imapUser: email,
                               smtpHost: "smtp.mail.ru", smtpPort: 465, smtpSecurity: .tls, smtpUser: email)
        case .gmail:
            return MailAccount(email: email, displayName: name, imapHost: "imap.gmail.com", imapUser: email,
                               smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls, smtpUser: email)
        case .exchange:
            // Сервер вводится в форме; здесь — догадка по домену.
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            return MailAccount.exchange(email: email, name: name, server: "mail.\(domain)", login: email)
                ?? MailAccount(email: email, displayName: name, imapHost: "", imapUser: email,
                               smtpHost: "", smtpPort: 0, smtpSecurity: .tls, smtpUser: "", kind: .exchange)
        case .custom:
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            return MailAccount(email: email, displayName: name, imapHost: "imap.\(domain)", imapUser: email,
                               smtpHost: "smtp.\(domain)", smtpPort: 587, smtpSecurity: .startTLS, smtpUser: email)
        }
    }

    /// Страница, где создают пароль приложения, — чтобы не искать её по меню.
    public var appPasswordPage: URL? {
        switch self {
        case .iCloud: return URL(string: "https://account.apple.com/account/manage/section/security")
        case .yandex: return URL(string: "https://id.yandex.ru/security/app-passwords")
        case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
        case .mailRu: return URL(string: "https://account.mail.ru/user/2-step-auth/passwords")
        case .exchange, .custom: return nil
        }
    }

    /// Пароль приложения Apple — четыре группы по четыре буквы через дефис.
    /// Обычный пароль Apple ID iCloud по IMAP не примет, и лучше сказать
    /// об этом сразу, чем ждать отказа сервера.
    public static func looksLikeAppleAppPassword(_ password: String) -> Bool {
        password.range(of: #"^[a-zA-Z]{4}-[a-zA-Z]{4}-[a-zA-Z]{4}-[a-zA-Z]{4}$"#, options: .regularExpression) != nil
    }

    /// Вставленный пароль часто приезжает с пробелом или переводом строки по краям.
    public static func cleanPassword(_ password: String) -> String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Угадать сервис по адресу.
    public static func guess(for email: String) -> MailPreset {
        let domain = email.split(separator: "@").last?.lowercased() ?? ""
        switch domain {
        case "icloud.com", "me.com", "mac.com": return .iCloud
        case "yandex.ru", "ya.ru", "yandex.com": return .yandex
        case "mail.ru", "inbox.ru", "list.ru", "bk.ru": return .mailRu
        case "gmail.com", "googlemail.com": return .gmail
        default: return .custom
        }
    }
}

/// Список ящиков — JSON в «Поддержке приложений», без паролей.
public enum AccountStore {
    static func url() throws -> URL {
        try SQLiteDatabase.applicationSupportURL("accounts.json")
    }

    public static func load() -> [MailAccount] {
        guard let url = try? url(), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MailAccount].self, from: data)) ?? []
    }

    public static func save(_ accounts: [MailAccount]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: try url(), options: .atomic)
    }
}

/// Пароли, прочитанные из Связки ключей, — в памяти до выхода.
///
/// Каждое чтение из Связки может спросить разрешение: приложение подписано
/// своим сертификатом, и после обновления macOS считает его новым. Почта,
/// календарь и сверка адреса берут пароль отсюда — окно появится не больше
/// одного раза за запуск.
public final class PasswordCache: @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    public init() {}

    public func password(for accountID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = passwords[accountID] { return known }
        let read = Keychain.password(for: accountID)
        passwords[accountID] = read
        return read
    }

    /// Новый пароль — после подключения ящика.
    public func remember(_ password: String, for accountID: String) {
        lock.lock()
        passwords[accountID] = password
        lock.unlock()
    }

    public func forget(_ accountID: String) {
        lock.lock()
        passwords[accountID] = nil
        lock.unlock()
    }
}

/// Пароли ящиков в Связке ключей.
///
/// Доступ к записи привязан к подписи приложения; подпись стабильная
/// (свой сертификат), поэтому после пересборки macOS пароль не переспрашивает.
public enum Keychain {
    static let service = "com.trudaybook.mail"

    public enum Failure: LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            if case .status(let status) = self {
                let message = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "код \(status)")
                return String(localized: "Связка ключей: \(message)")
            }
            return nil
        }
    }

    public static func password(for accountID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, for accountID: String, label: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        let data = Data(password.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.status(update) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Trudaybook — \(label)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    public static func deletePassword(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
