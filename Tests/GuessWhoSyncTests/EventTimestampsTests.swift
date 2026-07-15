import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// The event-side timestamp surface: `Event.createdAt` (derived from the
/// envelope's earliest cell stamp, or the live `EKEvent.creationDate` when
/// linked) and the `lastViewed` cell written by `stampEventViewed(at:now:)`.
@Suite("EventTimestamps")
struct EventTimestampsTests {
    private func makeOrchestrator(
        deviceID: String = "device-A"
    ) -> (GuessWhoSync, InMemorySidecarStore, InMemoryEventStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: events,
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars, events)
    }

    private func eventKey(for id: UUID) -> SidecarKey {
        SidecarKey(kind: .event, id: id.uuidString)
    }

    /// ISO8601 round-trips at millisecond precision — compare with a small
    /// tolerance rather than exact equality.
    private func expectClose(_ lhs: Date?, _ rhs: Date, tolerance: TimeInterval = 0.01) {
        guard let lhs else {
            Issue.record("expected a date within \(tolerance)s of \(rhs), got nil")
            return
        }
        #expect(abs(lhs.timeIntervalSince(rhs)) < tolerance)
    }

    // MARK: - createdAt

    @Test
    func manualEventCarriesCreatedAt() throws {
        let (sync, _, _) = makeOrchestrator()
        let before = Date()
        let id = try sync.createManualEvent(
            title: "Coffee",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil
        )
        let after = Date()

        let event = try #require(try sync.event(at: eventKey(for: id)))
        let createdAt = try #require(event.createdAt)
        // The cell stamps round-trip through ISO8601 (millisecond precision),
        // so allow a hair of slack on both bounds.
        #expect(createdAt >= before.addingTimeInterval(-0.01))
        #expect(createdAt <= after.addingTimeInterval(0.01))
    }

    @Test
    func editingDoesNotMoveCreatedAt() throws {
        let (sync, _, _) = makeOrchestrator()
        let id = try sync.createManualEvent(
            title: "Original",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)
        let created = try #require(try sync.event(at: key)?.createdAt)

        try sync.updateEventFields(
            at: key,
            title: "Edited",
            startDate: Date().addingTimeInterval(60),
            endDate: Date().addingTimeInterval(3660),
            isAllDay: true,
            location: "Elsewhere"
        )

        let reread = try #require(try sync.event(at: key))
        #expect(reread.title == "Edited")
        expectClose(reread.createdAt, created)
    }

    @Test
    func linkedEventPrefersLiveCreationDate() throws {
        let (sync, _, events) = makeOrchestrator()
        // A calendar event created long before its sidecar is adopted:
        // the projection must report the calendar's own creation stamp,
        // not the (much later) sidecar mint time.
        let calendarCreated = Date(timeIntervalSinceNow: -86_400 * 30)
        let live = Event(
            eventKitID: "ek-created",
            title: "Old Standup",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            createdAt: calendarCreated
        )
        try events._injectForTest(event: live)

        let id = try sync.linkEvent(toEventKitID: "ek-created", snapshot: live)
        let projected = try #require(try sync.event(at: eventKey(for: id)))
        #expect(projected.createdAt == calendarCreated)
    }

    @Test
    func linkedEventFallsBackToSidecarCreatedAtWhenLiveHasNone() throws {
        let (sync, _, events) = makeOrchestrator()
        let live = Event(
            eventKitID: "ek-nostamp",
            title: "No Creation Date",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800)
        )
        try events._injectForTest(event: live)

        let before = Date()
        let id = try sync.linkEvent(toEventKitID: "ek-nostamp", snapshot: live)
        let projected = try #require(try sync.event(at: eventKey(for: id)))
        let createdAt = try #require(projected.createdAt)
        #expect(createdAt >= before.addingTimeInterval(-0.01))
    }

    // MARK: - lastViewed

    @Test
    func stampEventViewedRoundTrip() throws {
        let (sync, _, _) = makeOrchestrator()
        let id = try sync.createManualEvent(
            title: "Coffee",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: "Cafe"
        )
        let key = eventKey(for: id)
        #expect(try sync.event(at: key)?.lastViewedAt == nil)

        let viewedAt = Date()
        try sync.stampEventViewed(at: key, now: viewedAt)

        let event = try #require(try sync.event(at: key))
        expectClose(event.lastViewedAt, viewedAt)
        // The stamp is additive — the cache cells are untouched.
        #expect(event.title == "Coffee")
        #expect(event.location == "Cafe")
    }

    @Test
    func stampEventViewedIsANoOpWithoutASidecar() throws {
        let (sync, sidecars, _) = makeOrchestrator()
        let key = eventKey(for: UUID())
        try sync.stampEventViewed(at: key, now: Date())
        // A view stamp must never mint a sidecar — adoption owns minting.
        #expect(try sidecars.read(key) == nil)
    }

    @Test
    func restampMovesLastViewedForward() throws {
        let (sync, _, _) = makeOrchestrator()
        let id = try sync.createManualEvent(
            title: "Coffee",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)
        let first = Date(timeIntervalSinceNow: -3600)
        let second = Date()
        try sync.stampEventViewed(at: key, now: first)
        try sync.stampEventViewed(at: key, now: second)
        expectClose(try sync.event(at: key)?.lastViewedAt, second)
    }

    @Test
    func lastViewedSurvivesLiveOverlay() throws {
        let (sync, _, events) = makeOrchestrator()
        let live = Event(
            eventKitID: "ek-viewed",
            title: "Linked",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800)
        )
        try events._injectForTest(event: live)
        let id = try sync.linkEvent(toEventKitID: "ek-viewed", snapshot: live)
        let key = eventKey(for: id)

        let viewedAt = Date()
        try sync.stampEventViewed(at: key, now: viewedAt)

        // The projection overlays live EventKit values, but lastViewed is
        // sidecar-only state and must ride through.
        let projected = try #require(try sync.event(at: key))
        #expect(projected.eventKitID == "ek-viewed")
        expectClose(projected.lastViewedAt, viewedAt)
    }
}
