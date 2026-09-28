import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Сводка для виджетов")
struct WidgetTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, in minutes: Double, length: Double = 30, declined: Bool = false) -> TimelineItem {
        let me = Attendee(person: Person(name: "Я", address: "me@x"), response: declined ? .declined : .accepted, isMe: true)
        return TimelineItem(id: id, title: "Встреча \(id)", time: now.addingTimeInterval(minutes * 60),
                            end: now.addingTimeInterval((minutes + length) * 60), color: RGB(0.2, 0.4, 0.8),
                            detail: .event(EventInfo(calendarTitle: "Работа", organizer: Person(name: "О", address: "o@x"),
                                                     attendees: [me])))
    }

    private func letter(_ id: String, bulk: Bool = false) -> TimelineItem {
        TimelineItem(id: id, title: "Тема \(id)", time: now,
                     detail: .mail(MailInfo(accountID: "a", from: Person(name: "Анна", address: "a@x"), isBulk: bulk)))
    }

    @Test("Отклонённые встречи не попадают; важные письма — первыми; темы по настройке")
    func сводка() throws {
        let snapshot = WidgetSnapshot.make(
            now: now, calendarItems: [event("b", in: 90), event("a", in: 30), event("x", in: 60, declined: true)],
            unresolved: [letter("m1"), letter("m2"), letter("m3")], isImportant: { $0.id == "m3" },
            showSubjects: false, weather: nil)
        #expect(snapshot.events.map(\.id) == ["a", "b"])
        #expect(snapshot.events.first?.color == "#3366CC")
        #expect(snapshot.unresolved == 3)
        #expect(snapshot.important == 1)
        #expect(snapshot.letters.first?.id == "m3")
        #expect(snapshot.letters.allSatisfy { $0.subject == nil })

        let data = try #require(snapshot.encoded())
        #expect(WidgetSnapshot.decode(data) == snapshot)
        #expect(WidgetSnapshot.decode(Data("{}".utf8)) == nil)
    }

    @Test("Ближайшие встречи и моменты перерисовки")
    func таймлайн() {
        let snapshot = WidgetSnapshot.make(now: now, calendarItems: [event("a", in: -10, length: 30), event("b", in: 60)],
                                           unresolved: [], isImportant: { _ in false }, showSubjects: true, weather: nil)
        // Идущая встреча ещё в списке, прошедшие — нет.
        #expect(snapshot.upcoming(at: now).map(\.id) == ["a", "b"])
        #expect(snapshot.upcoming(at: now.addingTimeInterval(25 * 60)).map(\.id) == ["b"])
        // Следующая перерисовка — конец идущей встречи.
        #expect(snapshot.nextChange(after: now) == now.addingTimeInterval(20 * 60))
    }

    @Test("Папка сводки — в настоящем домашнем каталоге, не в контейнере")
    func папка() {
        #expect(WidgetSnapshot.folder.path.hasSuffix("Library/Application Support/Trudaybook/widget"))
        #expect(!WidgetSnapshot.folder.path.contains("/Containers/"))
    }
}
