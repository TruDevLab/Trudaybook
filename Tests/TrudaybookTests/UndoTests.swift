import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Отмена переноса")
struct UndoTests {
    @Test func retimedEventKitAndDemoIDs() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(TimelineItem.retimedID("event:ABC-123@1789990000", to: start) == "event:ABC-123@1790000000")
        #expect(TimelineItem.retimedID("event:demo-standup@1789990000", to: start) == "event:demo-standup@1790000000")
    }

    @Test func otherIDsStay() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // У Exchange ключ от времени не зависит.
        #expect(TimelineItem.retimedID("event:ews:work:AAMkAD=", to: start) == "event:ews:work:AAMkAD=")
        #expect(TimelineItem.retimedID("reminder:demo-call", to: start) == "reminder:demo-call")
        #expect(TimelineItem.retimedID("mail:box:42", to: start) == "mail:box:42")
        // «@» без числа после него — не время.
        #expect(TimelineItem.retimedID("event:me@example.com", to: start) == "event:me@example.com")
    }
}

@Suite("Сочетания клавиш")
struct KeyComboTests {
    @Test func shiftBecomesCapitalLetter() {
        let combo = KeyCombo("n", [.command, .shift])
        #expect(combo.key == "N")
        #expect(combo.modifiers == .command)
        #expect(combo == KeyCombo("N"))
        // Не буква — ⇧ остаётся в маске.
        #expect(KeyCombo("=", [.command, .shift]).modifiers == [.command, .shift])
    }

    @Test func displayLikeMacMenu() {
        #expect(KeyCombo("n", [.command, .shift]).display == "⇧⌘N")
        #expect(KeyCombo("j", [.command, .option, .control]).display == "⌃⌥⌘J")
        #expect(KeyCombo("-").display == "⌘−")
        #expect(KeyCombo("\r").display == "⌘↩")
        #expect(KeyCombo("\u{1b}", []).display == "Esc")
    }

    @Test func findsDuplicates() {
        let entries: [(combo: KeyCombo, title: String)] = [
            (KeyCombo("t"), "Сегодня"),
            (KeyCombo("t"), "Новый разговор"),
            (KeyCombo("z", [.command, .shift]), "Повторить"),
            (KeyCombo("Z"), "Повторить ещё раз"),
            (KeyCombo("n"), "Новое письмо"),
        ]
        let duplicates = KeyCombo.duplicates(entries)
        #expect(duplicates.count == 2)
        #expect(duplicates[KeyCombo("t")] == ["Сегодня", "Новый разговор"])
        #expect(duplicates[KeyCombo("Z")]?.count == 2)
    }
}
