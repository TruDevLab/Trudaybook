import Foundation
import TrudaybookCore

/// Почта корпоративного Exchange через EWS (Exchange Web Services).
///
/// Устроена как `IMAPMailProvider`: всё, что показывает интерфейс, берётся
/// из кэша, а сервер спрашивается в фоне. Письма Exchange кладутся в кэш
/// заголовком RFC 5322 и флагами `\Seen`/`\Answered`, поэтому таймлайн,
/// «Не разобрано» и поиск работают с ними тем же кодом.
///
/// Всё идёт по HTTPS (порт 443) — его пропускают и VPN, и рабочие сети.
public actor EWSMailProvider: AccountMailProvider {
    public nonisolated let account: MailAccount
    public nonisolated var displayName: String { account.email }
    /// Основной адрес и имя входа, если оно похоже на адрес: письма бывают
    /// адресованы и так, и так.
    public nonisolated var ownAddresses: Set<String> {
        Set([account.email, account.imapUser].filter { $0.contains("@") }.map { $0.lowercased() })
    }

    private let cache: MailCache
    private let password: @Sendable () -> String?
    private let log: @Sendable (String) -> Void
    private var client: EWSClient?
    /// С какого дня письма лежат в кэше.
    private var syncedSince: Date
    private var headers: [String: ParsedMessage] = [:]
    private var folderList: [MailFolder] = []
    private var changeHandler: (@Sendable () -> Void)?
    private var statusHandler: (@Sendable (MailSyncStatus) -> Void)?
    private var status = MailSyncStatus()
    private var pollTask: Task<Void, Never>?
    private var polls = 0

    public static let pollInterval: Duration = .seconds(90)
    /// Раз в столько опросов сверяется весь месяц, а не только последние дни:
    /// так доезжают прочтения и ответы на старые письма.
    static let fullSyncEvery = 10
    static let inbox = "inbox"

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
    }

    // MARK: - Жизненный цикл

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        changeHandler = handler
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (MailSyncStatus) -> Void) {
        statusHandler = handler
        handler(status)
    }

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

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
    }

    public static let verifyTimeout: Double = 30

    /// Проверить вход: спросить у сервера папку «Входящие».
    public static func verify(
        _ account: MailAccount,
        password: String,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MailAccount {
        guard let url = account.ewsURL.flatMap(URL.init(string:)) else {
            throw MailNetworkError.server(String(localized: "не указан сервер Exchange"))
        }
        log("проверка входа: \(account.imapUser) на \(url.absoluteString)")
        let client = EWSClient(url: url, user: account.imapUser, password: password, log: log)
        do {
            try await OnceContinuation.withTimeout(verifyTimeout) {
                let response = try await client.call("GetFolder", body: EWSRequest.getFolders([inbox]))
                guard try EWSRequest.parseFolderIDs(response).first ?? nil != nil else {
                    throw MailNetworkError.server(String(localized: "у учётной записи нет почтового ящика на этом сервере"))
                }
            }
            log("вход удался")
            var working = account
            if let primary = await primaryAddress(client: client),
               primary.caseInsensitiveCompare(account.email) != .orderedSame {
                log("основной адрес ящика — \(primary)")
                working.email = primary
            }
            return working
        } catch {
            log("проверка не удалась: \(error)")
            throw error
        }
    }

    /// Основной почтовый адрес ящика. Входят часто по имени входа (UPN),
    /// а оно может не совпадать с адресом. Надёжнее всего — отправитель
    /// последнего отправленного письма: его ставит сам Exchange.
    static func primaryAddress(client: EWSClient) async -> String? {
        guard let sent = try? EWSRequest.parseFind(await client.call(
                  "FindItem", body: EWSRequest.findItems(in: "sentitems", limit: 1))).items.first,
              let detail = try? EWSRequest.parseGet(await client.call(
                  "GetItem", body: EWSRequest.getItems([sent.id]))).first
        else { return nil }
        return detail.from?.address
    }

    public static func primaryAddress(of account: MailAccount, password: String,
                                      log: @escaping @Sendable (String) -> Void = { _ in }) async -> String? {
        guard let url = account.ewsURL.flatMap(URL.init(string:)) else { return nil }
        return await primaryAddress(client: EWSClient(url: url, user: account.imapUser, password: password, log: log))
    }

    // MARK: - Соединение

    private func connection() throws -> EWSClient {
        if let client { return client }
        guard let url = account.ewsURL.flatMap(URL.init(string:)) else {
            throw MailNetworkError.server(String(localized: "не указан сервер Exchange"))
        }
        guard let password = password() else {
            throw MailNetworkError.authentication(String(localized: "пароль не найден в Связке ключей — введите его в настройках"))
        }
        let client = EWSClient(url: url, user: account.imapUser, password: password, log: log)
        self.client = client
        return client
    }

    private func call(_ operation: String, _ body: String) async throws -> XMLTreeNode {
        do {
            return try await connection().call(operation, body: body)
        } catch MailNetworkError.authentication(let reason) {
            // Пароль могли сменить в настройках — следующий запрос возьмёт новый.
            client = nil
            throw MailNetworkError.authentication(reason)
        }
    }

    // MARK: - Синхронизация

    public func refresh() async throws {
        report(MailSyncStatus(lastSync: status.lastSync, error: status.error, isSyncing: true))
        do {
            // Обычно — последние два дня, изредка — весь месяц.
            let recent = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? syncedSince
            let since = polls % Self.fullSyncEvery == 0 ? syncedSince : max(syncedSince, recent)
            polls += 1
            try await sync(Self.inbox, since: since)
            report(MailSyncStatus(lastSync: Date(), error: nil, isSyncing: false))
            changeHandler?()
        } catch {
            report(MailSyncStatus(lastSync: status.lastSync, error: MailAccounts.describe(error), isSyncing: false))
            throw error
        }
    }

    private func report(_ new: MailSyncStatus) {
        status = new
        statusHandler?(new)
    }

    /// Привести кэш папки к серверу начиная с `since`: новое скачать,
    /// пропавшее убрать, у остального обновить «прочитано» и «отвечено».
    private func sync(_ folder: String, since: Date) async throws {
        var found: [EWSItem] = []
        var offset = 0
        while true {
            let page = try EWSRequest.parseFind(try await call(
                "FindItem", EWSRequest.findItems(in: folder, since: since, offset: offset, limit: 500)))
            found += page.items
            offset += page.items.count
            // Больше 5000 писем за месяц в одной папке — уже не про таймлайн.
            if page.isLast || page.items.isEmpty || offset >= 5000 { break }
        }

        var onServer: [UInt32: EWSItem] = [:]
        for item in found {
            onServer[try cache.localUID(for: item.id, account: account.id)] = item
        }
        let known = Set(cache.uids(mailbox: folder, account: account.id, since: since))

        let gone = Array(known.subtracting(onServer.keys))
        if !gone.isEmpty {
            try cache.delete(gone, mailbox: folder, account: account.id)
            try cache.forgetRemoteIDs(gone, account: account.id)
            gone.forEach { headers[key(folder, $0)] = nil }
        }

        let fresh = onServer.keys.filter { !known.contains($0) }.sorted()
        if !fresh.isEmpty {
            try await store(fresh.compactMap { onServer[$0] }, in: folder)
            log("\(folder): новых писем \(fresh.count)")
        }

        var flags: [UInt32: [String]] = [:]
        for uid in known.intersection(onServer.keys) {
            if let item = onServer[uid] { flags[uid] = item.flags }
        }
        if !flags.isEmpty { try cache.updateFlags(flags, mailbox: folder, account: account.id) }
    }

    /// Дозапросить подробности писем (кто, кому, тема) и положить в кэш.
    private func store(_ items: [EWSItem], in folder: String) async throws {
        let found = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for batch in items.map(\.id).chunked(into: 50) {
            let detailed = try EWSRequest.parseGet(try await call("GetItem", EWSRequest.getItems(batch)))
            var messages: [CachedMessage] = []
            for var item in detailed {
                // Время и «ответ» — из поиска, если подробный ответ их не дал.
                if let listed = found[item.id] {
                    item.received = item.received ?? listed.received
                    item.lastVerb = item.lastVerb ?? listed.lastVerb
                }
                let uid = try cache.localUID(for: item.id, account: account.id)
                messages.append(CachedMessage(mailbox: folder, uid: uid, internalDate: item.received ?? Date(),
                                              flags: item.flags, header: item.headerData(), size: 0))
            }
            try cache.upsert(messages, account: account.id)
        }
    }

    // MARK: - Письма для интерфейса

    public func messages(from: Date, to: Date) async throws -> [TimelineItem] {
        if from < syncedSince {
            // Листнули в прошлое дальше кэша — дозагружаем с этого дня.
            syncedSince = Calendar.current.startOfDay(for: from)
            try? await sync(Self.inbox, since: syncedSince)
        }
        return cache.messages(mailbox: Self.inbox, account: account.id, from: from, to: to).map(item)
    }

    public func body(of itemID: String) async throws -> MailBody {
        let (folder, uid) = try locate(itemID)
        if let raw = cache.body(uid: uid, mailbox: folder, account: account.id) {
            return ParsedMessage.body(of: raw)
        }
        // Письма уже нет в кэше папки — значит, и на месте его нет (ушло в
        // архив, удалено). Скачивать нечего и не по чему.
        guard let cached = cache.message(uid: uid, mailbox: folder, account: account.id) else {
            throw MailNetworkError.server(String(localized: "письма больше нет на сервере"))
        }
        let remote = try remoteID(uid)
        let raw = try EWSRequest.parseMime(try await call("GetItem", EWSRequest.getMime(remote)))
        // Тело должно быть от того же письма, что и заголовок в списке:
        // никогда не показываем под одним письмом другое.
        if let expected = ParsedMessage(headerData: cached.header).messageID,
           let got = ParsedMessage(headerData: raw).messageID,
           expected.caseInsensitiveCompare(got) != .orderedSame {
            log("тело не совпало с письмом — не показываем")
            throw MailNetworkError.server(String(localized: "письмо на сервере изменилось, обновите список"))
        }
        try cache.storeBody(raw, uid: uid, mailbox: folder, account: account.id)
        // Открытое письмо — прочитанное, и в Outlook тоже.
        if !cached.flags.contains("\\Seen") {
            if (try? EWSRequest.requireSuccess(try await call("UpdateItem", EWSRequest.markRead(remote)))) != nil {
                try? cache.updateFlags([uid: cached.flags + ["\\Seen"]], mailbox: folder, account: account.id)
            }
        }
        return ParsedMessage.body(of: raw)
    }

    /// Ответ на приглашение командой Exchange: сервер сам отметит встречу
    /// в календаре и отправит ответ организатору. Письмо-приглашение
    /// Exchange после ответа убирает из Входящих — убираем и из кэша.
    public func respond(to itemID: String, invitation: Invitation, response: InvitationResponse, comment: String?) async throws {
        let (folder, uid) = try locate(itemID)
        try EWSRequest.requireSuccess(try await call("CreateItem",
            EWSRequest.respond(to: try remoteID(uid), response: response, comment: comment)))
        log("ответ на приглашение отправлен")
        try forgetHandled(uid, in: folder)
    }

    public func archive(_ itemID: String) async throws {
        let (folder, uid) = try locate(itemID)
        let target = try await archiveFolder()
        // Тело — заранее в кэш: после переноса Id письма другой, а на
        // таймлайне оно остаётся и должно открываться.
        if cache.body(uid: uid, mailbox: folder, account: account.id) == nil {
            _ = try? await body(of: itemID)
        }
        do {
            try EWSRequest.requireSuccess(try await call("MoveItem", EWSRequest.move([try remoteID(uid)], to: target)))
        } catch MailNetworkError.gone(let text) {
            // Убрано другой программой — из Входящих его всё равно нет;
            // на таймлайне оно остаётся разобранным, как после нашего архива.
            log("архив: письма уже нет на сервере")
            try forgetHandled(uid, in: folder)
            throw MailNetworkError.gone(text)
        }
        try forgetHandled(uid, in: folder)
    }

    /// В «Удалённые» (`deleteditems`) — `MoveItem`, а не `DeleteItem`:
    /// письмо вернётся из «Корзины» в Outlook или здесь.
    public func trash(_ itemID: String) async throws {
        let (folder, uid) = try locate(itemID)
        try EWSRequest.requireSuccess(try await call("MoveItem", EWSRequest.move([try remoteID(uid)], to: "deleteditems")))
        try cache.delete([uid], mailbox: folder, account: account.id)
        try cache.forgetRemoteIDs([uid], account: account.id)
        headers[key(folder, uid)] = nil
        changeHandler?()
    }

    /// Письмо ушло из папки нашим действием. Строка и тело остаются с
    /// отметкой «ушло» — на таймлайне письмо разобранное и открывается;
    /// номер письма больше никому не достанется (`MailCache.localUID`).
    private func forgetHandled(_ uid: UInt32, in folder: String) throws {
        try cache.markMoved([uid], mailbox: folder, account: account.id)
        try cache.forgetRemoteIDs([uid], account: account.id)
        headers[key(folder, uid)] = nil
        changeHandler?()
    }

    public func send(_ mail: OutgoingMail, replyingTo itemID: String?) async throws {
        let messageID = MessageBuilder.newMessageID(for: account.email)
        // Exchange берёт скрытых получателей из заголовка Bcc и сам убирает
        // его из уходящего письма, оставляя в копии «Отправленных».
        let data = MessageBuilder.build(mail, from: account.me, messageID: messageID, includeBcc: true)
        try EWSRequest.requireSuccess(try await call("CreateItem", EWSRequest.send(mime: data)))
        log("отправлено: \((mail.to + mail.cc + mail.bcc).count) получателям")

        if let itemID, let (folder, uid) = try? locate(itemID), let remote = cache.remoteID(uid: uid, account: account.id) {
            let marked: Void? = try? EWSRequest.requireSuccess(try await call(
                "UpdateItem", EWSRequest.markAnswered(remote, all: !mail.cc.isEmpty, at: Date())))
            if marked != nil, let cached = cache.message(uid: uid, mailbox: folder, account: account.id) {
                try? cache.updateFlags([uid: cached.flags + ["\\Answered"]], mailbox: folder, account: account.id)
            }
        }
        changeHandler?()
    }

    // MARK: - Папки и поиск

    public func folders() async throws -> [MailFolder] {
        if folderList.isEmpty { folderList = try await loadFolders() }
        return folderList
    }

    /// Папки ящика. Особые (Входящие, Отправленные…) получают идентификатор-
    /// слово Exchange: так письма Входящих из таймлайна и из списка папки —
    /// одни и те же письма кэша.
    private func loadFolders() async throws -> [MailFolder] {
        let special: [(String, MailFolder.Role)] = [
            ("inbox", .inbox), ("sentitems", .sent), ("drafts", .drafts),
            ("junkemail", .junk), ("deleteditems", .trash),
        ]
        let ids = try EWSRequest.parseFolderIDs(try await call("GetFolder", EWSRequest.getFolders(special.map(\.0))))
        var roles: [String: (key: String, role: MailFolder.Role)] = [:]
        for (index, id) in ids.enumerated() where index < special.count {
            if let id { roles[id] = (special[index].0, special[index].1) }
        }
        let all = try EWSRequest.parseFolders(try await call("FindFolder", EWSRequest.findFolders()))
        return Self.mailFolders(all, roles: roles, archive: account.archiveFolder)
    }

    /// `archive` — папка, выбранная для кнопки «В архив»; без неё архивом
    /// считается папка верхнего уровня «Архив» / «Archive».
    static func mailFolders(_ all: [EWSFolder], roles: [String: (key: String, role: MailFolder.Role)],
                            archive chosen: String? = nil) -> [MailFolder] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func path(_ folder: EWSFolder) -> String {
            var names = [folder.name]
            var parent = folder.parentID.flatMap { byID[$0] }
            while let current = parent, names.count < 10 {
                names.insert(current.name, at: 0)
                parent = current.parentID.flatMap { byID[$0] }
            }
            return names.joined(separator: " / ")
        }
        let order: [MailFolder.Role] = [.inbox, .sent, .archive, .drafts, .junk, .trash, .other]
        // Выбранная папка есть — она и архив, угадывать по имени не нужно.
        var archiveTaken = chosen.map { id in all.contains { $0.id == id } } ?? false
        return all.filter(\.isMail).map { folder -> MailFolder in
            if folder.id == chosen {
                return MailFolder(id: folder.id, name: folder.name, role: .archive, path: path(folder))
            }
            if let special = roles[folder.id] {
                return MailFolder(id: special.key, name: IMAPMailProvider.title(for: special.role) ?? folder.name,
                                  role: special.role, path: path(folder))
            }
            // Архив Outlook — обычная папка верхнего уровня «Архив» / «Archive».
            let isTopLevel = folder.parentID.flatMap { byID[$0] } == nil
            if !archiveTaken, isTopLevel, ["archive", "архив"].contains(folder.name.lowercased()) {
                archiveTaken = true
                return MailFolder(id: folder.id, name: "Архив", role: .archive, path: path(folder))
            }
            return MailFolder(id: folder.id, name: folder.name, role: .other, path: path(folder))
        }
        .sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.role) ?? order.count
            let right = order.firstIndex(of: rhs.role) ?? order.count
            return left == right ? lhs.path.localizedCompare(rhs.path) == .orderedAscending : left < right
        }
    }

    /// Папка архива. Если её нет — создаётся «Архив», как это делает
    /// кнопка «Архивировать» в Outlook.
    private func archiveFolder() async throws -> String {
        if let existing = try await folders().first(where: { $0.role == .archive }) { return existing.id }
        log("папки «Архив» нет — создаю")
        let response = try await call("CreateFolder", EWSRequest.createFolder("Архив"))
        guard let id = try EWSRequest.parseFolders(response).first?.id else {
            throw MailNetworkError.server(String(localized: "не удалось создать папку «Архив»"))
        }
        folderList = []
        return id
    }

    public func messages(inFolder folderID: String, limit: Int) async throws -> [TimelineItem] {
        if folderID != Self.inbox {
            let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? syncedSince
            try await sync(folderID, since: min(since, syncedSince))
        }
        return cache.latest(mailbox: folderID, account: account.id, limit: limit).map(item)
    }

    public func search(_ text: String, inFolder folderID: String?, fullText: Bool) async throws -> [TimelineItem] {
        let query = MailSearchQuery(text)
        guard !query.isEmpty else { return [] }
        let targets: [String]
        if let folderID {
            targets = [folderID]
        } else {
            let known = try? await folders()
            targets = [Self.inbox] + [MailFolder.Role.sent, .archive].compactMap { role in
                known?.first { $0.role == role }?.id
            }
        }

        var found: [String: TimelineItem] = [:]
        // Сначала кэш: тема, отправитель, получатели — мгновенно.
        for folder in targets {
            for message in cache.latest(mailbox: folder, account: account.id, limit: 5000) {
                let candidate = item(message)
                if query.matches(candidate) { found[candidate.id] = candidate }
            }
        }
        // Затем, если просили, — поиск Exchange по тексту писем.
        if fullText, !query.serverText.isEmpty {
            for folder in targets {
                let hits = try EWSRequest.parseFind(try await call(
                    "FindItem", EWSRequest.findItems(in: folder, query: query.serverText, limit: 200))).items
                var missing: [EWSItem] = []
                var uids: [UInt32] = []
                for hit in hits {
                    let uid = try cache.localUID(for: hit.id, account: account.id)
                    uids.append(uid)
                    if cache.message(uid: uid, mailbox: folder, account: account.id) == nil { missing.append(hit) }
                }
                if !missing.isEmpty { try await store(missing, in: folder) }
                for uid in uids {
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

    private func locate(_ itemID: String) throws -> (String, UInt32) {
        guard let located = CachedItem.parse(itemID) else { throw MailNetworkError.protocolError(String(localized: "чужое письмо")) }
        return located
    }

    private func remoteID(_ uid: UInt32) throws -> String {
        guard let id = cache.remoteID(uid: uid, account: account.id) else {
            throw MailNetworkError.server(String(localized: "письма больше нет на сервере"))
        }
        return id
    }

    private func key(_ folder: String, _ uid: UInt32) -> String { "\(folder)\u{1}\(uid)" }

    private func item(_ message: CachedMessage) -> TimelineItem {
        let key = key(message.mailbox, message.uid)
        let header = headers[key] ?? ParsedMessage(headerData: message.header)
        headers[key] = header
        return CachedItem.make(message, header: header, accountID: account.id)
    }
}
