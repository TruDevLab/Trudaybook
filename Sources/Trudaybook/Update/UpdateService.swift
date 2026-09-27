import AppKit
import CryptoKit
import Foundation
import TrudaybookCore

/// Проверяет GitHub на новую версию, скачивает её фоном и держит проверенной
/// до нажатия «Перезапустить». Устроена как в Trunook (`Update/UpdateService`):
/// разбор ответа, расписание и решения — чистые типы в `TrudaybookCore`,
/// их проверяют тесты; здесь только сеть, диск и процессы.
///
/// В сеть уходит одно: `GET /repos/TruDevLab/Trudaybook/releases/latest`
/// с именем и версией приложения в `User-Agent`, раз в сутки. Ни адресов,
/// ни данных почты.
final class UpdateService: NSObject, ObservableObject, @unchecked Sendable {
    /// Тот же репозиторий, что в README.
    static let repository = "TruDevLab/Trudaybook"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    @Published private(set) var state: UpdateState = .idle

    /// Своя версия. Подменяется только в тестовом режиме (`--pretend-version`),
    /// чтобы прогнать загрузку, не выпуская ничего нового.
    let currentVersion: AppVersion?

    private let defaults: UserDefaults
    private let firstCheckDelay: TimeInterval
    private let session: URLSession
    private var timer: Timer?
    private var downloadSession: URLSession?
    private var downloading: GitHubRelease?
    private var manualDownload = false

    /// Когда пробовали в последний раз — удачно или нет. В памяти, а не на
    /// диске: там только удачная проверка. Так нет ни долбёжки сети после
    /// каждого пробуждения, ни недели без проверок из-за одной поездки без сети.
    private var lastAttempt: Date?

    /// Тик — шесть часов при пороге в сутки: суточный таймер съедается сном
    /// крышки, а лишние тики гасит `UpdateSchedule.shouldCheck`.
    private static let tick: TimeInterval = 6 * 60 * 60
    private static let retryAfterFailure: TimeInterval = 60 * 60

    static let enabledKey = "autoUpdateEnabled"
    static let lastCheckKey = "lastUpdateCheck"
    static let rejectedKey = "updateRejectedVersion"

    init(defaults: UserDefaults = .standard, pretendVersion: String? = nil, firstCheckDelay: TimeInterval = 30) {
        self.defaults = defaults
        self.firstCheckDelay = firstCheckDelay
        currentVersion = AppVersion(pretendVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        super.init()
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.enabledKey)
            if newValue { check(manual: false) }
        }
    }

    /// Показ версии: «0.1.0 (2609261522)».
    var versionText: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [currentVersion?.text ?? "?", build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - Жизнь службы

    func start() {
        UpdateInstaller.cleanLeftovers(near: Bundle.main.bundleURL.resolvingSymlinksInPath())
        restoreStaged()

        // Первый заход не сразу: запуск и так занят почтой и календарём.
        DispatchQueue.main.asyncAfter(deadline: .now() + firstCheckDelay) { [weak self] in
            self?.check(manual: false)
        }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func woke() {
        check(manual: false)
    }

    /// Готовое после перезапуска: подпись перепроверяется — папка доступна
    /// на запись любому процессу пользователя.
    private func restoreStaged() {
        guard let staged = UpdateStore.staged() else { return }
        guard let ready = AppVersion(staged.version), let currentVersion, ready > currentVersion else {
            DebugLog.write("обновление: скачанное уже не новее — чистим")
            UpdateStore.clear()
            return
        }
        if case .rejected = CodeSignatureCheck.matchesSelf(UpdateStore.stagedApp) {
            DebugLog.write("обновление: подпись скачанного не сошлась при запуске — чистим")
            UpdateStore.clear()
            return
        }
        DebugLog.write("обновление: с прошлого раза готова \(ready), ждём проверки")
    }

    // MARK: - Проверка

    func check(manual: Bool) {
        let now = Date()
        guard UpdateSchedule.shouldCheck(now: now, last: defaults.object(forKey: Self.lastCheckKey) as? Date,
                                         enabled: isEnabled, manual: manual)
        else { return }
        if state.isBusy { return }
        if !manual, let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryAfterFailure { return }
        // Готовое не перепроверяем сами: ждёт нажатия. Рукой — можно, вдруг
        // вышло что-то новее.
        if !manual, state.readyRelease != nil { return }
        lastAttempt = now
        manualDownload = manual

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Без своего имени GitHub отвечает отказом — не поломка сети.
        request.setValue("Trudaybook/\(currentVersion?.text ?? "0")", forHTTPHeaderField: "User-Agent")

        settle(.checking)
        DebugLog.write("обновление: спрашиваем GitHub\(manual ? " (рукой)" : "")")
        session.dataTask(with: request) { [weak self] data, response, failure in
            guard let self else { return }
            if let failure {
                DebugLog.write("обновление: проверка не удалась — \(failure.localizedDescription)")
                self.settle(.failed(.network))
                return
            }
            self.received(data, response as? HTTPURLResponse)
        }.resume()
    }

    private func received(_ data: Data?, _ response: HTTPURLResponse?) {
        if let response, response.statusCode != 200 {
            // Исчерпанный лимит — «позже», а не «чините сеть».
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            let limited = (response.statusCode == 403 || response.statusCode == 429) && remaining == "0"
            DebugLog.write("обновление: GitHub ответил \(response.statusCode), запас \(remaining ?? "?")")
            settle(.failed(limited ? .rateLimited : .badResponse))
            return
        }
        guard let data, let release = GitHubRelease.parse(data) else {
            DebugLog.write("обновление: ответ GitHub не разобран")
            settle(.failed(.badResponse))
            return
        }

        let now = Date()
        defaults.set(now, forKey: Self.lastCheckKey)

        guard let currentVersion else {
            DebugLog.write("обновление: своя версия не разобрана, сравнивать не с чем")
            settle(.failed(.badResponse))
            return
        }
        // Строго новее, а не «другая»: `/releases/latest` — последний по дате
        // публикации, и заплатка к старой ветке иначе устроила бы откат.
        guard release.version > currentVersion else {
            DebugLog.write("обновление: на GitHub \(release.version), у нас \(currentVersion) — новее нет")
            if UpdateStore.staged() != nil { UpdateStore.clear() }
            settle(.upToDate(checkedAt: now))
            return
        }

        DebugLog.write("обновление: найдена \(release.version), у нас \(currentVersion)")
        guard UpdateSchedule.shouldDownload(release.version, rejected: defaults.string(forKey: Self.rejectedKey),
                                            manual: manualDownload)
        else {
            DebugLog.write("обновление: \(release.version) уже отвергнута за подпись — не качаем")
            settle(.failed(.wrongCertificate))
            return
        }
        useStagedOrDownload(release)
    }

    // MARK: - Загрузка

    private func useStagedOrDownload(_ release: GitHubRelease) {
        if let staged = UpdateStore.staged(), let ready = AppVersion(staged.version) {
            if ready == release.version {
                DebugLog.write("обновление: \(ready) уже скачана")
                settle(.ready(release, staged: UpdateStore.stagedApp))
                return
            }
            DebugLog.write("обновление: скачана \(ready), а нужна \(release.version) — чистим")
            UpdateStore.clear()
        }
        guard UpdateStore.makeFolder() else {
            settle(.failed(.installFailed))
            return
        }
        guard hasRoom(for: release) else {
            settle(.failed(.noSpace))
            return
        }

        settle(.downloading(release, progress: 0))
        downloading = release
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        downloadSession = session
        DebugLog.write("обновление: качаем \(release.assetName)")
        session.downloadTask(with: release.assetURL).resume()
    }

    /// Втрое больше образа: сам образ, распакованное приложение и копия
    /// рядом с целью при установке.
    private func hasRoom(for release: GitHubRelease) -> Bool {
        guard release.assetSize > 0 else { return true }
        let values = try? UpdateStore.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > Int64(release.assetSize) * 3
    }

    /// Сумма, монтирование, копия, подпись, версия. Подпись проверяется
    /// у **своей копии**, а не у приложения на образе: проверить одно,
    /// а поставить другое — значит не проверить ничего.
    private func unpack(_ release: GitHubRelease, from image: URL) {
        defer { try? FileManager.default.removeItem(at: image) }

        // Сумма ловит оборванную загрузку и не тот образ, от подмены она не
        // защищает. Поэтому: нет суммы — идём дальше, есть и не сошлась — отказ.
        if let expected = release.checksum {
            guard let actual = Self.checksum(of: image) else {
                settle(.failed(.damaged))
                return
            }
            guard actual == expected else {
                DebugLog.write("обновление: сумма не сошлась — ждали \(expected), вышло \(actual)")
                settle(.failed(.checksumMismatch))
                return
            }
        } else {
            DebugLog.write("обновление: в описании выпуска нет суммы, держимся на подписи")
        }

        guard let mounted = DiskImage.attach(image) else {
            settle(.failed(.damaged))
            return
        }
        defer { DiskImage.detach(mounted) }
        guard let source = DiskImage.application(in: mounted.mountPoint) else {
            settle(.failed(.damaged))
            return
        }

        let destination = UpdateStore.stagedApp
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            DebugLog.write("обновление: копия с образа не удалась — \(error.localizedDescription)")
            settle(.failed(.installFailed))
            return
        }

        if case let .rejected(reason) = CodeSignatureCheck.matchesSelf(destination) {
            UpdateStore.clear()
            if reason == .wrongCertificate { defaults.set(release.version.text, forKey: Self.rejectedKey) }
            settle(.failed(reason))
            return
        }

        let info = Self.plist(inside: destination)
        let inside = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard let inside, inside == release.version else {
            DebugLog.write("обновление: в образе версия \(inside?.text ?? "?"), обещали \(release.version)")
            UpdateStore.clear()
            settle(.failed(.badResponse))
            return
        }

        UpdateStore.write(StagedUpdate(
            tag: release.tag, version: release.version.text,
            build: info?["CFBundleVersion"] as? String ?? "?",
            checksum: release.checksum, verifiedAt: Date()
        ))
        defaults.removeObject(forKey: Self.rejectedKey)
        DebugLog.write("обновление: \(release.version) скачана и проверена")
        settle(.ready(release, staged: destination))
    }

    // MARK: - Установка

    /// Ставит скачанное и выходит. Дальше работает подменщик: дождётся
    /// выхода, подменит бандл и запустит новое приложение.
    func install() {
        guard case let .ready(release, staged) = state else { return }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let writable = FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)

        switch InstallTarget.decide(bundleURL: bundle, parentIsWritable: writable) {
        case let .refused(reason):
            DebugLog.write("обновление: ставить некуда — \(reason.message)")
            settle(.failed(reason))
        case let .ready(target):
            settle(.installing)
            if let reason = UpdateInstaller.install(staged: staged, into: target) {
                settle(.failed(reason))
                return
            }
            DebugLog.write("обновление: ставим \(release.version), выходим")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Показ готового обновления без сети — для снимка (`--update-preview 0.2.0`).
    func preview(version text: String) {
        guard let version = AppVersion(text),
              let url = URL(string: "https://github.com/\(Self.repository)/releases/download/v\(text)/Trudaybook-\(text).dmg")
        else { return }
        let release = GitHubRelease(tag: "v\(text)", version: version, assetName: url.lastPathComponent,
                                    assetURL: url, assetSize: 0, checksum: nil,
                                    pageURL: Self.releasesPage.appendingPathComponent("tag/v\(text)"))
        state = .ready(release, staged: UpdateStore.stagedApp)
    }

    // MARK: - Мелочи

    private func settle(_ next: UpdateState) {
        DispatchQueue.main.async { [weak self] in self?.state = next }
    }

    /// Кусками, а не целиком в память.
    static func checksum(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let piece = try? handle.read(upToCount: 1 << 20), !piece.isEmpty {
            digest.update(data: piece)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func plist(inside bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}

extension UpdateService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let release = downloading else { return }
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(release.assetSize)
        guard total > 0 else { return }
        let share = min(1, Double(totalBytesWritten) / total)
        if case let .downloading(_, shown) = state, Int(shown * 100) == Int(share * 100) { return }
        if Int(share * 100) % 25 == 0 { DebugLog.write("обновление: скачано \(Int(share * 100)) %") }
        settle(.downloading(release, progress: share))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let release = downloading else { return }
        // Временный файл система уносит сразу после возврата — переносим первым делом.
        let image = UpdateStore.imageFile(named: release.assetName)
        try? FileManager.default.removeItem(at: image)
        do {
            try FileManager.default.moveItem(at: location, to: image)
        } catch {
            DebugLog.write("обновление: скачанное не перенеслось — \(error.localizedDescription)")
            settle(.failed(.installFailed))
            return
        }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            DebugLog.write("обновление: образ не отдан — \(http.statusCode)")
            try? FileManager.default.removeItem(at: image)
            settle(.failed(.network))
            return
        }
        unpack(release, from: image)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            downloading = nil
        }
        guard let error else { return }
        DebugLog.write("обновление: загрузка сорвалась — \(error.localizedDescription)")
        settle(.failed(.network))
    }
}
