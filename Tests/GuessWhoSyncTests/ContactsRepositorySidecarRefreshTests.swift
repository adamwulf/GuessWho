import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// The sidecar-change refresh path on `ContactsRepository`
/// (`.guessWhoSidecarsDidChange` → debounce → `refreshFromSidecarChange`).
///
/// Covers FIX D (among the kinds with no scoped projection, ONLY `.group` — a
/// favorite-identity record — escalates to the full sidecar-derived refresh and
/// posts; an event/guide/place-only change names no kind this repository
/// projects and is dropped as a relevance no-op — zero projection work, no
/// post — mirroring `EventsRepository`. Mixed sets still process their relevant
/// kinds, and `.group` subsumes any `.contact`/`.link` alongside it with a full
/// refresh), FIX C (a scoped projection refresh re-checks its generation after
/// the timestamp read and before issuing the combined link scan, so a refresh
/// superseded mid-walk does not fire that remaining scan), and FIX 1 (a monotonic
/// refresh generation advanced whenever a refresh is SCHEDULED — every
/// notification and every `reload()` — so a newly scheduled refresh immediately
/// supersedes older in-flight ones: a superseded refresh applies no projection
/// state and posts nothing, only the latest pending task drains the merged key
/// set, and a direct `reload()` both supersedes and cancels the pending
/// debounced work it subsumes. The debounce and contact-delta scoping are
/// preserved).
///
/// Every test drives the REAL engine over an in-memory sidecar store: an
/// "external" change is seeded by writing straight through `sync` (as another
/// device would), so the repository's cache is genuinely stale until a refresh
/// re-reads it. Timing relies only on the production 300 ms debounce.
@Suite("ContactsRepository sidecar refresh")
@MainActor
struct ContactsRepositorySidecarRefreshTests {
    /// Comfortably longer than the repository's private 300 ms sidecar-refresh
    /// debounce, used to confirm that NO further post arrives after the one we
    /// awaited (the coalescing / supersede cases).
    private static let beyondDebounce: Duration = .milliseconds(500)

    private func makeSync(_ store: InMemoryContactStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
    }

    /// Variant that threads a specific sidecar store so a test can wrap it in a
    /// `ScanCountingSidecarStore` and count projection scans deterministically.
    private func makeSync(
        _ store: InMemoryContactStore,
        sidecars: SidecarStoreProtocol
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }

    /// A reconciled contact carrying an all-lowercase GuessWho UUID, so its
    /// canonical `guessWhoID` equals `uuid` verbatim and a `SidecarKey` built
    /// from the same `uuid` addresses its cells.
    private func reconciled(localID: String, uuid: String, given: String) -> Contact {
        Contact(
            localID: localID,
            givenName: given,
            urlAddresses: [
                LabeledValue(label: "g", value: "\(SidecarKey.guessWhoContactURLPrefix)\(uuid)")
            ]
        )
    }

    /// Post a sidecar change and wait, up to `timeout`, for the repository's
    /// next `.contactsRepositoryDidReload` (the debounced refresh completing).
    /// Returns whether it arrived, so a caller can assert it did — a dropped
    /// refresh then fails cleanly instead of hanging the test. All state is
    /// touched on the main actor; `nonisolated(unsafe)` is safe here.
    @discardableResult
    private func postAndAwaitReload(
        _ changeSet: SidecarChangeSet,
        center: NotificationCenter,
        repo: ContactsRepository,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        nonisolated(unsafe) var fired = false
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { _ in fired = true }
        defer { center.removeObserver(token) }

        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: changeSet]
        )

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !fired && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fired
    }

    // MARK: - FIX D: `.group` escalates to a full refresh; other unscopable
    // kinds are dropped as a relevance no-op.

    @Test
    func groupOnlyChange_runsFullRefreshAndReorders() async throws {
        // Two reconciled people, no timestamps yet → under .lastViewed they tie
        // and sort alphabetically (Amy before Zoe).
        let amy = reconciled(localID: "amy", uuid: "aaaaaaaa-0000-0000-0000-000000000001", given: "Amy")
        let zoe = reconciled(localID: "zoe", uuid: "aaaaaaaa-0000-0000-0000-000000000002", given: "Zoe")
        let store = InMemoryContactStore(contacts: [amy, zoe])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed
        #expect(repo.people.map(\.localID) == ["amy", "zoe"])

        // Externally view Zoe — written straight through the engine, so the
        // repository's cache is stale and the order has not moved yet.
        try sync.stampContactTimestamp(
            .viewed,
            at: SidecarKey(kind: .contact, id: "aaaaaaaa-0000-0000-0000-000000000002"),
            now: Date()
        )
        #expect(repo.people.map(\.localID) == ["amy", "zoe"])

        // A change naming ONLY a `.group` favorite-identity key has no scoped
        // projection; FIX D escalates it to the full sidecar-derived refresh, so
        // the wholesale timestamp re-read picks up Zoe's view and reorders her
        // ahead — and it must not be silently dropped.
        let posted = await postAndAwaitReload(
            SidecarChangeSet(changedKeys: [SidecarKey(kind: .group, id: "dddddddd-0000-0000-0000-000000000001")]),
            center: center,
            repo: repo
        )

        #expect(posted)   // the group refresh must not be silently dropped
        #expect(repo.people.map(\.localID) == ["zoe", "amy"])
    }

    @Test(arguments: [SidecarKind.event, .guide, .place])
    func irrelevantKindOnlyChange_doesZeroProjectionWorkAndPostsNothing(
        _ kind: SidecarKind
    ) async throws {
        // Two reconciled people; under .lastViewed they tie → alphabetical.
        let amy = reconciled(localID: "amy", uuid: "eeeeeeee-0000-0000-0000-000000000001", given: "Amy")
        let zoe = reconciled(localID: "zoe", uuid: "eeeeeeee-0000-0000-0000-000000000002", given: "Zoe")
        let store = InMemoryContactStore(contacts: [amy, zoe])
        let counting = ScanCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(store, sidecars: counting)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed
        #expect(repo.people.map(\.localID) == ["amy", "zoe"])

        // Externally view Zoe. A FULL sidecar-derived refresh WOULD pick this up
        // and reorder her ahead; a correctly-dropped irrelevant change must not.
        try sync.stampContactTimestamp(
            .viewed,
            at: SidecarKey(kind: .contact, id: "eeeeeeee-0000-0000-0000-000000000002"),
            now: Date()
        )

        // Baseline the projection-scan counters AFTER reload + the external
        // stamp, so the delta measures only work the notification triggers.
        let scansBefore = counting.scanCount

        // A change naming ONLY an event/guide/place key names no kind this
        // repository projects. It must be dropped before any scan or post.
        nonisolated(unsafe) var fired = false
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { _ in fired = true }
        defer { center.removeObserver(token) }

        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: [SidecarKey(kind: kind, id: "ffffffff-0000-0000-0000-000000000001")])]
        )
        try await Task.sleep(for: Self.beyondDebounce)

        // Deterministic work proof: NOT a single projection scan (allKeys/read)
        // ran for this change, and no reload posted. The stale order stands.
        #expect(counting.scanCount == scansBefore)
        #expect(!fired)
        #expect(repo.people.map(\.localID) == ["amy", "zoe"])
    }

    @Test
    func groupOnlyChange_postsPresentationOnlyReload() async throws {
        // The group-only refresh must post `.contactsRepositoryDidReload` with
        // contactDataChanged == false (no contact RECORD moved), matching the
        // full sidecar-derived refresh contract.
        let target = reconciled(localID: "t", uuid: "bbbbbbbb-0000-0000-0000-000000000001", given: "Tess")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()

        nonisolated(unsafe) var flags: [Bool] = []
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { note in
            flags.append((note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true)
        }
        defer { center.removeObserver(token) }

        await postAndAwaitReload(
            SidecarChangeSet(changedKeys: [SidecarKey(kind: .group, id: "cccccccc-0000-0000-0000-000000000001")]),
            center: center,
            repo: repo
        )
        try await Task.sleep(for: Self.beyondDebounce)

        #expect(flags == [false])
    }

    @Test
    func mixedContactAndIrrelevantKind_refreshesOnlyNamedContactNoFullRefresh() async throws {
        // A set mixing a relevant `.contact` key with an irrelevant `.guide`
        // key must process the contact scope and IGNORE the guide — NOT escalate
        // to a full refresh. Proven by an external view on an UNNAMED contact
        // that a full refresh would surface but a correctly-scoped delta won't.
        let anna = reconciled(localID: "a", uuid: "aabbccdd-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "aabbccdd-0000-0000-0000-000000000002", given: "Bob")
        let cara = reconciled(localID: "c", uuid: "aabbccdd-0000-0000-0000-000000000003", given: "Cara")
        let store = InMemoryContactStore(contacts: [anna, bob, cara])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "aabbccdd-0000-0000-0000-000000000002"), now: base)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "aabbccdd-0000-0000-0000-000000000003"), now: base.addingTimeInterval(10))

        await postAndAwaitReload(
            SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .contact, id: "aabbccdd-0000-0000-0000-000000000002"),
                SidecarKey(kind: .guide, id: "12121212-0000-0000-0000-000000000001"),
            ]),
            center: center,
            repo: repo
        )

        // Only Bob (named) surfaced; Cara's newer on-disk view was NOT pulled in,
        // so the change stayed scoped — the guide key forced no full refresh.
        #expect(repo.people.map(\.localID) == ["b", "a", "c"])
    }

    @Test
    func mixedGroupAndContact_runsFullRefreshSubsumingScopedKeys() async throws {
        // A set mixing a `.group` key with a scoped `.contact` key escalates to a
        // full refresh that SUBSUMES the scoped key. Proven by an external view on
        // an UNNAMED contact that only a full refresh would surface.
        let anna = reconciled(localID: "a", uuid: "abababab-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "abababab-0000-0000-0000-000000000002", given: "Bob")
        let cara = reconciled(localID: "c", uuid: "abababab-0000-0000-0000-000000000003", given: "Cara")
        let store = InMemoryContactStore(contacts: [anna, bob, cara])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "abababab-0000-0000-0000-000000000002"), now: base)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "abababab-0000-0000-0000-000000000003"), now: base.addingTimeInterval(10))

        // Name only Bob among the contacts, plus a group key. The full refresh the
        // group forces re-reads EVERY timestamp, so Cara's newer view surfaces her
        // ahead of Bob even though she was never named.
        await postAndAwaitReload(
            SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .contact, id: "abababab-0000-0000-0000-000000000002"),
                SidecarKey(kind: .group, id: "34343434-0000-0000-0000-000000000001"),
            ]),
            center: center,
            repo: repo
        )

        // Cara (newest view) ahead of Bob → the group escalated to a full refresh.
        #expect(repo.people.map(\.localID) == ["c", "b", "a"])
    }

    // MARK: - Delta scoping preserved (no spurious full refresh)

    @Test
    func contactOnlyChange_refreshesOnlyNamedContact() async throws {
        // Three reconciled people, alphabetical Anna/Bob/Cara.
        let anna = reconciled(localID: "a", uuid: "11111111-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "11111111-0000-0000-0000-000000000002", given: "Bob")
        let cara = reconciled(localID: "c", uuid: "11111111-0000-0000-0000-000000000003", given: "Cara")
        let store = InMemoryContactStore(contacts: [anna, bob, cara])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        // Externally view Bob AND Cara, Cara MORE recently. A full refresh would
        // surface both (Cara ahead of Bob); a correctly-scoped contact delta
        // naming only Bob must surface Bob alone and ignore Cara's newer view.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "11111111-0000-0000-0000-000000000002"), now: base)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "11111111-0000-0000-0000-000000000003"), now: base.addingTimeInterval(10))

        await postAndAwaitReload(
            SidecarChangeSet(changedKeys: [SidecarKey(kind: .contact, id: "11111111-0000-0000-0000-000000000002")]),
            center: center,
            repo: repo
        )

        // Bob (viewed) first; Anna and Cara still read as unviewed in the cache
        // → alphabetical. Cara's newer on-disk view was NOT pulled in.
        #expect(repo.people.map(\.localID) == ["b", "a", "c"])
    }

    // MARK: - Debounce + merged-set ownership

    @Test
    func rapidContactChanges_coalesceIntoOneScopedRefresh() async throws {
        // Anna/Bob/Cara again; this time view all three externally, Cara newest.
        let anna = reconciled(localID: "a", uuid: "22222222-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "22222222-0000-0000-0000-000000000002", given: "Bob")
        let cara = reconciled(localID: "c", uuid: "22222222-0000-0000-0000-000000000003", given: "Cara")
        let store = InMemoryContactStore(contacts: [anna, bob, cara])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "22222222-0000-0000-0000-000000000001"), now: base.addingTimeInterval(10))
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "22222222-0000-0000-0000-000000000002"), now: base.addingTimeInterval(20))
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "22222222-0000-0000-0000-000000000003"), now: base.addingTimeInterval(30))

        // Count every reload; resume once the first arrives.
        nonisolated(unsafe) var flags: [Bool] = []
        nonisolated(unsafe) var continuation: CheckedContinuation<Void, Never>?
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { note in
            flags.append((note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true)
            continuation?.resume()
            continuation = nil
        }
        defer { center.removeObserver(token) }

        // Two scoped bursts posted back-to-back (before the debounce elapses):
        // Anna, then Bob. They must COALESCE — the merged {Anna, Bob} set is
        // consumed by the single trailing task, producing exactly one refresh.
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: [SidecarKey(kind: .contact, id: "22222222-0000-0000-0000-000000000001")])
        ])
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: [SidecarKey(kind: .contact, id: "22222222-0000-0000-0000-000000000002")])
        ])

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in continuation = c }
        try await Task.sleep(for: Self.beyondDebounce)

        // Exactly one presentation-only reload for the coalesced burst.
        #expect(flags == [false])
        // Both named contacts refreshed (Bob newer than Anna → Bob first), Cara
        // was NOT named so her newer view stays out of the cache: the merged set
        // stayed SCOPED (no spurious escalation to a full refresh) → Cara last.
        #expect(repo.people.map(\.localID) == ["b", "a", "c"])
    }

    // MARK: - Sidecar-only projection never re-fetches Contacts

    @Test
    func fullSidecarRefresh_doesNotRefetchContacts() async throws {
        let anna = Contact(localID: "a", givenName: "Anna")
        let bob = Contact(localID: "b", givenName: "Bob")
        let store = InMemoryContactStore(contacts: [anna, bob])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        #expect(repo.contact(localID: "b") != nil)

        // Delete Bob straight from the store (no change notification reaches the
        // repository). A sidecar-derived refresh must project sidecars only — it
        // must NOT re-run the Contacts fetch — so the cached Bob survives.
        try await store.delete(localID: "b")
        await postAndAwaitReload(.fullRefresh, center: center, repo: repo)

        #expect(repo.contact(localID: "a") != nil)
        #expect(repo.contact(localID: "b") != nil)
    }

    // MARK: - FIX 1: schedule-time generation supersedes older running refreshes

    @Test
    func scheduleDuringInFlightReload_preservesContactReloadSignalAndDefersProjection() async throws {
        // A sidecar change SCHEDULED while a reload is in flight immediately
        // advances the token, superseding that reload. When the reload resumes
        // it must apply NO stale sidecar-derived state. Its freshly fetched
        // Contacts data still posts `contactDataChanged: true`; the debounced
        // delta then produces the fresh projection. (Requirement 1.)
        let zed = reconciled(localID: "z", uuid: "44444444-0000-0000-0000-000000000001", given: "Zed")
        let amy = reconciled(localID: "a", uuid: "44444444-0000-0000-0000-000000000002", given: "Amy")
        let inner = InMemoryContactStore(contacts: [zed, amy])
        let store = GatedFetchAllContactStore(inner)
        let sync = makeSync(inner)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()   // gate open (un-armed): normal pass-through
        repo.sortOrder = .lastViewed

        nonisolated(unsafe) var flags: [Bool] = []
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { note in
            flags.append((note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true)
        }
        defer { center.removeObserver(token) }

        // Park a reload in its Contacts fetch. WHILE it is parked, externally
        // view Zed (on disk) and schedule a sidecar change naming her. The
        // change advances the token; the reload is now superseded.
        await store.arm()
        let reloadTask = Task { @MainActor in await repo.reload() }
        await store.waitUntilEntered()
        try sync.stampContactTimestamp(
            .viewed,
            at: SidecarKey(kind: .contact, id: "44444444-0000-0000-0000-000000000001"),
            now: Date()
        )
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: [SidecarKey(kind: .contact, id: "44444444-0000-0000-0000-000000000001")])
        ])

        // Release the reload. It reads the sidecars fresh (Zed viewed) but, being
        // superseded, applies no projection — so the cache stays empty and the
        // order is the plain alphabetical [Amy, Zed]. Its Contacts fetch still
        // announces completion for cold-launch state restoration.
        await store.openGate()
        await reloadTask.value

        // The debounced delta has NOT fired yet (300 ms > the few ms above), so
        // this observes the reload's own outcome: no projection, but exactly its
        // contact-data completion signal.
        #expect(flags == [true])
        #expect(repo.people.map(\.localID) == ["a", "z"])
        #expect(!repo.isLoading)

        // Now let the queued delta run: it owns the token, applies the fresh
        // projection (Zed viewed → first) and posts exactly once.
        try await Task.sleep(for: Self.beyondDebounce)
        #expect(flags == [true, false])
        #expect(repo.people.map(\.localID) == ["z", "a"])
        #expect(!repo.isLoading) // the winning delta settled the load
    }

    @Test
    func scopedRefreshSupersedingRunningScopedRefreshKeepsBothContactKeys() async throws {
        let anna = reconciled(localID: "a", uuid: "66666666-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "66666666-0000-0000-0000-000000000002", given: "Bob")
        let cara = reconciled(localID: "c", uuid: "66666666-0000-0000-0000-000000000003", given: "Cara")
        let store = InMemoryContactStore(contacts: [anna, bob, cara])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        nonisolated(unsafe) var reloadCount = 0
        let observer = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { _ in reloadCount += 1 }
        defer { center.removeObserver(observer) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(
            .viewed,
            at: SidecarKey(kind: .contact, id: "66666666-0000-0000-0000-000000000001"),
            now: base.addingTimeInterval(20)
        )

        let gate = ContactsSidecarReadGate()
        repo.sidecarReadBarrierForTesting = { await gate.arriveAndWait() }
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .contact, id: "66666666-0000-0000-0000-000000000001")
            ])
        ])
        await gate.waitUntilReached()

        repo.sidecarReadBarrierForTesting = nil
        try sync.stampContactTimestamp(
            .viewed,
            at: SidecarKey(kind: .contact, id: "66666666-0000-0000-0000-000000000002"),
            now: base.addingTimeInterval(10)
        )
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .contact, id: "66666666-0000-0000-0000-000000000002")
            ])
        ])

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reloadCount == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        gate.release()
        try await Task.sleep(for: .milliseconds(20))

        #expect(reloadCount == 1)
        // With both keys inherited Anna's newer stamp wins. If her running key
        // is dropped, only Bob is stamped and the order becomes [Bob, Anna, Cara].
        #expect(repo.people.map(\.localID) == ["a", "b", "c"])
    }

    @Test
    func reloadStartedAfterPendingDelta_supersedesItAndPublishesFullProjection() async throws {
        // A scoped sidecar delta is queued, then a direct reload starts. The
        // reload advances the token AND cancels the pending debounced work it
        // subsumes, then publishes its OWN full fresh projection. The superseded
        // delta must produce nothing — no second, redundant refresh or post.
        // (Requirement 3.)
        let anna = reconciled(localID: "a", uuid: "55555555-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "55555555-0000-0000-0000-000000000002", given: "Bob")
        let cara = reconciled(localID: "c", uuid: "55555555-0000-0000-0000-000000000003", given: "Cara")
        let store = InMemoryContactStore(contacts: [anna, bob, cara])
        let sync = makeSync(store)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        // All three viewed externally, Cara newest — so a FULL projection orders
        // them Cara, Bob, Anna.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "55555555-0000-0000-0000-000000000001"), now: base.addingTimeInterval(10))
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "55555555-0000-0000-0000-000000000002"), now: base.addingTimeInterval(20))
        try sync.stampContactTimestamp(.viewed, at: SidecarKey(kind: .contact, id: "55555555-0000-0000-0000-000000000003"), now: base.addingTimeInterval(30))

        nonisolated(unsafe) var flags: [Bool] = []
        let token = center.addObserver(
            forName: .contactsRepositoryDidReload, object: repo, queue: nil
        ) { note in
            flags.append((note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true)
        }
        defer { center.removeObserver(token) }

        // Queue a SCOPED delta naming only Anna, let its trampoline schedule the
        // debounced task, then start a full reload that supersedes it.
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet:
                SidecarChangeSet(changedKeys: [SidecarKey(kind: .contact, id: "55555555-0000-0000-0000-000000000001")])
        ])
        try await Task.sleep(for: .milliseconds(20))
        await repo.reload()

        // Wait out the (now cancelled) delta's debounce window; it must stay
        // silent.
        try await Task.sleep(for: Self.beyondDebounce)

        // The reload published its FULL fresh projection (all three viewed →
        // Cara, Bob, Anna) and posted exactly once (contactDataChanged == true).
        // The superseded, cancelled delta neither refreshed nor posted.
        #expect(flags == [true])
        #expect(repo.people.map(\.localID) == ["c", "b", "a"])
    }

    // MARK: - B2-5: fused wholesale projection

    @Test
    func coldReloadEnumeratesOnceAndReadsEachContactAndLinkSidecarOnce() async throws {
        let annaUUID = "66666666-0000-0000-0000-000000000001"
        let zoeUUID = "66666666-0000-0000-0000-000000000002"
        let anna = reconciled(localID: "a", uuid: annaUUID, given: "Anna")
        let zoe = reconciled(localID: "z", uuid: zoeUUID, given: "Zoe")
        let store = InMemoryContactStore(contacts: [anna, zoe])
        let counting = ScanCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(store, sidecars: counting)

        // Seed timestamp envelopes before constructing/reloading the repository,
        // so its timestamp cache is genuinely cold. Zoe is newer despite
        // sorting after Anna alphabetically.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let annaKey = SidecarKey(kind: .contact, id: annaUUID)
        let zoeKey = SidecarKey(kind: .contact, id: zoeUUID)
        try sync.stampContactTimestamp(.viewed, at: annaKey, now: base)
        try sync.stampContactTimestamp(.viewed, at: zoeKey, now: base.addingTimeInterval(10))

        let live = try sync.addLink(from: annaKey, to: zoeKey, note: "live")
        let deleted = try sync.addLink(from: annaKey, to: zoeKey, note: "deleted")
        try sync.removeLink(id: deleted.id)
        let malformedID = UUID()
        let malformedKey = SidecarKey(kind: .link, id: malformedID.uuidString)
        try counting.write(
            SidecarEnvelope(entityID: malformedID.uuidString, fields: [:]),
            at: malformedKey
        )

        let allKeysBefore = counting.allKeysCount
        let readsBefore = counting.readCounts
        let totalReadsBefore = counting.readCount

        let repo = ContactsRepository(
            contacts: store,
            sync: sync,
            notificationCenter: NotificationCenter()
        )
        repo.sortOrder = .lastViewed
        await repo.reload()

        let relevantKeys = [
            annaKey,
            zoeKey,
            SidecarKey(kind: .link, id: live.id.uuidString),
            SidecarKey(kind: .link, id: deleted.id.uuidString),
            malformedKey,
        ]
        #expect(counting.allKeysCount == allKeysBefore + 1)
        #expect(counting.readCount == totalReadsBefore + relevantKeys.count)
        for key in relevantKeys {
            #expect(counting.readCounts[key, default: 0] == readsBefore[key, default: 0] + 1)
        }

        // Output proof from the cold load: timestamps were not skipped, the
        // live link feeds both membership and the badge count, and the deleted
        // and malformed links feed neither.
        #expect(repo.people.map(\.localID) == ["z", "a"])
        repo.peopleFilter = .linked
        #expect(Set(repo.people.map(\.localID)) == Set(["a", "z"]))
        #expect(repo.linkCount(for: anna) == 1)
        #expect(repo.linkCount(for: zoe) == 1)
    }

    // MARK: - FIX C: a refresh superseded mid-walk skips its later scans

    @Test
    func supersededScopedRefreshSkipsLaterLinkScans() async throws {
        // A scoped {contact, link} refresh starts. The barrier parks it AFTER its
        // scoped timestamp read but BEFORE the generation guard. While parked, a
        // newer {contact} change supersedes it. On resume, FIX C's guard right
        // after the timestamp scan bails BEFORE issuing the combined link-corpus
        // walk. Absent that guard the superseded refresh would still fire it,
        // only to no-op at its own guard — the wasted scan FIX C removes.
        let anna = reconciled(localID: "a", uuid: "77777777-0000-0000-0000-000000000001", given: "Anna")
        let bob = reconciled(localID: "b", uuid: "77777777-0000-0000-0000-000000000002", given: "Bob")
        let store = InMemoryContactStore(contacts: [anna, bob])
        let counting = ScanCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(store, sidecars: counting)
        let center = NotificationCenter()
        let repo = ContactsRepository(contacts: store, sync: sync, notificationCenter: center)
        await repo.reload()
        repo.sortOrder = .lastViewed

        // Count only the combined link-corpus walks; the scoped timestamp read
        // (`contactTimestamps(at:)`) reads named keys directly and never calls
        // `allKeys`.
        let allKeysBefore = counting.allKeysCount

        // Park the first ({contact:Anna, link}) refresh inside its timestamp scan.
        let gate = ContactsSidecarReadGate()
        repo.sidecarReadBarrierForTesting = { await gate.arriveAndWait() }
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .contact, id: "77777777-0000-0000-0000-000000000001"),
                SidecarKey(kind: .link, id: "99999999-0000-0000-0000-000000000001"),
            ])
        ])
        await gate.waitUntilReached()

        // While it is parked, a newer {contact:Bob} change supersedes it.
        repo.sidecarReadBarrierForTesting = nil
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .contact, id: "77777777-0000-0000-0000-000000000002")
            ])
        ])
        gate.release()

        // Let the first (superseded) refresh return and the newer one run.
        try await Task.sleep(for: Self.beyondDebounce)

        // The newer refresh INHERITS the link key (the in-flight handoff), so it
        // walks the link corpus exactly once (1 `allKeys`). Absent FIX C the
        // first, superseded refresh would ALSO have walked it → 2 total.
        // Exactly 1 proves the superseded refresh issued no link scan.
        #expect(counting.allKeysCount == allKeysBefore + 1)
    }
}

@MainActor
final class ContactsSidecarReadGate {
    private var reached = false
    private var released = false
    private var onReached: CheckedContinuation<Void, Never>?
    private var onRelease: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        reached = true
        onReached?.resume()
        onReached = nil
        guard !released else { return }
        await withCheckedContinuation { onRelease = $0 }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { onReached = $0 }
    }

    func release() {
        released = true
        onRelease?.resume()
        onRelease = nil
    }
}

/// Wraps an `InMemoryContactStore`, forwarding every call, but can PARK one
/// `fetchAll()` on demand so a test can hold a `reload()` mid-flight and drive a
/// deterministic interleaving against it. `arm()` primes the next `fetchAll` to
/// block; `waitUntilEntered()` resolves once it has parked; `openGate()` lets it
/// proceed. Un-armed, `fetchAll` passes straight through.
actor GatedFetchAllContactStore: ContactStoreProtocol {
    private let inner: InMemoryContactStore
    private var isArmed = false
    private var hasEntered = false
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    init(_ inner: InMemoryContactStore) { self.inner = inner }

    func arm() {
        isArmed = true
        hasEntered = false
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in entered = c }
    }

    func openGate() {
        isArmed = false
        gate?.resume()
        gate = nil
    }

    func fetchAll() async throws -> [Contact] {
        if isArmed {
            hasEntered = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in gate = c }
        }
        return try await inner.fetchAll()
    }

    func fetch(localID: String) async throws -> Contact? { try await inner.fetch(localID: localID) }
    func save(_ contact: Contact) async throws { try await inner.save(contact) }
    func delete(localID: String) async throws { try await inner.delete(localID: localID) }
    func fetchSources() async throws -> [ContactSource] { try await inner.fetchSources() }
    func sources(forContactLocalID localID: String) async throws -> [ContactSource] {
        try await inner.sources(forContactLocalID: localID)
    }
    func create(_ contact: Contact) async throws -> Contact { try await inner.create(contact) }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        await inner.contactsAuthorizationStatus()
    }
    func requestContactsAccess() async -> StoreAccessResult { await inner.requestContactsAccess() }
    func changes(since token: Data?) async throws -> ContactChangeSet { try await inner.changes(since: token) }
    func loadImageData(localID: String) async throws -> Data? { try await inner.loadImageData(localID: localID) }
    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await inner.loadThumbnailImageData(localID: localID)
    }
    func setImageData(localID: String, imageData: Data?) async throws {
        try await inner.setImageData(localID: localID, imageData: imageData)
    }
    func fetchAllGroups() async throws -> [ContactGroup] { try await inner.fetchAllGroups() }
    func fetchGroup(localID: String) async throws -> ContactGroup? { try await inner.fetchGroup(localID: localID) }
    func createGroup(name: String) async throws -> ContactGroup { try await inner.createGroup(name: name) }
    func renameGroup(localID: String, to name: String) async throws {
        try await inner.renameGroup(localID: localID, to: name)
    }
    func deleteGroup(localID: String) async throws { try await inner.deleteGroup(localID: localID) }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        try await inner.fetchMembers(ofGroup: groupLocalID)
    }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] {
        try await inner.fetchGroupMemberships(contactLocalID: contactLocalID)
    }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {
        try await inner.addMember(contactLocalID: contactLocalID, toGroup: groupLocalID)
    }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {
        try await inner.removeMember(contactLocalID: contactLocalID, fromGroup: groupLocalID)
    }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] {
        try await inner.fetchMemberLocalIDs(ofGroup: groupLocalID)
    }
}

/// Test-only sidecar store that forwards every call to an `InMemorySidecarStore`
/// while counting the reads a projection SCAN performs, so a test can prove
/// "zero projection work" (or "the later scans never fired") deterministically
/// rather than by timing.
///
/// - `allKeysCount` counts `allKeys()` — the corpus-walk primitive the fused
///   wholesale projection and the combined link-only projection begin with.
/// - `readCount` / `readCounts` count total/per-key `read(_:)` calls — every
///   scoped or wholesale envelope read.
/// - `scanCount` is their sum: the total projection-read work, which stays flat
///   when a change is dropped before any scan.
///
/// The async projection overloads run on `DispatchQueue.global`, so every
/// counter is guarded by an `NSLock`.
final class ScanCountingSidecarStore: SidecarStoreProtocol {
    private let inner: InMemorySidecarStore
    private let lock = NSLock()
    private var _allKeysCount = 0
    private var _readCount = 0
    private var _readCounts: [SidecarKey: Int] = [:]

    init(wrapping inner: InMemorySidecarStore) { self.inner = inner }

    var allKeysCount: Int { lock.lock(); defer { lock.unlock() }; return _allKeysCount }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }
    var readCounts: [SidecarKey: Int] { lock.lock(); defer { lock.unlock() }; return _readCounts }
    var scanCount: Int { lock.lock(); defer { lock.unlock() }; return _allKeysCount + _readCount }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        lock.lock()
        _readCount += 1
        _readCounts[key, default: 0] += 1
        lock.unlock()
        return try inner.read(key)
    }
    func allKeys() throws -> [SidecarKey] {
        lock.lock(); _allKeysCount += 1; lock.unlock()
        return try inner.allKeys()
    }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        try inner.write(envelope, at: key)
    }
    func delete(_ key: SidecarKey) throws { try inner.delete(key) }
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus { inner.downloadStatus(key) }
    func requestDownload(_ key: SidecarKey) throws { try inner.requestDownload(key) }
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws {
        try inner.writeBlob(data, blobId: blobId, for: key)
    }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? {
        try inner.readBlob(blobId: blobId, for: key)
    }
    func deleteBlob(blobId: String, for key: SidecarKey) throws {
        try inner.deleteBlob(blobId: blobId, for: key)
    }
    func blobIds(for key: SidecarKey) throws -> [String] { try inner.blobIds(for: key) }
}
