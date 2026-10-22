import AVFoundation
import Foundation
import os
import TrudaybookCore

/// Звук звонка: RTP по UDP, G.711, микрофон и динамик.
///
/// Свой сокет на звонок. Всё — на своей очереди: и приём, и отправка
/// каждые 20 мс. Отправляем туда, откуда пришёл звук той стороны
/// (симметричный RTP): за NAT адрес из SDP бывает внутренним и недоступным.
final class CallAudio: @unchecked Sendable {
    let port: Int
    private let socket: Int32
    private let queue = DispatchQueue(label: "com.trudaybook.rtp", qos: .userInteractive)
    private var source: DispatchSourceRead?
    private var sendTimer: DispatchSourceTimer?
    private var remote: sockaddr_in?
    private var latched = false
    private var payload = 8
    private var dtmfPayload: Int?
    private var srtpSend: SRTPContext?
    private var srtpReceive: SRTPContext?
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var started = false

    private let lock = NSLock()
    /// Снятое с микрофона, 8 кГц, ещё не отправленное.
    private var captured: [Int16] = []
    private var _muted = false
    private var queued = 0
    private var playing = false
    /// Тоновый набор в работе: событие и сколько кадров уже ушло.
    private var dtmf: [(event: UInt8, step: Int)] = []
    private var dtmfStamp: UInt32 = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// Слежение за сменой устройств у работающего движка.
    private var configurationObserver: NSObjectProtocol?
    private var lastRestart = Date.distantPast
    /// Звук так и не включился — сказать человеку, а не молчать в трубке.
    var onProblem: (@Sendable (String) -> Void)?
    private var echoCancellation = true
    /// Выбранные микрофон и динамик (`uid`); пусто — как в системе.
    private var inputUID = ""
    private var outputUID = ""
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    /// Кадр — 20 мс при 8 кГц.
    static let frame = 160
    /// Больше 200 мс в очереди динамика — сбрасываем: лучше пропуск, чем
    /// растущая задержка разговора.
    static let maxQueued = 10

    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    private init(socket: Int32, port: Int) {
        self.socket = socket
        self.port = port
    }

    /// Открыть сокет на случайном чётном порту (нечётный по обычаю — RTCP).
    static func open() -> CallAudio? {
        for _ in 0..<30 {
            let port = Int.random(in: 8192...16383) * 2
            if let socket = UDPSocket.open(port: port) { return CallAudio(socket: socket, port: port) }
        }
        return nil
    }

    // MARK: - Пуск

    /// Включить звук по договорённости из SDP. Повторный вызов (re-INVITE)
    /// меняет адрес, кодек и ключи, не трогая микрофон.
    func start(_ plan: SIPMediaPlan, echoCancellation: Bool, input: String, output: String) {
        queue.async {
            self.configure(plan)
            guard !self.started else { return }
            self.started = true
            self.echoCancellation = echoCancellation
            self.inputUID = input
            self.outputUID = output
            self.listen()
            self.startEngine()
            self.startSending()
        }
    }

    /// Сменить микрофон или динамик посреди разговора: звук перезапускается
    /// на новых устройствах, звонок и сеть не трогаются (пропадает доля секунды).
    func setDevices(input: String, output: String) {
        queue.async {
            guard input != self.inputUID || output != self.outputUID else { return }
            self.inputUID = input
            self.outputUID = output
            guard self.engine != nil else { return }
            self.stopEngine()
            self.startEngine()
        }
    }

    private func configure(_ plan: SIPMediaPlan) {
        let address = plan.remote.address
        if address != "0.0.0.0", !latched {
            remote = UDPSocket.resolve(address, port: plan.remote.port)
        }
        payload = plan.remote.audioPayload ?? plan.local.audioPayload ?? 8
        dtmfPayload = plan.remote.dtmfPayload
        if let mine = plan.localKey, let theirs = plan.remote.srtpKey {
            srtpSend = SRTPContext(inline: mine)
            srtpReceive = SRTPContext(inline: theirs)
        } else {
            srtpSend = nil
            srtpReceive = nil
        }
    }

    func stop() {
        queue.async {
            self.sendTimer?.cancel()
            self.sendTimer = nil
            if let source = self.source {
                source.cancel()
            } else {
                close(self.socket)
            }
            self.source = nil
            self.stopEngine()
        }
    }

    private func stopEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        player = nil
        lock.lock()
        queued = 0
        playing = false
        captured.removeAll()
        lock.unlock()
    }

    /// Тоновый набор (RFC 4733). `false` — та сторона его не понимает:
    /// тогда цифра уходит запросом INFO.
    func sendDigit(_ digit: Character) -> Bool {
        guard let event = DTMF.event(for: digit) else { return false }
        return queue.sync {
            guard dtmfPayload != nil else { return false }
            lock.lock()
            dtmf.append((event, 0))
            lock.unlock()
            return true
        }
    }

    // MARK: - Приём

    private func listen() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while let (data, from) = UDPSocket.receive(self.socket) {
                self.received(data, from: from)
            }
        }
        let socket = self.socket
        source.setCancelHandler { close(socket) }
        source.resume()
        self.source = source
    }

    private func received(_ data: Data, from: SIPEndpoint) {
        guard !RTPPacket.isRTCP(data) else { return }
        var bytes = data
        if let srtpReceive {
            guard let plain = srtpReceive.unprotect(data) else { return }
            bytes = plain
        }
        guard let packet = RTPPacket(bytes), packet.payloadType == 0 || packet.payloadType == 8 else { return }
        // Отвечаем туда, откуда пришло: за NAT это единственный рабочий адрес.
        if let address = UDPSocket.resolve(from.host, port: from.port) {
            remote = address
            latched = true
        }
        play(G711.decode(packet.payload, payload: packet.payloadType))
    }

    private func play(_ samples: [Int16]) {
        guard let player, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        lock.lock()
        guard queued < Self.maxQueued else {
            lock.unlock()
            return
        }
        queued += 1
        // Три кадра запаса перед первым звуком — от рывков сети.
        let begin = !playing && queued >= 3
        if begin { playing = true }
        lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // После смены устройств счёт обнулён, а старые буферы ещё отчитываются.
            self.queued = max(self.queued - 1, 0)
            self.lock.unlock()
        }
        if begin { player.play() }
    }

    // MARK: - Микрофон и динамик

    /// Включить микрофон и динамик. Не вышло с подавлением эха (наушники
    /// и встроенный микрофон — разные устройства, Bluetooth-гарнитура в
    /// своём режиме: `-10875`, ошибка запуска) — без него; не вышло на
    /// выбранных устройствах — на системных. Раньше первая же ошибка
    /// оставляла разговор без звука, и в журнале было только «не включился».
    private func startEngine() {
        let routed = !inputUID.isEmpty || !outputUID.isEmpty
        var attempts: [(voice: Bool, route: Bool)] = []
        if echoCancellation { attempts.append((true, routed)) }
        attempts.append((false, routed))
        if routed { attempts.append((false, false)) }
        for (index, attempt) in attempts.enumerated() {
            guard let (engine, player) = makeEngine(voice: attempt.voice, route: attempt.route) else { continue }
            if index > 0 { DebugLog.write("телефон: звук включён " + (attempt.route || !routed ? "без подавления эха" : "на системных устройствах")) }
            self.engine = engine
            self.player = player
            // Подавление эха само сообщает о смене устройств сразу после
            // запуска — такие первые сообщения не повод перезапускаться.
            lastRestart = Date()
            watchConfiguration(of: engine)
            return
        }
        onProblem?(String(localized: "Звук разговора не включился. Выберите микрофон и динамик в меню телефона (значок динамика) или в настройках звука macOS."))
    }

    private func makeEngine(voice: Bool, route: Bool) -> (AVAudioEngine, AVAudioPlayerNode)? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Подавление эха системой: без него собеседник слышит себя из динамиков.
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                DebugLog.write("телефон: подавление эха не включилось — \(error.localizedDescription)")
                return nil
            }
        }
        // Устройства — после подавления эха: оно заменяет узлы ввода и вывода,
        // и выбор, сделанный раньше, пропал бы. Нет устройства (наушники
        // отключили) — остаётся системное.
        if route, let device = AudioDevices.deviceID(uid: inputUID), let unit = input.audioUnit {
            let status = AudioDevices.route(unit, to: device)
            if status != noErr { DebugLog.write("телефон: микрофон не выбран — код \(status)") }
        }
        if route, let device = AudioDevices.deviceID(uid: outputUID), let unit = engine.outputNode.audioUnit {
            let status = AudioDevices.route(unit, to: device)
            if status != noErr { DebugLog.write("телефон: динамик не выбран — код \(status)") }
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        if inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: captureFormat) {
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.capture(buffer, converter: converter, rate: inputFormat.sampleRate)
            }
        } else {
            DebugLog.write("телефон: микрофона нет — собеседник вас не услышит")
        }
        do {
            try engine.start()
            return (engine, player)
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            DebugLog.write("телефон: звук не включился \(voice ? "с подавлением эха" : "без подавления эха") — \(error.localizedDescription)")
            return nil
        }
    }

    /// Подключили или отключили наушники, сменилось устройство в системе —
    /// `AVAudioEngine` останавливается и сам не запускается: разговор шёл
    /// дальше без звука. Перезапуск на новых устройствах, не чаще раза в 2 секунды.
    private func watchConfiguration(of engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.engine === engine, Date().timeIntervalSince(self.lastRestart) > 2 else { return }
                self.lastRestart = Date()
                DebugLog.write("телефон: устройства звука сменились — звук перезапущен")
                self.stopEngine()
                self.startEngine()
            }
        }
    }

    private func capture(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, rate: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 8000 / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
        lock.lock()
        captured += samples
        // Не копить больше 100 мс: микрофон и сеть идут каждый своим шагом.
        if captured.count > Self.frame * 5 { captured.removeFirst(captured.count - Self.frame * 5) }
        lock.unlock()
    }

    // MARK: - Отправка

    private func startSending() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        sendTimer = timer
    }

    private func tick() {
        guard let target = remote else { return }
        lock.lock()
        var frame: [Int16]
        if captured.count >= Self.frame {
            frame = Array(captured.prefix(Self.frame))
            captured.removeFirst(Self.frame)
        } else {
            frame = [Int16](repeating: 0, count: Self.frame)
        }
        if _muted { frame = [Int16](repeating: 0, count: Self.frame) }
        let digit = dtmf.first
        lock.unlock()

        if let digit, let dtmfPayload {
            sendDTMF(digit, payload: dtmfPayload, to: target)
        } else {
            send(RTPPacket(payloadType: payload, sequence: sequence, timestamp: timestamp, ssrc: ssrc,
                           payload: G711.encode(frame, payload: payload)), to: target)
        }
        timestamp &+= UInt32(Self.frame)
    }

    /// Цифра: 8 кадров по 20 мс с растущей длительностью и три «конца».
    private func sendDTMF(_ digit: (event: UInt8, step: Int), payload: Int, to target: sockaddr_in) {
        if digit.step == 0 { dtmfStamp = timestamp }
        let steps = 8
        let end = digit.step >= steps
        let duration = UInt16(min(digit.step + 1, steps) * Self.frame)
        send(RTPPacket(payloadType: payload, marker: digit.step == 0, sequence: sequence, timestamp: dtmfStamp, ssrc: ssrc,
                       payload: DTMF.payload(event: digit.event, end: end, duration: duration)), to: target)
        lock.lock()
        if digit.step >= steps + 2 {
            dtmf.removeFirst()
        } else if !dtmf.isEmpty {
            dtmf[0].step += 1
        }
        lock.unlock()
    }

    private func send(_ packet: RTPPacket, to target: sockaddr_in) {
        sequence &+= 1
        var data = packet.data
        if let srtpSend {
            guard let secret = srtpSend.protect(data) else { return }
            data = secret
        }
        UDPSocket.send(socket, data, to: target)
    }
}

/// Звонок, гудки и «занято» — синтезом: без звуковых файлов в приложении.
enum PhoneTones {
    enum Ringtone: String, CaseIterable, Identifiable {
        case trill, soft, classic
        var id: String { rawValue }

        var title: String {
            switch self {
            case .trill: String(localized: "Трель")
            case .soft: String(localized: "Мягкий")
            case .classic: String(localized: "Классический")
            }
        }
    }

    static let rate = 16_000.0

    static func ringtone(_ kind: Ringtone) -> Data {
        var samples: [Float] = []
        switch kind {
        case .trill:
            for _ in 0..<2 {
                for _ in 0..<10 {
                    samples += note(1318.5, 0.05, decay: 0) + note(1760, 0.05, decay: 0)
                }
                samples += silence(0.25)
            }
            samples += silence(1.6)
        case .soft:
            for _ in 0..<2 {
                for frequency in [659.3, 830.6, 987.8, 1318.5] { samples += note(frequency, 0.22, decay: 9) }
                samples += silence(0.35)
            }
            samples += silence(1.4)
        case .classic:
            // Звонок старого телефона: 440 и 480 Гц, «дребезг» молоточка 20 Гц.
            let length = Int(rate * 1.6)
            for index in 0..<length {
                let time = Double(index) / rate
                let bell = (sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)) / 2
                let hammer = 0.6 + 0.4 * sin(2 * .pi * 20 * time)
                samples.append(Float(bell * hammer * 0.35))
            }
            samples += silence(2.4)
        }
        return wav(samples)
    }

    /// Клавиша: пара частот тонового набора, 90 мс и тихо — щелчок с тоном,
    /// а не гудок на всю комнату.
    static func key(_ digit: Character) -> Data {
        if let cached = keyCache.withLock({ $0[digit] }) { return cached }
        let rows: [Character: Double] = ["1": 697, "2": 697, "3": 697, "4": 770, "5": 770, "6": 770,
                                         "7": 852, "8": 852, "9": 852, "*": 941, "0": 941, "#": 941]
        let columns: [Character: Double] = ["1": 1209, "4": 1209, "7": 1209, "*": 1209,
                                            "2": 1336, "5": 1336, "8": 1336, "0": 1336,
                                            "3": 1477, "6": 1477, "9": 1477, "#": 1477]
        let low = rows[digit] ?? 852, high = columns[digit] ?? 1336
        let count = Int(rate * 0.09)
        let fade = Int(rate * 0.008)
        let samples: [Float] = (0..<count).map { index in
            let time = Double(index) / rate
            var envelope = 1.0
            if index < fade { envelope = Double(index) / Double(fade) }
            if index > count - fade { envelope = Double(count - index) / Double(fade) }
            return Float((sin(2 * .pi * low * time) + sin(2 * .pi * high * time)) / 2 * envelope * 0.06)
        }
        let data = wav(samples)
        keyCache.withLock { $0[digit] = data }
        return data
    }

    private static let keyCache = OSAllocatedUnfairLock(initialState: [Character: Data]())

    /// Гудок «вызов» по ГОСТ: 425 Гц, секунда звука, четыре тишины.
    static var ringback: Data { wav(note(425, 1, decay: 0, level: 0.25) + silence(4)) }

    /// «Занято»: 425 Гц, по 0,35 с звука и тишины.
    static var busy: Data {
        var samples: [Float] = []
        for _ in 0..<4 { samples += note(425, 0.35, decay: 0, level: 0.25) + silence(0.35) }
        return wav(samples)
    }

    private static func note(_ frequency: Double, _ duration: Double, decay: Double, level: Double = 0.3) -> [Float] {
        let count = Int(rate * duration)
        let fade = Int(rate * 0.005)
        return (0..<count).map { index in
            let time = Double(index) / rate
            var envelope = decay > 0 ? exp(-decay * time) : 1
            // Края по 5 мс — без щелчков.
            if index < fade { envelope *= Double(index) / Double(fade) }
            if index > count - fade { envelope *= Double(count - index) / Double(fade) }
            let tone = sin(2 * .pi * frequency * time) + 0.25 * sin(4 * .pi * frequency * time)
            return Float(tone / 1.25 * envelope * level)
        }
    }

    private static func silence(_ duration: Double) -> [Float] {
        [Float](repeating: 0, count: Int(rate * duration))
    }

    /// WAV, 16 бит, моно.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(bytes))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32767))
        }
        return data
    }
}
