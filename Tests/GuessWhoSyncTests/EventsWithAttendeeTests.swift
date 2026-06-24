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
    func filtersByAttendeeEmailCaseInsensitively() throws {
        let now = Date()
        let alice = EventAttendee(name: "Alice", email: "Alice@Example.COM")
        let bob = EventAttendee(name: "Bob", email: "bob@example.com")
        let store = InMemoryEventStore(events: [
            event(ekid: "1", title: "with alice", startDate: now.addingTimeInterval(-86400), attendees: [alice]),
            event(ekid: "2", title: "with bob", startDate: now.addingTimeInterval(-172800), attendees: [bob]),
            event(ekid: "3", title: "no match", startDate: now.addingTimeInterval(-86400), attendees: []),
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
}
