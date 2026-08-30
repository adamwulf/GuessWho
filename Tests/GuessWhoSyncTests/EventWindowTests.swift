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

    /// Repository-style window membership. `EventsRepository` keeps a watcher
    /// delta's projected row only when its start falls in the inclusive window
    /// (`EventsRepository.swift` applies exactly
    /// `projected.startDate >= windowStart && projected.startDate <= windowEnd`).
    /// Model that here so a test can compare the VISIBLE delta row — the row the
    /// list would actually show — against the full-reload row, which
    /// `eventsWindow` has already start-filtered. Returns nil when the delta is
    /// nil (no sidecar) or its start is out of window (dropped by membership).
    private func repositoryVisibleRow(_ event: Event?, from: Date, to: Date) -> Event? {
        guard let event, event.startDate >= from, event.startDate <= to else { return nil }
        return event
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
    //
    // FIX B invariant: `eventsWindow` overlays whenever its single
    // `events(matching:)` batch surfaces the event (i.e. the live version
    // OVERLAPS the window), then its `projected.startDate` membership filter
    // decides whether the row stays. `eventForWatcherDelta` overlays under the
    // identical overlap test and leaves start membership to its caller
    // (`EventsRepository`, modeled here by `repositoryVisibleRow`). So the
    // delta's VISIBLE row and the full-reload row must agree for the same event:
    // no stale cached title/time survives for an event the overlapping batch
    // returned.

    /// FIX B — the regression this restores. A linked event whose CACHED start
    /// is inside the window but whose LIVE version has moved to START BEFORE
    /// `from` while STILL OVERLAPPING the window (its end is past `from`). The
    /// single `events(matching:)` batch surfaces it (it overlaps), so
    /// `eventsWindow` overlays the live values and then DROPS the row on start
    /// membership — it must NOT linger with the stale cached title/time. The
    /// delta overlays under the same overlap test and hands the caller the live
    /// (out-of-window) values, so the repository-visible row (after start
    /// membership) agrees with the full reload: both drop, and neither surfaces
    /// the cache.
    @Test
    func deltaAndWindowDropOverlapEventWhoseLiveStartMovedBeforeWindow() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        let seed = try events.createEvent(
            title: "Cached title",
            startDate: now.addingTimeInterval(3600),   // cached start in window
            endDate: now.addingTimeInterval(5400),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(seed.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: seed)
        let key = eventKey(for: id)

        // Live now STARTS BEFORE the window but ENDS inside it, so it still
        // overlaps and stays in the single window batch.
        try events.updateEvent(
            eventKitID: ekid,
            title: "Live title",
            startDate: from.addingTimeInterval(-3600),
            endDate: from.addingTimeInterval(1800),
            isAllDay: false,
            location: nil
        )
        // Sanity: the event genuinely overlaps, so `events(matching:)` sees it —
        // this is the case where the overlay MUST happen.
        let batch = try events.fetchEvents(in: DateInterval(start: from, end: to))
        #expect(batch.contains { $0.eventKitID == ekid })

        // Full reload: overlaid to the live (out-of-window) start, then dropped
        // by start membership. The stale cached row never appears.
        #expect(try sync.eventsWindow(from: from, to: to).contains { $0.id == id } == false)

        // Delta overlays the live values (never the cache), so the repository's
        // start-membership filter drops it — agreeing with the full reload.
        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: true)
        )
        #expect(delta.title == "Live title")            // overlaid live, NOT cached
        #expect(delta.title != "Cached title")
        #expect(delta.startDate == from.addingTimeInterval(-3600))
        #expect(repositoryVisibleRow(delta, from: from, to: to) == nil)   // dropped
    }

    /// A linked event whose LIVE version does NOT overlap the window at all (it
    /// sits entirely before `from`). `events(matching:)` cannot see it, so
    /// `eventsWindow` never overlays and falls back to the cached projection —
    /// itself out of window here — and the row is excluded. The delta's overlap
    /// gate likewise declines to overlay and returns the cached projection (NOT
    /// nil), which the repository's start membership then excludes. Both exclude,
    /// agreeing row-for-row under equivalent membership.
    @Test
    func deltaAndWindowExcludeEventWhoseLiveDoesNotOverlap() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        // Cached + live both sit entirely BEFORE the window (no overlap).
        let seed = try events.createEvent(
            title: "Past event",
            startDate: from.addingTimeInterval(-7200),
            endDate: from.addingTimeInterval(-6600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(seed.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: seed)
        let key = eventKey(for: id)

        // Sanity: the live event does NOT overlap, so the batch excludes it.
        let batch = try events.fetchEvents(in: DateInterval(start: from, end: to))
        #expect(batch.contains { $0.eventKitID == ekid } == false)

        // Full reload excludes the out-of-window row.
        #expect(try sync.eventsWindow(from: from, to: to).contains { $0.id == id } == false)

        // Delta returns the cached (out-of-window) projection — NOT nil, so the
        // caller (not the delta) applies membership — and the repository excludes
        // it, agreeing with the full reload. (The cached start round-trips
        // through ISO8601, so assert its window position, not an exact literal.)
        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: true)
        )
        #expect(delta.title == "Past event")            // cached projection, not overlaid
        #expect(delta.startDate < from)                 // sits before the window
        #expect(repositoryVisibleRow(delta, from: from, to: to) == nil)   // excluded
    }

    /// The boundary of the FIX B invariant: an event whose LIVE version has
    /// moved out of the window ENTIRELY (start past `to`, so it no longer
    /// overlaps) while its cached start is still inside the window. Because the
    /// single `events(matching:)` batch is scoped to the window, it cannot see
    /// the moved event, so `eventsWindow` legitimately keeps the CACHED row — the
    /// invariant only forbids stale cache for an event the OVERLAPPING batch
    /// returned, and this event is not in it. The delta's overlap gate agrees: it
    /// too keeps the cache, so the visible rows match.
    @Test
    func deltaAndWindowKeepCacheWhenLiveMovedOutOfBatch() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        let live = try events.createEvent(
            title: "Standup",
            startDate: now.addingTimeInterval(3600),        // cached start in window
            endDate: now.addingTimeInterval(3600 + 1800),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(live.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: live)
        let key = eventKey(for: id)

        // Move the LIVE event past the window end WITHOUT refreshing the cache,
        // so the cached start stays in window while the live start moves out and
        // the event no longer overlaps.
        try events.updateEvent(
            eventKitID: ekid,
            title: "Standup moved",
            startDate: to.addingTimeInterval(3600),
            endDate: to.addingTimeInterval(3600 + 1800),
            isAllDay: false,
            location: nil
        )
        // Sanity: the moved event does NOT overlap, so it is absent from the
        // batch — the reason the cached projection legitimately stands.
        let batch = try events.fetchEvents(in: DateInterval(start: from, end: to))
        #expect(batch.contains { $0.eventKitID == ekid } == false)

        // Full reload keeps the row via the cached (in-window) projection.
        let full = try #require(try sync.eventsWindow(from: from, to: to).first { $0.id == id })
        #expect(full.title == "Standup")   // cached title, NOT the moved live one
        #expect(full.startDate >= from && full.startDate <= to)

        // The delta projection agrees row-for-row with the full reload.
        let delta = try #require(
            try sync.eventForWatcherDelta(at: key, from: from, to: to, includeEventKit: true)
        )
        let deltaRow = try #require(repositoryVisibleRow(delta, from: from, to: to))
        #expect(deltaRow.startDate == full.startDate)
        #expect(deltaRow.title == full.title)
    }

    /// Inclusive start boundaries under FIX B. For an event whose live version
    /// OVERLAPS the window (kept overlapping at every boundary by pinning its end
    /// inside the window), the row is shown — with the LIVE values — exactly when
    /// the live START is in the inclusive `[from, to]`. A start one second before
    /// `from` still overlaps, so it is overlaid and then dropped by membership —
    /// never retained as stale cache. The delta's visible row and the full reload
    /// agree at every boundary.
    @Test
    func watcherDeltaAndWindowShareInclusiveStartBoundary() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let from = now
        let to = now.addingTimeInterval(3600 * 24)

        func check(liveStart: Date, expectShown: Bool, _ label: String) throws {
            let seed = try events.createEvent(
                title: "cache-\(label)",
                startDate: now.addingTimeInterval(3600),   // cached start in window
                endDate: now.addingTimeInterval(5400),
                isAllDay: false,
                location: nil
            )
            let ekid = try #require(seed.eventKitID)
            let id = try sync.linkEvent(toEventKitID: ekid, snapshot: seed)
            let key = eventKey(for: id)
            // Pin the live end inside the window so the event overlaps at every
            // boundary — only the live START crosses `from`/`to`.
            let liveEnd = max(liveStart.addingTimeInterval(1800), from.addingTimeInterval(1))
            try events.updateEvent(
                eventKitID: ekid,
                title: "live-\(label)",
                startDate: liveStart,
                endDate: liveEnd,
                isAllDay: false,
                location: nil
            )

            let full = try sync.eventsWindow(from: from, to: to).first { $0.id == id }
            let deltaRaw = try sync.eventForWatcherDelta(
                at: key, from: from, to: to, includeEventKit: true
            )
            let deltaRow = repositoryVisibleRow(deltaRaw, from: from, to: to)
            // Delta's visible row and the full reload agree on presence + values.
            #expect(full?.id == deltaRow?.id)
            #expect(full?.title == deltaRow?.title)
            #expect(full?.startDate == deltaRow?.startDate)
            if expectShown {
                #expect(deltaRow?.title == "live-\(label)")   // live overlaid, in window
                #expect(deltaRow?.startDate == liveStart)
            } else {
                #expect(deltaRow == nil)                       // overlaid live, then dropped
                #expect(full == nil)
            }
        }

        try check(liveStart: from, expectShown: true, "at-from")
        try check(liveStart: to, expectShown: true, "at-to")
        try check(liveStart: from.addingTimeInterval(-1), expectShown: false, "just-before")
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
