import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Приоритеты")
struct PriorityTests {
    private func mail(_ id: String, sender: Priority? = nil) -> TimelineItem {
        TimelineItem(id: id, title: id, time: Date(timeIntervalSince1970: 0),
                     detail: .mail(MailInfo(accountID: "A", from: Person(name: "X", address: "x@test"),
                                            senderPriority: sender)))
    }

    @Test func importanceFromHeaders() {
        #expect(Priority.fromHeaders(importance: "High", xPriority: nil) == .high)
        #expect(Priority.fromHeaders(importance: "low", xPriority: nil) == .low)
        #expect(Priority.fromHeaders(importance: "Normal", xPriority: "3 (Normal)") == nil)
        #expect(Priority.fromHeaders(importance: nil, xPriority: "1 (Highest)") == .high)
        #expect(Priority.fromHeaders(importance: nil, xPriority: "5") == .low)
        #expect(Priority.fromHeaders(importance: nil, xPriority: nil, priority: "urgent") == .high)
        #expect(Priority.fromHeaders(importance: nil, xPriority: nil) == nil)
    }

    @Test func parsedMessageReadsImportance() {
        let outlook = ParsedMessage(headerData: Data("Subject: Срочно\r\nImportance: high\r\n\r\n".utf8))
        #expect(outlook.priority == .high)
        let thunderbird = ParsedMessage(headerData: Data("Subject: Потом\r\nX-Priority: 5 (Lowest)\r\n\r\n".utf8))
        #expect(thunderbird.priority == .low)
        let plain = ParsedMessage(headerData: Data("Subject: Обычное\r\n\r\n".utf8))
        #expect(plain.priority == nil)
    }

    @Test func sortKeepsOrderInsideLevel() {
        let items = ["a", "b", "c", "d", "e"].map { mail($0) }
        let chosen: [String: Priority] = ["b": .low, "c": .high, "e": .high, "d": .medium]
        let sorted = PrioritySort.sorted(items) { chosen[$0.id] ?? .none }
        #expect(sorted.map(\.id) == ["c", "e", "d", "b", "a"])
    }

    @Test func storeKeepsChoiceAndForgetsIt() throws {
        let store = try ItemStateStore.inMemory()
        try store.setPriority(.high, for: "m1")
        try store.setPriority(Priority.none, for: "m2")
        #expect(store.allPriorities() == ["m1": .high, "m2": Priority.none])
        try store.setPriority(.low, for: "m1")
        try store.setPriority(nil, for: "m2")
        #expect(store.allPriorities() == ["m1": .low])
    }
}

@Suite("Заметки на день")
struct DayNoteTests {
    @Test func keyIsLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        // 2026-09-23 23:30 МСК = 20:30 UTC — день всё ещё 23-е.
        let late = Date(timeIntervalSince1970: 1_790_195_400)
        #expect(ItemStateStore.dayKey(late, calendar: calendar) == "2026-09-23")
    }

    @Test func noteSavedReplacedAndClearedByBlank() throws {
        let store = try ItemStateStore.inMemory()
        try store.setNote("Позвонить юристам", for: "2026-09-24")
        #expect(store.note(for: "2026-09-24") == "Позвонить юристам")
        #expect(store.daysWithNotes() == ["2026-09-24"])
        try store.setNote("Позвонить юристам до 12", for: "2026-09-24")
        #expect(store.note(for: "2026-09-24") == "Позвонить юристам до 12")
        try store.setNote("  \n ", for: "2026-09-24")
        #expect(store.note(for: "2026-09-24") == "")
        #expect(store.daysWithNotes().isEmpty)
    }
}
