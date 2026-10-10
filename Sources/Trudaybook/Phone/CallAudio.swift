import AVFoundation
import Foundation
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
    func start(_ plan: SIPMediaPlan, echoCancellation: Bool) {
        queue.async {
            self.configure(plan)
            guard !self.started else { return }
            self.started = true
            self.listen()
            self.startEngine(echoCancellation: echoCancellation)
            self.startSending()
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
            if let engine = self.engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            self.engine = nil
            self.player = nil
        }
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
            self.queued -= 1
            self.lock.unlock()
        }
        if begin { player.play() }
    }

    // MARK: - Микрофон и динамик

    private func startEngine(echoCancellation: Bool) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Подавление эха системой: без него собеседник слышит себя из динамиков.
        if echoCancellation { try? input.setVoiceProcessingEnabled(true) }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let inputFormat = input.outputFormat(forBus: 0)
        if inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: captureFormat) {
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.capture(buffer, converter: converter, rate: inputFormat.sampleRate)
            }
        }
        do {
            try engine.start()
        } catch {
            DebugLog.write("телефон: звук не включился — \(error.localizedDescription)")
        }
        self.engine = engine
        self.player = player
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
