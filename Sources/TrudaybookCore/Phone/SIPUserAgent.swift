import Foundation

/// Учётная запись SIP: где регистрироваться и под каким именем.
/// Пароль здесь не хранится — его держит Связка ключей.
public struct SIPAccount: Codable, Equatable, Sendable {
    /// Домен или адрес АТС, можно с портом: `pbx.example.ru`, `10.0.0.5:5080`.
    public var server = ""
    public var transport = SIPTransportKind.udp
    /// Добавочный или логин: часть адреса до `@`.
    public var username = ""
    /// Логин для проверки, если отличается от добавочного.
    public var authUsername = ""
    /// Как вас покажут тому, кому звоните.
    public var displayName = ""
    /// Исходящий прокси, если АТС велит слать всё через него: `host[:port]`.
    public var proxy = ""
    /// Шифровать звук (SRTP) — только вместе с TLS.
    public var srtp = true
    /// Срок регистрации, секунд.
    public var expires = 300

    public init() {}

    public var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func split(_ text: String) -> (host: String, port: Int?) {
        let clean = text.trimmingCharacters(in: .whitespaces)
        return SIPHeader.hostPort(in: clean.lowercased().hasPrefix("sip") ? clean : "sip:" + clean)
    }

    public var domain: String { Self.split(server).host }
    public var aor: String { "sip:\(username.trimmingCharacters(in: .whitespaces))@\(domain)" }
    public var usesSRTP: Bool { transport == .tls && srtp }
    public var authName: String {
        let trimmed = authUsername.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? username.trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// Куда соединяться: прокси, если задан, иначе сам сервер.
    public var outbound: SIPEndpoint {
        let target = proxy.trimmingCharacters(in: .whitespaces).isEmpty ? Self.split(server) : Self.split(proxy)
        return SIPEndpoint(host: target.host, port: target.port ?? transport.defaultPort)
    }
}

public enum SIPRegistration: Equatable, Sendable {
    case off
    case registering
    case registered
    case failed(String)
}

/// Чем кончился звонок.
public enum SIPCallEnd: Equatable, Sendable {
    /// Положили трубку мы или они — после ответа.
    case local, remote
    /// Исходящий: сами отменили до ответа.
    case cancelled
    /// Входящий: звонящий сдался или ответили на другом аппарате.
    case missed
    /// Входящий: отклонили сами.
    case declined
    case busy, rejected, unanswered, notFound
    case failed(String)
}

/// Звонок для показа: кто, куда, в каком он состоянии.
public struct SIPCall: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case incoming, outgoing }
    public enum State: Equatable, Sendable {
        case calling
        /// У того звонит. `early` — АТС сама шлёт гудки (ранний звук).
        case ringing(early: Bool)
        case incoming
        case active
        case ended(SIPCallEnd)
    }

    public let id: String
    public let direction: Direction
    /// Номер или добавочный той стороны.
    public var remoteUser: String
    /// Имя, которое прислала АТС.
    public var remoteName: String?
    public var state: State
    public let started: Date
    public var answered: Date?

    public init(id: String, direction: Direction, remoteUser: String, remoteName: String? = nil,
                state: State, started: Date, answered: Date? = nil) {
        self.id = id
        self.direction = direction
        self.remoteUser = remoteUser
        self.remoteName = remoteName
        self.state = state
        self.started = started
        self.answered = answered
    }

    public var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }
}

/// Что включить для звука: свой и чужой адрес, кодек, ключи.
public struct SIPMediaPlan: Equatable, Sendable {
    public let callID: String
    public let local: SDPDescription
    public let remote: SDPDescription
    /// Свой ключ SRTP (им шифруем), чужой — в `remote.srtpKey`.
    public let localKey: String?
}

/// Программный телефон SIP (RFC 3261): регистрация, звонки в обе стороны.
///
/// Один звонок за раз: второй входящий получает «занято». Всё состояние —
/// на своей очереди; события уходят замыканиями с неё же, а показывает их
/// приложение на главной.
public final class SIPUserAgent: @unchecked Sendable {
    public let queue = DispatchQueue(label: "com.trudaybook.sip")

    public var onRegistration: ((SIPRegistration) -> Void)?
    public var onCall: ((SIPCall) -> Void)?
    public var onMediaStart: ((SIPMediaPlan) -> Void)?
    public var onMediaStop: ((String) -> Void)?
    /// Открыть порт для звука звонка; `nil` — открыть не вышло.
    public var mediaPort: ((String) -> Int?)?
    /// Журнал: только методы и коды — без номеров, имён и тел сообщений.
    public var log: ((String) -> Void)?
    public var product = "Trudaybook"

    private var account: SIPAccount
    private let password: String
    private let makeTransport: (SIPAccount) -> SIPTransport
    private var transport: SIPTransport?

    // Таймеры RFC 3261: T1 — шаг повтора, T2 — его потолок, 64·T1 — срок.
    static let t1: TimeInterval = 0.5
    static let t2: TimeInterval = 4
    static let timeout: TimeInterval = 32
    static let allow = "INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, NOTIFY, UPDATE"

    public init(account: SIPAccount, password: String,
                transport: ((SIPAccount) -> SIPTransport)? = nil) {
        self.account = account
        self.password = password
        makeTransport = transport ?? Self.defaultTransport
    }

    static func defaultTransport(_ account: SIPAccount) -> SIPTransport {
        if account.transport == .udp { return UDPTransport(server: account.outbound) }
        return StreamTransport(server: account.outbound, tls: account.transport == .tls)
    }

    // MARK: - Состояние

    private var registration = SIPRegistration.off
    private let regCallID = SIPHeader.token(24)
    private let regTag = SIPHeader.token(10)
    private var regSeq = 0
    private var regAuthTries = 0
    private var natUpdated = false
    private var stopping = false
    /// Свой адрес снаружи (`received`/`rport` из ответа) — за NAT.
    private var publicContact: SIPEndpoint?
    private var refresh: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var keepAlive: DispatchSourceTimer?

    private var transactions: [String: ClientTransaction] = [:]
    private var call: CallSession?
    /// Закончившиеся звонки, чей последний ответ ещё ждёт ACK.
    private var lingering: [String: CallSession] = [:]

    // MARK: - Регистрация

    public func start() {
        queue.async { self.connect() }
    }

    /// Снять регистрацию и закрыть соединение.
    public func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.stopping = true
            self.refresh?.cancel()
            self.retry?.cancel()
            self.keepAlive?.cancel()
            if let call = self.call { self.hangup(call) }
            guard self.transport != nil, self.registration == .registered else {
                self.shutdown()
                completion?()
                return
            }
            self.register(expires: 0)
            // Ответа на снятие ждать незачем дольше секунды.
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.shutdown()
                completion?()
            }
        }
    }

    private func shutdown() {
        for transaction in transactions.values { transaction.finish() }
        transactions.removeAll()
        transport?.stop()
        transport = nil
        set(.off)
    }

    private func set(_ state: SIPRegistration) {
        guard state != registration else { return }
        registration = state
        onRegistration?(state)
    }

    private func connect() {
        guard !stopping else { return }
        retry?.cancel()
        let transport = makeTransport(account)
        self.transport = transport
        set(.registering)
        log?("SIP: подключение, \(account.transport.rawValue)")
        transport.start(queue: queue, ready: { [weak self] in
            self?.natUpdated = false
            self?.register()
            self?.startKeepAlive()
        }, receive: { [weak self] message, from in
            self?.handle(message, from: from)
        }, failure: { [weak self] reason in
            self?.transportFailed(reason)
        })
    }

    private func transportFailed(_ reason: String) {
        log?("SIP: соединение потеряно")
        transport?.stop()
        transport = nil
        if let call { end(call, .failed(reason)) }
        set(.failed(reason))
        scheduleReconnect(after: 15)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard !stopping else { return }
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.transport == nil { self.connect() } else { self.register() }
        }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Пинг пустой строкой: держит открытой дыру в NAT и соединение TCP.
    private func startKeepAlive() {
        keepAlive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in self?.transport?.send(Data("\r\n\r\n".utf8), to: nil) }
        timer.resume()
        keepAlive = timer
    }

    private func register(expires: Int? = nil, auth: (String, String)? = nil) {
        guard transport != nil else { return }
        regSeq += 1
        let expires = expires ?? account.expires
        var extra: [(String, String)] = [("Contact", contact()), ("Expires", "\(expires)"), ("Allow", Self.allow)]
        if let auth { extra.append(auth) }
        let request = makeRequest("REGISTER", uri: "sip:\(account.domain)",
                                  from: "\(localName)<\(account.aor)>;tag=\(regTag)", to: "<\(account.aor)>",
                                  callID: regCallID, cseq: regSeq, extra: extra)
        send(request) { [weak self] response in
            self?.registered(response, expires: expires)
        }
    }

    private func registered(_ response: SIPMessage?, expires: Int) {
        guard let response else {
            log?("SIP: регистрация — нет ответа")
            set(.failed(String(localized: "Сервер не отвечает")))
            scheduleReconnect(after: 30)
            return
        }
        guard let code = response.code, code >= 200 else { return }
        switch code {
        case 200..<300:
            regAuthTries = 0
            guard expires > 0 else {
                set(.off)
                return
            }
            // За NAT сервер видит нас по другому адресу: перерегистрироваться
            // с ним, иначе входящие звонки уйдут на внутренний адрес.
            if !natUpdated, let seen = Self.seenAddress(in: response), seen != contactEndpoint {
                natUpdated = true
                publicContact = seen
                log?("SIP: адрес снаружи другой — перерегистрация")
                register()
                return
            }
            let granted = grantedExpires(response) ?? expires
            log?("SIP: зарегистрирован на \(granted) с")
            set(.registered)
            refresh?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.register() }
            refresh = item
            queue.asyncAfter(deadline: .now() + max(15, Double(granted) * 0.8), execute: item)
        case 401, 407:
            if regAuthTries < 2, let auth = authorization(response, method: "REGISTER", uri: "sip:\(account.domain)") {
                regAuthTries += 1
                register(expires: expires, auth: auth)
            } else {
                regAuthTries = 0
                log?("SIP: регистрация — \(code), логин или пароль не приняты")
                set(.failed(String(localized: "Сервер не принял логин или пароль")))
            }
        case 423:
            let minimum = response.header("Min-Expires").flatMap(Int.init) ?? 600
            account.expires = minimum
            register(expires: minimum)
        default:
            log?("SIP: регистрация — \(code)")
            set(.failed(Self.reason(response)))
            scheduleReconnect(after: 60)
        }
    }

    /// Срок, который дал сервер: у нашего Contact или общим Expires.
    private func grantedExpires(_ response: SIPMessage) -> Int? {
        let ours = contactEndpoint
        for value in response.headers("Contact") {
            let (host, port) = SIPHeader.hostPort(in: SIPHeader.uri(in: value))
            if host == ours?.host, (port ?? 5060) == (ours?.port ?? 5060),
               let found = SIPHeader.parameter("expires", in: value).flatMap(Int.init) {
                return found
            }
        }
        return response.header("Expires").flatMap(Int.init)
    }

    /// Как сервер видит наш адрес — из `received` и `rport` верхнего Via.
    static func seenAddress(in response: SIPMessage) -> SIPEndpoint? {
        guard let via = response.headers("Via").first,
              let received = SIPHeader.parameter("received", in: via), !received.isEmpty else { return nil }
        let port = SIPHeader.parameter("rport", in: via).flatMap(Int.init)
        let sentBy = via.split(separator: ";").first.map { String($0.split(separator: " ").last ?? "") } ?? ""
        let fallback = SIPHeader.hostPort(in: "sip:" + sentBy).port ?? 5060
        return SIPEndpoint(host: received, port: port ?? fallback)
    }

    // MARK: - Исходящий звонок

    /// Позвонить: номер, добавочный или адрес `user@host`.
    public func dial(_ target: String) {
        queue.async { self.startCall(target) }
    }

    private func startCall(_ target: String) {
        let clean = PhoneNumber.dialable(target)
        guard !clean.isEmpty, call == nil else { return }
        let session = CallSession(direction: .outgoing, callID: SIPHeader.token(24), remoteUser: clean)
        guard transport != nil, let host = contactEndpoint?.host else {
            session.info.state = .ended(.failed(String(localized: "Телефон не подключён")))
            onCall?(session.info)
            return
        }
        call = session
        let uri = clean.contains("@") ? (clean.lowercased().hasPrefix("sip") ? clean : "sip:" + clean) : "sip:\(clean)@\(account.domain)"
        session.requestURI = uri
        session.localURI = "\(localName)<\(account.aor)>"
        session.remoteURI = "<\(uri)>"
        session.remoteTarget = uri
        onCall?(session.info)
        guard let port = mediaPort?(session.callID) else {
            end(session, .failed(String(localized: "Не открыть порт для звука")))
            return
        }
        session.localKey = account.usesSRTP ? SRTPContext.newInlineKey() : nil
        session.localSDP = SDPDescription.offer(address: host, port: port, srtpKey: session.localKey)
        log?("SIP: исходящий звонок")
        sendInvite(session, auth: nil)
    }

    private func sendInvite(_ session: CallSession, auth: (String, String)?) {
        guard let sdp = session.localSDP else { return }
        session.localSeq += 1
        var extra: [(String, String)] = [("Contact", contact()), ("Allow", Self.allow)]
        if let auth { extra.append(auth) }
        let request = makeRequest("INVITE", uri: session.requestURI,
                                  from: "\(session.localURI);tag=\(session.localTag)", to: session.remoteURI,
                                  callID: session.callID, cseq: session.localSeq, extra: extra,
                                  body: sdp.serialized(sessionID: session.sdpSession, version: session.sdpVersion),
                                  contentType: "application/sdp")
        session.invite = request
        session.gotProvisional = false
        session.cancelSent = false
        send(request) { [weak self] response in
            self?.inviteAnswered(response, session: session)
        }
    }

    private func inviteAnswered(_ response: SIPMessage?, session: CallSession) {
        guard let response, let code = response.code else {
            // Ни ответа за 32 секунды — сервер не дошёл до того телефона.
            end(session, session.cancelRequested ? .cancelled : .failed(String(localized: "Сервер не отвечает")))
            return
        }
        switch code {
        case 100..<200:
            session.gotProvisional = true
            if session.cancelRequested {
                sendCancel(session)
                return
            }
            guard !session.ended, code > 100 else { return }
            if let tag = response.toTag { session.remoteTag = tag }
            if !response.body.isEmpty, let sdp = SDPDescription.parse(response.body) {
                session.remoteSDP = sdp
                session.early = true
                startMedia(session)
            }
            session.info.state = .ringing(early: session.early)
            onCall?(session.info)
        case 200..<300:
            session.remoteTag = response.toTag
            if let contact = response.headers("Contact").first { session.remoteTarget = SIPHeader.uri(in: contact) }
            session.routeSet = response.headers("Record-Route").reversed()
            if !response.body.isEmpty, let sdp = SDPDescription.parse(response.body) { session.remoteSDP = sdp }
            sendAck(session)
            // Ответили, пока мы отменяли, или звонок уже закрыт — сразу отбой.
            if session.cancelRequested || session.ended {
                sendBye(session)
                end(session, .cancelled)
                return
            }
            guard let remote = session.remoteSDP, remote.audioPayload != nil,
                  !(session.localKey != nil && remote.srtpKey == nil) else {
                sendBye(session)
                end(session, .failed(String(localized: "Не договорились о звуке")))
                return
            }
            session.info.state = .active
            session.info.answered = Date()
            log?("SIP: ответили")
            startMedia(session)
            onCall?(session.info)
        case 401, 407:
            sendFailureAck(session, response: response)
            guard !session.ended, !session.cancelRequested else {
                end(session, .cancelled)
                return
            }
            if session.authTries < 2, let auth = authorization(response, method: "INVITE", uri: session.requestURI) {
                session.authTries += 1
                sendInvite(session, auth: auth)
            } else {
                end(session, .failed(String(localized: "Сервер не принял логин или пароль")))
            }
        default:
            sendFailureAck(session, response: response)
            log?("SIP: звонок — \(code)")
            end(session, Self.ending(for: code, response: response, cancelled: session.cancelRequested))
        }
    }

    static func ending(for code: Int, response: SIPMessage, cancelled: Bool) -> SIPCallEnd {
        if cancelled { return .cancelled }
        switch code {
        case 486, 600: return .busy
        case 603, 403: return .rejected
        case 404, 604, 484: return .notFound
        case 408, 480: return .unanswered
        case 487: return .cancelled
        default: return .failed(reason(response))
        }
    }

    static func reason(_ response: SIPMessage) -> String {
        if case let .response(code, reason) = response.start { return "\(code) \(reason)" }
        return ""
    }

    /// ACK на 2xx — отдельная транзакция по маршруту диалога.
    private func sendAck(_ session: CallSession) {
        let request = inDialogRequest("ACK", session: session, cseq: session.inviteSeq)
        session.lastAck = request.data
        transport?.send(request.data, to: nil)
    }

    /// ACK на отказ — в той же транзакции, что и INVITE: та же ветка Via.
    private func sendFailureAck(_ session: CallSession, response: SIPMessage) {
        guard let invite = session.invite else { return }
        let ack = SIPMessage(.request(method: "ACK", uri: session.requestURI), headers: [
            ("Via", invite.headers("Via").first ?? via()), ("Max-Forwards", "70"),
            ("From", invite.header("From") ?? ""), ("To", response.header("To") ?? invite.header("To") ?? ""),
            ("Call-ID", session.callID), ("CSeq", "\(session.inviteSeq) ACK"),
        ])
        transport?.send(ack.data, to: nil)
    }

    private func sendCancel(_ session: CallSession) {
        guard let invite = session.invite, !session.cancelSent else { return }
        session.cancelSent = true
        let cancel = SIPMessage(.request(method: "CANCEL", uri: session.requestURI), headers: [
            ("Via", invite.headers("Via").first ?? via()), ("Max-Forwards", "70"),
            ("From", invite.header("From") ?? ""), ("To", invite.header("To") ?? ""),
            ("Call-ID", session.callID), ("CSeq", "\(session.inviteSeq) CANCEL"),
        ])
        send(cancel) { _ in }
    }

    private func sendBye(_ session: CallSession) {
        session.localSeq += 1
        let bye = inDialogRequest("BYE", session: session, cseq: session.localSeq)
        send(bye) { [weak self] response in
            guard let self, let response, let code = response.code, code == 401 || code == 407,
                  let auth = self.authorization(response, method: "BYE", uri: session.remoteTarget) else { return }
            session.localSeq += 1
            let retry = self.inDialogRequest("BYE", session: session, cseq: session.localSeq, extra: [auth])
            self.send(retry) { _ in }
        }
    }

    private func inDialogRequest(_ method: String, session: CallSession, cseq: Int,
                                 extra: [(String, String)] = [], body: String = "", contentType: String? = nil) -> SIPMessage {
        var headers = session.routeSet.map { ("Route", $0) }
        if method != "ACK" { headers.append(("Contact", contact())) }
        headers += extra
        let to = session.remoteTag.map { "\(session.remoteURI);tag=\($0)" } ?? session.remoteURI
        return makeRequest(method, uri: session.remoteTarget, from: "\(session.localURI);tag=\(session.localTag)",
                           to: to, callID: session.callID, cseq: cseq, extra: headers, body: body, contentType: contentType)
    }

    // MARK: - Входящий звонок

    /// Ответить на входящий.
    public func answer() {
        queue.async { self.answerIncoming() }
    }

    private func answerIncoming() {
        guard let session = call, session.info.state == .incoming, let invite = session.invite else { return }
        guard let host = contactEndpoint?.host, let port = mediaPort?(session.callID) else {
            respondFinal(session, response(to: invite, 500, "Server Internal Error", toTag: session.localTag))
            end(session, .failed(String(localized: "Не открыть порт для звука")))
            return
        }
        if let offer = session.remoteSDP {
            session.localKey = offer.isSecure ? SRTPContext.newInlineKey() : nil
            guard let answer = SDPDescription.answer(to: offer, address: host, port: port, srtpKey: session.localKey) else {
                respondFinal(session, response(to: invite, 488, "Not Acceptable Here", toTag: session.localTag))
                end(session, .failed(String(localized: "Не договорились о звуке")))
                return
            }
            session.localSDP = answer
        } else {
            // Предложение придёт в ACK: шлём своё в 200.
            session.localKey = account.usesSRTP ? SRTPContext.newInlineKey() : nil
            session.localSDP = SDPDescription.offer(address: host, port: port, srtpKey: session.localKey)
        }
        let ok = response(to: invite, 200, "OK", toTag: session.localTag,
                          extra: [("Contact", contact()), ("Allow", Self.allow)],
                          body: session.localSDP!.serialized(sessionID: session.sdpSession, version: session.sdpVersion),
                          contentType: "application/sdp")
        respondFinal(session, ok)
        session.info.state = .active
        session.info.answered = Date()
        log?("SIP: входящий принят")
        if session.remoteSDP != nil { startMedia(session) }
        onCall?(session.info)
    }

    /// Отклонить входящий или положить трубку.
    public func hangup() {
        queue.async {
            guard let session = self.call else { return }
            self.hangup(session)
        }
    }

    private func hangup(_ session: CallSession) {
        switch session.info.state {
        case .incoming:
            if let invite = session.invite {
                respondFinal(session, response(to: invite, 603, "Decline", toTag: session.localTag))
            }
            end(session, .declined)
        case .calling, .ringing:
            session.cancelRequested = true
            if session.gotProvisional { sendCancel(session) }
            // Ответ на отмену приходит не всегда; на экране звонок кончается сразу.
            end(session, .cancelled)
        case .active:
            sendBye(session)
            end(session, .local)
        case .ended:
            break
        }
    }

    /// Тоновый набор запросом INFO — если звук не договорился о telephone-event.
    public func sendInfoDTMF(_ digit: Character) {
        queue.async {
            guard let session = self.call, session.info.state == .active else { return }
            session.localSeq += 1
            let request = self.inDialogRequest("INFO", session: session, cseq: session.localSeq,
                                               body: "Signal=\(digit)\r\nDuration=160\r\n",
                                               contentType: "application/dtmf-relay")
            self.send(request) { _ in }
        }
    }

    // MARK: - Входящие сообщения

    private func handle(_ message: SIPMessage, from: SIPEndpoint?) {
        if message.code != nil {
            handleResponse(message)
            return
        }
        switch message.method {
        case "INVITE":
            if message.toTag == nil { incoming(message, from: from) } else { reinvite(message, from: from) }
        case "ACK": acknowledged(message)
        case "CANCEL": cancelled(message, from: from)
        case "BYE": bye(message, from: from)
        case "OPTIONS":
            reply(response(to: message, 200, "OK", extra: [("Allow", Self.allow), ("Accept", "application/sdp")]), to: from)
        case "NOTIFY", "INFO", "MESSAGE", "UPDATE":
            reply(response(to: message, 200, "OK"), to: from)
        default:
            reply(response(to: message, 501, "Not Implemented"), to: from)
        }
    }

    private func handleResponse(_ response: SIPMessage) {
        guard let branch = response.branch, let cseq = response.cseq, let code = response.code else { return }
        let key = branch + cseq.method
        guard let transaction = transactions[key] else {
            // Повтор 200 на INVITE, когда транзакция уже закрыта, — повторить ACK.
            if cseq.method == "INVITE", (200..<300).contains(code) {
                let session = call?.callID == response.callID ? call : lingering[response.callID]
                if let ack = session?.lastAck { transport?.send(ack, to: nil) }
            }
            return
        }
        if code < 200 {
            transaction.provisional()
        } else {
            transaction.finish()
            transactions[key] = nil
        }
        transaction.handler(response)
    }

    private func incoming(_ invite: SIPMessage, from: SIPEndpoint?) {
        if let session = call ?? lingering[invite.callID], session.callID == invite.callID {
            // Повтор того же INVITE — повторить последний ответ.
            if let last = session.lastResponse { transport?.send(last, to: session.source) }
            return
        }
        guard call == nil else {
            reply(response(to: invite, 486, "Busy Here", toTag: SIPHeader.token(10)), to: from)
            log?("SIP: второй входящий — занято")
            return
        }
        let fromHeader = invite.header("P-Asserted-Identity") ?? invite.header("From") ?? ""
        let session = CallSession(direction: .incoming, callID: invite.callID,
                                  remoteUser: SIPHeader.user(in: SIPHeader.uri(in: fromHeader)))
        session.info.remoteName = SIPHeader.displayName(in: fromHeader) ?? invite.header("From").flatMap(SIPHeader.displayName(in:))
        session.invite = invite
        session.source = from
        session.remoteTag = invite.fromTag
        session.remoteURI = Self.withoutTag(invite.header("From") ?? "")
        session.localURI = Self.withoutTag(invite.header("To") ?? "")
        session.remoteTarget = invite.headers("Contact").first.map(SIPHeader.uri(in:)) ?? SIPHeader.uri(in: session.remoteURI)
        session.routeSet = invite.headers("Record-Route")
        session.localSeq = Int.random(in: 1...10_000)
        reply(response(to: invite, 100, "Trying"), to: from)
        if !invite.body.isEmpty {
            guard let offer = SDPDescription.parse(invite.body), offer.audioPayload != nil else {
                reply(response(to: invite, 488, "Not Acceptable Here", toTag: session.localTag), to: from)
                return
            }
            session.remoteSDP = offer
        }
        call = session
        let ringing = response(to: invite, 180, "Ringing", toTag: session.localTag, extra: [("Contact", contact())])
        session.lastResponse = ringing.data
        reply(ringing, to: from)
        log?("SIP: входящий звонок")
        onCall?(session.info)
    }

    private func reinvite(_ invite: SIPMessage, from: SIPEndpoint?) {
        guard let session = call, session.callID == invite.callID, session.info.state == .active,
              let local = session.localSDP else {
            reply(response(to: invite, 481, "Call/Transaction Does Not Exist"), to: from)
            return
        }
        if let contact = invite.headers("Contact").first { session.remoteTarget = SIPHeader.uri(in: contact) }
        session.sdpVersion += 1
        var body = local
        if !invite.body.isEmpty, let offer = SDPDescription.parse(invite.body) {
            let key = offer.isSecure ? (session.localKey ?? SRTPContext.newInlineKey()) : nil
            if let answer = SDPDescription.answer(to: offer, address: local.address, port: local.port, srtpKey: key) {
                session.localKey = key
                session.remoteSDP = offer
                session.localSDP = answer
                body = answer
                startMedia(session)
            }
        }
        let ok = response(to: invite, 200, "OK", extra: [("Contact", contact()), ("Allow", Self.allow)],
                          body: body.serialized(sessionID: session.sdpSession, version: session.sdpVersion),
                          contentType: "application/sdp")
        session.source = from
        respondFinal(session, ok)
    }

    private func acknowledged(_ ack: SIPMessage) {
        guard let session = call?.callID == ack.callID ? call : lingering[ack.callID] else { return }
        session.finalTimer?.cancel()
        session.finalTimer = nil
        // Позднее предложение: SDP пришёл в ACK.
        if session.remoteSDP == nil, !ack.body.isEmpty, let sdp = SDPDescription.parse(ack.body) {
            session.remoteSDP = sdp
            if session.info.state == .active { startMedia(session) }
        }
    }

    private func cancelled(_ cancel: SIPMessage, from: SIPEndpoint?) {
        guard let session = call, session.callID == cancel.callID, session.info.state == .incoming,
              let invite = session.invite else {
            reply(response(to: cancel, 481, "Call/Transaction Does Not Exist"), to: from)
            return
        }
        reply(response(to: cancel, 200, "OK"), to: from)
        respondFinal(session, response(to: invite, 487, "Request Terminated", toTag: session.localTag))
        log?("SIP: звонящий сдался")
        end(session, .missed)
    }

    private func bye(_ bye: SIPMessage, from: SIPEndpoint?) {
        guard let session = call, session.callID == bye.callID else {
            let known = lingering[bye.callID] != nil
            reply(response(to: bye, known ? 200 : 481, known ? "OK" : "Call/Transaction Does Not Exist"), to: from)
            return
        }
        reply(response(to: bye, 200, "OK"), to: from)
        log?("SIP: положили трубку")
        end(session, session.info.state == .incoming ? .missed : .remote)
    }

    /// Окончательный ответ на INVITE: по UDP повторяется, пока не придёт ACK.
    private func respondFinal(_ session: CallSession, _ response: SIPMessage) {
        let data = response.data
        session.lastResponse = data
        transport?.send(data, to: session.source)
        session.finalTimer?.cancel()
        session.finalTimer = nil
        guard account.transport == .udp else { return }
        retransmitFinal(session, data: data, interval: Self.t1, deadline: Date().addingTimeInterval(Self.timeout))
    }

    private func retransmitFinal(_ session: CallSession, data: Data, interval: TimeInterval, deadline: Date) {
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, session.lastResponse == data else { return }
            guard Date() < deadline else {
                session.finalTimer = nil
                // Ответили, а ACK так и не пришёл: звонок не состоялся.
                if self.call === session, session.info.state == .active {
                    self.sendBye(session)
                    self.end(session, .failed(String(localized: "Связь с сервером прервалась")))
                }
                return
            }
            self.transport?.send(data, to: session.source)
            self.retransmitFinal(session, data: data, interval: min(interval * 2, Self.t2), deadline: deadline)
        }
        session.finalTimer = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    // MARK: - Звук и конец

    private func startMedia(_ session: CallSession) {
        guard let local = session.localSDP, let remote = session.remoteSDP else { return }
        session.mediaStarted = true
        onMediaStart?(SIPMediaPlan(callID: session.callID, local: local, remote: remote, localKey: session.localKey))
    }

    private func end(_ session: CallSession, _ reason: SIPCallEnd) {
        guard !session.ended else { return }
        session.ended = true
        session.info.state = .ended(reason)
        if session.localSDP != nil { onMediaStop?(session.callID) }
        if call === session { call = nil }
        // Ждём ACK на последний ответ или повтор 200 — не дольше срока транзакции.
        lingering[session.callID] = session
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard self?.lingering[session.callID] === session else { return }
            self?.lingering[session.callID] = nil
        }
        onCall?(session.info)
    }

    // MARK: - Сборка сообщений

    private var localName: String {
        let name = account.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "" : SIPHeader.quoted(name) + " "
    }

    private var contactEndpoint: SIPEndpoint? { publicContact ?? transport?.local }

    private func contact() -> String {
        let endpoint = contactEndpoint ?? SIPEndpoint(host: "0.0.0.0", port: 0)
        let user = account.username.trimmingCharacters(in: .whitespaces)
        let suffix = account.transport == .udp ? "" : ";transport=\(account.transport.rawValue)"
        return "<sip:\(user)@\(endpoint.host):\(endpoint.port)\(suffix)>"
    }

    private func via() -> String {
        let local = transport?.local ?? SIPEndpoint(host: "0.0.0.0", port: 0)
        return "SIP/2.0/\(account.transport.viaName) \(local.host):\(local.port);branch=z9hG4bK\(SIPHeader.token(18));rport"
    }

    private func makeRequest(_ method: String, uri: String, from: String, to: String, callID: String, cseq: Int,
                             extra: [(String, String)] = [], body: String = "", contentType: String? = nil) -> SIPMessage {
        var headers: [(String, String)] = [
            ("Via", via()), ("Max-Forwards", "70"), ("From", from), ("To", to),
            ("Call-ID", callID), ("CSeq", "\(cseq) \(method)"),
        ]
        headers += extra
        headers.append(("User-Agent", product))
        if let contentType { headers.append(("Content-Type", contentType)) }
        return SIPMessage(.request(method: method, uri: uri), headers: headers, body: body)
    }

    private func response(to request: SIPMessage, _ code: Int, _ reason: String, toTag: String? = nil,
                          extra: [(String, String)] = [], body: String = "", contentType: String? = nil) -> SIPMessage {
        var headers: [(String, String)] = request.headers
            .filter { SIPMessage.canonical($0.name) == "via" }
            .map { ($0.name, $0.value) }
        if request.method == "INVITE", code > 100, code < 300 {
            headers += request.headers.filter { SIPMessage.canonical($0.name) == "record-route" }.map { ($0.name, $0.value) }
        }
        headers.append(("From", request.header("From") ?? ""))
        var to = request.header("To") ?? ""
        if let toTag, request.toTag == nil, code > 100 { to += ";tag=\(toTag)" }
        headers.append(("To", to))
        headers.append(("Call-ID", request.callID))
        headers.append(("CSeq", request.header("CSeq") ?? ""))
        headers += extra
        headers.append(("Server", product))
        if let contentType { headers.append(("Content-Type", contentType)) }
        return SIPMessage(.response(code: code, reason: reason), headers: headers, body: body)
    }

    private func reply(_ response: SIPMessage, to endpoint: SIPEndpoint?) {
        transport?.send(response.data, to: endpoint)
    }

    static func withoutTag(_ value: String) -> String {
        let pattern = #";\s*tag=[^;,\s]*"#
        guard let close = value.lastIndex(of: ">") else {
            return value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let tail = value[value.index(after: close)...].replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return String(value[...close]) + tail
    }

    private func authorization(_ response: SIPMessage, method: String, uri: String) -> (String, String)? {
        let proxy = response.code == 407
        guard let challenge = response.header(proxy ? "Proxy-Authenticate" : "WWW-Authenticate"),
              let value = SIPDigest.authorization(challenge: challenge, method: method, uri: uri,
                                                  username: account.authName, password: password) else { return nil }
        return (proxy ? "Proxy-Authorization" : "Authorization", value)
    }

    // MARK: - Транзакции клиента

    /// Отправить запрос и ждать ответов; по UDP — с повторами (RFC 3261 §17.1).
    private func send(_ request: SIPMessage, handler: @escaping (SIPMessage?) -> Void) {
        guard let transport, let branch = request.branch, let method = request.method else { return }
        let data = request.data
        let transaction = ClientTransaction(isInvite: method == "INVITE", data: data, handler: handler)
        let key = branch + method
        transactions[key] = transaction
        transport.send(data, to: nil)
        transaction.deadline = Date().addingTimeInterval(Self.timeout)
        schedule(transaction, key: key, reliable: transport.kind != .udp)
    }

    private func schedule(_ transaction: ClientTransaction, key: String, reliable: Bool) {
        let item = DispatchWorkItem { [weak self, weak transaction] in
            guard let self, let transaction, !transaction.finished else { return }
            guard Date() < transaction.deadline else {
                transaction.finish()
                self.transactions[key] = nil
                transaction.handler(nil)
                return
            }
            if !reliable { self.transport?.send(transaction.data, to: nil) }
            transaction.interval = transaction.gotProvisional ? Self.t2 : min(transaction.interval * 2, Self.t2)
            self.schedule(transaction, key: key, reliable: reliable)
        }
        transaction.timer = item
        // Надёжному транспорту повторы не нужны, но срок ответа — нужен.
        let delay = reliable ? max(0.1, transaction.deadline.timeIntervalSinceNow) : transaction.interval
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private final class ClientTransaction {
        let isInvite: Bool
        let data: Data
        let handler: (SIPMessage?) -> Void
        var timer: DispatchWorkItem?
        var interval = SIPUserAgent.t1
        var deadline = Date()
        var gotProvisional = false
        var finished = false

        init(isInvite: Bool, data: Data, handler: @escaping (SIPMessage?) -> Void) {
            self.isInvite = isInvite
            self.data = data
            self.handler = handler
        }

        func provisional() {
            gotProvisional = true
            // INVITE после предварительного ответа ждёт окончательного сколько
            // угодно — телефон на том конце звонит, пока не возьмут.
            if isInvite { timer?.cancel() }
        }

        func finish() {
            finished = true
            timer?.cancel()
        }
    }

    private final class CallSession {
        var info: SIPCall
        let callID: String
        let localTag = SIPHeader.token(10)
        var remoteTag: String?
        var localURI = ""
        var remoteURI = ""
        var requestURI = ""
        var remoteTarget = ""
        var routeSet: [String] = []
        var localSeq = 0
        var invite: SIPMessage?
        /// CSeq последнего INVITE — для ACK и CANCEL.
        var inviteSeq: Int { invite?.cseq?.number ?? localSeq }
        var source: SIPEndpoint?
        var authTries = 0
        var gotProvisional = false
        var cancelRequested = false
        var cancelSent = false
        var early = false
        var ended = false
        var localSDP: SDPDescription?
        var remoteSDP: SDPDescription?
        var localKey: String?
        var mediaStarted = false
        let sdpSession = UInt64.random(in: 1_000_000...9_999_999)
        var sdpVersion: UInt64 = 1
        var lastResponse: Data?
        var lastAck: Data?
        var finalTimer: DispatchWorkItem?

        init(direction: SIPCall.Direction, callID: String, remoteUser: String) {
            self.callID = callID
            info = SIPCall(id: callID, direction: direction, remoteUser: remoteUser,
                           state: direction == .incoming ? .incoming : .calling, started: Date())
        }
    }
}
