import AVFoundation
import Foundation
import Speech
import TrudaybookCore

/// Голосовой ввод для чата: речь — в текст поля вопроса.
///
/// Только распознавание на этом Mac (`requiresOnDeviceRecognition`): голос,
/// как и письма, в интернет не уходит. Нет местной модели речи для языка —
/// так и говорим, а не отправляем звук на серверы Apple.
@MainActor
final class VoiceInput: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Распознанное за этот раз — целиком, по мере речи.
    var onText: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var limit: Task<Void, Never>?

    /// Дольше минуты подряд не слушаем: забытый включённым микрофон.
    static let maxSeconds = 60

    var isActive: Bool { state == .starting || state == .listening }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func dismissProblem() {
        if case .failed = state { state = .idle }
    }

    func start() {
        guard !isActive else { return }
        state = .starting
        Task {
            guard await Self.speechAllowed() else {
                state = .failed(String(localized: "Нет доступа к распознаванию речи — разрешите его в Системных настройках → Конфиденциальность и безопасность → Распознавание речи."))
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                state = .failed(String(localized: "Нет доступа к микрофону — разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон."))
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Self.locale) else {
                state = .failed(String(localized: "Распознавание речи для этого языка недоступно."))
                return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                state = .failed(String(localized: "Распознавание речи на этом Mac для этого языка не установлено. Включите диктовку в Системных настройках → Клавиатура — macOS скачает её. Голос в интернет мы не отправляем."))
                return
            }
            // Пока macOS спрашивала разрешения, кнопку уже отпустили.
            guard state == .starting else { return }
            do {
                try begin(recognizer)
                state = .listening
                DebugLog.write("голосовой ввод: слушаем")
                limit = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.maxSeconds))
                    if !Task.isCancelled { self?.stop() }
                }
            } catch {
                finish()
                state = .failed(String(localized: "Микрофон не включился: \(error.localizedDescription)"))
            }
        }
    }

    /// Остановить и дождаться последних слов: распознавание дописывает их
    /// уже после конца звука. Не дождались за полторы секунды — `done`
    /// с тем, что есть.
    func stop(then done: @escaping () -> Void) {
        guard isActive, task != nil else {
            stop()
            done()
            return
        }
        whenDone = done
        stop()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.fireDone()
        }
    }

    private var whenDone: (() -> Void)?

    private func fireDone() {
        let done = whenDone
        whenDone = nil
        done?()
    }

    /// Хватит слушать: распознанное до этого места остаётся в поле.
    func stop() {
        guard isActive else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        limit?.cancel()
        limit = nil
        state = .idle
        DebugLog.write("голосовой ввод: остановлен")
    }

    private func begin(_ recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        let engine = AVAudioEngine()
        Self.tap(engine.inputNode, into: request)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.request = request
        task = Self.recognize(recognizer, request) { [weak self] text, final, failed in
            guard let self else { return }
            if let text { self.onText?(text) }
            if final || failed {
                if self.isActive { self.stop() }
                self.finish()
                self.fireDone()
            }
        }
    }

    private func finish() {
        task = nil
        request = nil
        engine = nil
    }

    /// Звук с микрофона — в просьбу. Вне главного потока: блок зовёт аудиопоток.
    private nonisolated static func tap(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(
        _ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
        _ handler: @escaping @MainActor (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in handler(text, final, failed) }
        }
    }

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Язык речи — язык приложения.
    static var locale: Locale {
        switch AppLanguage.code {
        case let code where code.hasPrefix("zh"): Locale(identifier: "zh-CN")
        case let code where code.hasPrefix("en"): Locale(identifier: "en-US")
        default: Locale(identifier: "ru-RU")
        }
    }
}
