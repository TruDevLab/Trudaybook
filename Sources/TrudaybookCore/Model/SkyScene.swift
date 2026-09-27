import Foundation

/// Тема «Небо»: что сейчас за окном — время суток и погода.
///
/// Чистая часть: из «сейчас», восхода с закатом и кода погоды WMO — цвета
/// неба, где солнце и луна, сколько облаков, идёт ли дождь или снег и
/// светлым или тёмным быть окну. Рисует это приложение (`SkyBackground`).
public struct SkyScene: Equatable, Sendable {
    public enum Weather: String, CaseIterable, Sendable {
        case clear, partlyCloudy, overcast, fog, drizzle, rain, snow, thunder
    }

    /// Точка на небе: `x` — слева направо, `y` — сверху вниз, доли окна.
    public struct Spot: Equatable, Sendable {
        public var x: Double
        public var y: Double
    }

    public var weather: Weather
    /// Сила осадков, 0…1.
    public var intensity: Double
    /// 0 — ночь, 1 — день; между ними — сумерки.
    public var daylight: Double
    /// Насколько сейчас рассвет или закат, 0…1: тёплое у горизонта.
    public var twilight: Double
    /// Облачность, 0…1.
    public var cloudCover: Double
    public var sun: Spot?
    public var moon: Spot?
    /// Фаза луны: 0 — новолуние, 0,5 — полнолуние.
    public var moonPhase: Double
    public var top: RGB
    public var bottom: RGB
    /// Окно — тёмное: ночь, поздние сумерки или гроза.
    public var isDark: Bool

    /// Звёзды видны ночью и сквозь редкие облака.
    public var starVisibility: Double { max(0, 1 - daylight * 1.6) * max(0, 1 - cloudCover * 1.2) }

    public var hasPrecipitation: Bool { [.drizzle, .rain, .snow, .thunder].contains(weather) }
}

public enum SkyRules {
    /// Погода по коду WMO и сила осадков.
    public static func weather(code: Int?) -> (SkyScene.Weather, Double) {
        switch code {
        case 0?: return (.clear, 0)
        case 1?, 2?: return (.partlyCloudy, 0)
        case 3?: return (.overcast, 0)
        case 45?, 48?: return (.fog, 0)
        case 51?, 56?: return (.drizzle, 0.3)
        case 53?, 55?, 57?: return (.drizzle, 0.5)
        case 61?, 66?, 80?: return (.rain, 0.4)
        case 63?, 81?: return (.rain, 0.7)
        case 65?, 67?, 82?: return (.rain, 1)
        case 71?, 77?, 85?: return (.snow, 0.4)
        case 73?: return (.snow, 0.7)
        case 75?, 86?: return (.snow, 1)
        case 95?: return (.thunder, 0.8)
        case 96?, 99?: return (.thunder, 1)
        case nil: return (.clear, 0)
        default: return (.overcast, 0)
        }
    }

    /// Код WMO для погоды, заданной руками (снимки, `--sky-weather`).
    public static func code(for weather: SkyScene.Weather) -> Int {
        switch weather {
        case .clear: 0
        case .partlyCloudy: 2
        case .overcast: 3
        case .fog: 45
        case .drizzle: 53
        case .rain: 63
        case .snow: 73
        case .thunder: 95
        }
    }

    static func cloudCover(_ weather: SkyScene.Weather, code: Int?) -> Double {
        switch weather {
        case .clear: 0
        case .partlyCloudy: code == 1 ? 0.2 : 0.4
        case .overcast: 0.85
        case .fog: 0.7
        case .drizzle: 0.75
        case .rain: 0.9
        case .snow: 0.85
        case .thunder: 1
        }
    }

    /// Восход и закат без прогноза Trunook — по времени года для средних
    /// широт северного полушария: длина дня 8–16 часов, полдень в 12:30.
    /// Грубо, но ночь остаётся ночью, а день — днём.
    public static func approximateSun(on day: Date, calendar: Calendar) -> (sunrise: Date, sunset: Date) {
        let start = calendar.startOfDay(for: day)
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: day) ?? 172)
        let length = 12 + 4 * sin(2 * .pi * (dayOfYear - 80) / 365)
        let noon = 12.5
        return (start.addingTimeInterval((noon - length / 2) * 3600), start.addingTimeInterval((noon + length / 2) * 3600))
    }

    /// Фаза луны по среднему синодическому месяцу от новолуния 6 января 2000.
    public static func moonPhase(at date: Date) -> Double {
        let synodic = 29.530588853 * 86_400
        let reference = Date(timeIntervalSince1970: 947_182_440)
        let age = date.timeIntervalSince(reference).truncatingRemainder(dividingBy: synodic)
        return (age < 0 ? age + synodic : age) / synodic
    }

    /// Сцена на момент `now`. Восход и закат — сегодняшние (из прогноза или
    /// приблизительные); `code` — погода этого часа. Вчерашний закат и
    /// завтрашний восход — для пути луны; нет их — сутки назад и вперёд.
    public static func scene(now: Date, sunrise: Date, sunset: Date, code: Int?,
                             previousSunset: Date? = nil, nextSunrise: Date? = nil) -> SkyScene {
        let (weather, intensity) = weather(code: code)
        let cover = cloudCover(weather, code: code)

        // Сумерки — по 40 минут в обе стороны от восхода и заката.
        let window: TimeInterval = 40 * 60
        func smooth(_ value: Double) -> Double {
            let t = min(max(value, 0), 1)
            return t * t * (3 - 2 * t)
        }
        let morning = smooth((now.timeIntervalSince(sunrise) + window) / (2 * window))
        let evening = 1 - smooth((now.timeIntervalSince(sunset) + window) / (2 * window))
        let daylight = min(morning, evening)
        func bump(_ center: Date) -> Double { max(0, 1 - abs(now.timeIntervalSince(center)) / (70 * 60)) }
        let twilight = max(bump(sunrise), bump(sunset))
        let isMorning = abs(now.timeIntervalSince(sunrise)) < abs(now.timeIntervalSince(sunset))

        // Солнце идёт дугой от восхода к закату, чуть заходя за край.
        var sun: SkyScene.Spot?
        let dayLength = sunset.timeIntervalSince(sunrise)
        if dayLength > 0 {
            let progress = now.timeIntervalSince(sunrise) / dayLength
            if progress > -0.04, progress < 1.04 { sun = arc(progress) }
        }
        // Луна — ночью, от заката до восхода.
        var moon: SkyScene.Spot?
        let nightStart = now < sunrise ? (previousSunset ?? sunset.addingTimeInterval(-86_400)) : sunset
        let nightEnd = now < sunrise ? sunrise : (nextSunrise ?? sunrise.addingTimeInterval(86_400))
        let nightLength = nightEnd.timeIntervalSince(nightStart)
        if nightLength > 0 {
            let progress = now.timeIntervalSince(nightStart) / nightLength
            if progress > 0.02, progress < 0.98 { moon = arc(progress) }
        }

        let (top, bottom) = colors(daylight: daylight, twilight: twilight, morning: isMorning,
                                   weather: weather, cover: cover)
        let middle = mix(top, bottom, 0.55)
        return SkyScene(weather: weather, intensity: intensity, daylight: daylight, twilight: twilight,
                        cloudCover: cover, sun: sun, moon: moon, moonPhase: moonPhase(at: now),
                        top: top, bottom: bottom, isDark: brightness(middle) < 0.4)
    }

    /// Дуга по небу: низко у краёв, выше всего посередине.
    static func arc(_ progress: Double) -> SkyScene.Spot {
        let height = sin(min(max(progress, 0), 1) * .pi)
        return SkyScene.Spot(x: 0.1 + 0.8 * progress, y: 0.8 - 0.62 * height)
    }

    // MARK: - Цвета

    static let nightTop = hex("#0A1030"), nightBottom = hex("#1D2750")
    static let dayTop = hex("#5FA6EC"), dayBottom = hex("#CFE7FB")
    static let dawnTop = hex("#6474B0"), dawnBottom = hex("#F6BE92")
    static let duskTop = hex("#3B3F75"), duskBottom = hex("#EE966C")
    static let grayDayTop = hex("#7F8B9C"), grayDayBottom = hex("#C4CBD5")
    static let grayNightTop = hex("#12161E"), grayNightBottom = hex("#232A35")
    static let snowDayTop = hex("#98A5B7"), snowDayBottom = hex("#D0D7E1")
    static let fogDayTop = hex("#B6BBC3"), fogDayBottom = hex("#DEE1E5")
    static let stormDayTop = hex("#4E5663"), stormDayBottom = hex("#7C8592")

    static func colors(daylight: Double, twilight: Double, morning: Bool,
                       weather: SkyScene.Weather, cover: Double) -> (RGB, RGB) {
        var top = mix(nightTop, dayTop, daylight)
        var bottom = mix(nightBottom, dayBottom, daylight)
        // Тёплое у горизонта — только когда облака его не закрыли.
        let warm = twilight * 0.85 * (1 - cover * 0.8)
        top = mix(top, morning ? dawnTop : duskTop, warm * 0.7)
        bottom = mix(bottom, morning ? dawnBottom : duskBottom, warm)

        let (grayTop, grayBottom): (RGB, RGB) = switch weather {
        case .snow: (snowDayTop, snowDayBottom)
        case .fog: (fogDayTop, fogDayBottom)
        case .thunder: (stormDayTop, stormDayBottom)
        default: (grayDayTop, grayDayBottom)
        }
        let cloudyTop = mix(grayNightTop, grayTop, daylight)
        let cloudyBottom = mix(grayNightBottom, grayBottom, daylight)
        top = mix(top, cloudyTop, cover * 0.9)
        bottom = mix(bottom, cloudyBottom, cover * 0.9)
        return (top, bottom)
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        return RGB(a.red + (b.red - a.red) * k, a.green + (b.green - a.green) * k, a.blue + (b.blue - a.blue) * k)
    }

    /// Относительная яркость (WCAG), 0 — чёрный, 1 — белый.
    static func brightness(_ color: RGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    /// Цвет из «#RRGGBB» своих таблиц.
    private static func hex(_ value: String) -> RGB {
        let number = Int(value.dropFirst(), radix: 16) ?? 0
        return RGB(Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }
}
