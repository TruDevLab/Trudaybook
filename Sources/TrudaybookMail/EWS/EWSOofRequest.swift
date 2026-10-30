import Foundation
import TrudaybookCore

/// Автоответ Exchange: `GetUserOofSettings` и `SetUserOofSettings`. У этих
/// операций ответ не в `ResponseMessages`, а одним `ResponseMessage`, рядом
/// с настройками.
enum EWSOofRequest {
    static func get(_ address: String) -> String {
        "<m:GetUserOofSettingsRequest><t:Mailbox><t:Address>\(XMLEscape.text(address))</t:Address></t:Mailbox>"
            + "</m:GetUserOofSettingsRequest>"
    }

    /// Порядок полей — по схеме: состояние, кому вне организации, срок,
    /// ответ коллегам, ответ внешним.
    static func set(_ address: String, _ reply: AutoReply) -> String {
        let state = switch reply.state {
        case .off: "Disabled"
        case .on: "Enabled"
        case .scheduled: "Scheduled"
        }
        let audience = switch reply.audience {
        case .none: "None"
        case .known: "Known"
        case .all: "All"
        }
        return "<m:SetUserOofSettingsRequest>"
            + "<t:Mailbox><t:Address>\(XMLEscape.text(address))</t:Address></t:Mailbox>"
            + "<t:UserOofSettings><t:OofState>\(state)</t:OofState><t:ExternalAudience>\(audience)</t:ExternalAudience>"
            + "<t:Duration><t:StartTime>\(EWSRequest.date(reply.start))</t:StartTime>"
            + "<t:EndTime>\(EWSRequest.date(reply.end))</t:EndTime></t:Duration>"
            + "<t:InternalReply><t:Message>\(XMLEscape.text(AutoReply.html(reply.internalMessage)))</t:Message></t:InternalReply>"
            + "<t:ExternalReply><t:Message>\(XMLEscape.text(AutoReply.html(reply.externalMessage)))</t:Message></t:ExternalReply>"
            + "</t:UserOofSettings></m:SetUserOofSettingsRequest>"
    }

    static func requireSuccess(_ response: XMLTreeNode) throws {
        guard let message = response.child("ResponseMessage") else {
            throw MailNetworkError.protocolError(String(localized: "в ответе нет ResponseMessage"))
        }
        if !EWSRequest.isSuccess(message) { throw EWSRequest.failure(message) }
    }

    static func parse(_ response: XMLTreeNode, now: Date = Date()) throws -> AutoReply {
        try requireSuccess(response)
        guard let settings = response.child("OofSettings") else {
            throw MailNetworkError.protocolError(String(localized: "в ответе нет настроек автоответа"))
        }
        let state: AutoReply.State = switch settings.child("OofState")?.text {
        case "Enabled": .on
        case "Scheduled": .scheduled
        default: .off
        }
        let audience: AutoReply.Audience = switch settings.child("ExternalAudience")?.text {
        case "None": .none
        case "Known": .known
        default: .all
        }
        let duration = settings.child("Duration")
        let start = duration?.child("StartTime").flatMap { date($0.text) } ?? now
        let end = duration?.child("EndTime").flatMap { date($0.text) } ?? now.addingTimeInterval(86_400)
        return AutoReply(
            state: state, start: start, end: end,
            internalMessage: AutoReply.text(fromHTML: settings["InternalReply", "Message"]?.text ?? ""),
            externalMessage: AutoReply.text(fromHTML: settings["ExternalReply", "Message"]?.text ?? ""),
            audience: audience
        )
    }

    /// Время срока — UTC; старые серверы пишут его без «Z».
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed + "Z")
    }
}
