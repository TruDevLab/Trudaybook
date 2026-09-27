import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Тема «Небо»")
struct SkyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func scene(_ time: String, code: Int?) -> SkyScene {
        SkyRules.scene(now: date("2026-09-27 \(time)"), sunrise: date("2026-09-27 06:50"),
                       sunset: date("2026-09-27 18:40"), code: code)
    }

    @Test("Ночь тёмная, с луной и звёздами; день светлый, с солнцем")
    func деньИНочь() {
        let night = scene("23:30", code: 0)
        #expect(night.isDark)
        #expect(night.daylight == 0)
        #expect(night.sun == nil)
        #expect(night.moon != nil)
        #expect(night.starVisibility > 0.9)

        let noon = scene("12:45", code: 0)
        #expect(!noon.isDark)
        #expect(noon.daylight == 1)
        #expect(noon.moon == nil)
        let sun = try? #require(noon.sun)
        // В полдень солнце выше всего и посередине.
        #expect(abs((sun?.x ?? 0) - 0.5) < 0.02)
        #expect((sun?.y ?? 1) < 0.2)
        #expect(noon.starVisibility == 0)
    }

    @Test("На закате — сумерки: тёплый горизонт, солнце у края")
    func закат() {
        let dusk = scene("18:40", code: 0)
        #expect(dusk.twilight == 1)
        #expect(dusk.daylight > 0.3 && dusk.daylight < 0.7)
        #expect((dusk.sun?.y ?? 0) > 0.75)
        // У горизонта теплее, чем наверху.
        #expect(dusk.bottom.red > dusk.bottom.blue)
    }

    @Test("Погода по коду WMO: дождь, снег, гроза, туман")
    func погода() {
        #expect(SkyRules.weather(code: 63).0 == .rain)
        #expect(SkyRules.weather(code: 75) == (.snow, 1))
        #expect(SkyRules.weather(code: 95).0 == .thunder)
        #expect(SkyRules.weather(code: 45).0 == .fog)
        #expect(SkyRules.weather(code: nil).0 == .clear)
        for weather in SkyScene.Weather.allCases {
            #expect(SkyRules.weather(code: SkyRules.code(for: weather)).0 == weather)
        }
        let rain = scene("12:45", code: 65)
        #expect(rain.hasPrecipitation)
        #expect(rain.cloudCover > 0.8)
        // Днём в дождь окно светлое, в грозу — тёмное.
        #expect(!rain.isDark)
        #expect(scene("12:45", code: 99).isDark)
        // Сквозь тучи звёзд не видно.
        #expect(scene("23:30", code: 63).starVisibility == 0)
    }

    @Test("Без прогноза: день длиннее летом, чем зимой")
    func безПрогноза() {
        let summer = SkyRules.approximateSun(on: date("2026-06-21 12:00"), calendar: calendar)
        let winter = SkyRules.approximateSun(on: date("2026-12-21 12:00"), calendar: calendar)
        #expect(summer.sunset.timeIntervalSince(summer.sunrise) > 15 * 3600)
        #expect(winter.sunset.timeIntervalSince(winter.sunrise) < 9 * 3600)
    }

    @Test("Фаза луны: полнолуние 25 января 2024")
    func луна() {
        // Полнолуние по астрономическим таблицам — 25 января 2024, 17:54 UTC.
        let full = SkyRules.moonPhase(at: Date(timeIntervalSince1970: 1_706_205_240))
        #expect(abs(full - 0.5) < 0.04)
    }

    @Test("Восход и закат читаются из прогноза Trunook, погода — по часу")
    func прогноз() throws {
        let json = """
        {"version":1,"updated":"2026-09-27T09:00:00Z","days":[{"date":"2026-09-27","code":3,"max":14,"min":6,
         "precip":10,"sunrise":"2026-09-27T03:50:00Z","sunset":"2026-09-27T15:40:00Z"}],
         "hours":[{"time":"2026-09-27T09:00:00Z","temp":12,"code":61,"precip":60}]}
        """
        let weather = try #require(WeekWeather.decode(Data(json.utf8)))
        let day = try #require(weather.days.first)
        #expect(day.sunrise == ISO8601DateFormatter().date(from: "2026-09-27T03:50:00Z"))
        #expect(weather.code(at: try #require(ISO8601DateFormatter().date(from: "2026-09-27T09:30:00Z")), calendar: calendar) == 61)
        // Часа нет — погода дня.
        #expect(weather.code(at: try #require(ISO8601DateFormatter().date(from: "2026-09-27T13:30:00Z")), calendar: calendar) == 3)
    }
}
