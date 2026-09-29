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
        let file = try url()
        try encoder.encode(accounts).write(to: file, options: .atomic)
        // Адреса, серверы, имена входа — только владельцу.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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
/// Все секреты приложения — пароли ящиков и ключ кэша — одной записью
/// Связки ключей («trudaybook-secrets»).
///
/// Почему одной: приложение подписано своим сертификатом без Team ID, и после
/// каждой пересборки или обновления macOS спрашивает доступ к каждой записи
/// отдельно. Было две записи (пароль и ключ кэша) — было два окна; теперь
/// одно. Прежние отдельные записи переносятся сюда при первом чтении и
/// удаляются.
public enum Keychain {
    static let service = "com.trudaybook.mail"
    static let vault = SecretVault(backend: SystemKeychain(service: service))

    public enum Failure: LocalizedError {
        case status(OSStatus)
        case denied

        public var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "код \(status)")
                return String(localized: "Связка ключей: \(message)")
            case .denied:
                return String(localized: "Связка ключей не дала доступ к паролям Trudaybook")
            }
        }
    }

    public static func password(for accountID: String) -> String? {
        vault.password(for: accountID)
    }

    public static func setPassword(_ password: String, for accountID: String, label: String) throws {
        try vault.setPassword(password, for: accountID)
    }

    /// Ключ шифрования кэша писем: берётся из Связки ключей, а нет его —
    /// создаётся. `nil` — Связка не дала (человек отказал в доступе): кэш
    /// тогда живёт с временным ключом и после перезапуска скачается заново.
    public static func cacheKey() -> Data? {
        vault.cacheKey()
    }

    public static func deletePassword(for accountID: String) {
        vault.deletePassword(for: accountID)
    }
}

/// Где лежат записи: Связка ключей или, в тестах, память.
public protocol SecretBackend: Sendable {
    func read(_ account: String) -> (status: OSStatus, data: Data?)
    func write(_ account: String, data: Data, label: String) -> OSStatus
    func delete(_ account: String)
}

/// Записи приложения в Связке ключей: служба `com.trudaybook.mail`.
struct SystemKeychain: SecretBackend {
    let service: String

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> (status: OSStatus, data: Data?) {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func write(_ account: String, data: Data, label: String) -> OSStatus {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return update }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil)
    }

    func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

/// Содержимое общей записи и переносы из прежних отдельных записей.
///
/// Запись читается один раз за запуск и держится в памяти. Если Связка
/// отказала или запись не читается — её не перезаписываем: иначе пустая
/// новая затёрла бы сохранённые пароли.
public final class SecretVault: @unchecked Sendable {
    struct Contents: Codable, Equatable {
        var passwords: [String: String] = [:]
        var cacheKey: Data?
    }

    private enum State {
        case unknown
        case loaded(Contents)
        case unavailable
    }

    static let account = "trudaybook-secrets"
    static let legacyCacheKey = "mail-cache-key"
    static let label = String(localized: "Trudaybook — пароли почты и ключ кэша")

    private let backend: SecretBackend
    private let lock = NSLock()
    private var state = State.unknown

    public init(backend: SecretBackend) {
        self.backend = backend
    }

    public func password(for accountID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard var contents = load() else { return nil }
        if let known = contents.passwords[accountID] { return known }
        // Пароль прежней версии — отдельной записью: перенести и убрать её.
        let legacy = backend.read(accountID)
        guard legacy.status == errSecSuccess, let data = legacy.data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        contents.passwords[accountID] = password
        if save(contents) == errSecSuccess { backend.delete(accountID) }
        return password
    }

    public func setPassword(_ password: String, for accountID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var contents = load() else { throw Keychain.Failure.denied }
        contents.passwords[accountID] = password
        let status = save(contents)
        guard status == errSecSuccess else { throw Keychain.Failure.status(status) }
        backend.delete(accountID)
    }

    public func deletePassword(for accountID: String) {
        lock.lock()
        defer { lock.unlock() }
        if var contents = load(), contents.passwords[accountID] != nil {
            contents.passwords[accountID] = nil
            _ = save(contents)
        }
        backend.delete(accountID)
    }

    public func cacheKey() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard var contents = load() else { return nil }
        if let key = contents.cacheKey, key.count == 32 { return key }
        let legacy = backend.read(Self.legacyCacheKey)
        if legacy.status == errSecSuccess, let key = legacy.data, key.count == 32 {
            contents.cacheKey = key
            if save(contents) == errSecSuccess { backend.delete(Self.legacyCacheKey) }
            return key
        }
        // Прежний ключ есть, но не дался — новый не заводим: кэш под старым
        // ключом тогда пропал бы насовсем.
        guard legacy.status == errSecItemNotFound else { return nil }
        let key = DataSealer.newKeyData()
        contents.cacheKey = key
        return save(contents) == errSecSuccess ? key : nil
    }

    /// Под замком.
    private func load() -> Contents? {
        switch state {
        case .loaded(let contents):
            return contents
        case .unavailable:
            return nil
        case .unknown:
            let read = backend.read(Self.account)
            if read.status == errSecSuccess, let data = read.data,
               let contents = try? JSONDecoder().decode(Contents.self, from: data) {
                state = .loaded(contents)
                return contents
            }
            if read.status == errSecItemNotFound {
                state = .loaded(Contents())
                return Contents()
            }
            state = .unavailable
            return nil
        }
    }

    /// Под замком.
    private func save(_ contents: Contents) -> OSStatus {
        guard let data = try? JSONEncoder().encode(contents) else { return errSecParam }
        let status = backend.write(Self.account, data: data, label: Self.label)
        if status == errSecSuccess { state = .loaded(contents) }
        return status
    }
}
