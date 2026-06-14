import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("InMemoryEventStore")
struct InMemoryEventStoreTests {
    private func event(
        id: String,
        start: TimeInterval,
        durationHours: Double = 1
    ) -> Event {
        Event(
            externalID: id,
            title: "Event \(id)",
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start + durationHours * 3600)
        )
    }

    @Test
    func fetchByExternalIDReturnsMatch() throws {
        let e = event(id: "ext-1", start: 1_000_000)
        let store = InMemoryEventStore(events: [e])
        #expect(try store.fetch(externalID: "ext-1") == e)
    }

    @Test
    func fetchByExternalIDReturnsNilWhenAbsent() throws {
        let store = InMemoryEventStore(events: [event(id: "ext-1", start: 1_000_000)])
        #expect(try store.fetch(externalID: "missing") == nil)
    }

    @Test
    func fetchEventsInIntervalReturnsIntersectingEvents() throws {
        let inside = event(id: "inside", start: 1_000_000)
        let overlappingStart = event(id: "overlap-start", start: 999_000, durationHours: 2)
        let overlappingEnd = event(id: "overlap-end", start: 1_003_000, durationHours: 2)
        let store = InMemoryEventStore(events: [inside, overlappingStart, overlappingEnd])

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_005_000)
        )
        let results = try store.fetchEvents(in: interval)
        #expect(Set(results.map(\.externalID)) == ["inside", "overlap-start", "overlap-end"])
    }

    @Test
    func fetchEventsInIntervalExcludesNonIntersectingEvents() throws {
        let before = event(id: "before", start: 0, durationHours: 1)
        let after = event(id: "after", start: 2_000_000, durationHours: 1)
        let inside = event(id: "inside", start: 1_000_000, durationHours: 1)
        let store = InMemoryEventStore(events: [before, after, inside])

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 999_000),
            end: Date(timeIntervalSince1970: 1_005_000)
        )
        let results = try store.fetchEvents(in: interval)
        #expect(results.map(\.externalID) == ["inside"])
    }

    @Test
    func emptyStoreReturnsNoEventsInAnyInterval() throws {
        let store = InMemoryEventStore()
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000_000_000)
        )
        #expect(try store.fetchEvents(in: interval).isEmpty)
    }
}
