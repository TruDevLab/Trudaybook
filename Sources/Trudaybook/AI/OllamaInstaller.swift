import AppKit
import Foundation
import TrudaybookCore

/// Где Ollama на этом Mac, как её запустить и как поставить, если её нет.
///
/// Перенесено из Trunook (`OllamaApp`, `OllamaDownload`). Главное правило:
/// **порт старше бандла** — отвечающий порт значит, что движок работает,
/// откуда бы он ни взялся (Homebrew, руками); такую Ollama не трогаем.
///
/// Установка — образ с ollama.com, проверка подписи и перенос в «Программы».
/// Подпись сверяется с названной (нотаризация + команда Ollama): иначе мы
/// копировали бы в «Программы» всё, что пришло по ссылке. Пароля не просим
/// никогда: не вышло положить в «Программы» — показываем образ в Finder,
/// дальше человек перетаскивает сам.
@MainActor
final class OllamaInstaller: NSObject {
    enum Step: Equatable {
        case downloading(Double)
        case verifying
        case copying
        case failed(String)
    }

    static let bundleID = "com.electron.ollama"
    /// Владелец подписи — `Infra Technologies, Inc`. Имя у Ollama уже менялось
    /// однажды; сменится снова — установка откажет с понятной причиной,
    /// а образ откроется в Finder.
    static let teamID = "3MU9H2V9Y9"
    static let requirement = "anchor apple generic and identifier \"\(bundleID)\""
        + " and certificate leaf[subject.OU] = \"\(teamID)\" and notarized"
    /// Постоянная ссылка на образ: ведёт переходами на выпуск в GitHub.
    static let imageURL = URL(string: "https://ollama.com/download/Ollama.dmg")!
    static let page = URL(string: "https://ollama.com")!
    static let cliPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]

    enum Found: Equatable {
        case app(URL)
        /// Утилита без приложения (Homebrew): запускать её — дело человека.
        case cli(URL)
    }

    /// Что установлено. Утилита, которая на деле симлинк внутрь бандла
    /// (Ollama сама ставит такую), — это приложение, а не Homebrew.
    static func find() -> Found? {
        if let known = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return .app(known) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for candidate in [URL(fileURLWithPath: "/Applications/Ollama.app"), home.appendingPathComponent("Applications/Ollama.app")]
        where FileManager.default.fileExists(atPath: candidate.path) {
            return .app(candidate)
        }
        for path in cliPaths where FileManager.default.fileExists(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let range = resolved.range(of: ".app/Contents") {
                return .app(URL(fileURLWithPath: String(resolved[..<range.lowerBound]) + ".app"))
            }
            return .cli(URL(fileURLWithPath: path))
        }
        return nil
    }

    static func launch(_ bundle: URL, activates: Bool) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
            return true
        } catch {
            DebugLog.write("ИИ: Ollama не открылась — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Установка

    private var onStep: ((Step) -> Void)?
    private var finished: CheckedContinuation<URL?, Never>?
    private var session: URLSession?
    private var shown = -1

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trudaybook/Ollama", isDirectory: true)
    }

    /// Скачать, проверить, поставить. Готовый бандл в «Программах» или `nil`.
    func install(onStep: @escaping (Step) -> Void) async -> URL? {
        self.onStep = onStep
        onStep(.downloading(0))
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        return await withCheckedContinuation { continuation in
            finished = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 300
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            self.session = session
            session.downloadTask(with: Self.imageURL).resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        finish(nil)
    }

    private func finish(_ result: URL?) {
        finished?.resume(returning: result)
        finished = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    private func fail(_ reason: String, reveal app: URL? = nil) {
        onStep?(.failed(reason))
        if let app { NSWorkspace.shared.activateFileViewerSelecting([app]) }
        finish(nil)
    }

    private func settle(image: URL) {
        onStep?(.verifying)
        guard let volume = DiskImage.attach(image), let app = DiskImage.application(in: volume.mountPoint) else {
            fail(String(localized: "Образ Ollama повреждён — попробуйте ещё раз."))
            return
        }
        // Проверяем тот бандл, который сейчас и скопируем: проверить одно,
        // а поставить другое — не проверить ничего.
        if case .rejected = CodeSignatureCheck.matches(app, requirement: Self.requirement) {
            DebugLog.write("ИИ: подпись Ollama не сошлась — не ставим")
            // Образ оставлен смонтированным: путь руками — единственный, что остаётся.
            fail(String(localized: "Подпись скачанной Ollama не совпала с подписью её разработчика — не ставим. Образ открыт в Finder."), reveal: app)
            return
        }
        onStep?(.copying)
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(app.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: app, to: target)
        } catch {
            DebugLog.write("ИИ: Ollama не легла в «Программы» — \(error.localizedDescription)")
            fail(String(localized: "Нет права положить Ollama в «Программы» — перетащите её туда из открывшегося окна."), reveal: app)
            return
        }
        DiskImage.detach(volume)
        try? FileManager.default.removeItem(at: image)
        DebugLog.write("ИИ: Ollama установлена в «Программы»")
        finish(target)
    }
}

extension OllamaInstaller: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let share = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        MainActor.assumeIsolated {
            // Раз в процент: иначе состояние меняется сотни раз в секунду.
            let percent = Int(share * 100)
            guard percent != shown else { return }
            shown = percent
            onStep?(.downloading(share))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Временный файл система уносит сразу после возврата — переносим прежде всего.
        let image = OllamaInstaller.folder.appendingPathComponent("Ollama.dmg")
        try? FileManager.default.removeItem(at: image)
        let moved = (try? FileManager.default.moveItem(at: location, to: image)) != nil
        MainActor.assumeIsolated {
            if moved { settle(image: image) } else { fail(String(localized: "Образ Ollama не сохранился.")) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let reason = error.localizedDescription
        MainActor.assumeIsolated {
            DebugLog.write("ИИ: образ Ollama не скачался — \(reason)")
            fail(String(localized: "Ollama не скачалась: \(reason)"))
        }
    }
}
