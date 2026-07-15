import Foundation
import Testing
@testable import GuessWhoSync

@Suite("EventSortOrder")
struct EventSortOrderTests {
    /// Fixed UUIDs so tiebreak assertions are deterministic.
    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let idC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!

    private func event(
        id: UUID,
        start: TimeInterval,
        createdAt: TimeInterval? = nil,
        lastViewedAt: TimeInterval? = nil
    ) -> Event {
        Event(
            id: id,
            title: "",
            startDate: Date(timeIntervalSinceReferenceDate: start),
            endDate: Date(timeIntervalSinceReferenceDate: start + 60),
            createdAt: createdAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            lastViewedAt: lastViewedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    @Test
    func chronologicalSortsByStartDateAscending() {
        let events = [
            event(id: idA, start: 300),
            event(id: idB, start: 100),
            event(id: idC, start: 200),
        ]
        let sorted = EventSortOrder.chronological.sorted(events)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func recentlyAddedSortsNewestFirstWithNilsLast() {
        let events = [
            event(id: idA, start: 100, createdAt: 50),
            event(id: idB, start: 200, createdAt: nil),
            event(id: idC, start: 300, createdAt: 90),
        ]
        let sorted = EventSortOrder.recentlyAdded.sorted(events)
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func lastViewedSortsMostRecentFirstWithNeverViewedLast() {
        let events = [
            event(id: idA, start: 100, lastViewedAt: nil),
            event(id: idB, start: 200, lastViewedAt: 90),
            event(id: idC, start: 300, lastViewedAt: 50),
        ]
        let sorted = EventSortOrder.lastViewed.sorted(events)
        #expect(sorted.map(\.id) == [idB, idC, idA])
    }

    @Test
    func timeOrderTiesFallBackToStartDateThenID() {
        // Same lastViewed stamp → start date decides; same start date too →
        // UUID string decides, so repeat sorts can't shuffle rows.
        let events = [
            event(id: idB, start: 200, lastViewedAt: 70),
            event(id: idC, start: 100, lastViewedAt: 70),
            event(id: idA, start: 200, lastViewedAt: 70),
        ]
        let sorted = EventSortOrder.lastViewed.sorted(events)
        #expect(sorted.map(\.id) == [idC, idA, idB])
    }

    @Test
    func rawValuesAreStable() {
        // Persisted in UserDefaults by the app — renaming a case is a
        // breaking change, so pin the strings.
        #expect(EventSortOrder.chronological.rawValue == "chronological")
        #expect(EventSortOrder.recentlyAdded.rawValue == "recentlyAdded")
        #expect(EventSortOrder.lastViewed.rawValue == "lastViewed")
    }
}
