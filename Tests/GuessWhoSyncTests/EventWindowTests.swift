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
    func eventsWindowLinkedEventRetainsCalendarNameAndColor() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600)

        // A live EKEvent carrying its source calendar's name + color. Inject
        // it directly so the fields survive (createEvent can't set them).
        let live = Event(
            id: UUID(),
            eventKitID: "ek-cal-1",
            title: "Shared event",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(120),
            isAllDay: false,
            location: nil,
            calendarName: "Family",
            calendarColorHex: "#34C759"
        )
        try events._injectForTest(event: live)

        // Adopt it: minting a sidecar makes the row take the linked-overlay
        // branch of eventsWindow (the case that previously stripped these).
        _ = try sync.linkEvent(toEventKitID: "ek-cal-1", snapshot: live)

        let window = try sync.eventsWindow(from: from, to: to)
        let projected = try #require(window.first(where: { $0.title == "Shared event" }))
        #expect(projected.isLinked)
        #expect(projected.calendarName == "Family")
        #expect(projected.calendarColorHex == "#34C759")
    }

    // MARK: - Window-aware watcher-delta projection (must match `eventsWindow`)

    /// A linked event whose CACHED start sits inside the window but whose LIVE
    /// start has since moved OUTSIDE it. `eventsWindow` keeps the row via its
    /// cached start (the live event no longer appears in the single window
    /// batch, so no live overlay). The window-aware delta projection must reach
    /// the same result — otherwise a scoped delta refresh would drop a row a
    /// full reload shows.
    @Test
    func watcherDeltaProjectionMatchesEventsWindowForCachedInLiveOut() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        let live = try events.createEvent(
            title: "Standup",
            startDate: now.addingTimeInterval(3600),        // in window
            endDate: now.addingTimeInterval(3600 + 1800),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(live.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: live)
        let key = eventKey(for: id)

        // Move the LIVE event past the window end WITHOUT refreshing the cache,
        // so the cached start stays in window while the live start moves out.
        try events.updateEvent(
            eventKitID: ekid,
            title: "Standup moved",
            startDate: to.addingTimeInterval(3600),
            endDate: to.addingTimeInterval(3600 + 1800),
            isAllDay: false,
            location: nil
        )

        // Full reload keeps the row via the cached (in-window) projection.
        let window = try sync.eventsWindow(from: from, to: to)
        let full = try #require(window.first(where: { $0.id == id }))
        #expect(full.title == "Standup")   // cached title, NOT the moved live one
        #expect(full.startDate >= from && full.startDate <= to)

        // The delta projection agrees row-for-row with the full reload (both read
        // the same round-tripped cache), and the row stays in the window.
        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: true)
        )
        #expect(delta.startDate == full.startDate)
        #expect(delta.title == full.title)
        #expect(delta.startDate >= from && delta.startDate <= to)
    }

    /// A linked event whose LIVE version overlaps the window but STARTS BEFORE
    /// it, while its cached start is inside the window. `eventsWindow` overlays
    /// the live values (the event is in the window batch) and then drops the row
    /// because the projected (live) start falls before the window. The delta
    /// projection overlays the same live values, so a caller applying the
    /// identical membership filter drops it too — delta and full reload agree.
    @Test
    func watcherDeltaProjectionMatchesEventsWindowForLiveOverlapStartingBeforeWindow() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        let live = try events.createEvent(
            title: "Long meeting",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(7200),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(live.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: live)
        let key = eventKey(for: id)

        // Live now starts an hour BEFORE the window but ends inside it (overlaps).
        try events.updateEvent(
            eventKitID: ekid,
            title: "Long meeting",
            startDate: from.addingTimeInterval(-3600),
            endDate: from.addingTimeInterval(1800),
            isAllDay: false,
            location: nil
        )

        // Full reload overlays the live values, then filters the row out.
        let window = try sync.eventsWindow(from: from, to: to)
        #expect(window.contains(where: { $0.id == id }) == false)

        // Delta overlays the same live values; its start is before the window,
        // so the caller's membership filter drops it, matching the full reload.
        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: true)
        )
        #expect(delta.startDate == from.addingTimeInterval(-3600))
        #expect((delta.startDate >= from && delta.startDate <= to) == false)
    }

    /// The positive overlay case: a linked event whose live version is still
    /// inside the window. Both the full reload and the delta projection surface
    /// the live (overlaid) values, not the stale cache.
    @Test
    func watcherDeltaProjectionOverlaysLiveWhenLiveStartsInWindow() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        let live = try events.createEvent(
            title: "Old title",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(live.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: live)
        let key = eventKey(for: id)

        // Live edited in place, still inside the window.
        try events.updateEvent(
            eventKitID: ekid,
            title: "New title",
            startDate: now.addingTimeInterval(7200),
            endDate: now.addingTimeInterval(9000),
            isAllDay: false,
            location: nil
        )

        let window = try sync.eventsWindow(from: from, to: to)
        let full = try #require(window.first(where: { $0.id == id }))
        #expect(full.title == "New title")
        #expect(full.startDate == now.addingTimeInterval(7200))

        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: true)
        )
        #expect(delta.title == full.title)
        #expect(delta.startDate == full.startDate)
    }

    /// With EventKit excluded, the delta projection never overlays — it returns
    /// the cached projection, matching `eventsWindow(..., includeEventKit: false)`.
    @Test
    func watcherDeltaProjectionUsesCacheWhenEventKitExcluded() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        let live = try events.createEvent(
            title: "Cached title",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(5400),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(live.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: live)
        let key = eventKey(for: id)

        try events.updateEvent(
            eventKitID: ekid,
            title: "Live title",
            startDate: now.addingTimeInterval(7200),
            endDate: now.addingTimeInterval(9000),
            isAllDay: false,
            location: nil
        )

        // Match the full reload with EventKit excluded: the cached projection,
        // read the same way (so the ISO round-trip agrees on both sides).
        let cachedRef = try #require(
            try sync.eventsWindow(from: from, to: to, includeEventKit: false)
                .first(where: { $0.id == id })
        )
        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: false)
        )
        #expect(delta.title == "Cached title")
        #expect(delta.title == cachedRef.title)
        #expect(delta.startDate == cachedRef.startDate)
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
