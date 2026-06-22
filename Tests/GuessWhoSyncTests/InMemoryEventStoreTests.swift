import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("InMemoryEventStore")
struct InMemoryEventStoreTests {
    private func event(
        eventKitID: String,
        start: TimeInterval,
        durationHours: Double = 1,
        title: String? = nil,
        location: String? = nil
    ) -> Event {
        Event(
            id: UUID(),
            eventKitID: eventKitID,
            title: title ?? "Event \(eventKitID)",
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start + durationHours * 3600),
            isAllDay: false,
            location: location,
            eventKitNotes: nil
        )
    }

    @Test
    func fetchByEventKitIDReturnsMatch() throws {
        let e = event(eventKitID: "ext-1", start: 1_000_000)
        let store = InMemoryEventStore(events: [e])
        #expect(try store.fetch(eventKitID: "ext-1") == e)
    }

    @Test
    func fetchByEventKitIDReturnsNilWhenAbsent() throws {
        let store = InMemoryEventStore(events: [event(eventKitID: "ext-1", start: 1_000_000)])
        #expect(try store.fetch(eventKitID: "missing") == nil)
    }

    @Test
    func fetchEventsInIntervalReturnsIntersectingEvents() throws {
        let inside = event(eventKitID: "inside", start: 1_000_000)
        let overlappingStart = event(eventKitID: "overlap-start", start: 999_000, durationHours: 2)
        let overlappingEnd = event(eventKitID: "overlap-end", start: 1_003_000, durationHours: 2)
        let store = InMemoryEventStore(events: [inside, overlappingStart, overlappingEnd])

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000_000),
            end: Date(timeIntervalSince1970: 1_005_000)
        )
        let results = try store.fetchEvents(in: interval)
        #expect(Set(results.compactMap(\.eventKitID)) == ["inside", "overlap-start", "overlap-end"])
    }

    @Test
    func fetchEventsInIntervalExcludesNonIntersectingEvents() throws {
        let before = event(eventKitID: "before", start: 0, durationHours: 1)
        let after = event(eventKitID: "after", start: 2_000_000, durationHours: 1)
        let inside = event(eventKitID: "inside", start: 1_000_000, durationHours: 1)
        let store = InMemoryEventStore(events: [before, after, inside])

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 999_000),
            end: Date(timeIntervalSince1970: 1_005_000)
        )
        let results = try store.fetchEvents(in: interval)
        #expect(results.compactMap(\.eventKitID) == ["inside"])
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

    // MARK: - fetchEvents(on:)

    @Test
    func fetchEventsOnDayReturnsEventsStartingThatDay() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let todayStartTS = today.timeIntervalSince1970
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: today)!.timeIntervalSince1970
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: today)!.timeIntervalSince1970

        let onDay1 = event(eventKitID: "on-1", start: todayStartTS + 3600)
        let onDay2 = event(eventKitID: "on-2", start: todayStartTS + 7200)
        let before = event(eventKitID: "before", start: dayBefore + 3600)
        let after = event(eventKitID: "after", start: dayAfter + 3600)

        let store = InMemoryEventStore(events: [onDay1, onDay2, before, after])
        let results = try store.fetchEvents(on: today)
        #expect(Set(results.compactMap(\.eventKitID)) == ["on-1", "on-2"])
    }

    @Test
    func fetchEventsOnDayEmptyWhenNoMatches() throws {
        let store = InMemoryEventStore()
        #expect(try store.fetchEvents(on: Date(timeIntervalSince1970: 0)).isEmpty)
    }

    // MARK: - searchEvents(matching:in:)

    @Test
    func searchEventsMatchesTitleSubstringCaseInsensitively() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let dinner = event(eventKitID: "ek-dinner", start: 1_000_000, title: "Dinner with Alice")
        let lunch = event(eventKitID: "ek-lunch", start: 1_001_000, title: "Lunch")
        let store = InMemoryEventStore(events: [dinner, lunch])

        let results = try store.searchEvents(matching: "DINNER", in: interval)
        #expect(results.compactMap(\.eventKitID) == ["ek-dinner"])
    }

    @Test
    func searchEventsMatchesLocationSubstringCaseInsensitively() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000_000_000)
        )
        let park = event(eventKitID: "ek-park", start: 1_000_000, title: "Walk", location: "Apple Park")
        let office = event(eventKitID: "ek-office", start: 1_001_000, title: "Standup", location: "Office")
        let store = InMemoryEventStore(events: [park, office])

        let results = try store.searchEvents(matching: "park", in: interval)
        #expect(results.compactMap(\.eventKitID) == ["ek-park"])
    }

    @Test
    func searchEventsEmptyTextReturnsEverythingInWindow() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 2_000_000)
        )
        let a = event(eventKitID: "a", start: 1_000_000)
        let b = event(eventKitID: "b", start: 1_500_000)
        let store = InMemoryEventStore(events: [a, b])
        let results = try store.searchEvents(matching: "", in: interval)
        #expect(Set(results.compactMap(\.eventKitID)) == ["a", "b"])
    }

    // MARK: - createEvent / updateEvent / removeEvent

    @Test
    func createEventMintsEventKitIDAndStoresEvent() throws {
        let store = InMemoryEventStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_003_600)
        let created = try store.createEvent(
            title: "New",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: "Here"
        )
        let ekid = try #require(created.eventKitID)
        #expect(ekid.hasPrefix("ek-"))
        let fetched = try #require(try store.fetch(eventKitID: ekid))
        #expect(fetched.title == "New")
        #expect(fetched.location == "Here")
    }

    @Test
    func updateEventMutatesStoredFields() throws {
        let store = InMemoryEventStore()
        let created = try store.createEvent(
            title: "Old",
            startDate: Date(timeIntervalSince1970: 1_000_000),
            endDate: Date(timeIntervalSince1970: 1_003_600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(created.eventKitID)
        try store.updateEvent(
            eventKitID: ekid,
            title: "New",
            startDate: Date(timeIntervalSince1970: 1_010_000),
            endDate: Date(timeIntervalSince1970: 1_013_600),
            isAllDay: true,
            location: "There"
        )
        let fetched = try #require(try store.fetch(eventKitID: ekid))
        #expect(fetched.title == "New")
        #expect(fetched.startDate == Date(timeIntervalSince1970: 1_010_000))
        #expect(fetched.isAllDay)
        #expect(fetched.location == "There")
    }

    @Test
    func updateEventThrowsWhenMissing() throws {
        let store = InMemoryEventStore()
        #expect(throws: EventStoreError.eventNotFound(eventKitID: "absent")) {
            try store.updateEvent(
                eventKitID: "absent",
                title: "x",
                startDate: Date(timeIntervalSince1970: 0),
                endDate: Date(timeIntervalSince1970: 60),
                isAllDay: false,
                location: nil
            )
        }
    }

    @Test
    func removeEventMakesFetchReturnNil() throws {
        let e = event(eventKitID: "ext-removable", start: 1_000_000)
        let store = InMemoryEventStore(events: [e])
        store.removeEvent(eventKitID: "ext-removable")
        #expect(try store.fetch(eventKitID: "ext-removable") == nil)
    }
}
