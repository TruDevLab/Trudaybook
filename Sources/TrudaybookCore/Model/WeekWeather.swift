import Foundation

/// Погода на неделю — от Trunook: он знает, где мы (или какой город выбран),
/// и уже спрашивает Open-Meteo. Trudaybook в сеть за погодой не ходит,
/// а читает файл `~/Library/Application Support/Trunook/weather-week.json`.
public struct WeekWeather: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        /// `ГГГГ-ММ-ДД` по местному времени места прогноза.
        public var date: String
        public var code: Int
        public var max: Double
        public var min: Double
        /// Вероятность осадков за день, %.
        public var precipitation: Int

        public init(date: String, code: Int, max: Double, min: Double, precipitation: Int) {
            self.date = date
            self.code = code
            self.max = max
            self.min = min
            self.precipitation = precipitation
        }
    }

    public struct Hour: Equatable, Sendable {
        public var time: Date
        public var temperature: Double
        public var code: Int
        public var precipitation: Int

        public init(time: Date, temperature: Double, code: Int, precipitation: Int) {
            self.time = time
            self.temperature = temperature
            self.code = code
            self.precipitation = precipitation
        }
    }

    public var updated: Date
    public var place: String?
    public var days: [Day]
    public var hours: [Hour]

    public init(updated: Date, place: String? = nil, days: [Day], hours: [Hour]) {
        self.updated = updated
        self.place = place
        self.days = days
        self.hours = hours
    }

    /// Потолок файла: две недели по часам — это сотни строк, не мегабайты.
    public static let maxFileSize = 512 * 1024
    /// Старше суток прогноз не показываем: Trunook его давно не обновлял.
    public static let freshness: TimeInterval = 24 * 3600

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Trunook/weather-week.json")
    }

    public static func decode(_ data: Data) -> WeekWeather? {
        guard data.count <= maxFileSize,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["version"] as? NSNumber)?.intValue == 1 else { return nil }
        let iso = ISO8601DateFormatter()
        guard let updated = (json["updated"] as? String).flatMap(iso.date(from:)) else { return nil }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let days: [Day] = ((json["days"] as? [[String: Any]]) ?? []).prefix(40).compactMap { day in
            guard let date = day["date"] as? String, date.count == 10,
                  let code = number(day["code"]), let max = number(day["max"]), let min = number(day["min"]) else { return nil }
            return Day(date: date, code: Int(code), max: max, min: min, precipitation: Int(number(day["precip"]) ?? 0))
        }
        let hours: [Hour] = ((json["hours"] as? [[String: Any]]) ?? []).prefix(24 * 40).compactMap { hour in
            guard let time = (hour["time"] as? String).flatMap(iso.date(from:)),
                  let temperature = number(hour["temp"]), let code = number(hour["code"]) else { return nil }
            return Hour(time: time, temperature: temperature, code: Int(code), precipitation: Int(number(hour["precip"]) ?? 0))
        }
        return WeekWeather(updated: updated, place: json["place"] as? String, days: days, hours: hours)
    }

    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(updated) < Self.freshness }

    /// Погода дня `date` по календарю человека.
    public func day(_ date: Date, calendar: Calendar = .current) -> Day? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return days.first { $0.date == key }
    }

    /// Часы дня `date` — по порядку.
    public func hours(on date: Date, calendar: Calendar = .current) -> [Hour] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return hours.filter { $0.time >= start && $0.time < end }.sorted { $0.time < $1.time }
    }

    /// Значок SF Symbols по коду WMO. Ночью ясно — луна.
    public static func symbol(_ code: Int, night: Bool = false) -> String {
        switch code {
        case 0: return night ? "moon.stars.fill" : "sun.max.fill"
        case 1, 2: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// Словами — для подсказки.
    public static func title(_ code: Int) -> String {
        switch code {
        case 0: return String(localized: "Ясно")
        case 1, 2: return String(localized: "Переменная облачность")
        case 3: return String(localized: "Пасмурно")
        case 45, 48: return String(localized: "Туман")
        case 51, 53, 55, 56, 57: return String(localized: "Морось")
        case 61, 63, 65, 66, 67, 80, 81, 82: return String(localized: "Дождь")
        case 71, 73, 75, 77, 85, 86: return String(localized: "Снег")
        case 95, 96, 99: return String(localized: "Гроза")
        default: return String(localized: "Облачно")
        }
    }

    /// «14°» — без десятых и без «-0°».
    public static func degrees(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }
}
