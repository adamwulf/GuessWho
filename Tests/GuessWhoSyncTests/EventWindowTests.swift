import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventWindow")
struct EventWindowTests {
    private func makeOrchestratorWithCountingEvents(
        deviceID: String = "device-A"
    ) -> (GuessWhoSync, InMemorySidecarStore, CountingEventStore, InMemoryEventStore) {
        let contacts = InMemoryContactStore()
        let innerEvents = InMemoryEventStore()
        let counting = CountingEventStore(wrapping: innerEvents)
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: counting,
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars, counting, innerEvents)
    }

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

    // MARK: -

    @Test
    func eventsWindowDoesOneFetchInWindow() throws {
        let (sync, _, counting, _) = makeOrchestratorWithCountingEvents()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        // Seed: 5 EKEvents in-window, each linked from its own sidecar.
        for i in 0..<5 {
            let start = now.addingTimeInterval(Double(i) * 600)
            let end = start.addingTimeInterval(300)
            let snapshot = try counting.createEvent(
                title: "Event \(i)",
                startDate: start,
                endDate: end,
                isAllDay: false,
                location: nil
            )
            let ekid = try #require(snapshot.eventKitID)
            _ = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        }

        let createCount = counting.createEventCount
        let fetchEKBefore = counting.fetchEventKitIDCount
        let fetchInIntervalBefore = counting.fetchEventsInIntervalCount

        let window = try sync.eventsWindow(from: from, to: to)
        #expect(window.count == 5)

        // Critical: ONE batch fetch, ZERO per-event fetch.
        #expect(counting.fetchEventsInIntervalCount == fetchInIntervalBefore + 1)
        #expect(counting.fetchEventKitIDCount == fetchEKBefore)
        _ = createCount

        // Live overlay: titles came through.
        let titles = Set(window.map(\.title))
        #expect(titles == Set((0..<5).map { "Event \($0)" }))
    }

    @Test
    func eventsWindowExcludesDeletedEnvelopes() throws {
        let (sync, _, _) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600)
        let alive = try sync.createManualEvent(
            title: "Alive",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(120),
            isAllDay: false,
            location: nil
        )
        let dead = try sync.createManualEvent(
            title: "Dead",
            startDate: now.addingTimeInterval(180),
            endDate: now.addingTimeInterval(240),
            isAllDay: false,
            location: nil
        )
        try sync.deleteEvent(at: eventKey(for: dead))

        let window = try sync.eventsWindow(from: from, to: to)
        let ids = Set(window.map(\.id))
        #expect(ids.contains(alive))
        #expect(ids.contains(dead) == false)
    }

    @Test
    func eventsWindowIncludeEventKitFalseReturnsSidecarOnly() throws {
        let (sync, _, counting, _) = makeOrchestratorWithCountingEvents()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        // One linked sidecar event (cache contains the live title at link time).
        let snapshot = try counting.createEvent(
            title: "Linked",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(120),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        _ = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)

        // One ephemeral EKEvent (no sidecar).
        _ = try counting.createEvent(
            title: "Ephemeral",
            startDate: now.addingTimeInterval(300),
            endDate: now.addingTimeInterval(360),
            isAllDay: false,
            location: nil
        )

        // One manual sidecar.
        _ = try sync.createManualEvent(
            title: "Manual",
            startDate: now.addingTimeInterval(600),
            endDate: now.addingTimeInterval(660),
            isAllDay: false,
            location: nil
        )

        let fetchInIntervalBefore = counting.fetchEventsInIntervalCount
        let fetchEKBefore = counting.fetchEventKitIDCount
        let window = try sync.eventsWindow(from: from, to: to, includeEventKit: false)

        // No EventKit traffic at all.
        #expect(counting.fetchEventsInIntervalCount == fetchInIntervalBefore)
        #expect(counting.fetchEventKitIDCount == fetchEKBefore)

        // Only sidecar events (Linked + Manual) returned; Ephemeral skipped.
        let titles = Set(window.map(\.title))
        #expect(titles == Set(["Linked", "Manual"]))
    }

    @Test
    func eventsWindowEphemeralRowsUseStableID() throws {
        let (sync, _, _, inner) = makeOrchestratorWithCountingEvents()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600)

        _ = try inner.createEvent(
            title: "Ephemeral",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(120),
            isAllDay: false,
            location: nil
        )

        let first = try sync.eventsWindow(from: from, to: to)
        let second = try sync.eventsWindow(from: from, to: to)
        let f = try #require(first.first(where: { $0.title == "Ephemeral" }))
        let s = try #require(second.first(where: { $0.title == "Ephemeral" }))
        #expect(f.id == s.id)
        let ekid = try #require(f.eventKitID)
        #expect(f.id == Event.stableID(forEventKitID: ekid))
    }
}
