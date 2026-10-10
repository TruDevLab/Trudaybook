import Foundation
import Testing
@testable import TrudaybookCore
@testable import TrudaybookMail

/// Ответы Exchange — в том виде, в каком их отдаёт Exchange 2016/2019
/// (формат из документации EWS), с условными адресами и Id.
@Suite("Exchange (EWS)")
struct EWSTests {
    static let findResponse = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Header><h:ServerVersionInfo MajorVersion="15" MinorVersion="2" MajorBuildNumber="1748" MinorBuildNumber="39" xmlns:h="http://schemas.microsoft.com/exchange/services/2006/types"/></s:Header>
          <s:Body>
            <m:FindItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:FindItemResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
                  <m:RootFolder IndexedPagingOffset="2" TotalItemsInView="2" IncludesLastItemInRange="true">
                    <t:Items>
                      <t:Message>
                        <t:ItemId Id="AAMkADAx=" ChangeKey="CQAAABYA"/>
                        <t:DateTimeReceived>2026-09-23T07:48:00Z</t:DateTimeReceived>
                        <t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x1081" PropertyType="Integer"/><t:Value>102</t:Value></t:ExtendedProperty>
                        <t:IsRead>true</t:IsRead>
                      </t:Message>
                      <t:MeetingRequest>
                        <t:ItemId Id="AAMkADAy=" ChangeKey="CwAAABYA"/>
                        <t:DateTimeReceived>2026-09-23T06:10:00Z</t:DateTimeReceived>
                        <t:IsRead>false</t:IsRead>
                      </t:MeetingRequest>
                    </t:Items>
                  </m:RootFolder>
                </m:FindItemResponseMessage>
              </m:ResponseMessages>
            </m:FindItemResponse>
          </s:Body>
        </s:Envelope>
        """

    static let getResponse = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
          <m:ResponseMessages>
            <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items>
              <t:Message>
                <t:ItemId Id="AAMkADAx=" ChangeKey="CQAAABYA"/>
                <t:Subject>Согласование бюджета &amp; сроков</t:Subject>
                <t:DateTimeReceived>2026-09-23T07:48:00Z</t:DateTimeReceived>
                <t:HasAttachments>true</t:HasAttachments>
                <t:InReplyTo>&lt;root@company.test&gt;</t:InReplyTo>
                <t:ToRecipients>
                  <t:Mailbox><t:Name>Иванов Пётр</t:Name><t:EmailAddress>s.ivanov@company.test</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:Mailbox>
                  <t:Mailbox><t:Name>Отдел продаж</t:Name><t:EmailAddress>/O=COMPANY/OU=EXCHANGE ADMINISTRATIVE GROUP/CN=RECIPIENTS/CN=SALES</t:EmailAddress><t:RoutingType>EX</t:RoutingType></t:Mailbox>
                </t:ToRecipients>
                <t:CcRecipients><t:Mailbox><t:Name>Petrov, Ivan</t:Name><t:EmailAddress>petrov@partner.test</t:EmailAddress></t:Mailbox></t:CcRecipients>
                <t:From><t:Mailbox><t:Name>Анна Смирнова</t:Name><t:EmailAddress>anna@company.test</t:EmailAddress></t:Mailbox></t:From>
                <t:InternetMessageId>&lt;msg-1@company.test&gt;</t:InternetMessageId>
                <t:IsRead>true</t:IsRead>
                <t:References>&lt;root@company.test&gt;</t:References>
                <t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x1081" PropertyType="Integer"/><t:Value>103</t:Value></t:ExtendedProperty>
              </t:Message>
            </m:Items></m:GetItemResponseMessage>
            <m:GetItemResponseMessage ResponseClass="Error"><m:MessageText>The specified object was not found in the store.</m:MessageText><m:ResponseCode>ErrorItemNotFound</m:ResponseCode><m:Items/></m:GetItemResponseMessage>
          </m:ResponseMessages>
        </m:GetItemResponse></s:Body></s:Envelope>
        """

    private func body(_ xml: String) throws -> XMLTreeNode {
        let root = try XMLTreeNode.parse(Data(xml.utf8))
        return try #require(root.child("Body")?.children.first)
    }

    @Test func findItemGivesIdsDatesAndFlags() throws {
        let page = try EWSRequest.parseFind(try body(Self.findResponse))
        #expect(page.items.count == 2)
        #expect(page.isLast)
        let first = page.items[0]
        #expect(first.id == "AAMkADAx=")
        #expect(first.isAnswered)
        #expect(first.flags == ["\\Seen", "\\Answered"])
        #expect(first.received == ISO8601DateFormatter().date(from: "2026-09-23T07:48:00Z"))
        // Приглашение на встречу во Входящих — тоже письмо.
        #expect(page.items[1].flags.isEmpty)
    }

    @Test func getItemDetailsBecomeAHeaderOurParserReads() throws {
        let items = try EWSRequest.parseGet(try body(Self.getResponse))
        // Пропавшее между запросами письмо не ломает остальные.
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.subject == "Согласование бюджета & сроков")
        #expect(item.from == Person(name: "Анна Смирнова", address: "anna@company.test"))
        // Внутренний адрес Exchange для ответа не годится — остаётся имя.
        #expect(item.to.map(\.address) == ["s.ivanov@company.test", nil])
        #expect(item.lastVerb == 103)

        let header = ParsedMessage(headerData: item.headerData())
        #expect(header.subject == item.subject)
        #expect(header.from == item.from)
        #expect(header.cc.first?.name == "Petrov, Ivan")
        #expect(header.messageID == "msg-1@company.test")
        #expect(header.inReplyTo == "root@company.test")
        #expect(header.references == ["root@company.test"])

        let message = CachedMessage(mailbox: "inbox", uid: 7, internalDate: item.received!, flags: item.flags,
                                    header: item.headerData(), size: 0)
        let timeline = CachedItem.make(message, header: header, accountID: "X")
        #expect(timeline.id == "mail:X:7:inbox")
        #expect(timeline.mail?.isAnsweredOnServer == true)
        #expect(timeline.mail?.hasAttachments == true)
        #expect(timeline.mail?.isRead == true)
    }

    @Test func errorsAndFaults() throws {
        let failed = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
            <m:GetFolderResponse xmlns:m="m"><m:ResponseMessages>
            <m:GetFolderResponseMessage ResponseClass="Error"><m:MessageText>Mailbox does not exist.</m:MessageText>
            <m:ResponseCode>ErrorNonExistentMailbox</m:ResponseCode></m:GetFolderResponseMessage>
            </m:ResponseMessages></m:GetFolderResponse></s:Body></s:Envelope>
            """
        #expect(throws: MailNetworkError.authentication("Mailbox does not exist.")) {
            try EWSRequest.parseFolderIDs(try body(failed))
        }
    }

    @Test func foldersGetRolesAndPaths() {
        let all = [
            EWSFolder(id: "F-in", parentID: "ROOT", name: "Входящие", folderClass: "IPF.Note"),
            EWSFolder(id: "F-sent", parentID: "ROOT", name: "Отправленные", folderClass: "IPF.Note"),
            EWSFolder(id: "F-arch", parentID: "ROOT", name: "Архив", folderClass: "IPF.Note"),
            EWSFolder(id: "F-proj", parentID: "F-in", name: "Проекты", folderClass: "IPF.Note"),
            EWSFolder(id: "F-cal", parentID: "ROOT", name: "Календарь", folderClass: "IPF.Appointment"),
        ]
        let folders = EWSMailProvider.mailFolders(all, roles: ["F-in": ("inbox", .inbox), "F-sent": ("sentitems", .sent)])
        #expect(folders.map(\.id) == ["inbox", "sentitems", "F-arch", "F-proj"])
        #expect(folders[2].role == .archive)
        #expect(folders[3].path == "Входящие / Проекты")
    }

    @Test func chosenArchiveFolderWins() {
        let all = [
            EWSFolder(id: "F-in", parentID: "ROOT", name: "Входящие", folderClass: "IPF.Note"),
            EWSFolder(id: "F-arch", parentID: "ROOT", name: "Архив", folderClass: "IPF.Note"),
            EWSFolder(id: "F-arch25", parentID: "ROOT", name: "Архив 2025", folderClass: "IPF.Note"),
        ]
        let folders = EWSMailProvider.mailFolders(all, roles: ["F-in": ("inbox", .inbox)], archive: "F-arch25")
        // Архив — только выбранная папка; «Архив» по имени больше не угадывается.
        #expect(folders.filter { $0.role == .archive }.map(\.id) == ["F-arch25"])
        #expect(folders.first { $0.id == "F-arch25" }?.name == "Архив 2025")
        // Выбранной папки на сервере нет — снова угадываем по имени.
        let fallback = EWSMailProvider.mailFolders(all, roles: ["F-in": ("inbox", .inbox)], archive: "F-gone")
        #expect(fallback.filter { $0.role == .archive }.map(\.id) == ["F-arch"])
    }

    @Test func requestsAreWellFormedXML() throws {
        let requests = [
            EWSRequest.findItems(in: "inbox", since: Date(timeIntervalSince1970: 1_790_000_000), limit: 500),
            EWSRequest.findItems(in: "AAMk/Id+=", query: "отчёт & план", limit: 200),
            EWSRequest.getItems(["A=", "B="]),
            EWSRequest.getMime("A="),
            EWSRequest.markRead("A="),
            EWSRequest.markAnswered("A=", all: true, at: Date()),
            EWSRequest.move(["A="], to: "F-arch"),
            EWSRequest.respond(to: "A=", response: .decline, comment: "<не смогу> & \"перенесём\""),
            EWSRequest.respond(to: "A=", response: .accept, comment: nil),
            EWSRequest.send(mime: Data("Subject: x\r\n\r\ny".utf8)),
            EWSRequest.findFolders(),
            EWSRequest.getFolders(["inbox", "sentitems"]),
            EWSRequest.createFolder("Архив"),
        ]
        for request in requests {
            let envelope = try XMLTreeNode.parse(Data(EWSRequest.envelope(request).utf8))
            #expect(envelope["Body"]?.children.count == 1)
        }
        let find = try XMLTreeNode.parse(Data(EWSRequest.envelope(requests[1]).utf8))
        #expect(find.first("QueryString")?.text == "отчёт & план")
        #expect(find.first("Restriction") == nil)
        #expect(find.first("FolderId")?.attributes["Id"] == "AAMk/Id+=")
    }

    @Test func serverAddressBecomesEWSEndpoint() {
        #expect(EWSClient.endpoint(for: "mail.company.example")?.absoluteString == "https://mail.company.example/EWS/Exchange.asmx")
        #expect(EWSClient.endpoint(for: " https://mail.x.ru/EWS/Exchange.asmx ")?.absoluteString == "https://mail.x.ru/EWS/Exchange.asmx")
        #expect(EWSClient.endpoint(for: "") == nil)
        let account = MailAccount.exchange(email: "me@company.example", name: "Я", server: "mail.company.example", login: "")
        #expect(account?.imapUser == "me@company.example")
        #expect(account?.kind == .exchange)
    }

    @Test func accountsSavedBeforeExchangeStillLoad() throws {
        let old = """
            [{"displayName":"Я","email":"me@icloud.com","id":"A","imapHost":"imap.mail.me.com","imapPort":993,
              "imapUser":"me","smtpHost":"smtp.mail.me.com","smtpPort":587,"smtpSecurity":"startTLS","smtpUser":"me@icloud.com"}]
            """
        let accounts = try JSONDecoder().decode([MailAccount].self, from: Data(old.utf8))
        #expect(accounts.first?.kind == .imap)
        let exchange = try #require(MailAccount.exchange(email: "me@company.example", name: "Я", server: "mail.company.example", login: "COMPANY\\me"))
        let again = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(exchange))
        #expect(again == exchange)
    }

    @Test func remoteIDsGetStableShortNumbers() throws {
        let cache = try MailCache.inMemory()
        let a = try cache.localUID(for: "AAMk-long-id-1=", account: "X")
        let b = try cache.localUID(for: "AAMk-long-id-2=", account: "X")
        #expect(a != b)
        #expect(try cache.localUID(for: "AAMk-long-id-1=", account: "X") == a)
        #expect(cache.remoteID(uid: b, account: "X") == "AAMk-long-id-2=")
        try cache.forgetRemoteIDs([a], account: "X")
        #expect(cache.remoteID(uid: a, account: "X") == nil)
    }

    /// Ответили на приглашение (письмо ушло из Входящих), потом пришло или
    /// ушло новое письмо — оно не должно получить номер ушедшего: иначе
    /// под приглашением в списке открывается чужое тело.
    @Test func forgottenNumbersAreNeverReused() throws {
        let cache = try MailCache.inMemory()
        _ = try cache.localUID(for: "old", account: "X")
        let invitation = try cache.localUID(for: "invitation", account: "X")
        try cache.storeBody(Data("приглашение".utf8), uid: invitation, mailbox: "inbox", account: "X")
        try cache.upsert([CachedMessage(mailbox: "inbox", uid: invitation, internalDate: Date(), flags: ["\\Seen"],
                                        header: Data(), size: 0)], account: "X")
        try cache.markMoved([invitation], mailbox: "inbox", account: "X")
        try cache.forgetRemoteIDs([invitation], account: "X")

        let test = try cache.localUID(for: "test-mail", account: "X")
        #expect(test > invitation)
        #expect(cache.remoteID(uid: invitation, account: "X") == nil)
        // Письмо в списке ещё видно — открывается своё тело.
        #expect(cache.body(uid: invitation, mailbox: "inbox", account: "X") == Data("приглашение".utf8))
        // На таймлайне оно остаётся, а в папке и в сверке с сервером — нет.
        let day = cache.messages(mailbox: "inbox", account: "X", from: .distantPast, to: .distantFuture)
        #expect(day.first?.flags == ["\\Seen", MailCache.movedFlag])
        #expect(cache.latest(mailbox: "inbox", account: "X", limit: 10).isEmpty)
        #expect(cache.uids(mailbox: "inbox", account: "X", since: .distantPast).isEmpty)
        // Через месяц такие забываются вместе с телом.
        try cache.pruneMoved(before: .distantFuture, account: "X")
        #expect(cache.body(uid: invitation, mailbox: "inbox", account: "X") == nil)
        // У другого ящика свой счёт.
        #expect(try cache.localUID(for: "test-mail", account: "Y") == 1)
    }
}

@Suite("Exchange: описание встречи с картинками")
struct EWSRichDescriptionTests {
    static let item = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
          <m:ResponseMessages><m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>
            <m:Items><t:CalendarItem><t:ItemId Id="CAL1=" ChangeKey="DwAA"/>
              <t:Body BodyType="HTML">&lt;p&gt;План &lt;img src="cid:logo@x"&gt;&lt;/p&gt;</t:Body>
              <t:Attachments>
                <t:FileAttachment><t:AttachmentId Id="ATT1="/><t:Name>logo.png</t:Name><t:ContentType>image/png</t:ContentType>
                  <t:ContentId>logo@x</t:ContentId><t:Size>3</t:Size><t:IsInline>true</t:IsInline></t:FileAttachment>
                <t:FileAttachment><t:AttachmentId Id="ATT2="/><t:Name>План.pdf</t:Name><t:ContentType>application/pdf</t:ContentType>
                  <t:Size>4</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment>
                <t:ItemAttachment><t:AttachmentId Id="ATT3="/><t:Name>Письмо</t:Name></t:ItemAttachment>
              </t:Attachments>
            </t:CalendarItem></m:Items>
          </m:GetItemResponseMessage></m:ResponseMessages>
        </m:GetItemResponse></s:Body></s:Envelope>
        """

    static let contents = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <m:GetAttachmentResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
          <m:ResponseMessages>
            <m:GetAttachmentResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>
              <m:Attachments><t:FileAttachment><t:AttachmentId Id="ATT1="/><t:Content>AQID</t:Content></t:FileAttachment></m:Attachments>
            </m:GetAttachmentResponseMessage>
            <m:GetAttachmentResponseMessage ResponseClass="Error"><m:ResponseCode>ErrorItemNotFound</m:ResponseCode></m:GetAttachmentResponseMessage>
          </m:ResponseMessages>
        </m:GetAttachmentResponse></s:Body></s:Envelope>
        """

    /// Ответ EWS — содержимое `<s:Body>`, как его отдаёт `EWSClient`.
    private func response(_ xml: String) throws -> XMLTreeNode {
        try #require(try XMLTreeNode.parse(Data(xml.utf8)).child("Body")?.children.first)
    }

    @Test("HTML и файлы — без вложенных писем; встроенная картинка помечена")
    func разбор() throws {
        let parsed = try EWSCalendarRequest.parseRichBody(try response(Self.item))
        #expect(parsed.html == #"<p>План <img src="cid:logo@x"></p>"#)
        #expect(parsed.attachments.map(\.id) == ["ATT1=", "ATT2="])
        #expect(parsed.attachments.first?.isInline == true)
        #expect(parsed.attachments.first?.contentID == "logo@x")
        #expect(parsed.attachments.last?.name == "План.pdf")
    }

    @Test("Содержимое вложений по Id; не отданное сервером — пропущено")
    func содержимое() throws {
        let contents = try EWSCalendarRequest.parseAttachmentContents(try response(Self.contents))
        #expect(contents == ["ATT1=": Data([1, 2, 3])])
        #expect(EWSCalendarRequest.getAttachments(["A\"1"]).contains(#"Id="A&quot;1""#))
    }
}
