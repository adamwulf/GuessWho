import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventsWithAttendee")
struct EventsWithAttendeeTests {
    private func makeOrchestrator(
        events: [Event] = []
    ) -> (GuessWhoSync, InMemoryEventStore) {
        let contacts = InMemoryContactStore()
        let store = InMemoryEventStore(events: events)
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: store,
            sidecars: sidecars,
            deviceID: "device-A"
        )
        return (sync, store)
    }

    private func event(
        ekid: String,
        title: String,
        startDate: Date,
        attendees: [EventAttendee]
    ) -> Event {
        Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: title,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            location: nil,
            eventKitNotes: nil,
            attendees: attendees
        )
    }

    // MARK: - Adapter-level filter behaviour

    @Test
    func normalizesQueryEmailsCaseAndWhitespace() throws {
        // EventAttendee.init lowercases on the way in, so attendee storage is
        // always normalized. The interesting case-insensitive path is on the
        // QUERY side: callers may pass raw user-typed addresses with mixed
        // case or leading/trailing whitespace, and the adapter must normalize
        // those before comparing against the lowercased attendee storage.
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let bob = EventAttendee(name: "Bob", email: "bob@example.com")
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "with alice", startDate: now.addingTimeInterval(-86400), attendees: [alice]),
            event(ekid: "2", title: "with bob", startDate: now.addingTimeInterval(-172800), attendees: [bob]),
            event(ekid: "3", title: "no match", startDate: now.addingTimeInterval(-86400), attendees: []),
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: ["  Alice@Example.COM  "],
            in: DateInterval(start: now.addingTimeInterval(-86400 * 30), end: now),
            limit: 10
        )
        #expect(result.map(\.eventKitID) == ["1"])
    }

    @Test
    func filtersWhenAttendeeStorageIsNotLowercase() throws {
        // EventAttendee's stored `email` is normally lowercased by init, but
        // it's a `var` and the type is Codable — a decoded attendee could
        // arrive with mixed-case storage. The filter must still match, since
        // both sides are lowercased on compare.
        let now = Date()
        var alice = EventAttendee(name: "Alice", email: nil)
        alice.email = "Alice@Example.COM" // bypasses init's lowercasing
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "with alice", startDate: now.addingTimeInterval(-86400), attendees: [alice])
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: ["alice@example.com"],
            in: DateInterval(start: now.addingTimeInterval(-86400 * 30), end: now),
            limit: 10
        )
        #expect(result.map(\.eventKitID) == ["1"])
    }

    @Test
    func returnsResultsSortedMostRecentFirstAndRespectsLimit() throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        var seeded: [Event] = []
        for i in 0..<5 {
            seeded.append(
                event(
                    ekid: "ek-\(i)",
                    title: "event \(i)",
                    // Day i back from now: ek-0 is most recent, ek-4 is oldest.
                    startDate: now.addingTimeInterval(Double(-i) * 86400),
                    attendees: [alice]
                )
            )
        }
        let store = InMemoryEventStore(events: seeded)
        let result = try store.eventsWithAttendee(
            matchingEmails: ["alice@example.com"],
            in: DateInterval(start: now.addingTimeInterval(-86400 * 10), end: now.addingTimeInterval(86400)),
            limit: 3
        )
        #expect(result.count == 3)
        #expect(result.map(\.eventKitID) == ["ek-0", "ek-1", "ek-2"])
    }

    @Test
    func emptyEmailsReturnsEmpty() throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "with alice", startDate: now, attendees: [alice])
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: [],
            in: DateInterval(start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(86400)),
            limit: 10
        )
        #expect(result.isEmpty)
    }

    @Test
    func zeroLimitReturnsEmpty() throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "with alice", startDate: now, attendees: [alice])
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: ["alice@example.com"],
            in: DateInterval(start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(86400)),
            limit: 0
        )
        #expect(result.isEmpty)
    }

    @Test
    func matchesAnyEmailFromCandidateSet() throws {
        let now = Date()
        let work = EventAttendee(name: "Alice", email: "alice@work.com")
        let personal = EventAttendee(name: "Alice", email: "alice@personal.com")
        let other = EventAttendee(name: "Bob", email: "bob@example.com")
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "work", startDate: now.addingTimeInterval(-3600), attendees: [work]),
            event(ekid: "2", title: "personal", startDate: now.addingTimeInterval(-7200), attendees: [personal]),
            event(ekid: "3", title: "neither", startDate: now.addingTimeInterval(-10800), attendees: [other]),
        ])
        let result = try store.eventsWithAttendee(
            matchingEmails: ["alice@work.com", "alice@personal.com"],
            in: DateInterval(start: now.addingTimeInterval(-86400), end: now),
            limit: 10
        )
        // Most-recent-first: work (1h ago), personal (2h ago).
        #expect(result.map(\.eventKitID) == ["1", "2"])
    }

    // MARK: - Async wrapper on GuessWhoSync

    @Test
    func recentEventsAsyncReturnsSameResultAsAdapter() async throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let (sync, _) = makeOrchestrator(events: [
            event(ekid: "1", title: "yesterday", startDate: now.addingTimeInterval(-86400), attendees: [alice]),
            event(ekid: "2", title: "last week", startDate: now.addingTimeInterval(-86400 * 7), attendees: [alice]),
        ])
        let result = try await sync.recentEvents(
            matchingEmails: ["alice@example.com"],
            asOf: now,
            limit: 10
        )
        #expect(result.map(\.eventKitID) == ["1", "2"])
    }

    @Test
    func recentEventsAsyncSkipsEventsOutsideTenYearWindow() async throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let calendar = Calendar(identifier: .gregorian)
        // 11 years back should fall outside the [-10y, +1y] window.
        let waaayBack = calendar.date(byAdding: .year, value: -11, to: now)!
        let recent = now.addingTimeInterval(-86400)
        let (sync, _) = makeOrchestrator(events: [
            event(ekid: "1", title: "recent", startDate: recent, attendees: [alice]),
            event(ekid: "2", title: "very old", startDate: waaayBack, attendees: [alice]),
        ])
        let result = try await sync.recentEvents(
            matchingEmails: ["alice@example.com"],
            asOf: now,
            limit: 10
        )
        #expect(result.map(\.eventKitID) == ["1"])
    }

    @Test
    func recentEventsAsyncEmptyEmailsReturnsEmpty() async throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let (sync, _) = makeOrchestrator(events: [
            event(ekid: "1", title: "x", startDate: now, attendees: [alice])
        ])
        let result = try await sync.recentEvents(matchingEmails: [], asOf: now, limit: 10)
        #expect(result.isEmpty)
    }

    @Test
    func recentEventsAsyncMakesOneAdapterCall() async throws {
        // Guards against the wrapper accidentally fanning out into multiple
        // adapter invocations (e.g. one per email or one per chunk) — the
        // 4-year predicate chunking happens INSIDE the adapter and is opaque
        // to the package-level call count.
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "alice@example.com")
        let inner = InMemoryEventStore(events: [
            event(ekid: "1", title: "yesterday", startDate: now.addingTimeInterval(-86400), attendees: [alice])
        ])
        let counting = CountingEventStore(wrapping: inner)
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: counting,
            sidecars: InMemorySidecarStore(),
            deviceID: "device-A"
        )

        let before = counting.eventsWithAttendeeCount
        _ = try await sync.recentEvents(
            matchingEmails: ["alice@example.com", "alice@personal.com"],
            asOf: now,
            limit: 10
        )
        #expect(counting.eventsWithAttendeeCount == before + 1)
    }
}
