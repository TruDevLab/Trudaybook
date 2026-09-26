import Foundation

/// Несколько ящиков как один источник почты.
///
/// Таймлайн, «Не разобрано» и поиск общие. Открыть, ответить и переложить
/// в архив письмо можно только в его ящике: ящик берётся из идентификатора
/// письма (`MailItemID`).
///
/// Папки получают приставку ящика: `<ящик>:<папка>`. Когда ящиков больше
/// одного, первыми идут общие «Входящие», «Отправленные» и «Архив» —
/// в них письма всех ящиков вместе.
public final class CombinedMailProvider: MailProvider {
    public struct Box: Sendable {
        public let accountID: String
        /// Адрес ящика — для заголовков и подписей.
        public let name: String
        public let provider: any MailProvider

        public init(accountID: String, name: String, provider: any MailProvider) {
            self.accountID = accountID
            self.name = name
            self.provider = provider
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case unknownAccount

        public var errorDescription: String? {
            String(localized: "Ящик этого письма отключён")
        }
    }

    public let boxes: [Box]
    public let displayName: String
    public let ownAddresses: Set<String>

    /// Общие папки — только эти три: в остальных смешивать ящики незачем.
    static let sharedRoles: [MailFolder.Role] = [.inbox, .sent, .archive]
    static let sharedPrefix = "all:"

    public init(_ boxes: [Box]) {
        self.boxes = boxes
        displayName = boxes.count == 1 ? boxes[0].name : Self.boxesTitle(boxes.count)
        ownAddresses = boxes.reduce(into: []) { $0.formUnion($1.provider.ownAddresses) }
    }

    /// «2 ящика», «5 ящиков».
    public static func boxesTitle(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        let word: String
        if (11...14).contains(tens) {
            word = String(localized: "ящиков")
        } else if ones == 1 {
            word = String(localized: "ящик")
        } else if (2...4).contains(ones) {
            word = String(localized: "ящика")
        } else {
            word = String(localized: "ящиков")
        }
        return "\(count) \(word)"
    }

    // MARK: - Письма

    public func messages(from: Date, to: Date) async throws -> [TimelineItem] {
        try await gather(boxes) { try await $0.provider.messages(from: from, to: to) }
    }

    public func body(of itemID: String) async throws -> MailBody {
        try await box(ofItem: itemID).provider.body(of: itemID)
    }

    public func respond(to itemID: String, invitation: Invitation, response: InvitationResponse, comment: String?) async throws {
        try await box(ofItem: itemID).provider.respond(to: itemID, invitation: invitation, response: response, comment: comment)
    }

    public func archive(_ itemID: String) async throws {
        try await box(ofItem: itemID).provider.archive(itemID)
    }

    public func send(_ mail: OutgoingMail, replyingTo itemID: String?) async throws {
        let box: Box
        if let accountID = mail.accountID {
            guard let chosen = boxes.first(where: { $0.accountID == accountID }) else { throw Failure.unknownAccount }
            box = chosen
        } else if let itemID {
            box = try self.box(ofItem: itemID)
        } else if let first = boxes.first {
            box = first
        } else {
            throw Failure.unknownAccount
        }
        // Пометку «отвечено» ставит ящик, куда пришло письмо. Если ответ
        // уходит с другого ящика, пометить исходное ему нечем.
        let sameBox = itemID.flatMap(MailItemID.account(of:)) == box.accountID
        try await box.provider.send(mail, replyingTo: sameBox ? itemID : nil)
    }

    // MARK: - Папки

    public func folders() async throws -> [MailFolder] {
        let many = boxes.count > 1
        // `gather` возвращает папки в порядке ящиков, внутри — как их отдал ящик.
        let own = try await gather(boxes) { box in
            try await box.provider.folders().map { folder in
                var folder = folder
                folder.id = Self.folderID(account: box.accountID, folder: folder.id)
                if many { folder.accountName = box.name }
                return folder
            }
        }
        guard many else { return own }
        let shared = Self.sharedRoles
            .filter { role in own.contains { $0.role == role } }
            .map { role in
                MailFolder(id: Self.sharedPrefix + role.rawValue, name: Self.sharedTitle(role), role: role)
            }
        return shared + own
    }

    public func messages(inFolder folderID: String, limit: Int) async throws -> [TimelineItem] {
        let targets = try await resolve(folderID)
        let items = try await gather(targets) { try await $0.box.provider.messages(inFolder: $0.folder, limit: limit) }
        return Array(items.sorted { $0.time > $1.time }.prefix(limit))
    }

    public func search(_ text: String, inFolder folderID: String?, fullText: Bool) async throws -> [TimelineItem] {
        let items: [TimelineItem]
        if let folderID {
            let targets = try await resolve(folderID)
            items = try await gather(targets) { try await $0.box.provider.search(text, inFolder: $0.folder, fullText: fullText) }
        } else {
            items = try await gather(boxes) { try await $0.provider.search(text, inFolder: nil, fullText: fullText) }
        }
        return items.sorted { $0.time > $1.time }
    }

    public func refresh() async throws {
        _ = try await gather(boxes) { box -> [Int] in
            try await box.provider.refresh()
            return []
        }
    }

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async {
        for box in boxes { await box.provider.setChangeHandler(handler) }
    }

    // MARK: - Разбор

    static func folderID(account: String, folder: String) -> String {
        "\(account):\(folder)"
    }

    /// `<ящик>:<папка>` → ящик и папка. Папка последней: в её имени
    /// бывают двоеточия, а в идентификаторе ящика — нет.
    static func parseFolder(_ id: String) -> (account: String, folder: String)? {
        let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    static func sharedTitle(_ role: MailFolder.Role) -> String {
        switch role {
        case .inbox: return String(localized: "Входящие")
        case .sent: return String(localized: "Отправленные")
        case .archive: return String(localized: "Архив")
        default: return role.rawValue
        }
    }

    private func box(ofItem itemID: String) throws -> Box {
        guard let account = MailItemID.account(of: itemID),
              let box = boxes.first(where: { $0.accountID == account }) else { throw Failure.unknownAccount }
        return box
    }

    private struct Target: Sendable {
        let box: Box
        let folder: String
    }

    /// Какие папки каких ящиков стоят за идентификатором: одна папка
    /// одного ящика или папка этой роли в каждом ящике.
    private func resolve(_ folderID: String) async throws -> [Target] {
        if folderID.hasPrefix(Self.sharedPrefix) {
            let role = MailFolder.Role(rawValue: String(folderID.dropFirst(Self.sharedPrefix.count)))
            return try await gather(boxes) { box -> [Target] in
                let match = try await box.provider.folders().first { $0.role == role }
                return match.map { [Target(box: box, folder: $0.id)] } ?? []
            }
        }
        guard let (account, folder) = Self.parseFolder(folderID),
              let box = boxes.first(where: { $0.accountID == account }) else { throw Failure.unknownAccount }
        return [Target(box: box, folder: folder)]
    }

    /// Выполнить работу во всех ящиках сразу и сложить результаты
    /// в порядке ящиков.
    ///
    /// Один недоступный ящик не должен прятать письма остальных: ошибка
    /// выбрасывается, только если не ответил ни один. О сбое конкретного
    /// ящика сообщает его строка состояния.
    private func gather<Source: Sendable, T: Sendable>(
        _ sources: [Source],
        _ work: @escaping @Sendable (Source) async throws -> [T]
    ) async throws -> [T] {
        guard !sources.isEmpty else { return [] }
        let results = await withTaskGroup(of: (Int, Result<[T], Error>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await work(source)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[T], Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var items: [T] = []
        var succeeded = false
        var firstError: Error?
        for result in results {
            switch result {
            case .success(let found):
                items += found
                succeeded = true
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if !succeeded, let firstError { throw firstError }
        return items
    }
}
