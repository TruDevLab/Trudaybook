import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Несколько ящиков")
struct CombinedMailTests {
    /// Будний день, вечер: писем за день много в обоих ящиках.
    private static let now = Date(timeIntervalSince1970: 1_790_182_800) // 2026-09-23 20:00 МСК
    private let clock: @Sendable () -> Date = { CombinedMailTests.now }
    private let work = Person(name: "Я", address: "me@company.test")
    private let home = Person(name: "Я", address: "me@icloud.test")

    private func boxes() -> (CombinedMailProvider, DemoMailProvider, DemoMailProvider) {
        let first = DemoMailProvider(clock: clock, accountID: "A", me: work)
        let second = DemoMailProvider(clock: clock, accountID: "B", me: home, variant: 1)
        let combined = CombinedMailProvider([
            .init(accountID: "A", name: "me@company.test", provider: first),
            .init(accountID: "B", name: "me@icloud.test", provider: second),
        ])
        return (combined, first, second)
    }

    private var today: (Date, Date) {
        let start = Calendar.current.startOfDay(for: Self.now)
        return (start, start.addingTimeInterval(86_400))
    }

    @Test func timelineHasMailOfBothBoxes() async throws {
        let (combined, first, second) = boxes()
        let all = try await combined.messages(from: today.0, to: today.1)
        let a = try await first.messages(from: today.0, to: today.1)
        let b = try await second.messages(from: today.0, to: today.1)
        #expect(!a.isEmpty && !b.isEmpty)
        #expect(all.count == a.count + b.count)
        #expect(Set(all.compactMap { $0.mail?.accountID }) == ["A", "B"])
        #expect(combined.ownAddresses == ["me@company.test", "me@icloud.test"])
        #expect(combined.displayName == "2 ящика")
    }

    @Test func archiveGoesToTheLettersBox() async throws {
        let (combined, first, second) = boxes()
        let letter = try #require(try await second.messages(from: today.0, to: today.1).first)
        let before = try await first.messages(from: today.0, to: today.1).count
        try await combined.archive(letter.id)
        // Письмо ушло в архив своего ящика, но на таймлайне дня остаётся — разобранным.
        let archived = try await second.messages(from: today.0, to: today.1).first { $0.id == letter.id }
        #expect(archived?.mail?.movedAway == true)
        #expect(try await first.messages(from: today.0, to: today.1).count == before)
        await #expect(throws: CombinedMailProvider.Failure.unknownAccount) {
            try await combined.archive("mail:Z:1:INBOX")
        }
    }

    @Test func replyLeavesFromTheLettersBoxUnlessChosen() async throws {
        let (combined, first, second) = boxes()
        let letter = try #require(try await second.messages(from: today.0, to: today.1).first)
        // Тема своя: в тестовых «Отправленных» уже лежат ответы на похожие письма.
        let reply = OutgoingMail(to: [letter.mail!.from], subject: "Re: с домашнего", text: "Да")

        try await combined.send(reply, replyingTo: letter.id)
        #expect(await second.messages(inFolder: "Sent", limit: 50).contains { $0.title == reply.subject })
        #expect(await first.messages(inFolder: "Sent", limit: 50).contains { $0.title == reply.subject } == false)

        // Выбран другой ящик: письмо уходит с него.
        var fromWork = reply
        fromWork.subject = "Re: с рабочего"
        fromWork.accountID = "A"
        try await combined.send(fromWork, replyingTo: letter.id)
        #expect(await first.messages(inFolder: "Sent", limit: 50).contains { $0.title == "Re: с рабочего" })
    }

    @Test func foldersSharedFirstThenPerBox() async throws {
        let (combined, _, _) = boxes()
        let folders = try await combined.folders()
        #expect(folders.prefix(3).map(\.id) == ["all:inbox", "all:sent", "all:archive"])
        #expect(folders.prefix(3).allSatisfy { $0.accountName == nil })
        let own = folders.dropFirst(3)
        #expect(own.first?.id == "A:INBOX")
        #expect(own.contains { $0.id == "B:Work/Projects" && $0.accountName == "me@icloud.test" })

        let inboxes = try await combined.messages(inFolder: "all:inbox", limit: 1000)
        #expect(Set(inboxes.compactMap { $0.mail?.accountID }) == ["A", "B"])
        #expect(inboxes.map(\.time) == inboxes.map(\.time).sorted(by: >))
        let onlyB = try await combined.messages(inFolder: "B:INBOX", limit: 1000)
        #expect(!onlyB.isEmpty && onlyB.allSatisfy { $0.mail?.accountID == "B" })
    }

    @Test func singleBoxHasNoSharedFolders() async throws {
        let only = CombinedMailProvider([
            .init(accountID: "A", name: "me@company.test", provider: DemoMailProvider(clock: clock, accountID: "A")),
        ])
        let folders = try await only.folders()
        #expect(folders.first?.id == "A:INBOX")
        #expect(folders.allSatisfy { $0.accountName == nil })
        #expect(only.displayName == "me@company.test")
    }

    @Test func brokenBoxDoesNotHideTheOthers() async throws {
        let working = DemoMailProvider(clock: clock, accountID: "A")
        let combined = CombinedMailProvider([
            .init(accountID: "A", name: "a", provider: working),
            .init(accountID: "B", name: "b", provider: BrokenMailProvider()),
        ])
        #expect(!(try await combined.messages(from: today.0, to: today.1)).isEmpty)
        #expect(!(try await combined.folders()).isEmpty)

        let allBroken = CombinedMailProvider([.init(accountID: "B", name: "b", provider: BrokenMailProvider())])
        await #expect(throws: BrokenMailProvider.Offline.self) {
            try await allBroken.messages(from: today.0, to: today.1)
        }
    }

    @Test func identifiersAndWords() {
        #expect(MailItemID.account(of: "mail:A-1:42:Work:Projects") == "A-1")
        #expect(MailItemID.account(of: "event:123") == nil)
        #expect(CombinedMailProvider.parseFolder("A-1:Work:Projects")?.folder == "Work:Projects")
        #expect(CombinedMailProvider.boxesTitle(1) == "1 ящик")
        #expect(CombinedMailProvider.boxesTitle(3) == "3 ящика")
        #expect(CombinedMailProvider.boxesTitle(5) == "5 ящиков")
        #expect(CombinedMailProvider.boxesTitle(12) == "12 ящиков")
        #expect(CombinedMailProvider.boxesTitle(22) == "22 ящика")
    }
}

/// Ящик без связи: всё кончается ошибкой.
private final class BrokenMailProvider: MailProvider {
    struct Offline: Error {}

    let displayName = "b"
    let ownAddresses: Set<String> = []

    func messages(from: Date, to: Date) async throws -> [TimelineItem] { throw Offline() }
    func body(of itemID: String) async throws -> MailBody { throw Offline() }
    func archive(_ itemID: String) async throws { throw Offline() }
    func send(_ mail: OutgoingMail, replyingTo itemID: String?) async throws { throw Offline() }
    func folders() async throws -> [MailFolder] { throw Offline() }
    func messages(inFolder folderID: String, limit: Int) async throws -> [TimelineItem] { throw Offline() }
    func search(_ text: String, inFolder folderID: String?, fullText: Bool) async throws -> [TimelineItem] { throw Offline() }
    func refresh() async throws { throw Offline() }
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
}
