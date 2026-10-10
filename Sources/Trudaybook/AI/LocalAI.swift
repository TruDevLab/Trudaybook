import AppKit
import Foundation
import TrudaybookCore

/// Местная модель для всего ИИ в приложении: пересказ писем, метки, шаблон
/// ответа, повестка и итоги по заметкам, чат с ассистентом.
///
/// Напрямую с Ollama на этом Mac — без Trunook (раньше просьбы шли к нему
/// файлами). Здесь же — то, что раньше настраивалось в Trunook: установка
/// Ollama, рекомендованные модели и их загрузка, выбор модели.
///
/// Просьбы — по одной: модель на машине одна, и две разом только замедлили
/// бы обе. Текст писем и заметок в журнал не пишется — только вид просьбы,
/// модель и время.
@MainActor
final class LocalAI: ObservableObject {
    enum Engine: Equatable {
        case checking
        case notInstalled
        /// Утилита Homebrew без приложения: запускает её человек (`ollama serve`).
        case cliOnly
        case stopped
        case starting
        case installing(OllamaInstaller.Step)
        case running(version: String)
    }

    struct Failure: Error, Equatable {
        let code: String
        let message: String
    }

    @Published private(set) var engine: Engine = .checking
    @Published private(set) var installed: [Ollama.InstalledModel] = []
    /// Что качается сейчас и сколько.
    @Published private(set) var pulling: (tag: String, share: Double)?
    @Published private(set) var pullProblem: String?

    /// Всё ИИ в приложении — выключателем.
    @Published var enabled: Bool { didSet { save(enabled, "aiEnabled") } }
    /// Метки для «Не разобрано» — сами, не чаще раза в десять минут.
    @Published var autoLabel: Bool { didSet { save(autoLabel, "aiAutoLabel") } }
    /// Выбранная модель; `nil` — подобрать самим (`Ollama.choose`).
    @Published var selectedModel: String? {
        didSet { if !demo { UserDefaults.standard.set(selectedModel, forKey: "aiModel") } }
    }

    private let client = OllamaClient()
    private let demo: Bool
    private var installer: OllamaInstaller?
    private var queue: Task<Void, Never>?

    init(demo: Bool) {
        self.demo = demo
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        // Прежняя настройка автометок была у связи с Trunook.
        autoLabel = defaults.object(forKey: "aiAutoLabel") as? Bool
            ?? defaults.object(forKey: "trunookAutoLabel") as? Bool ?? true
        selectedModel = defaults.string(forKey: "aiModel")
    }

    private func save(_ value: Bool, _ key: String) {
        if !demo { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: - Состояние

    /// Какой моделью отвечать сейчас.
    var activeModel: String? { Ollama.choose(selected: selectedModel, installed: installed, recommended: recommended) }

    /// Что по силам этой машине: память и место на домашнем томе — там
    /// Ollama держит модели (`~/.ollama/models`).
    var recommended: Ollama.Offer {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return Ollama.recommended(ram: Int64(ProcessInfo.processInfo.physicalMemory), freeDisk: Int64(free))
    }

    var isRunning: Bool {
        if case .running = engine { return true }
        return false
    }

    /// Местные модели — для выбора в настройках и в чате.
    var localModels: [Ollama.InstalledModel] { installed.filter { !$0.isCloud } }

    /// Почему спросить модель нельзя — одной фразой для места, где спросили.
    /// `nil` — можно (или движок можно поднять сам: `ensureRunning`).
    var problem: String? {
        guard enabled else { return String(localized: "ИИ выключен в Настройках → ИИ.") }
        switch engine {
        case .notInstalled: return String(localized: "Нужна Ollama — установите её в Настройках → ИИ.")
        case .cliOnly: return String(localized: "Ollama не запущена — выполните «ollama serve» в Терминале.")
        case .installing: return String(localized: "Ollama ещё устанавливается.")
        case .running where activeModel == nil:
            return String(localized: "Нет местной модели — скачайте рекомендованную в Настройках → ИИ.")
        default: return nil
        }
    }

    /// Порт, потом бандл: работающий движок не трогаем, откуда бы он ни был.
    func refresh() async {
        if case .installing = engine { return }
        if let version = await client.version() {
            engine = .running(version: version)
            installed = (try? await client.models()) ?? installed
            return
        }
        installed = []
        switch OllamaInstaller.find() {
        case .app?: engine = .stopped
        case .cli?: engine = .cliOnly
        case nil: engine = .notInstalled
        }
    }

    /// Поднять установленную Ollama, если она не запущена: открыть приложение
    /// без вывода вперёд и ждать порт до полуминуты.
    @discardableResult
    func ensureRunning() async -> Bool {
        if isRunning { return true }
        await refresh()
        if isRunning { return true }
        guard engine == .stopped, case .app(let bundle)? = OllamaInstaller.find() else { return false }
        return await start(bundle, activates: false)
    }

    func startOllama() {
        guard case .app(let bundle)? = OllamaInstaller.find() else { return }
        Task { await start(bundle, activates: true) }
    }

    private func start(_ bundle: URL, activates: Bool) async -> Bool {
        engine = .starting
        DebugLog.write("ИИ: запускаем Ollama")
        guard await OllamaInstaller.launch(bundle, activates: activates) else {
            engine = .stopped
            return false
        }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if await client.version() != nil { break }
        }
        await refresh()
        if !isRunning { engine = .stopped }
        return isRunning
    }

    // MARK: - Установка Ollama и моделей

    func installOllama() {
        guard installer == nil else { return }
        let installer = OllamaInstaller()
        self.installer = installer
        DebugLog.write("ИИ: ставим Ollama с ollama.com")
        Task {
            let bundle = await installer.install { [weak self] step in self?.engine = .installing(step) }
            self.installer = nil
            if let bundle {
                // Первый запуск — с окном: Ollama спрашивает своё, и спрятанное окно было бы тупиком.
                _ = await start(bundle, activates: true)
            } else if case .installing(.failed) = engine {
                // Причина остаётся на экране, пока не нажмут ещё раз.
            } else {
                await refresh()
            }
        }
    }

    func cancelInstall() {
        installer?.cancel()
        installer = nil
        Task { await refresh() }
    }

    /// Скачать модель. Одна за раз: две загрузки разом делят канал и место.
    func pull(_ tag: String) {
        guard pulling == nil else { return }
        pulling = (tag, 0)
        pullProblem = nil
        DebugLog.write("ИИ: качаем модель \(tag)")
        Task {
            guard await ensureRunning() else {
                pulling = nil
                pullProblem = String(localized: "Ollama не запущена.")
                return
            }
            do {
                try await client.pull(tag) { [weak self] share in self?.pulling = (tag, share) }
                DebugLog.write("ИИ: модель \(tag) скачана")
                if selectedModel == nil { selectedModel = tag }
            } catch {
                DebugLog.write("ИИ: модель \(tag) не скачалась — \(error.localizedDescription)")
                pullProblem = error.localizedDescription
            }
            pulling = nil
            await refresh()
        }
    }

    // MARK: - Просьбы

    /// Разовая просьба: промт → ответ.
    func complete(_ prompt: String, purpose: String) async -> Result<String, Failure> {
        await chat([Ollama.Message(.user, prompt)], purpose: purpose)
    }

    /// Разговор: история целиком. `onText` — ответ по мере написания.
    func chat(_ messages: [Ollama.Message], model: String? = nil, purpose: String,
              onText: (@MainActor @Sendable (String) -> Void)? = nil) async -> Result<String, Failure> {
        guard enabled else { return .failure(Failure(code: "disabled", message: problem ?? "")) }
        // Очередь: следующая просьба ждёт, пока модель ответит на предыдущую.
        let previous = queue
        let gate = Task<Void, Never> { _ = await previous?.value }
        let work = Task<Result<String, Failure>, Never> {
            await gate.value
            return await run(messages, model: model, purpose: purpose, onText: onText)
        }
        queue = Task { _ = await work.value }
        // Отмену («Остановить» в чате) — дальше, в саму просьбу: без этого
        // отменялось только ожидание, а модель дописывала ответ до конца.
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Что умеет модель (`vision` — видит картинки). Спрашиваем раз на модель.
    func capabilities(of requested: String?) async -> Set<String> {
        guard isRunning,
              let model = Ollama.choose(selected: requested ?? selectedModel, installed: installed, recommended: recommended)
        else { return [] }
        if let known = capabilityCache[model] { return known }
        let found = await client.capabilities(of: model)
        capabilityCache[model] = found
        return found
    }

    private var capabilityCache: [String: Set<String>] = [:]

    private func run(_ messages: [Ollama.Message], model requested: String?, purpose: String,
                     onText: (@MainActor @Sendable (String) -> Void)?) async -> Result<String, Failure> {
        guard await ensureRunning() else {
            return .failure(Failure(code: "offline", message: problem ?? String(localized: "Ollama не запущена.")))
        }
        // Названная модель — только скачанная и местная: облачная `…-cloud`
        // отвечала бы с того же адреса, но из интернета.
        let model = Ollama.choose(selected: requested ?? selectedModel, installed: installed, recommended: recommended)
        guard let model else {
            return .failure(Failure(code: "noModel", message: problem
                ?? String(localized: "Нет местной модели — скачайте рекомендованную в Настройках → ИИ.")))
        }
        let started = Date()
        DebugLog.write("ИИ: \(purpose) — \(model)")
        do {
            let text = try await client.chat(model: model, messages: messages, onText: onText)
            DebugLog.write("ИИ: \(purpose) готово за \(Int(Date().timeIntervalSince(started))) с")
            return .success(text)
        } catch where error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
            DebugLog.write("ИИ: \(purpose) — остановлено")
            return .failure(Failure(code: "cancelled", message: String(localized: "Остановлено.")))
        } catch let failure as OllamaClient.Failure {
            if failure == .offline { await refresh() }
            DebugLog.write("ИИ: \(purpose) — модель не ответила")
            return .failure(Failure(code: failure == .offline ? "offline" : "server",
                                    message: failure.errorDescription ?? ""))
        } catch {
            DebugLog.write("ИИ: \(purpose) — модель не ответила: \(error.localizedDescription)")
            return .failure(Failure(code: "failed", message: String(localized: "Модель не ответила: \(error.localizedDescription)")))
        }
    }
}

/// Пересказ письма в правой панели.
enum SummaryState: Equatable {
    case loading
    case ready(String)
    case failed(code: String, message: String)
}

/// Разметка «Не разобрано» моделью.
enum LabelingState: Equatable {
    case idle
    case running(done: Int, total: Int)
    case finished(count: Int)
    case failed(String)
}
