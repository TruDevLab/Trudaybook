import Foundation

/// Соединение с Exchange Web Services: SOAP поверх HTTPS.
///
/// Вход — NTLM, как у Outlook вне домена. Корпоративный Exchange часто
/// предлагает сначала `Negotiate` (Kerberos): на Mac вне домена он не
/// сработает, поэтому отклоняется, и URLSession переходит к NTLM.
/// Basic тоже поддержан — на случай, если сервер предложит только его.
///
/// Пароль уходит только в ответ на запрос сервера и в журнал не пишется.
final class EWSClient: @unchecked Sendable {
    let url: URL
    private let session: URLSession
    private let auth: AuthDelegate
    private let log: @Sendable (String) -> Void

    init(url: URL, user: String, password: String, timeout: TimeInterval = 60,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url
        self.log = log
        auth = AuthDelegate(user: user, password: password)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = true
        session = URLSession(configuration: configuration, delegate: auth, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Адрес EWS по имени сервера: `post.company.ru` → `https://post.company.ru/EWS/Exchange.asmx`.
    /// Полный адрес оставляется как есть.
    static func endpoint(for server: String) -> URL? {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http") { return URL(string: trimmed) }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        return URL(string: "https://\(host)/EWS/Exchange.asmx")
    }

    /// Отправить операцию (содержимое `soap:Body`) и вернуть ответ операции —
    /// первый элемент внутри `soap:Body` ответа.
    func call(_ operation: String, body: String, timeZone: String? = nil) async throws -> XMLTreeNode {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Trudaybook", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(EWSRequest.envelope(body, timeZone: timeZone).utf8)

        log("→ \(operation)")
        let started = Date()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        if status == 401 {
            log("← \(operation) 401 (\(elapsed) мс)")
            throw MailNetworkError.authentication(String(localized: "сервер не принял логин или пароль"))
        }
        if status == 403 {
            log("← \(operation) 403 (\(elapsed) мс)")
            throw MailNetworkError.server(String(localized: "доступ к EWS запрещён для этой учётной записи — спросите администратора"))
        }
        let root: XMLTreeNode
        do {
            root = try XMLTreeNode.parse(data)
        } catch {
            log("← \(operation) HTTP \(status), не XML (\(elapsed) мс)")
            throw MailNetworkError.server("HTTP \(status)")
        }
        if let fault = root.first("Fault") {
            let text = fault.first("faultstring")?.text ?? fault.first("Text")?.text ?? String(localized: "ошибка SOAP")
            log("← \(operation) ошибка: \(text)")
            throw MailNetworkError.server(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let body = root.child("Body"), let result = body.children.first else {
            throw MailNetworkError.protocolError(String(localized: "в ответе нет тела"))
        }
        log("← \(operation) HTTP \(status) (\(elapsed) мс)")
        return result
    }

    private final class AuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let user: String
        let password: String

        init(user: String, password: String) {
            self.user = user
            self.password = password
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodHTTPBasic:
                // Второй запрос пароля — значит, первый не подошёл. Повторять
                // тот же бессмысленно: пусть сервер вернёт 401.
                guard challenge.previousFailureCount == 0 else { return (.rejectProtectionSpace, nil) }
                return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
            case NSURLAuthenticationMethodNegotiate:
                return (.rejectProtectionSpace, nil)
            default:
                return (.performDefaultHandling, nil)
            }
        }
    }
}
