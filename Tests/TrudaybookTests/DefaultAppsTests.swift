import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Почта и календарь по умолчанию, погода без Trunook")
struct DefaultAppsTests {
    @Test("mailto: адреса, тема, текст; скрытая копия отдельно, чужие заголовки — мимо")
    func ссылка() throws {
        let url = try #require(URL(string: "mailto:anna@example.test,bob@example.test?cc=c@example.test&bcc=secret@example.test&subject=%D0%9E%D1%82%D1%87%D1%91%D1%82%0A2&body=%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82%0D%0A1+1&In-Reply-To=%3Cx%40y%3E&from=evil@example.test"))
        let link = try #require(MailtoLink.parse(url))
        #expect(link.to.compactMap(\.address) == ["anna@example.test", "bob@example.test"])
        #expect(link.cc.compactMap(\.address) == ["c@example.test"])
        #expect(link.bcc.compactMap(\.address) == ["secret@example.test"])
        #expect(link.subject == "Отчёт 2")
        // «+» в mailto — плюс, перевод строки — один.
        #expect(link.body == "Привет\n1+1")
        #expect(MailtoLink.parse(try #require(URL(string: "https://example.test"))) == nil)
        #expect(MailtoLink.parse(try #require(URL(string: "mailto:?subject=x")))?.to == [])
    }

    @Test("Файл .ics — черновик встречи без участников, организатор строкой")
    func файлКалендаря() throws {
        let ics = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:1
        DTSTART:20260928T070000Z
        DTEND:20260928T080000Z
        SUMMARY:Обзор плана
        LOCATION:Переговорная 3
        DESCRIPTION:Повестка во вложении
        ORGANIZER;CN=Ольга:mailto:olga@example.test
        ATTENDEE;CN=Андрей:mailto:a@example.test
        END:VEVENT
        END:VCALENDAR
        """
        let draft = try #require(CalendarFile.draft(fromICS: ics, calendarID: "work"))
        #expect(draft.title == "Обзор плана")
        #expect(draft.location == "Переговорная 3")
        #expect(draft.end.timeIntervalSince(draft.start) == 3600)
        #expect(draft.attendees.isEmpty)
        #expect(draft.calendarID == "work")
        #expect(draft.notes.contains("Повестка во вложении"))
        #expect(draft.notes.contains("olga@example.test"))
        #expect(CalendarFile.draft(fromICS: "не календарь", calendarID: nil) == nil)
    }

    @Test("Open-Meteo: координаты округляются до десятой, ответ — в формат Trunook")
    func погода() throws {
        let url = try #require(OpenMeteo.forecastURL(latitude: 55.75583, longitude: 37.61731))
        #expect(url.absoluteString.contains("latitude=55.8"))
        #expect(url.absoluteString.contains("longitude=37.6"))
        #expect(url.absoluteString.contains("sunrise"))
        let answer = """
        {"utc_offset_seconds":10800,
         "hourly":{"time":["2026-09-25T09:00","2026-09-25T10:00"],"temperature_2m":[10.44,null],
                   "weather_code":[61,3],"precipitation_probability":[70,10]},
         "daily":{"time":["2026-09-25"],"weather_code":[61],"temperature_2m_max":[14.2],
                  "temperature_2m_min":[8.1],"precipitation_probability_max":[80],
                  "sunrise":["2026-09-25T06:44"],"sunset":["2026-09-25T18:43"]}}
        """
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let data = try #require(OpenMeteo.export(from: Data(answer.utf8), now: now, place: "Москва"))
        let weather = try #require(WeekWeather.decode(data))
        #expect(weather.place == "Москва")
        // Час без температуры пропущен; 09:00 по Москве — 06:00 UTC.
        #expect(weather.hours.count == 1)
        #expect(weather.hours.first?.time == ISO8601DateFormatter().date(from: "2026-09-25T06:00:00Z"))
        #expect(weather.days.first?.sunrise == ISO8601DateFormatter().date(from: "2026-09-25T03:44:00Z"))
        #expect(OpenMeteo.export(from: Data("{}".utf8), now: now, place: nil) == nil)
    }

    @Test("Поиск города: только название, результаты с координатами")
    func город() throws {
        #expect(OpenMeteo.searchURL("М", language: "ru") == nil)
        let url = try #require(OpenMeteo.searchURL("Химки", language: "ru"))
        #expect(url.host == "geocoding-api.open-meteo.com")
        let answer = """
        {"results":[{"name":"Химки","admin1":"Московская область","country":"Россия","latitude":55.89,"longitude":37.44},
                    {"name":"Без координат"},{"name":"Мимо","latitude":123,"longitude":0}]}
        """
        let places = OpenMeteo.places(from: Data(answer.utf8))
        #expect(places.map(\.title) == ["Химки, Московская область"])
    }
}
