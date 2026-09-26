import Foundation
import TrudaybookCore

/// Отправка письма по SMTP.
///
/// Соединение на одно письмо: открыть, представиться, включить TLS, войти,
/// передать, закрыть. Держать его открытым незачем — отвечают не каждую
/// минуту, а серверы рвут простаивающие SMTP-сессии.
public enum SMTPClient {
    public static func send(
        _ message: Data,
        from sender: String,
        to recipients: [String],
        account: MailAccount,
        password: String,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let stream = MailStream(host: account.smtpHost, port: account.smtpPort,
                                implicitTLS: account.smtpSecurity == .tls)
        defer { stream.close() }
        var session = Session(stream: stream, log: log)

        try await session.expect(220)
        var features = try await session.command("EHLO trudaybook.local", expect: 250)
        if account.smtpSecurity == .startTLS {
            try await session.command("STARTTLS", expect: 220)
            stream.startTLS()
            // После TLS сервер забывает всё сказанное — представляемся заново.
            features = try await session.command("EHLO trudaybook.local", expect: 250)
        }

        let auth = features.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased() ?? ""
        do {
            if auth.contains("PLAIN") || !auth.contains("LOGIN") {
                let token = Data("\0\(account.smtpUser)\0\(password)".utf8).base64EncodedString()
                try await session.command("AUTH PLAIN \(token)", expect: 235, shown: "AUTH PLAIN ***")
            } else {
                try await session.command("AUTH LOGIN", expect: 334)
                try await session.command(Data(account.smtpUser.utf8).base64EncodedString(), expect: 334, shown: "***")
                try await session.command(Data(password.utf8).base64EncodedString(), expect: 235, shown: "***")
            }
        } catch MailNetworkError.server(let text) {
            throw MailNetworkError.authentication(text)
        }

        try await session.command("MAIL FROM:<\(sender)>", expect: 250)
        for recipient in recipients {
            try await session.command("RCPT TO:<\(recipient)>", expect: 250, 251)
        }
        try await session.command("DATA", expect: 354)
        try await stream.write(dotStuffed(message))
        try await session.command(".", expect: 250)
        _ = try? await session.command("QUIT", expect: 221)
    }

    /// Строка из одной точки означает конец письма, поэтому точка в начале
    /// строки удваивается (RFC 5321, 4.5.2). Переводы строк — только CRLF.
    public static func dotStuffed(_ message: Data) -> Data {
        let text = String(decoding: message, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        var lines = text.components(separatedBy: "\r\n")
        if lines.last == "" { lines.removeLast() }
        let stuffed = lines.map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
        return Data((stuffed + "\r\n").utf8)
    }

    struct Session {
        let stream: MailStream
        let log: (@Sendable (String) -> Void)?

        /// Ответ сервера; многострочный — `250-…` до `250 …`.
        mutating func read() async throws -> (code: Int, lines: [String]) {
            var lines: [String] = []
            while true {
                let raw = String(decoding: try await stream.readLine(), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                guard raw.count >= 3, let code = Int(raw.prefix(3)) else {
                    throw MailNetworkError.protocolError(raw)
                }
                lines.append(String(raw.dropFirst(4)))
                if raw.count == 3 || raw[raw.index(raw.startIndex, offsetBy: 3)] == " " {
                    log?("← \(code) \(lines.last ?? "")")
                    return (code, lines)
                }
            }
        }

        mutating func expect(_ codes: Int...) async throws {
            let (code, lines) = try await read()
            guard codes.contains(code) else { throw MailNetworkError.server("\(code) \(lines.joined(separator: " "))") }
        }

        @discardableResult
        mutating func command(_ text: String, expect codes: Int..., shown: String? = nil) async throws -> [String] {
            log?("→ \(shown ?? text)")
            try await stream.write(Data((text + "\r\n").utf8))
            let (code, lines) = try await read()
            guard codes.contains(code) else { throw MailNetworkError.server("\(code) \(lines.joined(separator: " "))") }
            return lines
        }
    }
}
