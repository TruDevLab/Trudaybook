import Foundation
import Testing
@testable import TrudaybookCore

@Suite("Раскладка писем")
struct PointGroupingTests {
    private func group(_ xs: [Double]) -> [PointGroup] {
        TimelineLayout.groupPoints(
            xs.enumerated().map { TimelineLayout.Point(id: "p\($0.offset)", x: $0.element) },
            cardWidth: 20, gap: 4, maxSideBySide: 3, clusterWidth: 40
        )
    }

    @Test func farApartStayInPlace() {
        #expect(group([0, 100, 200]) == [.single(id: "p0", x: 0), .single(id: "p1", x: 100), .single(id: "p2", x: 200)])
    }

    @Test func closeOnesStandSideBySide() {
        #expect(group([0, 5, 10]) == [.single(id: "p0", x: 0), .single(id: "p1", x: 24), .single(id: "p2", x: 48)])
    }

    @Test func tooManyCollapseIntoCluster() {
        let result = group([0, 2, 4, 6, 8])
        #expect(result == [.cluster(ids: ["p0", "p1", "p2", "p3", "p4"], x: 0, width: 40)])
    }

    @Test func clusterDoesNotChainThroughTheDay() {
        // Плотный поток: письмо каждые 10 точек. Пачка фиксированной ширины
        // забирает только соседей, а не весь день.
        let result = group(stride(from: 0.0, through: 600, by: 10).map { $0 })
        #expect(result.count > 5)
        #expect(result.flatMap(\.ids).count == 61)
        #expect(result.allSatisfy { if case .cluster(let ids, _, _) = $0 { return ids.count < 10 } else { return true } })
    }
}

@Suite("Раскладка встреч")
struct IntervalPlacementTests {
    private func place(_ spans: [(Double, Double)]) -> [IntervalPlacement] {
        TimelineLayout.placeIntervals(
            spans.enumerated().map { TimelineLayout.Interval(id: "e\($0.offset)", start: $0.element.0, end: $0.element.1) },
            minWidth: 30
        ).sorted { $0.id < $1.id }
    }

    @Test func separateEventsTakeFullHeight() {
        let result = place([(0, 100), (100, 200)])
        #expect(result.map(\.rows) == [1, 1])
        #expect(result.map(\.row) == [0, 0])
    }

    @Test func overlappingShareRows() {
        let result = place([(0, 100), (50, 150), (300, 400)])
        #expect(result.map(\.row) == [0, 1, 0])
        #expect(result.map(\.rows) == [2, 2, 1])
    }

    @Test func freedRowIsReused() {
        let result = place([(0, 300), (10, 50), (60, 100)])
        #expect(result.map(\.row) == [0, 1, 1])
        #expect(result.map(\.rows) == [2, 2, 2])
    }

    @Test func shortEventGetsMinimumWidthAndPushesNeighbour() {
        // Встреча на 5 точек рисуется шириной 30, и соседка с 10 уже пересекается.
        let result = place([(0, 5), (10, 40)])
        #expect(result[0].width == 30)
        #expect(result.map(\.rows) == [2, 2])
    }
}

@Suite("Хранилище отметок")
struct ItemStateStoreTests {
    @Test func roundTrip() throws {
        let store = try ItemStateStore.inMemory()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try store.update("mail:a:1") { $0.archivedAt = date }
        #expect(store.state(for: "mail:a:1") == LocalState(archivedAt: date))
        #expect(store.allStates().count == 1)
    }

    @Test func emptyStateDeletesRow() throws {
        let store = try ItemStateStore.inMemory()
        try store.update("mail:a:1") { $0.snoozedUntil = Date() }
        try store.update("mail:a:1") { $0.snoozedUntil = nil }
        #expect(store.state(for: "mail:a:1") == nil)
        #expect(store.allStates().isEmpty)
    }

    @Test func cutoffIsFixedOnFirstUse() throws {
        let store = try ItemStateStore.inMemory()
        let first = store.mailCutoff(defaultDays: 7, now: Date(timeIntervalSince1970: 1_790_000_000))
        let later = store.mailCutoff(defaultDays: 7, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(first == later)
    }
}
