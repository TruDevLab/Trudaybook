import Foundation
import TrudaybookCore

/// Письмо, как его описывает Exchange.
struct EWSItem: Sendable, Equatable {
    var id: String
    var changeKey: String?
    var received: Date?
    var subject: String?
    var from: Person?
    var replyTo: Person?
    var to: [Person] = []
    var cc: [Person] = []
    var isRead: Bool?
    var hasAttachments: Bool?
    var messageID: String?
    var inReplyTo: String?
    var references: [String] = []
    /// `PR_LAST_VERB_EXECUTED` (0x1081): 102 — ответ, 103 — ответ всем,
    /// 104 — пересылка. Ставят Outlook, OWA и телефон.
    var lastVerb: Int?
    /// `item:Importance`: Low, Normal, High.
    var importance: String?
    /// `item:ItemClass`: `IPM.Note`, приглашение — `IPM.Schedule.Meeting.Request`.
    var itemClass: String?

    var isAnswered: Bool { lastVerb == 102 || lastVerb == 103 }

    /// Флаги в духе IMAP — чтобы кэш и таймлайн работали с Exchange так же.
    var flags: [String] {
        (isRead == true ? ["\\Seen"] : []) + (isAnswered ? ["\\Answered"] : [])
    }

    /// Заголовок RFC 5322 из свойств Exchange. Кэш хранит письма заголовками,
    /// и дальше письмо Exchange разбирается тем же кодом, что и письмо IMAP.
    func headerData() -> Data {
        var lines: [String] = []
        if let from { lines.append("From: \(MessageBuilder.formatAddress(from))") }
        if let replyTo { lines.append("Reply-To: \(MessageBuilder.formatAddress(replyTo))") }
        if !to.isEmpty { lines.append("To: \(to.map(MessageBuilder.formatAddress).joined(separator: ", "))") }
        if !cc.isEmpty { lines.append("Cc: \(cc.map(MessageBuilder.formatAddress).joined(separator: ", "))") }
        lines.append("Subject: \(MessageBuilder.encodeHeader(subject ?? ""))")
        if let messageID { lines.append("Message-ID: <\(messageID)>") }
        if let inReplyTo { lines.append("In-Reply-To: <\(inReplyTo)>") }
        if !references.isEmpty { lines.append("References: " + references.map { "<\($0)>" }.joined(separator: " ")) }
        if let importance, importance != "Normal" { lines.append("Importance: \(importance)") }
        // Приглашение — так же, как его помечает сам Exchange в MIME.
        if itemClass?.hasPrefix("IPM.Schedule.Meeting") == true {
            lines.append("Content-Class: urn:content-classes:calendarmessage")
        }
        if hasAttachments == true { lines.append("Content-Type: multipart/mixed") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// Папка Exchange.
struct EWSFolder: Sendable, Equatable {
    var id: String
    var parentID: String?
    var name: String
    var folderClass: String?

    /// Только почтовые папки: календарь, контакты и задачи — не сюда.
    var isMail: Bool {
        guard let folderClass, !folderClass.isEmpty else { return true }
        return folderClass.hasPrefix("IPF.Note")
    }
}

/// Запросы EWS и разбор ответов. Схема — Exchange 2013 SP1 и новее:
/// её понимают Exchange 2016/2019 и Microsoft 365.
enum EWSRequest {
    static let lastVerbTag = "0x1081"

    /// `timeZone` — пояс Windows для встреч: по нему Exchange раскладывает
    /// повторы и события на весь день.
    static func envelope(_ body: String, timeZone: String? = nil) -> String {
        let context = timeZone.map {
            "<t:TimeZoneContext><t:TimeZoneDefinition Id=\"\(XMLEscape.text($0))\"/></t:TimeZoneContext>"
        } ?? ""
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
        <soap:Header><t:RequestServerVersion Version="Exchange2013_SP1"/>\(context)</soap:Header>
        <soap:Body>\(body)</soap:Body>
        </soap:Envelope>
        """
    }

    /// Особые папки Exchange называет словами, у остальных — длинные Id.
    static let distinguished: Set<String> = ["inbox", "sentitems", "deleteditems", "drafts", "junkemail", "msgfolderroot"]

    static func folderRef(_ id: String) -> String {
        distinguished.contains(id)
            ? "<t:DistinguishedFolderId Id=\"\(id)\"/>"
            : "<t:FolderId Id=\"\(XMLEscape.text(id))\"/>"
    }

    /// Ответ на приглашение: `AcceptItem` / `TentativelyAcceptItem` / `DeclineItem`.
    /// `Body` — до `ReferenceItemId`: так требует схема.
    static func respond(to id: String, response: InvitationResponse, comment: String?) -> String {
        let element = switch response {
        case .accept: "AcceptItem"
        case .tentative: "TentativelyAcceptItem"
        case .decline: "DeclineItem"
        }
        let note = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = note.isEmpty ? "" : "<t:Body BodyType=\"Text\">\(XMLEscape.text(note))</t:Body>"
        return "<m:CreateItem MessageDisposition=\"SendAndSaveCopy\"><m:Items><t:\(element)>\(body)"
            + "<t:ReferenceItemId Id=\"\(XMLEscape.text(id))\"/></t:\(element)></m:Items></m:CreateItem>"
    }

    static func itemRef(_ id: String) -> String {
        "<t:ItemId Id=\"\(XMLEscape.text(id))\"/>"
    }

    static func date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static let lastVerbField = "<t:ExtendedFieldURI PropertyTag=\"\(lastVerbTag)\" PropertyType=\"Integer\"/>"

    // MARK: - Письма

    /// Письма папки: без условия — последние, с `since` — полученные с этого
    /// времени, с `query` — найденные поиском Exchange. Новые первыми.
    static func findItems(in folder: String, since: Date? = nil, query: String? = nil,
                          offset: Int = 0, limit: Int) -> String {
        let restriction = since.map { since in
            """
            <m:Restriction><t:IsGreaterThanOrEqualTo><t:FieldURI FieldURI="item:DateTimeReceived"/>\
            <t:FieldURIOrConstant><t:Constant Value="\(date(since))"/></t:FieldURIOrConstant>\
            </t:IsGreaterThanOrEqualTo></m:Restriction>
            """
        } ?? ""
        let search = query.map { "<m:QueryString>\(XMLEscape.text($0))</m:QueryString>" } ?? ""
        return """
            <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
            <t:AdditionalProperties><t:FieldURI FieldURI="item:DateTimeReceived"/>\
            <t:FieldURI FieldURI="message:IsRead"/>\(lastVerbField)</t:AdditionalProperties></m:ItemShape>\
            <m:IndexedPageItemView MaxEntriesReturned="\(limit)" Offset="\(offset)" BasePoint="Beginning"/>\
            \(query == nil ? restriction : "")\
            <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder></m:SortOrder>\
            <m:ParentFolderIds>\(folderRef(folder))</m:ParentFolderIds>\(search)</m:FindItem>
            """
    }

    /// Всё, что нужно таймлайну и ответу: кто, кому, тема, цепочка.
    static func getItems(_ ids: [String]) -> String {
        let fields = [
            "item:Subject", "item:DateTimeReceived", "item:HasAttachments", "item:InReplyTo", "item:Importance", "item:ItemClass",
            "message:From", "message:ToRecipients", "message:CcRecipients", "message:ReplyTo",
            "message:IsRead", "message:InternetMessageId", "message:References",
        ]
        return """
            <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
            \(fields.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined())\(lastVerbField)\
            </t:AdditionalProperties></m:ItemShape>\
            <m:ItemIds>\(ids.map(itemRef).joined())</m:ItemIds></m:GetItem>
            """
    }

    /// Письмо целиком в MIME — его разбирает тот же код, что письма IMAP.
    static func getMime(_ id: String) -> String {
        """
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
        <t:FieldURI FieldURI="item:MimeContent"/></t:AdditionalProperties></m:ItemShape>\
        <m:ItemIds>\(itemRef(id))</m:ItemIds></m:GetItem>
        """
    }

    static func markRead(_ id: String) -> String {
        update(id, """
            <t:SetItemField><t:FieldURI FieldURI="message:IsRead"/>\
            <t:Message><t:IsRead>true</t:IsRead></t:Message></t:SetItemField>
            """)
    }

    /// Пометить отвеченным так, как это делает Outlook: последнее действие —
    /// ответ (или ответ всем), значок стрелки и время ответа.
    static func markAnswered(_ id: String, all: Bool, at time: Date) -> String {
        func extended(_ tag: String, _ type: String, _ value: String) -> String {
            let field = "<t:ExtendedFieldURI PropertyTag=\"\(tag)\" PropertyType=\"\(type)\"/>"
            return "<t:SetItemField>\(field)<t:Message><t:ExtendedProperty>\(field)<t:Value>\(value)</t:Value></t:ExtendedProperty></t:Message></t:SetItemField>"
        }
        return update(id, extended(lastVerbTag, "Integer", all ? "103" : "102")
            + extended("0x1082", "SystemTime", date(time))
            + extended("0x1080", "Integer", "261"))
    }

    private static func update(_ id: String, _ changes: String) -> String {
        """
        <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite" SuppressReadReceipts="true">\
        <m:ItemChanges><t:ItemChange>\(itemRef(id))<t:Updates>\(changes)</t:Updates></t:ItemChange></m:ItemChanges>\
        </m:UpdateItem>
        """
    }

    static func move(_ ids: [String], to folder: String) -> String {
        "<m:MoveItem><m:ToFolderId>\(folderRef(folder))</m:ToFolderId><m:ItemIds>\(ids.map(itemRef).joined())</m:ItemIds></m:MoveItem>"
    }

    /// Отправить готовое письмо: Exchange сам доставит его и положит копию
    /// в «Отправленные».
    static func send(mime: Data) -> String {
        """
        <m:CreateItem MessageDisposition="SendAndSaveCopy"><m:SavedItemFolderId>\(folderRef("sentitems"))</m:SavedItemFolderId>\
        <m:Items><t:Message><t:MimeContent CharacterSet="UTF-8">\(mime.base64EncodedString())</t:MimeContent></t:Message></m:Items>\
        </m:CreateItem>
        """
    }

    // MARK: - Папки

    static func findFolders() -> String {
        """
        <m:FindFolder Traversal="Deep"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
        <t:FieldURI FieldURI="folder:DisplayName"/><t:FieldURI FieldURI="folder:FolderClass"/>\
        <t:FieldURI FieldURI="folder:ParentFolderId"/></t:AdditionalProperties></m:FolderShape>\
        <m:ParentFolderIds>\(folderRef("msgfolderroot"))</m:ParentFolderIds></m:FindFolder>
        """
    }

    /// Id особых папок — чтобы узнать их в общем списке.
    static func getFolders(_ distinguishedIDs: [String]) -> String {
        """
        <m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>\
        <m:FolderIds>\(distinguishedIDs.map(folderRef).joined())</m:FolderIds></m:GetFolder>
        """
    }

    static func createFolder(_ name: String) -> String {
        """
        <m:CreateFolder><m:ParentFolderId>\(folderRef("msgfolderroot"))</m:ParentFolderId>\
        <m:Folders><t:Folder><t:FolderClass>IPF.Note</t:FolderClass>\
        <t:DisplayName>\(XMLEscape.text(name))</t:DisplayName></t:Folder></m:Folders></m:CreateFolder>
        """
    }

    // MARK: - Разбор ответов

    /// Ответы на каждую часть запроса (`…ResponseMessage`). Ошибка всего
    /// запроса — исключение; ошибка отдельного письма остаётся в списке.
    static func responseMessages(_ response: XMLTreeNode) throws -> [XMLTreeNode] {
        guard let messages = response.child("ResponseMessages")?.children, !messages.isEmpty else {
            throw MailNetworkError.protocolError(String(localized: "в ответе нет ResponseMessages"))
        }
        if messages.allSatisfy({ $0.attributes["ResponseClass"] == "Error" }), let first = messages.first {
            throw failure(first)
        }
        return messages
    }

    static func failure(_ message: XMLTreeNode) -> MailNetworkError {
        let code = message.child("ResponseCode")?.text ?? ""
        let text = message.child("MessageText")?.text ?? code
        if code == "ErrorAccessDenied" || code == "ErrorNonExistentMailbox" {
            return .authentication(text)
        }
        if code == "ErrorItemNotFound" { return .gone(text) }
        return .server(text.isEmpty ? String(localized: "ошибка Exchange") : text)
    }

    static func isSuccess(_ message: XMLTreeNode) -> Bool {
        message.attributes["ResponseClass"] != "Error"
    }

    /// Письма из `FindItem` и число всех писем, подходящих под запрос.
    static func parseFind(_ response: XMLTreeNode) throws -> (items: [EWSItem], total: Int, isLast: Bool) {
        guard let message = try responseMessages(response).first else { return ([], 0, true) }
        guard isSuccess(message) else { throw failure(message) }
        guard let root = message.child("RootFolder") else { return ([], 0, true) }
        let items = root.child("Items")?.children.compactMap(parseItem) ?? []
        let total = Int(root.attributes["TotalItemsInView"] ?? "") ?? items.count
        let isLast = root.attributes["IncludesLastItemInRange"] != "false"
        return (items, total, isLast)
    }

    /// Письма из `GetItem`; пропавшие между запросами пропускаются.
    static func parseGet(_ response: XMLTreeNode) throws -> [EWSItem] {
        try responseMessages(response).filter(isSuccess).flatMap { message in
            message.child("Items")?.children.compactMap(parseItem) ?? []
        }
    }

    static func parseMime(_ response: XMLTreeNode) throws -> Data {
        guard let message = try responseMessages(response).first else {
            throw MailNetworkError.protocolError(String(localized: "пустой ответ"))
        }
        guard isSuccess(message) else { throw failure(message) }
        guard let mime = message.first("MimeContent")?.text else {
            throw MailNetworkError.server(String(localized: "Exchange не отдал письмо"))
        }
        return Data(base64Encoded: mime, options: .ignoreUnknownCharacters) ?? Data()
    }

    static func parseItem(_ node: XMLTreeNode) -> EWSItem? {
        guard let idNode = node.child("ItemId"), let id = idNode.attributes["Id"] else { return nil }
        var item = EWSItem(id: id, changeKey: idNode.attributes["ChangeKey"])
        item.received = parseDate(node.child("DateTimeReceived")?.text)
        item.subject = node.child("Subject")?.text
        item.from = node["From", "Mailbox"].flatMap(parsePerson)
        item.replyTo = node.child("ReplyTo")?.all("Mailbox").compactMap(parsePerson).first
        item.to = node.child("ToRecipients")?.all("Mailbox").compactMap(parsePerson) ?? []
        item.cc = node.child("CcRecipients")?.all("Mailbox").compactMap(parsePerson) ?? []
        item.isRead = node.child("IsRead").map { $0.text == "true" }
        item.hasAttachments = node.child("HasAttachments").map { $0.text == "true" }
        item.importance = node.child("Importance")?.text
        item.itemClass = node.child("ItemClass")?.text
        item.messageID = node.child("InternetMessageId").flatMap { MIME.messageIDs($0.text).first }
        item.inReplyTo = node.child("InReplyTo").flatMap { MIME.messageIDs($0.text).first }
        item.references = node.child("References").map { MIME.messageIDs($0.text) } ?? []
        for property in node.all("ExtendedProperty")
        where property["ExtendedFieldURI"]?.attributes["PropertyTag"]?.lowercased() == lastVerbTag {
            item.lastVerb = property.child("Value").flatMap { Int($0.text) }
        }
        return item
    }

    /// Человек из `t:Mailbox`. Внутренний адрес Exchange (`/O=…`) вместо
    /// почтового не годится для ответа — такой адрес отбрасывается.
    static func parsePerson(_ mailbox: XMLTreeNode) -> Person? {
        let name = mailbox.child("Name")?.text.trimmingCharacters(in: .whitespaces)
        var address = mailbox.child("EmailAddress")?.text.trimmingCharacters(in: .whitespaces)
        if let current = address, current.hasPrefix("/") || !current.contains("@") { address = nil }
        guard (name?.isEmpty == false) || address != nil else { return nil }
        return Person(name: name?.isEmpty == false ? name : nil, address: address)
    }

    static func parseFolders(_ response: XMLTreeNode) throws -> [EWSFolder] {
        guard let message = try responseMessages(response).first else { return [] }
        guard isSuccess(message) else { throw failure(message) }
        return message.first("Folders")?.children.compactMap { node in
            guard let id = node.child("FolderId")?.attributes["Id"] else { return nil }
            return EWSFolder(
                id: id,
                parentID: node.child("ParentFolderId")?.attributes["Id"],
                name: node.child("DisplayName")?.text ?? "",
                folderClass: node.child("FolderClass")?.text
            )
        } ?? []
    }

    /// Id особых папок по порядку запроса; несуществующая — `nil`.
    static func parseFolderIDs(_ response: XMLTreeNode) throws -> [String?] {
        try responseMessages(response).map { message in
            isSuccess(message) ? message.first("FolderId")?.attributes["Id"] : nil
        }
    }

    /// Проверить, что запрос без ответа-данных (UpdateItem, MoveItem, CreateItem) прошёл.
    static func requireSuccess(_ response: XMLTreeNode) throws {
        for message in try responseMessages(response) where !isSuccess(message) {
            throw failure(message)
        }
    }
}
