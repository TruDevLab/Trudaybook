import Foundation

/// Автоответ «нет на месте», как в Outlook: выключен, включён или по
/// расписанию; свой текст коллегам и внешним, внешним — никому, только
/// знакомым или всем. Хранит его сервер: отвечает Exchange сам, даже когда
/// Mac выключен.
public struct AutoReply: Equatable, Sendable {
    public enum State: String, Sendable, CaseIterable {
        case off, on, scheduled
    }

    /// Кому вне организации отвечать.
    public enum Audience: String, Sendable, CaseIterable {
        case none, known, all
    }

    public var state: State
    public var start: Date
    public var end: Date
    public var internalMessage: String
    public var externalMessage: String
    public var audience: Audience

    public init(state: State = .off, start: Date, end: Date, internalMessage: String = "",
                externalMessage: String = "", audience: Audience = .all) {
        self.state = state
        self.start = start
        self.end = end
        self.internalMessage = internalMessage
        self.externalMessage = externalMessage
        self.audience = audience
    }

    /// Отвечает ли сервер прямо сейчас.
    public func isActive(at now: Date) -> Bool {
        switch state {
        case .off: false
        case .on: true
        case .scheduled: start <= now && now < end
        }
    }

    /// Текст из поля — в HTML для сервера: Exchange хранит ответ разметкой,
    /// и простые переносы строк в нём склеились бы в одну строку.
    public static func html(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<html><body>\(escaped)</body></html>"
    }

    /// Ответ с сервера — простым текстом для поля: разметку, которую
    /// оставил Outlook или веб-почта, убираем, переносы сохраняем.
    public static func text(fromHTML html: String) -> String {
        guard html.contains("<") else { return html.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = html
        // Стили и заголовок документа — не текст ответа.
        for tag in ["style", "head", "script"] {
            while let open = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let close = text.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        for breaker in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>"] {
            text = text.replacingOccurrences(of: breaker, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
