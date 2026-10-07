import Foundation
import TrudaybookCore

/// Как дела у синхронизации — для строки состояния в окне.
public struct MailSyncStatus: Sendable, Equatable {
    public var lastSync: Date?
    public var error: String?
    public var isSyncing = false

    public init(lastSync: Date? = nil, error: String? = nil, isSyncing: Bool = false) {
        self.lastSync = lastSync
        self.error = error
        self.isSyncing = isSyncing
    }
}

/// Почта по IMAP (чтение, папки, архив) и SMTP (отправка).
///
/// Всё, что показывает интерфейс, берётся из кэша, а сервер спрашивается
/// в фоне раз в полторы минуты: так таймлайн открывается сразу и не мигает
/// при каждом обращении к сети.
public actor IMAPMailProvider: MailProvider {
    public nonisolated let account: MailAccount
    public nonisolated var displayName: String { account.email }
    public nonisolated var ownAddresses: Set<String> { [account.email.lowercased()] }

    private let cache: MailCache
    private let client: IMAPClient
    private let password: @Sendable () -> String?
    private let log: @Sendable (String) -> Void
    private var loggedIn = false
    private var mailboxes: [IMAPMailbox] = []
    /// С какого дня письма лежат в кэше. Раньше — дозагружаются по запросу.
    private var syncedSince: Date
    /// `Message-ID` писем, на которые есть ответ в «Отправленных».
    private var repliedMessageIDs: Set<String> = []
    private var headers: [String: ParsedMessage] = [:]
    private var changeHandler: (@Sendable () -> Void)?
    private var statusHandler: (@Sendable (MailSyncStatus) -> Void)?
    private var status = MailSyncStatus()
    private var pollTask: Task<Void, Never>?

    public static let pollInterval: Duration = .seconds(90)

    public init(
        account: MailAccount,
        cache: MailCache,
        syncSince: Date,
        password: @escaping @Sendable () -> String?,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.account = account
        self.cache = cache
        self.password = password
        self.log = log
        syncedSince = Calendar.current.startOfDay(for: syncSince)
        client = IMAPClient(host: account.imapHost, port: account.imapPort)
    }

    // MARK: - Жизненный цикл

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        changeHandler = handler
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (MailSyncStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

    /// Синхронизация сразу и дальше по таймеру.
    public func start() {
        // Ушедшие в архив держим на таймлайне месяц, дальше они не нужны.
        try? cache.pruneMoved(before: Date().addingTimeInterval(-40 * 86_400), account: account.id)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        await client.logout()
        loggedIn = false
    }

    /// Больше этого проверка не ждёт: форма настроек не должна висеть.
    public static let verifyTimeout: Double = 30

    /// Проверить настройки ящика до сохранения: соединиться и войти.
    /// Возвращает настройки с тем именем входа, которое подошло.
    public static func verify(
        _ account: MailAccount,
        password: String,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MailAccount {
        let client = IMAPClient(host: account.imapHost, port: account.imapPort)
        await client.setLog(log)
        log("проверка входа: \(account.imapUser) на \(account.imapHost):\(account.imapPort)")
        do {
            let working = try await OnceContinuation.withTimeout(verifyTimeout) {
                var working = account
                try await client.connect()
                do {
                    try await client.login(user: account.imapUser, password: password)
                } catch MailNetworkError.authentication(_) where account.imapUser != account.email {
                    // iCloud пускает кого по короткому имени, кого по полному
                    // адресу — смотря какой ящик. Пробуем второй вариант.
                    log("вход по «\(account.imapUser)» не принят — пробую полный адрес")
                    try await client.connect()
                    try await client.login(user: account.email, password: password)
                    working.imapUser = account.email
                }
                let boxes = try await client.listMailboxes()
                log("вход удался, папок: \(boxes.count)")
                return working
            }
            await client.logout()
            return working
        } catch {
            log("проверка не удалась: \(error)")
            await client.disconnect()
            throw error
        }
    }

    // MARK: - Соединение

    private func connected() async throws {
        if loggedIn, await client.isConnected { return }
        loggedIn = false
        guard let password = password() else {
            throw MailNetworkError.authentication(String(localized: "пароль не найден в Связке ключей — введите его в настройках"))
        }
        await client.setLog(log)
        try await client.connect()
        try await client.login(user: account.imapUser, password: password)
        loggedIn = true
        mailboxes = try await client.listMailboxes()
    }

    /// Выполнить работу с сервером; при обрыве — переподключиться и повторить один раз.
    private func perform<T>(_ body: () async throws -> T) async throws -> T {
        try await connected()
        do {
            return try await body()
        } catch {
            guard Self.isConnectionLoss(error) else { throw error }
            log("соединение оборвалось (\(error.localizedDescription)) — переподключаюсь")
            loggedIn = false
            await client.disconnect()
            try await connected()
            return try await body()
        }
    }

    static func isConnectionLoss(_ error: Error) -> Bool {
        if let error = error as? MailNetworkError { return error == .closed || error == .timeout }
        let domain = (error as NSError).domain
        return domain == NSPOSIXErrorDomain || domain == NSURLErrorDomain
    }

    private func select(_ mailbox: String) async throws {
        if await client.selected != mailbox { try await client.select(mailbox) }
    }

    // MARK: - Синхронизация

    public func refresh() async throws {
        report(MailSyncStatus(lastSync: status.lastSync, error: status.error, isSyncing: true))
        do {
            try await perform { try await syncMailbox("INBOX", since: syncedSince) }
            if let sent = mailbox(for: .sent) {
                try await perform { try await syncMailbox(sent, since: syncedSince) }
                recomputeReplies(sentMailbox: sent)
            }
            report(MailSyncStatus(lastSync: Date(), error: nil, isSyncing: false))
            changeHandler?()
        } catch {
            report(MailSyncStatus(lastSync: status.lastSync, error: Self.describe(error), isSyncing: false))
            throw error
        }
    }

    private func report(_ new: MailSyncStatus) {
        status = new
        statusHandler?(new)
    }

    /// Привести кэш папки к серверу начиная с `since`: новое скачать,
    /// пропавшее (переложили с телефона) убрать, у остального обновить флаги.
    private func syncMailbox(_ name: String, since: Date) async throws {
        let selection = try await client.select(name)
        try cache.resetIfNeeded(uidValidity: selection.uidValidity, mailbox: name, account: account.id)

        let onServer = Set(try await client.uidSearch("SINCE \(IMAPDate.searchDay(since))"))
        let known = Set(cache.uids(mailbox: name, account: account.id, since: since))

        let gone = Array(known.subtracting(onServer))
        if !gone.isEmpty {
            try cache.delete(gone, mailbox: name, account: account.id)
            gone.forEach { headers["\(name)\u{1}\($0)"] = nil }
        }

        let fresh = onServer.subtracting(known).sorted()
        for batch in fresh.chunked(into: 100) {
            try await fetchHeaders(batch, mailbox: name)
        }

        for batch in Array(known.intersection(onServer)).chunked(into: 500) {
            var flags: [UInt32: [String]] = [:]
            for fetch in try await client.uidFetch(batch, items: "(UID FLAGS)") {
                if let uid = fetch.uid { flags[uid] = fetch.flags }
            }
            try cache.updateFlags(flags, mailbox: name, account: account.id)
        }
        if !fresh.isEmpty { log("\(ModifiedUTF7.decode(name)): новых писем \(fresh.count)") }
    }

    private func fetchHeaders(_ uids: [UInt32], mailbox: String) async throws {
        let fetched = try await client.uidFetch(uids, items: "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER])")
        let messages = fetched.compactMap { fetch -> CachedMessage? in
            guard let uid = fetch.uid, let header = fetch.section("BODY[HEADER") else { return nil }
            return CachedMessage(mailbox: mailbox, uid: uid, internalDate: fetch.internalDate ?? Date(),
                                 flags: fetch.flags, header: header, size: fetch.size ?? 0)
        }
        try cache.upsert(messages, account: account.id)
    }

    /// Ответ, отправленный с телефона или из другой программы, лежит
    /// в «Отправленных» с `In-Reply-To` исходного письма. Флаг `\Answered`
    /// ставят не все клиенты — поэтому смотрим и сюда.
    private func recomputeReplies(sentMailbox: String) {
        let sent = cache.messages(mailbox: sentMailbox, account: account.id, from: syncedSince, to: .distantFuture)
        repliedMessageIDs = Set(sent.compactMap { parsed($0).inReplyTo })
    }

    // MARK: - Письма для интерфейса

    public func messages(from: Date, to: Date) async throws -> [TimelineItem] {
        if from < syncedSince {
            // Листнули в прошлое дальше кэша — дозагружаем с этого дня.
            syncedSince = Calendar.current.startOfDay(for: from)
            try? await perform { try await syncMailbox("INBOX", since: syncedSince) }
        }
        return cache.messages(mailbox: "INBOX", account: account.id, from: from, to: to).map(item)
    }

    public func body(of itemID: String) async throws -> MailBody {
        guard let (mailbox, uid) = Self.parse(itemID) else { throw MailNetworkError.protocolError(String(localized: "чужое письмо")) }
        if let raw = cache.body(uid: uid, mailbox: mailbox, account: account.id) {
            return ParsedMessage.body(of: raw)
        }
        let raw: Data = try await perform {
            try await select(mailbox)
            let fetched = try await client.uidFetch([uid], items: "(UID BODY.PEEK[])")
            guard let data = fetched.first?.section("BODY[]") else {
                throw MailNetworkError.server(String(localized: "письма больше нет на сервере"))
            }
            return data
        }
        try cache.storeBody(raw, uid: uid, mailbox: mailbox, account: account.id)
        // Открытое письмо — прочитанное, и на телефоне тоже.
        if let cached = cache.message(uid: uid, mailbox: mailbox, account: account.id),
           !cached.flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }) {
            try? await perform { try await client.uidStore([uid], "+FLAGS.SILENT (\\Seen)") }
            try? cache.updateFlags([uid: cached.flags + ["\\Seen"]], mailbox: mailbox, account: account.id)
        }
        return ParsedMessage.body(of: raw)
    }

    /// Ответ на приглашение — письмо iTIP организатору; исходное письмо
    /// помечается отвеченным, как после обычного ответа.
    public func respond(to itemID: String, invitation: Invitation, response: InvitationResponse, comment: String?) async throws {
        let mail = try ICalendar.replyMail(to: invitation, response: response, me: account.me, comment: comment)
        try await send(mail, replyingTo: itemID)
    }

    public func archive(_ itemID: String) async throws {
        guard let (mailbox, uid) = Self.parse(itemID) else { return }
        guard let archive = self.mailbox(for: .archive) else {
            throw MailNetworkError.server(String(localized: "на сервере нет папки «Архив»"))
        }
        // Тело — заранее в кэш: после переноса письмо остаётся на таймлайне
        // разобранным и должно открываться, а в этой папке его уже не будет.
        if cache.body(uid: uid, mailbox: mailbox, account: account.id) == nil {
            _ = try? await body(of: itemID)
        }
        try await perform {
            try await select(mailbox)
            try await client.uidMove([uid], to: archive)
        }
        try cache.markMoved([uid], mailbox: mailbox, account: account.id)
        changeHandler?()
    }

    public func trash(_ itemID: String) async throws {
        guard let (mailbox, uid) = Self.parse(itemID) else { return }
        guard let trash = self.mailbox(for: .trash) else {
            throw MailNetworkError.server(String(localized: "на сервере нет папки «Корзина»"))
        }
        // Из самой «Корзины» — только навсегда (`\Deleted`); такого
        // необратимого действия у приложения нет.
        guard mailbox != trash else {
            throw MailNetworkError.server(String(localized: "письмо уже в «Корзине»"))
        }
        try await perform {
            try await select(mailbox)
            try await client.uidMove([uid], to: trash)
        }
        try cache.delete([uid], mailbox: mailbox, account: account.id)
        changeHandler?()
    }

    public func send(_ mail: OutgoingMail, replyingTo itemID: String?) async throws {
        guard let password = password() else {
            throw MailNetworkError.authentication(String(localized: "пароль не найден в Связке ключей"))
        }
        let messageID = MessageBuilder.newMessageID(for: account.email)
        let data = MessageBuilder.build(mail, from: account.me, messageID: messageID)
        let recipients = (mail.to + mail.cc + mail.bcc).compactMap(\.address)
        try await SMTPClient.send(data, from: account.email, to: recipients, account: account,
                                  password: password, log: log)
        log("отправлено: \(recipients.count) получателям")

        if let itemID, let (mailbox, uid) = Self.parse(itemID) {
            try? await perform {
                try await select(mailbox)
                try await client.uidStore([uid], "+FLAGS (\\Answered)")
            }
            if let cached = cache.message(uid: uid, mailbox: mailbox, account: account.id) {
                try? cache.updateFlags([uid: cached.flags + ["\\Answered"]], mailbox: mailbox, account: account.id)
            }
        }

        // Копия в «Отправленные». Gmail и часть серверов кладут её сами —
        // проверяем по Message-ID, чтобы не задвоить.
        if let sent = mailbox(for: .sent) {
            try? await perform {
                try await Task.sleep(for: .seconds(2))
                try await client.select(sent)
                let found = try await client.uidSearch("HEADER Message-ID \(IMAPArgument.quoted("<\(messageID)>"))")
                // В своей копии скрытые адресаты видны — как в любой почте.
                if found.isEmpty {
                    let copy = mail.bcc.isEmpty ? data : MessageBuilder.build(mail, from: account.me, messageID: messageID, includeBcc: true)
                    try await client.append(copy, to: sent)
                }
            }
        }
        changeHandler?()
    }

    // MARK: - Папки и поиск

    public func folders() async throws -> [MailFolder] {
        try await connected()
        let order: [MailFolder.Role] = [.inbox, .sent, .archive, .drafts, .junk, .trash, .other]
        return mailboxes.filter(\.isSelectable).map { mailbox in
            let role = role(of: mailbox.rawName)
            let path = ModifiedUTF7.decode(mailbox.rawName)
                .replacingOccurrences(of: mailbox.delimiter ?? "/", with: " / ")
            // Архивом выбрана своя папка — у неё остаётся собственное имя.
            let chosenArchive = role == .archive && mailbox.rawName == account.archiveFolder
            let name = chosenArchive ? mailbox.displayName : (Self.title(for: role) ?? mailbox.displayName)
            return MailFolder(id: mailbox.rawName, name: name, role: role, path: path)
        }
        .sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.role) ?? order.count
            let right = order.firstIndex(of: rhs.role) ?? order.count
            return left == right ? lhs.path.localizedCompare(rhs.path) == .orderedAscending : left < right
        }
    }

    public func messages(inFolder folderID: String, limit: Int) async throws -> [TimelineItem] {
        if folderID != "INBOX" {
            let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? syncedSince
            try await perform { try await syncMailbox(folderID, since: min(since, syncedSince)) }
        }
        return cache.latest(mailbox: folderID, account: account.id, limit: limit).map(item)
    }

    public func search(_ text: String, inFolder folderID: String?, fullText: Bool) async throws -> [TimelineItem] {
        let query = MailSearchQuery(text)
        guard !query.isEmpty else { return [] }
        let targets = folderID.map { [$0] } ?? ["INBOX", mailbox(for: .sent), mailbox(for: .archive)].compactMap { $0 }

        var found: [String: TimelineItem] = [:]
        // Сначала кэш: тема, отправитель, получатели и копия — мгновенно.
        for folder in targets {
            for message in cache.latest(mailbox: folder, account: account.id, limit: 5000) {
                let candidate = item(message)
                if query.matches(candidate) { found[candidate.id] = candidate }
            }
        }
        // Затем, если просили, — текст писем на сервере. Уточнения «от:»
        // сервер по тексту не поймёт, их проверяем на найденном сами.
        if fullText, !query.serverText.isEmpty {
            for folder in targets {
                let uids: [UInt32] = try await perform {
                    try await select(folder)
                    return try await client.uidSearchText(query.serverText)
                }
                let recent = Array(uids.suffix(200))
                let missing = recent.filter { cache.message(uid: $0, mailbox: folder, account: account.id) == nil }
                if !missing.isEmpty { try await perform { try await fetchHeaders(missing, mailbox: folder) } }
                for uid in recent {
                    if let message = cache.message(uid: uid, mailbox: folder, account: account.id) {
                        let candidate = item(message)
                        if query.matchesFields(candidate) { found[candidate.id] = candidate }
                    }
                }
            }
        }
        return found.values.sorted { $0.time > $1.time }
    }

    // MARK: - Разбор

    static func itemID(account: String, mailbox: String, uid: UInt32) -> String {
        CachedItem.id(account: account, mailbox: mailbox, uid: uid)
    }

    static func parse(_ id: String) -> (String, UInt32)? {
        CachedItem.parse(id)
    }

    private func parsed(_ message: CachedMessage) -> ParsedMessage {
        let key = "\(message.mailbox)\u{1}\(message.uid)"
        if let cached = headers[key] { return cached }
        let parsed = ParsedMessage(headerData: message.header)
        headers[key] = parsed
        return parsed
    }

    private func item(_ message: CachedMessage) -> TimelineItem {
        CachedItem.make(message, header: parsed(message), accountID: account.id, repliedMessageIDs: repliedMessageIDs)
    }

    // MARK: - Роли папок

    /// Особые папки: сначала по флагу RFC 6154, затем по привычным именам —
    /// не все серверы флаги отдают.
    func mailbox(for role: MailFolder.Role) -> String? {
        let candidates: (flag: String, names: [String])
        switch role {
        case .inbox: return "INBOX"
        case .sent: candidates = ("\\Sent", ["Sent Messages", "Sent", "Sent Items", "Отправленные", "INBOX.Sent"])
        case .archive:
            // Выбранная в настройках папка — если она ещё есть на сервере.
            if let chosen = account.archiveFolder, mailboxes.contains(where: { $0.rawName == chosen }) { return chosen }
            candidates = ("\\Archive", ["Archive", "Archives", "Архив", "INBOX.Archive"])
        case .drafts: candidates = ("\\Drafts", ["Drafts", "Черновики", "INBOX.Drafts"])
        case .trash: candidates = ("\\Trash", ["Deleted Messages", "Trash", "Deleted Items", "Корзина", "INBOX.Trash"])
        case .junk: candidates = ("\\Junk", ["Junk", "Spam", "Junk E-mail", "Спам", "INBOX.Junk"])
        case .other: return nil
        }
        if let flagged = mailboxes.first(where: { $0.has(candidates.flag) }) { return flagged.rawName }
        for name in candidates.names {
            if let match = mailboxes.first(where: {
                ModifiedUTF7.decode($0.rawName).caseInsensitiveCompare(name) == .orderedSame
            }) { return match.rawName }
        }
        return nil
    }

    func role(of rawName: String) -> MailFolder.Role {
        if rawName.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        for role in [MailFolder.Role.sent, .archive, .drafts, .trash, .junk] where mailbox(for: role) == rawName {
            return role
        }
        return .other
    }

    static func title(for role: MailFolder.Role) -> String? {
        switch role {
        case .inbox: return String(localized: "Входящие")
        case .sent: return String(localized: "Отправленные")
        case .archive: return String(localized: "Архив")
        case .drafts: return String(localized: "Черновики")
        case .trash: return String(localized: "Корзина")
        case .junk: return String(localized: "Спам")
        case .other: return nil
        }
    }

    /// Ошибка человеческими словами.
    public static func describe(_ error: Error) -> String {
        if let error = error as? MailNetworkError {
            if error == .timeout {
                // Так выглядит закрытый порт: ни ответа, ни отказа. У пользователя
                // это был VPN, пропускающий только веб-порты.
                return String(localized: "Сервер не отвечает. Похоже, почтовые порты (993, 587) закрыты — чаще всего их не пропускает VPN или рабочая сеть")
            }
            if case .authentication(let reason) = error {
                // Своя причина важнее общей фразы: «пароль не найден в Связке ключей».
                if reason.contains("Связке") { return String(localized: "Не удалось войти: \(reason)") }
                // Gmail объясняет отказ сам — пересказываем, а не прячем за общей фразой.
                if reason.localizedCaseInsensitiveContains("Application-specific password required") {
                    return String(localized: "Gmail не узнал пароль приложения. Создайте новый на myaccount.google.com/apppasswords и вставьте его целиком — пробелы можно не убирать")
                }
                if reason.localizedCaseInsensitiveContains("Too many simultaneous connections") {
                    return String(localized: "Gmail: слишком много открытых подключений к ящику (не больше 15). Закройте почту на других устройствах или подождите 10–15 минут и повторите")
                }
                if reason.localizedCaseInsensitiveContains("web browser") || reason.localizedCaseInsensitiveContains("WEBALERT") {
                    return String(localized: "Сервер просит сначала войти в почту через браузер и подтвердить вход — затем повторите")
                }
                return String(localized: "Не удалось войти: проверьте логин и пароль")
            }
            return error.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 60 {
            return String(localized: "Сервер не отвечает — проверьте интернет")
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return String(localized: "Сервер не отвечает — проверьте адрес сервера и интернет")
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return String(localized: "Сервер не найден — проверьте его адрес")
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
                return String(localized: "Сертификат сервера не доверенный — если сервер внутренний, Mac должен доверять сертификату компании")
            case NSURLErrorUserCancelledAuthentication, NSURLErrorUserAuthenticationRequired:
                return String(localized: "Не удалось войти: проверьте логин и пароль")
            default:
                return String(localized: "Нет связи с сервером: \(nsError.localizedDescription)")
            }
        }
        if nsError.domain == NSOSStatusErrorDomain {
            return String(localized: "Не удалось установить защищённое соединение (код \(nsError.code)) — проверьте адрес и порт сервера")
        }
        return error.localizedDescription
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
