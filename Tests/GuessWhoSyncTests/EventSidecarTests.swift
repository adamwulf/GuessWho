import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("EventSidecar")
struct EventSidecarTests {
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

    private func makeOrchestratorWithCountingSidecars(
        deviceID: String = "device-A"
    ) -> (GuessWhoSync, CountingSidecarStore, InMemoryEventStore) {
        let contacts = InMemoryContactStore()
        let events = InMemoryEventStore()
        let inner = InMemorySidecarStore()
        let counting = CountingSidecarStore(wrapping: inner)
        let sync = GuessWhoSync(
            contacts: contacts,
            events: events,
            sidecars: counting,
            deviceID: deviceID
        )
        return (sync, counting, events)
    }

    private func eventKey(for id: UUID) -> SidecarKey {
        SidecarKey(kind: .event, id: id.uuidString)
    }

    // MARK: - Lifecycle

    @Test
    func createManualEventRoundTrip() throws {
        let (sync, _, _) = makeOrchestrator()
        let start = Date()
        let end = start.addingTimeInterval(3600)
        let id = try sync.createManualEvent(
            title: "Coffee",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: "Cafe"
        )
        let key = eventKey(for: id)
        let event = try #require(try sync.event(at: key))
        #expect(event.id == id)
        #expect(event.title == "Coffee")
        #expect(event.location == "Cafe")
        #expect(event.isAllDay == false)
        #expect(event.eventKitID == nil)
        #expect(event.isLinked == false)
    }

    @Test
    func createLinkedEventCreatesEKEventAndSidecar() throws {
        let (sync, _, counting, inner) = makeOrchestratorWithCountingEvents()
        let start = Date()
        let end = start.addingTimeInterval(1800)
        let id = try sync.createLinkedEvent(
            title: "Standup",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)
        #expect(counting.createEventCount == 1)

        let event = try #require(try sync.event(at: key))
        let ekid = try #require(event.eventKitID)
        let liveEK = try #require(try inner.fetch(eventKitID: ekid))
        #expect(liveEK.title == "Standup")
        #expect(event.title == "Standup")
        #expect(event.id == id)
        #expect(event.isLinked == true)
    }

    @Test
    func linkEventStoresEventKitIDAndCache() throws {
        let (sync, _, events) = makeOrchestrator()
        let start = Date()
        let end = start.addingTimeInterval(900)
        let snapshot = try events.createEvent(
            title: "Linked Snap",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: "HQ"
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)
        let event = try #require(try sync.event(at: key))
        #expect(event.eventKitID == ekid)
        #expect(event.title == "Linked Snap")
        #expect(event.location == "HQ")
        #expect(event.isLinked == true)
    }

    @Test
    func linkExistingSidecarAdoptsManualEvent() throws {
        let (sync, _, events) = makeOrchestrator()
        let start = Date()
        let end = start.addingTimeInterval(1800)
        let id = try sync.createManualEvent(
            title: "Manual",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)

        let ek = try events.createEvent(
            title: "Live",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(ek.eventKitID)
        try sync.linkExistingSidecar(at: key, toEventKitID: ekid)

        let event = try #require(try sync.event(at: key))
        #expect(event.eventKitID == ekid)
        #expect(event.title == "Live")

        // titleCache cell now also reads "Live" — refresh wrote it.
        let envelope = try #require(try sync.sidecar(at: key))
        let titleCell = try #require(envelope.fields[GuessWhoSync.eventTitleCacheKey])
        guard case .object(let inner) = titleCell.value,
              case .string(let cached) = inner[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("titleCache missing inner string")
            return
        }
        #expect(cached == "Live")
    }

    // MARK: - Projection

    @Test
    func displayPrefersLiveOverCacheWhenLinked() throws {
        let (sync, _, events) = makeOrchestrator()
        let start = Date()
        let end = start.addingTimeInterval(600)
        let stale = try events.createEvent(
            title: "Stale",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(stale.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: stale)
        let key = eventKey(for: id)

        // Mutate EventKit to a fresh title.
        try events.updateEvent(
            eventKitID: ekid,
            title: "Fresh",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )

        let event = try #require(try sync.event(at: key))
        #expect(event.title == "Fresh")
    }

    @Test
    func displayFallsBackToCacheWhenEventKitGone() throws {
        let (sync, _, events) = makeOrchestrator()
        let start = Date()
        let end = start.addingTimeInterval(600)
        let snapshot = try events.createEvent(
            title: "Cached",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: "Room A"
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        events.removeEvent(eventKitID: ekid)

        let event = try #require(try sync.event(at: key))
        #expect(event.title == "Cached")
        #expect(event.location == "Room A")
        #expect(event.eventKitID == ekid) // not auto-cleared
        #expect(event.isLinked == true)
    }

    // MARK: - Edit (write routing)

    @Test
    func updateLinkedEventWritesEventKitAndRefreshesCache() throws {
        let (sync, _, counting, inner) = makeOrchestratorWithCountingEvents()
        let start = Date()
        let end = start.addingTimeInterval(900)
        let snapshot = try counting.createEvent(
            title: "Original",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        try sync.updateEventFields(
            at: key,
            title: "Renamed",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: "HQ"
        )
        #expect(counting.updateEventCount == 1)
        let liveEK = try #require(try inner.fetch(eventKitID: ekid))
        #expect(liveEK.title == "Renamed")
        #expect(liveEK.location == "HQ")

        // Refresh wrote the new title to the cache cell.
        let envelope = try #require(try sync.sidecar(at: key))
        let titleCell = try #require(envelope.fields[GuessWhoSync.eventTitleCacheKey])
        guard case .object(let inner2) = titleCell.value,
              case .string(let cached) = inner2[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("titleCache missing inner string")
            return
        }
        #expect(cached == "Renamed")
    }

    @Test
    func updateUnlinkedEventWritesCacheOnly() throws {
        let (sync, _, counting, _) = makeOrchestratorWithCountingEvents()
        let start = Date()
        let end = start.addingTimeInterval(600)
        let id = try sync.createManualEvent(
            title: "Manual",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)
        try sync.updateEventFields(
            at: key,
            title: "Manual v2",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        #expect(counting.updateEventCount == 0)
        let event = try #require(try sync.event(at: key))
        #expect(event.title == "Manual v2")
        #expect(event.eventKitID == nil)
    }

    @Test
    func updateLinkedButDeletedWritesCacheOnly() throws {
        let (sync, _, counting, inner) = makeOrchestratorWithCountingEvents()
        let start = Date()
        let end = start.addingTimeInterval(600)
        let snapshot = try counting.createEvent(
            title: "Linked",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        inner.removeEvent(eventKitID: ekid)
        let updateCountBefore = counting.updateEventCount

        try sync.updateEventFields(
            at: key,
            title: "Edited After Gone",
            startDate: start,
            endDate: end,
            isAllDay: false,
            location: nil
        )

        // No EventKit write fired.
        #expect(counting.updateEventCount == updateCountBefore)

        // Did not auto-unlink: eventKitID cell is still live.
        let event = try #require(try sync.event(at: key))
        #expect(event.eventKitID == ekid)
        #expect(event.title == "Edited After Gone")
        #expect(event.isLinked == true)
    }

    // MARK: - Reverse lookup

    @Test
    func eventUUIDForEventKitIDReverseLookup() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let snapshot = try events.createEvent(
            title: "Reverse",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let lookup = try #require(try sync.eventUUID(forEventKitID: ekid))
        #expect(lookup == id)
        #expect(try sync.eventUUID(forEventKitID: "nonexistent") == nil)
    }

    @Test
    func eventUUIDForEventKitIDExcludesUnlinkedAndPicksLexMin() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let snapshot = try events.createEvent(
            title: "Shared",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let idA = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let idB = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let expected = [idA, idB].min { $0.uuidString.lowercased() < $1.uuidString.lowercased() }!
        let other = (expected == idA) ? idB : idA
        let lookup = try #require(try sync.eventUUID(forEventKitID: ekid))
        #expect(lookup == expected)

        // Unlink the lex-min winner; the other remains.
        try sync.unlinkEvent(at: eventKey(for: expected))
        let lookup2 = try #require(try sync.eventUUID(forEventKitID: ekid))
        #expect(lookup2 == other)
    }

    // MARK: - Unlink

    @Test
    func unlinkEventSoftDeletesEventKitIDCellPreservesValue() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let snapshot = try events.createEvent(
            title: "X",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: "Loc"
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        try sync.unlinkEvent(at: key)

        let envelope = try #require(try sync.sidecar(at: key))
        let cell = try #require(envelope.fields[GuessWhoSync.eventKitIDCellKey])
        #expect(cell.deletedAt != nil)
        guard case .object(let inner) = cell.value,
              case .string(let cellValue) = inner[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("eventKitID cell missing inner string")
            return
        }
        #expect(cellValue == ekid)

        // Cache cells still present.
        #expect(envelope.fields[GuessWhoSync.eventTitleCacheKey] != nil)
        #expect(envelope.fields[GuessWhoSync.eventLocationCacheKey] != nil)

        // event(at:) falls back to cache.
        let event = try #require(try sync.event(at: key))
        #expect(event.title == "X")
        #expect(event.location == "Loc")
        #expect(event.eventKitID == nil) // soft-deleted → not exposed
        #expect(event.isLinked == false)
    }

    /// Renamed from `unlinkVsRefreshDisjointCellsConverge`. The original
    /// name and the plan (E1.7 / E6.4) promised a two-device disjoint-cell
    /// LWW convergence test (A unlinks, B refreshes from a mutated EKEvent,
    /// the merge under §5.3 yields both the unlink stamp AND the refreshed
    /// cache values). What the test actually proves is the
    /// single-store post-unlink behavior: `refreshEventCache` is a no-op on
    /// an envelope whose `eventKitID` cell is soft-deleted, so the cache
    /// stays at v1 even when EventKit has moved to v2. That's a real
    /// invariant worth keeping (it's distinct from
    /// `refreshEventCacheNoOpForUnlinked`, which exercises a manual
    /// never-linked event — never had an `eventKitID` cell at all),
    /// so we keep the test and rename it. The two-device convergence
    /// claim is not yet verified by tests; flagged for follow-up.
    @Test
    func refreshEventCacheNoOpAfterUnlink() throws {
        let (syncA, sidecarsA, eventsA) = makeOrchestrator(deviceID: "A")
        let now = Date()
        let snapshot = try eventsA.createEvent(
            title: "Title v1",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try syncA.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        // Unlink (soft-deletes the eventKitID cell).
        try syncA.unlinkEvent(at: key)

        // EventKit moves to v2 underneath us.
        try eventsA.updateEvent(
            eventKitID: ekid,
            title: "Title v2",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )

        // Refresh must no-op: a soft-deleted eventKitID cell means the
        // sidecar is no longer linked, so we don't read EventKit's v2.
        _ = try syncA.refreshEventCache(at: key)

        let envelope = try #require(try sidecarsA.read(key))
        let ekCell = try #require(envelope.fields[GuessWhoSync.eventKitIDCellKey])
        #expect(ekCell.deletedAt != nil)
        guard case .object(let inner) = envelope.fields[GuessWhoSync.eventTitleCacheKey]!.value,
              case .string(let cachedTitle) = inner[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("titleCache missing inner string")
            return
        }
        #expect(cachedTitle == "Title v1")
    }

    // MARK: - Whole-event delete

    @Test
    func deleteEventWritesDeletedAtCellAndFiltersFromAllEvents() throws {
        let (sync, sidecars, _) = makeOrchestrator()
        let now = Date()
        let id = try sync.createManualEvent(
            title: "Delete me",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)
        try sync.deleteEvent(at: key)

        // event(at:) returns nil; allEvents excludes.
        #expect(try sync.event(at: key) == nil)
        let all = try sync.allEvents()
        #expect(all.contains(where: { $0.id == id }) == false)

        // Raw sidecar still has the envelope with a deletedAt well-known cell.
        let envelope = try #require(try sidecars.read(key))
        let cell = try #require(envelope.fields[GuessWhoSync.eventDeletedAtCellKey])
        guard case .object(let inner) = cell.value,
              case .string(_) = inner[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("deletedAt cell shape wrong")
            return
        }
        #expect(cell.deletedAt == nil) // the deletedAt CELL itself is live; payload is timestamp
    }

    // MARK: - Refresh cache

    @Test
    func refreshEventCacheNoOpForUnlinked() throws {
        let (sync, _, _) = makeOrchestrator()
        let id = try sync.createManualEvent(
            title: "Manual",
            startDate: Date(),
            endDate: Date().addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let key = eventKey(for: id)
        let result = try sync.refreshEventCache(at: key)
        let projected = try #require(result)
        #expect(projected.title == "Manual")
        #expect(projected.eventKitID == nil)
    }

    @Test
    func refreshEventCacheUpdatesFromEventKit() throws {
        let (sync, _, events) = makeOrchestrator()
        let now = Date()
        let snapshot = try events.createEvent(
            title: "v1",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        try events.updateEvent(
            eventKitID: ekid,
            title: "v2",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        _ = try sync.refreshEventCache(at: key)

        let envelope = try #require(try sync.sidecar(at: key))
        guard case .object(let inner) = envelope.fields[GuessWhoSync.eventTitleCacheKey]!.value,
              case .string(let cached) = inner[SidecarField.innerValueKey] ?? .null
        else {
            Issue.record("titleCache missing inner string")
            return
        }
        #expect(cached == "v2")
    }

    @Test
    func refreshEventCacheNoOpWhenGone() throws {
        let (sync, sidecars, events) = makeOrchestrator()
        let now = Date()
        let snapshot = try events.createEvent(
            title: "Gone",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: nil
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        events.removeEvent(eventKitID: ekid)

        let before = try #require(try sidecars.read(key))
        _ = try sync.refreshEventCache(at: key)
        let after = try #require(try sidecars.read(key))

        // Cache cells unchanged (no write fired).
        for cellKey in [
            GuessWhoSync.eventTitleCacheKey,
            GuessWhoSync.eventStartCacheKey,
            GuessWhoSync.eventEndCacheKey,
            GuessWhoSync.eventIsAllDayCacheKey,
            GuessWhoSync.eventLocationCacheKey,
            GuessWhoSync.eventNotesCacheKey
        ] {
            let b = before.fields[cellKey]
            let a = after.fields[cellKey]
            #expect(a?.modifiedAt == b?.modifiedAt)
        }
    }

    @Test
    func refreshEventCacheOnlyWritesChangedCells() throws {
        let (sync, sidecars, events) = makeOrchestratorWithCountingSidecars()
        let now = Date()
        let snapshot = try events.createEvent(
            title: "Same",
            startDate: now,
            endDate: now.addingTimeInterval(600),
            isAllDay: false,
            location: "Loc"
        )
        let ekid = try #require(snapshot.eventKitID)
        let id = try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
        let key = eventKey(for: id)

        let writesAfterLink = sidecars.writeCount
        // Refresh with no change in EventKit: no writes should fire.
        _ = try sync.refreshEventCache(at: key)
        #expect(sidecars.writeCount == writesAfterLink)
    }
}
