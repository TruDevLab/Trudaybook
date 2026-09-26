import Foundation
import TrudaybookCore

/// Письмо из кэша → элемент таймлайна. Общее для IMAP и Exchange:
/// оба кладут в кэш заголовок RFC 5322 и флаги в духе IMAP.
enum CachedItem {
    /// `mail:<ящик>:<uid>:<папка>`. Папка последней: в её имени могут быть двоеточия.
    static func id(account: String, mailbox: String, uid: UInt32) -> String {
        "mail:\(account):\(uid):\(mailbox)"
    }

    /// `mail:<ящик>:<uid>:<папка>` → папка и UID.
    static func parse(_ id: String) -> (String, UInt32)? {
        let parts = id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "mail", let uid = UInt32(parts[2]) else { return nil }
        return (String(parts[3]), uid)
    }

    /// `repliedMessageIDs` — письма, ответ на которые нашёлся в «Отправленных».
    static func make(_ message: CachedMessage, header: ParsedMessage, accountID: String,
                     repliedMessageIDs: Set<String> = []) -> TimelineItem {
        let flags = Set(message.flags.map { $0.lowercased() })
        let answered = flags.contains("\\answered") || header.messageID.map(repliedMessageIDs.contains) == true
        let type = header.headers["Content-Type"].map(MIME.parseParameterized)
        return TimelineItem(
            id: id(account: accountID, mailbox: message.mailbox, uid: message.uid),
            title: header.subject.isEmpty ? String(localized: "(без темы)") : header.subject,
            time: message.internalDate,
            detail: .mail(MailInfo(
                accountID: accountID,
                from: header.from ?? Person(name: nil, address: nil),
                replyTo: header.replyTo,
                to: header.to,
                cc: header.cc,
                messageID: header.messageID,
                references: header.references,
                isRead: flags.contains("\\seen"),
                isAnsweredOnServer: answered,
                hasAttachments: type?.type == "multipart/mixed",
                senderPriority: header.priority,
                isInvitation: header.isInvitation,
                movedAway: flags.contains(MailCache.movedFlag.lowercased())
            ))
        )
    }
}
