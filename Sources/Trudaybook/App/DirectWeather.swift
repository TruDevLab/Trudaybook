import AppKit
import CoreLocation
import TrudaybookCore

/// Погода без Trunook — прямо у Open-Meteo.
///
/// Выключена по умолчанию: это единственный сторонний сервис, к которому
/// Trudaybook ходит сам (правило приложения — ничего не отправлять наружу
/// без спроса). Включённая, спрашивает прогноз, только когда Trunook его
/// не прислал: Trunook нет, он закрыт или файл его устарел. Наружу уходят
/// координаты, округлённые до ~10 км, или название города при поиске.
@MainActor
final class DirectWeather: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Source: String, CaseIterable, Identifiable {
        case location, city
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case off
        case waiting
        case loading
        case ready(Date)
        case failed(String)
    }

    @Published var enabled: Bool {
        didSet { save(enabled, "weatherDirect"); if enabled { refresh(force: true) } else { status = .off } }
    }
    @Published var source: Source {
        didSet { save(source.rawValue, "weatherDirectSource"); refresh(force: true) }
    }
    /// Выбранный город (для `source == .city`).
    @Published var place: OpenMeteo.Place? {
        didSet {
            if persists { UserDefaults.standard.set(place.flatMap { try? JSONEncoder().encode($0) }, forKey: "weatherDirectPlace") }
            refresh(force: true)
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var results: [OpenMeteo.Place] = []
    @Published private(set) var searching = false

    /// Свой файл прогноза — того же вида, что у Trunook.
    var file: URL
    /// В тестовом режиме — без сети и без записи настроек.
    var persists = true
    /// Прогноз обновился — модель перечитает файл.
    var onUpdate: (() -> Void)?
    /// Прислал ли Trunook свежую погоду — тогда своя не нужна.
    var trunookFresh: () -> Bool = { false }

    private let session: URLSession
    private let locator = CLLocationManager()
    private var lastAttempt: Date?
    private var searchTask: Task<Void, Never>?

    static let refreshInterval: TimeInterval = 3600

    override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "weatherDirect")
        source = Source(rawValue: defaults.string(forKey: "weatherDirectSource") ?? "") ?? .city
        place = defaults.data(forKey: "weatherDirectPlace").flatMap { try? JSONDecoder().decode(OpenMeteo.Place.self, from: $0) }
        file = (try? SQLiteDatabase.applicationSupportURL("weather-week.json"))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("weather-week.json")
        // Без куки, кэша и сохранённых учётных данных: запросу нечего о нас сообщать.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        super.init()
        locator.delegate = self
        locator.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        status = enabled ? .waiting : .off
    }

    private func save(_ value: Any, _ key: String) {
        if persists { UserDefaults.standard.set(value, forKey: key) }
    }

    /// Раз в полминуты от часов модели. Спрашивает, только если включено,
    /// Trunook молчит и свой прогноз старше часа. После неудачи — не чаще
    /// раза в десять минут.
    func refresh(force: Bool = false) {
        guard enabled, persists else { return }
        guard force || !trunookFresh() else { return }
        if !force {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < Self.refreshInterval { return }
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 600 { return }
        }
        lastAttempt = Date()
        switch source {
        case .city:
            guard let place else {
                status = .failed(String(localized: "Выберите город."))
                return
            }
            fetch(latitude: place.latitude, longitude: place.longitude, name: place.title)
        case .location:
            status = .loading
            switch locator.authorizationStatus {
            case .notDetermined: locator.requestWhenInUseAuthorization()
            case .denied, .restricted: status = .failed(Self.noAccess)
            default: locator.requestLocation()
            }
        }
    }

    static var noAccess: String {
        String(localized: "Нет доступа к геолокации — выберите город или разрешите в Системных настройках → Конфиденциальность → Службы геолокации.")
    }

    private func fetch(latitude: Double, longitude: Double, name: String?) {
        guard let url = OpenMeteo.forecastURL(latitude: latitude, longitude: longitude) else { return }
        status = .loading
        Task {
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let export = OpenMeteo.export(from: data, now: Date(), place: name) else {
                    status = .failed(String(localized: "Open-Meteo ответил непонятно."))
                    return
                }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try export.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                DebugLog.write("погода: прогноз Open-Meteo получен")
                status = .ready(Date())
                onUpdate?()
            } catch {
                DebugLog.write("погода: Open-Meteo не ответил — \(error.localizedDescription)")
                status = .failed(String(localized: "Погода не получена: \(error.localizedDescription)"))
            }
        }
    }

    /// Поиск города — с задержкой: не по запросу на каждую букву.
    func search(_ query: String) {
        searchTask?.cancel()
        guard persists, let url = OpenMeteo.searchURL(query, language: AppLanguage.code) else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            guard let (data, _) = try? await session.data(from: url), !Task.isCancelled else { return }
            results = OpenMeteo.places(from: data)
        }
    }

    // MARK: - Геолокация

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        Task { @MainActor in
            guard self.enabled, self.source == .location, self.status == .loading else { return }
            switch authorization {
            case .denied, .restricted: self.status = .failed(Self.noAccess)
            case .notDetermined: break
            default: self.locator.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude, longitude = coordinate.longitude
        Task { @MainActor in
            // Где именно — не спрашиваем у Apple (обратный геокодинг): название
            // места погоде не нужно, а лишний запрос о нашем месте — ни к чему.
            self.fetch(latitude: latitude, longitude: longitude, name: nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            DebugLog.write("погода: место не определилось — \(message)")
            self.status = .failed(String(localized: "Место не определилось: \(message)"))
        }
    }
}
