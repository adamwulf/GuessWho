#if canImport(EventKit)
import EventKit
import Foundation
import Testing
@testable import GuessWhoSync

/// DL-2: the attendee/location index behind `eventsWithAttendee`. These pin the
/// caching win (one raw walk per window) and the lookup semantics carried over
/// verbatim from the pre-index linear scan — email/location matching, the
/// latest-MATCHING-occurrence collapse, descending-start order, and the limit —
/// plus the invalidation discipline shared with the raw window coordinator.
@Suite("EKEventStoreAdapter attendee index")
struct EKEventStoreAdapterAttendeeIndexTests {
    private func makeAdapter(
        center: NotificationCenter = NotificationCenter(),
        cacheLifetime: TimeInterval = 60,
        authorization: @escaping @Sendable () -> StoreAuthorizationStatus = { .authorized },
        spy: AttendeeIndexFetchSpy
    ) -> EKEventStoreAdapter {
        EKEventStoreAdapter(
            notificationCenter: center,
            cacheLifetime: cacheLifetime,
            fetchEventsWork: { _, interval in spy.fetch(interval: interval) },
            authorizationStatusWork: authorization
        )
    }

    /// A window wide enough that every synthetic event falls inside it. The
    /// injected fake ignores the interval for filtering, so only start < end
    /// matters here.
    private func window(start: TimeInterval = 0, duration: TimeInterval = 10_000_000) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: start), duration: duration)
    }

    private func event(
        ekid: String,
        start: TimeInterval,
        location: String? = nil,
        emails: [String] = []
    ) -> Event {
        Event(
            eventKitID: ekid,
            title: ekid,
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start + 3_600),
            location: location,
            attendees: emails.map { EventAttendee(name: $0, email: $0) }
        )
    }

    /// Start `eventsWithAttendee` on a dedicated OS thread (see `BlockingFuture`)
    /// — deliberately NOT `Task.detached` nor a libdispatch worker. The lookup
    /// blocks on the coordinator's `NSCondition` while a build is gated; running
    /// it on a cooperative-pool or dispatch thread lets the parallel test runner
    /// starve it once those user-space pools are saturated by other suites'
    /// blocking tests. A raw thread is kernel-scheduled immediately, so the
    /// gated call always starts promptly.
    private func blockingLookup(
        _ adapter: EKEventStoreAdapter,
        emails: Set<String>,
        locations: Set<String> = [],
        window: DateInterval,
        limit: Int = 10
    ) -> BlockingFuture<[Event]> {
        BlockingFuture {
            try adapter.eventsWithAttendee(
                matchingEmails: emails, orLocations: locations, in: window, limit: limit
            )
        }
    }

    /// Poll until `callers` identical lookups have joined one in-flight index
    /// build, or a wall-clock deadline elapses. Synchronous by design: it must
    /// not depend on the cooperative pool making progress while two dedicated
    /// threads are parked in the coordinator.
    private func waitForJoin(
        _ adapter: EKEventStoreAdapter,
        window: DateInterval,
        callers: Int,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if adapter.inFlightAttendeeIndexCallerCountForTesting(window) == callers {
                return true
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }

    // MARK: - Caching / repeat-count

    @Test
    func repeatedAuthorizedLookupsForOneWindowWalkEventKitOnce() throws {
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "email-hit", start: 100, emails: ["a@x.com"]),
            event(ekid: "loc-hit", start: 200, location: "1 Infinite Loop, Cupertino"),
        ])
        let adapter = makeAdapter(spy: spy)
        let w = window()

        // First query builds the index (one walk). A SECOND query over the same
        // window with an entirely different needle is served from the cached
        // index, proving the INDEX — not a per-query result — is what's cached.
        let byEmail = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        let byLocation = try adapter.eventsWithAttendee(
            matchingEmails: [], orLocations: ["1 Infinite Loop"], in: w, limit: 10
        )

        #expect(spy.fetchCount == 1)
        #expect(byEmail.map(\.eventKitID) == ["email-hit"])
        #expect(byLocation.map(\.eventKitID) == ["loc-hit"])
    }

    @Test
    func attendeeIndexIsNonExpiringAndSurvivesWindowCacheTTL() throws {
        // The adapter's cacheLifetime governs the RAW window cache's TTL. The
        // attendee index must be invalidation-only (one walk per launch, not
        // one walk per TTL), so it stays cached well past that window TTL.
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(cacheLifetime: 0.05, spy: spy)
        let w = window()

        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)

        // Sleep well past the injected 0.05s window-cache TTL.
        Thread.sleep(forTimeInterval: 0.25)

        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)   // still cached — the index never expires
        #expect(result.map(\.eventKitID) == ["e1"])
    }

    @Test
    func concurrentIdenticalLookupsShareOneIndexBuild() throws {
        let w = window()
        let spy = AttendeeIndexFetchSpy(
            events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])],
            blockFirstFetch: true
        )
        let adapter = makeAdapter(spy: spy)

        let first = blockingLookup(adapter, emails: ["a@x.com"], window: w)
        #expect(spy.waitForFetchCount(1))

        let second = blockingLookup(adapter, emails: ["a@x.com"], window: w)
        #expect(waitForJoin(adapter, window: w, callers: 2))

        spy.releaseFirstFetch()
        let firstResult = try first.value()
        let secondResult = try second.value()

        #expect(spy.fetchCount == 1)
        #expect(firstResult == secondResult)
        #expect(firstResult.map(\.eventKitID) == ["e1"])
    }

    // MARK: - Lookup dimensions

    @Test
    func emailDimensionMatchesOnlyQueriedAttendees() throws {
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "wanted", start: 100, emails: ["Wanted@X.com"]),
            event(ekid: "other", start: 200, emails: ["someone@else.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        // Query casing differs from the stored attendee — normalization on both
        // sides must still match.
        let result = try adapter.eventsWithAttendee(matchingEmails: ["  wanted@x.com "], in: window(), limit: 10)
        #expect(result.map(\.eventKitID) == ["wanted"])
    }

    @Test
    func mixedCaseStoredAttendeeEmailStillMatchesLowercasedQuery() throws {
        // Force a mixed-case STORED email, bypassing EventAttendee.init's
        // lowercasing (mirrors a Codable-decoded or directly-mutated attendee).
        // The index must lowercase at build time — as the old adapter did at
        // match time — so a lowercased query still matches.
        var attendee = EventAttendee(name: "Mixed", email: "placeholder@example.com")
        attendee.email = "MixedCase@X.com"
        #expect(attendee.email == "MixedCase@X.com")   // stored verbatim, not lowercased
        let mixed = Event(
            eventKitID: "mixed",
            title: "mixed",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 3_700),
            attendees: [attendee]
        )
        let spy = AttendeeIndexFetchSpy(events: [mixed])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(matchingEmails: ["mixedcase@x.com"], in: window(), limit: 10)
        #expect(result.map(\.eventKitID) == ["mixed"])
    }

    @Test
    func locationDimensionMatchesStreetLineAsWordRun() throws {
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "at-loop", start: 100, location: "1 Infinite Loop, Cupertino, CA"),
            event(ekid: "room", start: 200, location: "Conference Room B"),
            event(ekid: "no-loc", start: 300),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(
            matchingEmails: [], orLocations: ["1 Infinite Loop"], in: window(), limit: 10
        )
        #expect(result.map(\.eventKitID) == ["at-loop"])
    }

    @Test
    func bothDimensionsUnionEmailAndLocationHits() throws {
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "by-email", start: 100, emails: ["a@x.com"]),
            event(ekid: "by-loc", start: 300, location: "1 Infinite Loop, Cupertino"),
            event(ekid: "neither", start: 200, location: "Somewhere Else", emails: ["z@z.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(
            matchingEmails: ["a@x.com"], orLocations: ["1 Infinite Loop"], in: window(), limit: 10
        )
        // Descending start: by-loc (300) before by-email (100).
        #expect(result.map(\.eventKitID) == ["by-loc", "by-email"])
    }

    @Test
    func noMatchReturnsEmpty() throws {
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "e1", start: 100, location: "Room 4", emails: ["a@x.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(
            matchingEmails: ["nobody@nowhere.com"], orLocations: ["9 Missing Way"], in: window(), limit: 10
        )
        #expect(result.isEmpty)
    }

    @Test
    func limitCapsToNewestMatches() throws {
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "old", start: 100, emails: ["a@x.com"]),
            event(ekid: "mid", start: 200, emails: ["a@x.com"]),
            event(ekid: "new", start: 300, emails: ["a@x.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: window(), limit: 2)
        // Two newest, descending.
        #expect(result.map(\.eventKitID) == ["new", "mid"])
    }

    // MARK: - Occurrence collapse (semantic traps)

    @Test
    func multipleMatchingOccurrencesCollapseToLatest() throws {
        // Same eventKitID, two occurrences both matching by email.
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "recurring", start: 100, emails: ["a@x.com"]),
            event(ekid: "recurring", start: 500, emails: ["a@x.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: window(), limit: 10)
        #expect(result.count == 1)
        #expect(result.first?.eventKitID == "recurring")
        #expect(result.first?.startDate == Date(timeIntervalSince1970: 500))
    }

    @Test
    func collapsePicksLatestMATCHINGOccurrenceNotLaterNonMatch() throws {
        // A recurring event whose LATER occurrence dropped the queried
        // attendee. The earlier, matching occurrence must win — the collapse
        // happens AFTER per-occurrence filtering, never before it.
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "recurring", start: 100, emails: ["a@x.com"]),
            event(ekid: "recurring", start: 900, emails: ["z@z.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: window(), limit: 10)
        #expect(result.count == 1)
        #expect(result.first?.startDate == Date(timeIntervalSince1970: 100))
    }

    @Test
    func eventMatchedByBothSignalsAppearsExactlyOnce() throws {
        // One event satisfying BOTH the email and location needles must not be
        // emitted twice through the union.
        let spy = AttendeeIndexFetchSpy(events: [
            event(ekid: "dual", start: 100, location: "1 Infinite Loop, Cupertino", emails: ["a@x.com"]),
        ])
        let adapter = makeAdapter(spy: spy)

        let result = try adapter.eventsWithAttendee(
            matchingEmails: ["a@x.com"], orLocations: ["1 Infinite Loop"], in: window(), limit: 10
        )
        #expect(result.map(\.eventKitID) == ["dual"])
    }

    // MARK: - Invalidation

    @Test
    func eventStoreChangedRebuildsIndexWithFreshData() throws {
        let center = NotificationCenter()
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "before", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(center: center, spy: spy)
        let w = window()

        let first = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)
        #expect(first.map(\.eventKitID) == ["before"])

        center.post(name: .EKEventStoreChanged, object: nil)
        spy.events = [event(ekid: "after", start: 200, emails: ["a@x.com"])]

        let fresh = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 2)
        #expect(fresh.map(\.eventKitID) == ["after"])
    }

    @Test
    func appInitiatedWriteInvalidatesIndexThroughSharedHook() throws {
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "before", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(spy: spy)
        let w = window()

        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)

        // Stand-in for createEvent/updateEvent, which drive the very same
        // invalidateCaches hook this seam calls.
        adapter.invalidateAfterWriteForTesting()
        spy.events = [event(ekid: "after", start: 200, emails: ["a@x.com"])]

        let fresh = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 2)
        #expect(fresh.map(\.eventKitID) == ["after"])
    }

    @Test
    func authorizationTransitionsInvalidateAndDeniedBypassesCache() throws {
        let authorization = AuthorizationStatusBox(.authorized)
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(authorization: { authorization.value }, spy: spy)
        let w = window()

        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)

        // Denied: each call bypasses the cache (walks) and caches nothing.
        authorization.value = .denied
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 3)

        // Restoring access is a transition too, so the next read is a fresh
        // build that then caches again.
        authorization.value = .authorized
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 4)
    }

    @Test
    func authorizationTransitionInvalidatesBothWindowAndAttendeeCachesTogether() throws {
        // Centralized transition tracking must clear BOTH caches on one edge, so
        // the non-expiring attendee index can never be left stale while the
        // window cache is refreshed (or vice versa).
        let auth = AuthorizationStatusBox(.authorized)
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(authorization: { auth.value }, spy: spy)
        let w = window()

        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)  // attendee walk
        _ = try adapter.fetchEvents(in: w)                                                 // window walk
        #expect(spy.fetchCount == 2)
        // Both are now cached — repeat reads add no walks.
        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        _ = try adapter.fetchEvents(in: w)
        #expect(spy.fetchCount == 2)

        // One observed transition (revoke then re-grant) must invalidate BOTH.
        adapter.observeAuthorizationForTesting(.denied)
        adapter.observeAuthorizationForTesting(.authorized)

        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)  // attendee re-walk
        #expect(spy.fetchCount == 3)
        _ = try adapter.fetchEvents(in: w)                                                 // window re-walk
        #expect(spy.fetchCount == 4)   // == 3 would mean only one cache was cleared
    }

    @Test
    func interleavedDifferingAuthObservationsNeverLeaveAttendeeCacheStale() throws {
        // Hammer the centralized detector with concurrent, differing,
        // interleaved authorization observations on dedicated threads. The
        // single serialized baseline must stay thread-safe and every observed
        // edge must invalidate the (non-expiring) attendee cache, so the
        // authorized index built beforehand cannot survive the churn.
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(spy: spy)
        let w = window()

        _ = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)

        let threadCount = 8
        let iterations = 300
        let churn = (0..<threadCount).map { index in
            BlockingFuture<Void> {
                for i in 0..<iterations {
                    let status: StoreAuthorizationStatus = ((i + index) % 2 == 0) ? .authorized : .denied
                    adapter.observeAuthorizationForTesting(status)
                }
            }
        }
        for future in churn { try future.value() }

        // A .denied edge definitely occurred after the cache was built (so it
        // was cleared), and no lookup ran during the churn to repopulate it.
        // Settle to authorized and read: the lookup must re-walk.
        adapter.observeAuthorizationForTesting(.authorized)
        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 2)
        #expect(result.map(\.eventKitID) == ["e1"])
    }

    @Test
    func invalidationDuringBuildDiscardsRacedIndexAndRetriesFresh() throws {
        let center = NotificationCenter()
        let spy = AttendeeIndexFetchSpy(
            events: [event(ekid: "old", start: 100, emails: ["a@x.com"])],
            blockFirstFetch: true
        )
        let adapter = makeAdapter(center: center, spy: spy)
        let w = window()

        let preChange = blockingLookup(adapter, emails: ["a@x.com"], window: w)
        #expect(spy.waitForFetchCount(1))

        center.post(name: .EKEventStoreChanged, object: nil)
        spy.events = [event(ekid: "new", start: 200, emails: ["a@x.com"])]
        let postChange = blockingLookup(adapter, emails: ["a@x.com"], window: w)
        #expect(spy.waitForFetchCount(2))

        spy.releaseFirstFetch()
        let preResult = try preChange.value()
        let postResult = try postChange.value()

        // The gen-1 "old" build finished after invalidation, so it was
        // discarded; its caller retried and joined/used the gen-2 build. No
        // caller sees pre-change data.
        #expect(spy.fetchCount == 2)
        #expect(preResult.map(\.eventKitID) == ["new"])
        #expect(postResult.map(\.eventKitID) == ["new"])
    }

    @Test
    func invalidateCachesAtomicallyBlocksLookupFromServingPreInvalidationSnapshot() throws {
        // FIX 2: the raw window cache and the non-expiring attendee index share
        // ONE lock + generation, so `invalidateCaches` clears BOTH inside a
        // single critical section. A lookup racing an in-progress invalidation
        // must never slip between the two clears and serve a pre-invalidation
        // attendee snapshot; it blocks on the shared lock and, once invalidation
        // completes, rebuilds against fresh data.
        //
        // The interpose runs WHILE the shared lock is held — after both caches
        // are cleared and the generation bumped, before the lock is released. A
        // split-lock design would already have cleared the window cache while
        // leaving the attendee index readable AND unlocked, so the racing lookup
        // would hit the stale "before" entry and return it without rebuilding.
        // The atomic design parks that lookup on the one shared lock until
        // invalidation finishes, then forces a fresh rebuild.
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "before", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(spy: spy)
        let w = window()

        // Seed the attendee index (one walk; "before" cached). This also
        // establishes the .authorized baseline, so the racing lookup's own
        // authorization read below is a no-op edge and never re-invalidates.
        let seeded = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)
        #expect(seeded.map(\.eventKitID) == ["before"])

        // Swap the underlying data so any rebuild yields "after".
        spy.events = [event(ekid: "after", start: 200, emails: ["a@x.com"])]

        // The interpose runs on THIS thread, synchronously, while the shared
        // lock is held. It launches the racing lookup on a dedicated thread and
        // gives it ample time to reach the attendee cache.
        var racing: BlockingFuture<[Event]>?
        var completedWhileLockHeld = true
        var fetchCountWhileLockHeld = -1
        adapter.invalidateCachesWithInterposeForTesting {
            let future = blockingLookup(adapter, emails: ["a@x.com"], window: w)
            racing = future
            // The racing lookup is parked on the shared lock we still hold here,
            // so under the atomic design it can neither complete nor start a
            // rebuild no matter how long we wait.
            Thread.sleep(forTimeInterval: 0.2)
            completedWhileLockHeld = future.hasCompleted
            fetchCountWhileLockHeld = spy.fetchCount
        }

        // While the shared lock was held, the racing lookup could neither
        // complete (a split-lock design would have completed here with stale
        // data) nor trigger a rebuild — it was blocked on that one lock.
        #expect(completedWhileLockHeld == false)
        #expect(fetchCountWhileLockHeld == 1)

        // Once invalidation released the shared lock, the lookup missed the
        // cleared cache and rebuilt against fresh data — never the "before"
        // snapshot.
        let future = try #require(racing)
        let result = try future.value()
        #expect(result.map(\.eventKitID) == ["after"])
        #expect(spy.fetchCount == 2)
    }

    // MARK: - Warm-up

    @Test
    func prepareWarmsCacheSoFirstLookupHitsWithoutASecondWalk() throws {
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(spy: spy)
        let w = window()

        try adapter.prepareEventsWithAttendeeIndex(in: w)
        #expect(spy.fetchCount == 1)

        // The real lookup over the identical window is now a cache hit.
        let result = try adapter.eventsWithAttendee(matchingEmails: ["a@x.com"], in: w, limit: 10)
        #expect(spy.fetchCount == 1)
        #expect(result.map(\.eventKitID) == ["e1"])
    }

    @Test
    func prepareWhenDeniedWarmsNothing() throws {
        let spy = AttendeeIndexFetchSpy(events: [event(ekid: "e1", start: 100, emails: ["a@x.com"])])
        let adapter = makeAdapter(authorization: { .denied }, spy: spy)
        let w = window()

        // Non-authorized warm-up neither walks nor caches.
        try adapter.prepareEventsWithAttendeeIndex(in: w)
        #expect(spy.fetchCount == 0)
    }
}

/// Thread-safe fake for the injected raw window walk. Returns a configurable
/// event batch, counts invocations, snapshots the batch at ENTRY (so a swap
/// between two gated calls yields deterministically different results), and can
/// park its first invocation for single-flight / race tests.
private final class AttendeeIndexFetchSpy: @unchecked Sendable {
    private let condition = NSCondition()
    private let blockFirstFetch: Bool
    private var firstFetchReleased = false
    private var _events: [Event]
    private var _fetchCount = 0
    private var _intervals: [DateInterval] = []

    init(events: [Event], blockFirstFetch: Bool = false) {
        self._events = events
        self.blockFirstFetch = blockFirstFetch
    }

    func fetch(interval: DateInterval) -> [Event] {
        condition.lock()
        _fetchCount += 1
        let invocation = _fetchCount
        _intervals.append(interval)
        // Snapshot before parking so a later `events =` swap can't retroactively
        // change what an already-entered call returns.
        let snapshot = _events
        condition.broadcast()
        while blockFirstFetch && invocation == 1 && !firstFetchReleased {
            condition.wait()
        }
        condition.unlock()
        return snapshot
    }

    var events: [Event] {
        get {
            condition.lock()
            defer { condition.unlock() }
            return _events
        }
        set {
            condition.lock()
            _events = newValue
            condition.unlock()
        }
    }

    var fetchCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return _fetchCount
    }

    var intervals: [DateInterval] {
        condition.lock()
        defer { condition.unlock() }
        return _intervals
    }

    func waitForFetchCount(_ expected: Int) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        condition.lock()
        defer { condition.unlock() }
        while _fetchCount < expected {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseFirstFetch() {
        condition.lock()
        firstFetchReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A future whose blocking work runs on a DEDICATED OS thread spawned at
/// construction — not the Swift cooperative pool and not a libdispatch worker.
/// Under the full parallel test suite both of those user-space pools get
/// exhausted by every suite's thread-blocking concurrency tests, so work queued
/// onto them can stall past a short deadline. A raw `Thread` is scheduled by the
/// kernel immediately and independently, so the gated `eventsWithAttendee` here
/// always starts promptly. `value()` blocks the caller until the work finishes.
private final class BlockingFuture<T: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, Error>?

    init(_ work: @escaping @Sendable () throws -> T) {
        let thread = Thread { [self] in
            let outcome = Result(catching: work)
            condition.lock()
            result = outcome
            condition.broadcast()
            condition.unlock()
        }
        thread.name = "attendee-index-test-blocking-future"
        thread.start()
    }

    func value() throws -> T {
        condition.lock()
        while result == nil { condition.wait() }
        let outcome = result!
        condition.unlock()
        return try outcome.get()
    }

    /// Non-blocking peek: has the work finished? Lock-guarded so it is safe to
    /// call from another thread while the work is still running.
    var hasCompleted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return result != nil
    }
}

/// Mutable authorization source for transition tests.
private final class AuthorizationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: StoreAuthorizationStatus

    init(_ status: StoreAuthorizationStatus) {
        self.status = status
    }

    var value: StoreAuthorizationStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
        set {
            lock.lock()
            status = newValue
            lock.unlock()
        }
    }
}
#endif
