import Foundation

/// Погода без Trunook: прямо у Open-Meteo (open-meteo.com) — бесплатно,
/// без ключей и учётных записей. Тот же источник, что у Trunook, и тот же
/// формат файла: неделя, шапка дня и тема «Небо» не знают, откуда прогноз.
///
/// Наружу уходят только координаты, округлённые до десятой градуса
/// (около 10 км): для погоды точнее не нужно, а дом так не найти.
public enum OpenMeteo {
    /// Место прогноза: город из поиска или «где я» (координаты от macOS).
    public struct Place: Codable, Equatable, Hashable, Identifiable, Sendable {
        public var name: String
        public var region: String?
        public var country: String?
        public var latitude: Double
        public var longitude: Double

        public init(name: String, region: String? = nil, country: String? = nil, latitude: Double, longitude: Double) {
            self.name = name
            self.region = region
            self.country = country
            self.latitude = latitude
            self.longitude = longitude
        }

        public var id: String { "\(name)|\(latitude)|\(longitude)" }

        /// «Химки, Московская область».
        public var title: String {
            guard let region, !region.isEmpty, region != name else { return name }
            return "\(name), \(region)"
        }
    }

    public static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Прогноз: часы и дни, с прошлой недели по следующую, восход и закат.
    public static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(rounded(latitude))),
            URLQueryItem(name: "longitude", value: String(rounded(longitude))),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "past_days", value: "7"),
            URLQueryItem(name: "forecast_days", value: "8"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components?.url
    }

    /// Поиск города по названию — только название уходит наружу.
    public static func searchURL(_ name: String, language: String) -> URL? {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return nil }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: String(query.prefix(100))),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: String(language.prefix(2))),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// Потолок ответа: прогноз на две недели по часам — десятки килобайт.
    public static let maxResponse = 2 * 1024 * 1024

    public static func places(from data: Data) -> [Place] {
        guard data.count <= maxResponse,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        return results.prefix(8).compactMap { item in
            guard let name = item["name"] as? String,
                  let latitude = (item["latitude"] as? NSNumber)?.doubleValue,
                  let longitude = (item["longitude"] as? NSNumber)?.doubleValue,
                  abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
            return Place(name: String(name.prefix(100)), region: (item["admin1"] as? String).map { String($0.prefix(100)) },
                         country: (item["country"] as? String).map { String($0.prefix(100)) },
                         latitude: latitude, longitude: longitude)
        }
    }

    /// Ответ прогноза — в файл того же вида, что пишет Trunook
    /// (`WeekWeather.decode`). Часы у Open-Meteo местные и без пояса
    /// («2026-09-25T09:00»), смещение приходит отдельно — в файл они идут
    /// абсолютным временем.
    public static func export(from data: Data, now: Date, place: String?) -> Data? {
        guard data.count <= maxResponse,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let hourTimes = hourly["time"] as? [String],
              let dayTimes = daily["time"] as? [String] else { return nil }
        let offset = (root["utc_offset_seconds"] as? NSNumber)?.doubleValue ?? 0
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(secondsFromGMT: 0)
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let iso = ISO8601DateFormatter()

        func numbers(_ block: [String: Any], _ key: String) -> [Double?] {
            ((block[key] as? [Any]) ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        func absolute(_ raw: String) -> String? {
            local.date(from: raw).map { iso.string(from: $0.addingTimeInterval(-offset)) }
        }
        let temperatures = numbers(hourly, "temperature_2m")
        let codes = numbers(hourly, "weather_code")
        let chances = numbers(hourly, "precipitation_probability")
        var hours: [[String: Any]] = []
        for (index, raw) in hourTimes.prefix(24 * 40).enumerated() {
            guard let time = absolute(raw),
                  index < temperatures.count, let temperature = temperatures[index],
                  index < codes.count, let code = codes[index] else { continue }
            hours.append(["time": time, "temp": (temperature * 10).rounded() / 10, "code": Int(code),
                          "precip": Int((index < chances.count ? chances[index] : nil) ?? 0)])
        }
        let dayCodes = numbers(daily, "weather_code")
        let maxima = numbers(daily, "temperature_2m_max")
        let minima = numbers(daily, "temperature_2m_min")
        let dayChances = numbers(daily, "precipitation_probability_max")
        let sunrises = (daily["sunrise"] as? [Any]) ?? []
        let sunsets = (daily["sunset"] as? [Any]) ?? []
        var days: [[String: Any]] = []
        for (index, date) in dayTimes.prefix(40).enumerated() {
            guard date.count == 10, index < dayCodes.count, let code = dayCodes[index],
                  index < maxima.count, let max = maxima[index],
                  index < minima.count, let min = minima[index] else { continue }
            var day: [String: Any] = ["date": date, "code": Int(code), "max": max, "min": min,
                                      "precip": Int((index < dayChances.count ? dayChances[index] : nil) ?? 0)]
            if index < sunrises.count, let raw = sunrises[index] as? String, let time = absolute(raw) { day["sunrise"] = time }
            if index < sunsets.count, let raw = sunsets[index] as? String, let time = absolute(raw) { day["sunset"] = time }
            days.append(day)
        }
        guard !days.isEmpty || !hours.isEmpty else { return nil }
        var json: [String: Any] = ["version": 1, "updated": iso.string(from: now), "days": days, "hours": hours]
        if let place { json["place"] = String(place.prefix(200)) }
        return try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}
