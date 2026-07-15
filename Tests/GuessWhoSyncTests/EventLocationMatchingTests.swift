import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventLocationMatcher (pure)")
struct EventLocationMatcherTests {
    @Test
    func matchesStreetLineAsContiguousRun() {
        #expect(EventLocationMatcher.matches(
            location: "1 Infinite Loop, Cupertino, CA 95014",
            anyOf: ["1 Infinite Loop"]
        ))
    }

    @Test
    func matchIsCaseAndPunctuationInsensitive() {
        #expect(EventLocationMatcher.matches(
            location: "  1 INFINITE   LOOP\nCupertino ",
            anyOf: ["1 infinite loop"]
        ))
    }

    @Test
    func respectsWordBoundaries() {
        // Raw substring "1 Main" lives inside "21 Main St", but token matching
        // must NOT treat "21" as containing "1".
        #expect(!EventLocationMatcher.matches(
            location: "21 Main St, Springfield",
            anyOf: ["1 Main"]
        ))
    }

    @Test
    func ignoresSingleTokenNeedles() {
        // A one-word street ("Broadway") is too generic to match safely.
        #expect(!EventLocationMatcher.matches(
            location: "Broadway Theater, New York",
            anyOf: ["Broadway"]
        ))
    }

    @Test
    func nilOrEmptyLocationNeverMatches() {
        #expect(!EventLocationMatcher.matches(location: nil, anyOf: ["1 Infinite Loop"]))
        #expect(!EventLocationMatcher.matches(location: "", anyOf: ["1 Infinite Loop"]))
    }

    @Test
    func emptyNeedlesNeverMatch() {
        #expect(!EventLocationMatcher.matches(location: "1 Infinite Loop", anyOf: []))
    }

    @Test
    func matchesAnyNeedleFromSet() {
        #expect(EventLocationMatcher.matches(
            location: "500 Terry A Francois Blvd, San Francisco",
            anyOf: ["1 Infinite Loop", "500 Terry A Francois Blvd"]
        ))
    }
}

@Suite("EventsWithLocation")
struct EventsWithLocationTests {
    private func event(
        ekid: String,
        title: String,
        startDate: Date,
        location: String?,
        attendees: [EventAttendee] = []
    ) -> Event {
        Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            location: location,
            eventKitNotes: nil,
            attendees: attendees
        )
    }

    // MARK: - Adapter-level filter behaviour

    @Test
    func matchesEventsByLocationStreetLine() throws {
        let now = Date()
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "at office", startDate: now.addingTimeInterval(-86400),
                  location: "1 Infinite Loop, Cupertino, CA"),
            event(ekid: "2", title: "elsewhere", startDate: now.addingTimeInterval(-172800),
                  location: "Conference Room B"),
            event(ekid: "3", title: "no location", startDate: now.addingTimeInterval(-86400),
                  location: nil),
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: [],
            orLocations: ["1 Infinite Loop"],
            in: DateInterval(start: now.addingTimeInterval(-86400 * 30), end: now),
            limit: 10
        )
        #expect(result.map(\.eventKitID) == ["1"])
    }

    @Test
    func unionsEmailAndLocationMatchesWithoutDuplicates() throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let store = InMemoryEventStore(events: [
            // Matches on BOTH email and location — must appear exactly once.
            event(ekid: "1", title: "both", startDate: now.addingTimeInterval(-3600),
                  location: "1 Infinite Loop", attendees: [alice]),
            // Location only.
            event(ekid: "2", title: "loc only", startDate: now.addingTimeInterval(-7200),
                  location: "1 Infinite Loop, Cupertino"),
            // Email only.
            event(ekid: "3", title: "email only", startDate: now.addingTimeInterval(-10800),
                  location: "Somewhere Else", attendees: [alice]),
            // Neither.
            event(ekid: "4", title: "neither", startDate: now.addingTimeInterval(-14400),
                  location: "Nowhere"),
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: ["alice@example.com"],
            orLocations: ["1 Infinite Loop"],
            in: DateInterval(start: now.addingTimeInterval(-86400), end: now),
            limit: 10
        )
        // Most-recent-first; ek-1 appears once despite matching both signals.
        #expect(result.map(\.eventKitID) == ["1", "2", "3"])
    }

    @Test
    func emptyEmailsAndLocationsReturnsEmpty() throws {
        let now = Date()
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "x", startDate: now, location: "1 Infinite Loop")
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: [],
            orLocations: [],
            in: DateInterval(start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(86400)),
            limit: 10
        )
        #expect(result.isEmpty)
    }

    // MARK: - Async wrapper on GuessWhoSync

    @Test
    func recentEventsAsyncMatchesByLocation() async throws {
        let now = Date()
        let contacts = InMemoryContactStore()
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "at office", startDate: now.addingTimeInterval(-86400),
                  location: "1 Infinite Loop, Cupertino, CA"),
            event(ekid: "2", title: "elsewhere", startDate: now.addingTimeInterval(-172800),
                  location: "Conference Room B"),
        ])
        let sync = GuessWhoSync(
            contacts: contacts,
            events: store,
            sidecars: InMemorySidecarStore(),
            deviceID: "device-A"
        )
        let result = try await sync.recentEvents(
            matchingEmails: [],
            matchingLocations: ["1 Infinite Loop"],
            asOf: now,
            limit: 10
        )
        #expect(result.map(\.eventKitID) == ["1"])
    }
}
