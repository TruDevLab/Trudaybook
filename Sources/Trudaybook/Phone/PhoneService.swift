import AppKit
import AVFoundation
import SwiftUI
import TrudaybookCore
import TrudaybookMail

/// Телефон SIP: настройки, регистрация, текущий звонок, номера и журнал.
///
/// Сеть и звук — в `SIPUserAgent` и `CallAudio` на своих очередях; здесь
/// только состояние для окна. Пароль — в Связке ключей, номера и журнал —
/// файлом в Application Support; в журнал приложения номера не пишутся.
@MainActor
final class PhoneService: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            save(enabled, "phoneEnabled")
            restart()
        }
    }
    @Published private(set) var account: SIPAccount
    @Published private(set) var registration = SIPRegistration.off
    /// Текущий звонок; закончившийся висит пару секунд, чтобы было видно, чем кончился.
    @Published private(set) var call: SIPCall?
    @Published private(set) var book = PhoneBook()
    @Published private(set) var muted = false
    @Published var ringtone: PhoneTones.Ringtone {
        didSet { save(ringtone.rawValue, "phoneRingtone") }
    }
    @Published var ringSound: Bool {
        didSet { save(ringSound, "phoneRingSound") }
    }
    @Published var echoCancellation: Bool {
        didSet {
            save(echoCancellation, "phoneEchoCancellation")
            media.echo = echoCancellation
        }
    }
    /// Пропущенные, которых человек ещё не видел в панели.
    @Published private(set) var unseenMissed = 0
    /// Что мешает звонить: нет микрофона и т. п.
    @Published var notice: String?
    /// Набранный номер — живёт между открытиями панели.
    @Published var dialed = ""

    let demo: Bool
    weak var model: AppModel?
    private var agent: SIPUserAgent?
    private let media = MediaRegistry()
    private var ringer: AVAudioPlayer?
    private var tone: AVAudioPlayer?
    private var demoTimers: [DispatchWorkItem] = []

    static let passwordAccount = "sip-phone"

    init(demo: Bool) {
        self.demo = demo
        let defaults = UserDefaults.standard
        enabled = demo || defaults.bool(forKey: "phoneEnabled")
        account = defaults.data(forKey: "phoneAccount").flatMap { try? JSONDecoder().decode(SIPAccount.self, from: $0) } ?? SIPAccount()
        ringtone = defaults.string(forKey: "phoneRingtone").flatMap(PhoneTones.Ringtone.init(rawValue:)) ?? .trill
        ringSound = defaults.object(forKey: "phoneRingSound") as? Bool ?? true
        echoCancellation = defaults.object(forKey: "phoneEchoCancellation") as? Bool ?? true
        media.echo = echoCancellation
        if demo {
            account.server = "pbx.demo"
            account.username = "101"
            account.displayName = String(localized: "Я")
        } else {
            book = PhoneBook.load(from: Self.bookURL)
        }
    }

    private func save(_ value: Any, _ key: String) {
        if !demo { UserDefaults.standard.set(value, forKey: key) }
    }

    static var bookURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Trudaybook/phone.json")
    }

    private func saveBook() {
        guard !demo else { return }
        do {
            try book.save(to: Self.bookURL)
        } catch {
            DebugLog.write("телефон: журнал не сохранился — \(error.localizedDescription)")
        }
    }

    // MARK: - Учётная запись

    var hasPassword: Bool {
        demo || !(Keychain.password(for: Self.passwordAccount) ?? "").isEmpty
    }

    /// Сохранить настройки; `password` — новый пароль, `nil` — прежний.
    func update(_ account: SIPAccount, password: String?) {
        self.account = account
        if !demo, let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: "phoneAccount")
        }
        if let password, !demo {
            do {
                if password.isEmpty {
                    Keychain.deletePassword(for: Self.passwordAccount)
                } else {
                    try Keychain.setPassword(password, for: Self.passwordAccount, label: "Trudaybook SIP")
                }
            } catch {
                notice = error.localizedDescription
            }
        }
        restart()
    }

    // MARK: - Жизнь

    func start(model: AppModel) {
        self.model = model
        if demo { book = Demo.phoneBook(now: model.now) }
        connect()
    }

    func restart() {
        disconnect()
        connect()
    }

    /// Выход из приложения: снять регистрацию, чтобы АТС не звонила в пустоту.
    func shutdown() {
        disconnect()
        // Снятие регистрации уходит с очереди агента — дать ему уйти до выхода.
        if !demo { Thread.sleep(forTimeInterval: 0.3) }
    }

    private func disconnect() {
        agent?.stop()
        agent = nil
        demoTimers.forEach { $0.cancel() }
        if let call, !call.isEnded {
            changed(SIPCall(id: call.id, direction: call.direction, remoteUser: call.remoteUser, remoteName: call.remoteName,
                            state: .ended(.local), started: call.started, answered: call.answered))
        }
        registration = .off
    }

    private func connect() {
        guard enabled, account.isComplete else {
            registration = .off
            return
        }
        if demo {
            registration = .registered
            return
        }
        guard let password = Keychain.password(for: Self.passwordAccount), !password.isEmpty else {
            registration = .failed(String(localized: "Не задан пароль"))
            return
        }
        let agent = SIPUserAgent(account: account, password: password)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        agent.product = "Trudaybook/\(version)"
        agent.log = { DebugLog.write($0) }
        let media = self.media
        agent.mediaPort = { media.open($0) }
        agent.onMediaStart = { media.start($0) }
        agent.onMediaStop = { media.stop($0) }
        agent.onRegistration = { [weak self] state in
            Task { @MainActor in self?.registration = state }
        }
        agent.onCall = { [weak self] call in
            Task { @MainActor in self?.changed(call) }
        }
        self.agent = agent
        agent.start()
    }

    var isRegistered: Bool { registration == .registered }

    var inCall: Bool {
        guard let call else { return false }
        return !call.isEnded
    }

    // MARK: - Звонок

    func dial(_ number: String) {
        let clean = PhoneNumber.dialable(number)
        guard !clean.isEmpty, !inCall else { return }
        notice = nil
        if demo {
            demoDial(clean)
            return
        }
        withMicrophone { [weak self] in self?.agent?.dial(clean) }
    }

    func answer() {
        guard call?.state == .incoming else { return }
        stopRinging()
        if demo {
            update(state: .active, answered: Date())
            return
        }
        withMicrophone { [weak self] in self?.agent?.answer() }
    }

    /// Отклонить входящий, отменить исходящий или положить трубку.
    func hangup() {
        guard let call, !call.isEnded else { return }
        if demo {
            demoTimers.forEach { $0.cancel() }
            let reason: SIPCallEnd = switch call.state {
            case .incoming: .declined
            case .calling, .ringing: .cancelled
            default: .local
            }
            update(state: .ended(reason))
            return
        }
        agent?.hangup()
    }

    func toggleMute() {
        guard let call, call.state == .active else { return }
        muted.toggle()
        media.setMuted(muted, for: call.id)
    }

    /// Цифра во время разговора — тоновым набором.
    func digit(_ digit: Character) {
        guard let call, call.state == .active, !demo else { return }
        if !media.sendDigit(digit, for: call.id) { agent?.sendInfoDTMF(digit) }
    }

    func markMissedSeen() {
        unseenMissed = 0
    }

    private func changed(_ new: SIPCall) {
        // Конец чужого, уже забытого звонка — только в журнал.
        if let current = call, current.id != new.id, !current.isEnded, new.isEnded {
            record(new)
            return
        }
        call = new
        switch new.state {
        case .calling:
            muted = false
        case .incoming:
            muted = false
            startRinging()
            IncomingCallWindow.show(self)
        case let .ringing(early):
            if early { stopTone() } else { playTone(PhoneTones.ringback, loop: true) }
        case .active:
            stopRinging()
            stopTone()
            IncomingCallWindow.close()
        case let .ended(reason):
            stopRinging()
            stopTone()
            IncomingCallWindow.close()
            if reason == .busy { playTone(PhoneTones.busy, loop: false) }
            record(new)
            let id = new.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.call?.id == id, self.call?.isEnded == true else { return }
                withAnimation(Motion.move) { self.call = nil }
                self.muted = false
            }
        }
    }

    private func record(_ call: SIPCall) {
        guard case let .ended(reason) = call.state else { return }
        let outcome: CallRecord.Outcome = switch (call.direction, reason) {
        case (_, .local), (_, .remote): call.answered == nil ? .failed : .answered
        case (.incoming, .declined): .declined
        case (.incoming, _): .missed
        case (.outgoing, .cancelled): .cancelled
        case (.outgoing, .busy): .busy
        case (.outgoing, .rejected): .rejected
        case (.outgoing, .unanswered): .unanswered
        case (.outgoing, _): .failed
        }
        let duration = call.answered.map { Date().timeIntervalSince($0) } ?? 0
        book.record(CallRecord(number: call.remoteUser, name: call.remoteName,
                               direction: call.direction == .incoming ? .incoming : .outgoing,
                               outcome: outcome, start: call.started, duration: duration))
        saveBook()
        if outcome == .missed, model?.phoneOpen != true { unseenMissed += 1 }
    }

    /// Имя для показа: своё для номера, иначе присланное, иначе номер.
    func name(for call: SIPCall) -> String {
        book.displayName(for: call.remoteUser, fallback: call.remoteName)
    }

    // MARK: - Номера

    func saveContact(number: String, name: String) {
        book.save(number: number, name: name)
        saveBook()
    }

    func toggleFavorite(number: String) {
        book.toggleFavorite(number: number)
        saveBook()
    }

    func removeContact(_ id: UUID) {
        book.remove(contact: id)
        saveBook()
    }

    func removeCall(_ id: UUID) {
        book.calls.removeAll { $0.id == id }
        saveBook()
    }

    func clearHistory() {
        book.calls.removeAll()
        saveBook()
    }

    // MARK: - Микрофон и звуки

    /// Звонок идёт и без микрофона — тогда вас не слышно, о чём и сказать.
    private func withMicrophone(_ action: @escaping () -> Void) {
        let denied = String(localized: "Нет доступа к микрофону — собеседник вас не услышит. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон.")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            action()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if !granted { self?.notice = denied }
                    action()
                }
            }
        default:
            notice = denied
            action()
        }
    }

    private func startRinging() {
        guard ringSound else { return }
        ringer?.stop()
        ringer = try? AVAudioPlayer(data: PhoneTones.ringtone(ringtone))
        ringer?.numberOfLoops = -1
        ringer?.play()
    }

    private func stopRinging() {
        ringer?.stop()
        ringer = nil
    }

    /// Послушать мелодию в настройках.
    func previewRingtone() {
        playTone(PhoneTones.ringtone(ringtone), loop: false)
    }

    private func playTone(_ data: Data, loop: Bool) {
        tone?.stop()
        tone = try? AVAudioPlayer(data: data)
        tone?.numberOfLoops = loop ? -1 : 0
        tone?.play()
    }

    private func stopTone() {
        tone?.stop()
        tone = nil
    }

    // MARK: - Тестовый режим

    /// Входящий для снимка и обучения: `--incoming-call`.
    func simulateIncoming() {
        guard demo, !inCall else { return }
        let caller = Demo.phoneCaller
        changed(SIPCall(id: UUID().uuidString, direction: .incoming, remoteUser: caller.number,
                        remoteName: caller.name, state: .incoming, started: Date()))
    }

    /// Разговор для снимка: `--phone-call`.
    func simulateActive() {
        guard demo, !inCall else { return }
        let caller = Demo.phoneCaller
        changed(SIPCall(id: UUID().uuidString, direction: .outgoing, remoteUser: caller.number,
                        remoteName: caller.name, state: .active, started: Date().addingTimeInterval(-95),
                        answered: Date().addingTimeInterval(-83)))
    }

    private func demoDial(_ number: String) {
        changed(SIPCall(id: UUID().uuidString, direction: .outgoing, remoteUser: number, state: .calling, started: Date()))
        schedule(after: 1) { $0.update(state: .ringing(early: false)) }
        schedule(after: 4) { $0.update(state: .active, answered: Date()) }
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping (PhoneService) -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            body(self)
        }
        demoTimers.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func update(state: SIPCall.State, answered: Date? = nil) {
        guard let call, !call.isEnded else { return }
        changed(SIPCall(id: call.id, direction: call.direction, remoteUser: call.remoteUser, remoteName: call.remoteName,
                        state: state, started: call.started, answered: answered ?? call.answered))
    }
}

/// Звук звонков по их номеру: агент спрашивает порт и включает звук
/// со своей очереди, поэтому — под замком, не на главной.
final class MediaRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: CallAudio] = [:]
    private var _echo = true

    var echo: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _echo }
        set { lock.lock(); _echo = newValue; lock.unlock() }
    }

    func open(_ id: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = calls[id] { return existing.port }
        guard let audio = CallAudio.open() else { return nil }
        calls[id] = audio
        return audio.port
    }

    func start(_ plan: SIPMediaPlan) {
        lock.lock()
        let audio = calls[plan.callID]
        let echo = _echo
        lock.unlock()
        audio?.start(plan, echoCancellation: echo)
    }

    func stop(_ id: String) {
        lock.lock()
        let audio = calls.removeValue(forKey: id)
        lock.unlock()
        audio?.stop()
    }

    func setMuted(_ muted: Bool, for id: String) {
        lock.lock()
        let audio = calls[id]
        lock.unlock()
        audio?.muted = muted
    }

    func sendDigit(_ digit: Character, for id: String) -> Bool {
        lock.lock()
        let audio = calls[id]
        lock.unlock()
        return audio?.sendDigit(digit) ?? false
    }
}
