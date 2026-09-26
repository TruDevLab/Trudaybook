import Foundation
import Testing
@testable import TrudaybookCore

@Suite struct WeekWeatherTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-25T09:00:00Z")!

    @Test func decodesTrunookFile() throws {
        let json = """
        {"version":1,"updated":"2026-09-25T06:00:00Z","place":"Москва",
         "days":[{"date":"2026-09-25","code":61,"max":14.2,"min":8.1,"precip":80},{"date":"плохо"}],
         "hours":[{"time":"2026-09-25T06:00:00Z","temp":10.4,"code":61,"precip":70},{"time":"не время","temp":1,"code":0}]}
        """
        let weather = try #require(WeekWeather.decode(Data(json.utf8)))
        #expect(weather.place == "Москва")
        #expect(weather.days.count == 1)
        #expect(weather.hours.count == 1)
        #expect(weather.isFresh(at: now))
        #expect(!weather.isFresh(at: now.addingTimeInterval(2 * 86_400)))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(weather.day(now, calendar: utc)?.max == 14.2)
        #expect(weather.hours(on: now, calendar: utc).count == 1)
        #expect(WeekWeather.decode(Data(#"{"version":2,"updated":"2026-09-25T06:00:00Z"}"#.utf8)) == nil)
    }

    @Test func symbolsAndDegrees() {
        #expect(WeekWeather.symbol(0) == "sun.max.fill")
        #expect(WeekWeather.symbol(0, night: true) == "moon.stars.fill")
        #expect(WeekWeather.symbol(63) == "cloud.rain.fill")
        #expect(WeekWeather.degrees(-0.4) == "0°")
        #expect(WeekWeather.degrees(14.6) == "15°")
    }

    @Test func myAnswerMarksUnconfirmedMeetings() {
        let me = Person(name: "Я", address: "me@example.com")
        let boss = Person(name: "Шеф", address: "boss@example.com")
        func info(_ response: Attendee.Response, organizer: Person) -> EventInfo {
            EventInfo(calendarTitle: "Работа", organizer: organizer,
                      attendees: [Attendee(person: boss, response: .accepted),
                                  Attendee(person: me, response: response, isMe: true)])
        }
        #expect(info(.pending, organizer: boss).isUnconfirmed)
        #expect(info(.tentative, organizer: boss).isUnconfirmed)
        #expect(!info(.accepted, organizer: boss).isUnconfirmed)
        // Своя встреча (я организатор) подтверждать нечего.
        #expect(info(.pending, organizer: me).myResponse == nil)
        #expect(EventInfo(calendarTitle: "Личное").myResponse == nil)
    }
}
