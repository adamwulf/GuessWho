import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

/// The monotonic refresh-generation contract for `EventsRepository` and
/// `GuidesRepository`: a scoped sidecar-change delta may only PATCH a complete
/// base, and a delta and a full reload must agree on the resulting set.
///
/// These drive the repositories the way the sidecar watcher does — post
/// `.guessWhoSidecarsDidChange` with a scoped `SidecarChangeSet` — over a real
/// filesystem sidecar store, then poll the published state (the repos schedule
/// their work in `Task`s and debounce it, so the assertions wait for it to
/// settle rather than racing it).
///
/// Each repository is built over a FRESH `NotificationCenter()` and every test
/// post lands on that same center. The test host is the real app, whose live
/// `SidecarFileWatcher` floods `.default`; without this isolation those posts
/// would keep bumping a test repo's generation and supersede its reads. The
/// injected center confines both the repo's observers and the test's posts to
/// the test — the same isolation `ContactsRepository` documents.
@MainActor
@Suite("Repository refresh generation")
struct RepositoryRefreshGenerationTests {
    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-refresh-gen-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeService(root: URL) -> SyncService {
        SyncService(
            contactsAdapter: RefreshGenContactStore(),
            eventsAdapter: RefreshGenEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
    }

    /// Poll `condition` on the main actor until it holds or `timeout` elapses,
    /// yielding between checks so the repositories' debounced `Task`s can run.
    ///
    /// The budget is deliberately generous: with the injected center the repo is
    /// isolated from the host's `.default` churn, but its reads still hop to the
    /// shared background queue that the real app saturates with corpus walks at
    /// launch, so a settle can take a few seconds even though nothing supersedes
    /// it.
    private func waitUntil(
        timeout: Duration = .seconds(20),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func postSidecarChange(_ keys: Set<SidecarKey>, on center: NotificationCenter) {
        center.post(
            name: .guessWhoSidecarsDidChange,
            object: nil,
            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: keys)]
        )
    }

    private func sampleGuideSnapshot(name: String) -> MapsGuideURL.Snapshot {
        MapsGuideURL.Snapshot(
            name: name,
            entries: [
                MapsGuideURL.Entry(mapsPlaceID: "ID-\(name)-1"),
                MapsGuideURL.Entry(mapsPlaceID: "ID-\(name)-2"),
            ]
        )
    }

    // MARK: - EventsRepository

    /// A scoped sidecar change that arrives BEFORE any full load has landed must
    /// upgrade to a full reload rather than patch an empty base — otherwise the
    /// list would show only the one named event and drop every other one.
    @Test
    func eventsScopedChangeBeforeFirstLoadRebuildsWholeList() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        let a = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "C", startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(300), isAllDay: false, location: nil
        )

        // A brand-new repository has never fully loaded.
        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)

        // Name ONLY event A; a partial delta would leave the list at one row.
        postSidecarChange([SidecarKey(kind: .event, id: a.uuidString)], on: center)

        await waitUntil { repository.events.count == 3 }
        #expect(repository.events.count == 3)
        #expect(Set(repository.events.map(\.title)) == ["A", "B", "C"])
    }

    /// After a full load, a scoped change that adds an event patches it in, and
    /// the delta result matches what a full reload produces.
    @Test
    func eventsScopedAddAgreesWithFullReload() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        _ = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.events.count == 2 }
        #expect(repository.events.count == 2)

        // Add a third event, then announce just its key.
        let c = try service.createManualEvent(
            title: "C", startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(300), isAllDay: false, location: nil
        )
        postSidecarChange([SidecarKey(kind: .event, id: c.uuidString)], on: center)

        await waitUntil { repository.events.count == 3 }
        let afterDelta = Set(repository.events.map(\.id))
        #expect(afterDelta.contains(c))
        #expect(afterDelta.count == 3)

        // A full reload settles to the same set the delta produced.
        await repository.reload()
        await waitUntil { repository.events.count == 3 }
        #expect(Set(repository.events.map(\.id)) == afterDelta)
    }

    // MARK: - GuidesRepository

    /// The guides twin of `eventsScopedChangeBeforeFirstLoadRebuildsWholeList`:
    /// a scoped change ahead of the first full load rebuilds the whole
    /// projection instead of stranding a one-guide list.
    @Test
    func guidesScopedChangeBeforeFirstLoadRebuildsWholeList() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let g1 = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)
        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)

        postSidecarChange([SidecarKey(kind: .guide, id: g1.uuidString)], on: center)

        await waitUntil { repository.guides.count == 2 }
        #expect(repository.guides.count == 2)
        #expect(Set(repository.guides.map(\.name)) == ["Berlin", "Lisbon"])
    }

    /// After a full load, a scoped change that adds a guide patches it in, and
    /// the delta result matches a full reload.
    @Test
    func guidesScopedAddAgreesWithFullReload() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.guides.count == 1 }
        #expect(repository.guides.count == 1)

        let g2 = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)
        postSidecarChange([SidecarKey(kind: .guide, id: g2.uuidString)], on: center)

        await waitUntil { repository.guides.count == 2 }
        let afterDelta = Set(repository.guides.map(\.id))
        #expect(afterDelta.contains(g2))
        #expect(afterDelta.count == 2)

        await repository.reload()
        await waitUntil { repository.guides.count == 2 }
        #expect(Set(repository.guides.map(\.id)) == afterDelta)
    }

    // MARK: - Reentrancy: direct reload supersedes pending work

    /// A scoped change is pending (debounce scheduled) when a direct reload
    /// arrives. The direct reload's full read subsumes the pending delta, so it
    /// cancels and clears it: the list settles once to the full-reload result,
    /// and the superseded debounce never fires a delayed second refresh.
    @Test
    func eventsDirectReloadSupersedesPendingScopedChange() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        _ = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.events.count == 2 }

        let counter = ReloadPostCounter(.eventsRepositoryDidReload, on: center)
        counter.reset()

        // A third event exists, and a scoped change naming it is already pending.
        let c = try service.createManualEvent(
            title: "C", startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(300), isAllDay: false, location: nil
        )
        // Establish the pending debounce synchronously (the notification path's
        // Task hop would make the ordering nondeterministic).
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .event, id: c.uuidString)]))

        // The direct reload must cancel + clear that pending work.
        await repository.reload()

        // Wait well past the debounce; the cancelled task must NOT fire.
        try await Task.sleep(for: .milliseconds(600))

        #expect(counter.count == 1)                       // exactly one post
        #expect(repository.events.count == 3)             // one final state
        #expect(Set(repository.events.map(\.title)) == ["A", "B", "C"])
    }

    /// The guides twin: a pending scoped change is superseded by a direct reload,
    /// which posts exactly once with no delayed refresh.
    @Test
    func guidesDirectReloadSupersedesPendingScopedChange() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.guides.count == 1 }

        let counter = ReloadPostCounter(.guidesRepositoryDidReload, on: center)
        counter.reset()

        let g2 = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .guide, id: g2.uuidString)]))

        await repository.reload()

        try await Task.sleep(for: .milliseconds(600))

        #expect(counter.count == 1)
        #expect(repository.guides.count == 2)
        #expect(Set(repository.guides.map(\.name)) == ["Berlin", "Lisbon"])
    }

    // MARK: - Reentrancy: an older read cannot overwrite a newer refresh

    /// An older full read is held mid-flight (after its read, before it
    /// publishes) while a newer reload — over changed data — completes. When the
    /// older read is released it must discard, so the newer result stands.
    @Test
    func eventsOlderReadCannotOverwriteNewerRefresh() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        _ = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.events.count == 2 }

        // Hold the NEXT read after it finishes reading but before it publishes.
        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }

        // Start the older read; it reads {A,B} then parks at the gate.
        let older = Task { await repository.reload() }
        await gate.waitUntilReached()

        // Let the newer read run unhindered, over changed data.
        repository.readBarrierForTesting = nil
        let c = try service.createManualEvent(
            title: "C", startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(300), isAllDay: false, location: nil
        )
        _ = c
        await repository.reload()
        await waitUntil { repository.events.count == 3 }

        // Release the older read; its stale {A,B} snapshot must not win.
        gate.release()
        await older.value

        #expect(repository.events.count == 3)
        #expect(Set(repository.events.map(\.title)) == ["A", "B", "C"])
    }

    /// The guides twin: an older read held past its data read cannot overwrite a
    /// newer reload's result.
    @Test
    func guidesOlderReadCannotOverwriteNewerRefresh() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.guides.count == 1 }

        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }

        let older = Task { await repository.reload() }
        await gate.waitUntilReached()

        repository.readBarrierForTesting = nil
        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)
        await repository.reload()
        await waitUntil { repository.guides.count == 2 }

        gate.release()
        await older.value

        #expect(repository.guides.count == 2)
        #expect(Set(repository.guides.map(\.name)) == ["Berlin", "Lisbon"])
    }

    // MARK: - Reentrancy: a newer scoped refresh inherits running scoped keys

    /// A second scoped change can arrive after the first task consumed its keys
    /// but before that task publishes. Superseding the first token discards its
    /// snapshot, so the successor must own both disjoint key sets.
    @Test
    func eventsScopedRefreshSupersedingRunningScopedRefreshKeepsBothKeys() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)
        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload() // establish a complete, empty base

        let now = Date()
        let a = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [
            SidecarKey(kind: .event, id: a.uuidString)
        ]))
        await gate.waitUntilReached() // A's task consumed its set and read A

        repository.readBarrierForTesting = nil
        let b = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [
            SidecarKey(kind: .event, id: b.uuidString)
        ]))

        await waitUntil { repository.events.count == 2 }
        gate.release()
        try await Task.sleep(for: .milliseconds(20))

        #expect(Set(repository.events.map(\.title)) == ["A", "B"])
    }

    /// Guides equivalent of the running-scoped handoff. Without inherited
    /// ownership, the parked Berlin addition is discarded and only Lisbon is
    /// ever published.
    @Test
    func guidesScopedRefreshSupersedingRunningScopedRefreshKeepsBothKeys() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)
        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()

        let berlin = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)
        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [
            SidecarKey(kind: .guide, id: berlin.uuidString)
        ]))
        await gate.waitUntilReached()

        repository.readBarrierForTesting = nil
        let lisbon = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [
            SidecarKey(kind: .guide, id: lisbon.uuidString)
        ]))

        await waitUntil { repository.guides.count == 2 }
        gate.release()
        try await Task.sleep(for: .milliseconds(20))

        #expect(Set(repository.guides.map(\.name)) == ["Berlin", "Lisbon"])
    }

    // MARK: - Reentrancy: a delta that supersedes a loading reload settles isLoading

    /// The reported production race: an older reload set `isLoading = true` then
    /// aborts on its stale token, while a scheduled scoped change supersedes it
    /// and publishes. The superseding change must settle `isLoading = false` —
    /// otherwise the repository stays loading forever. (Under FIX A the parked
    /// reload holds `.fullRefresh` ownership, so the scoped change inherits it
    /// and publishes via a full read; either way it must settle loading.)
    @Test
    func eventsDeltaSupersedingLoadingReloadSettlesIsLoading() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        _ = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.events.count == 2 }

        let counter = ReloadPostCounter(.eventsRepositoryDidReload, on: center)
        counter.reset()

        // Park an OLDER reload after its stale read — `isLoading` is now true.
        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        let older = Task { await repository.reload() }
        await gate.waitUntilReached()
        #expect(repository.isLoading == true)

        repository.readBarrierForTesting = nil

        // Changed data + a RELEVANT scoped delta naming it, scheduled directly.
        let c = try service.createManualEvent(
            title: "C", startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(300), isAllDay: false, location: nil
        )
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .event, id: c.uuidString)]))

        // The delta publishes while the older reload is still parked.
        await waitUntil { repository.events.count == 3 }

        // Release the older read; it must abort without touching loading state.
        gate.release()
        await older.value

        #expect(repository.events.count == 3)
        #expect(Set(repository.events.map(\.title)) == ["A", "B", "C"])
        #expect(counter.count == 1)                    // exactly the delta's post
        #expect(repository.isLoading == false)         // settled, not stuck
    }

    /// The guides twin of the loading-settle race. (As above, under FIX A the
    /// superseding scoped change inherits the parked reload's `.fullRefresh`
    /// ownership and publishes via a full read; it must still settle loading.)
    @Test
    func guidesDeltaSupersedingLoadingReloadSettlesIsLoading() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.guides.count == 1 }

        let counter = ReloadPostCounter(.guidesRepositoryDidReload, on: center)
        counter.reset()

        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        let older = Task { await repository.reload() }
        await gate.waitUntilReached()
        #expect(repository.isLoading == true)

        repository.readBarrierForTesting = nil

        let g2 = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .guide, id: g2.uuidString)]))

        await waitUntil { repository.guides.count == 2 }

        gate.release()
        await older.value

        #expect(repository.guides.count == 2)
        #expect(Set(repository.guides.map(\.name)) == ["Berlin", "Lisbon"])
        #expect(counter.count == 1)
        #expect(repository.isLoading == false)
    }

    // MARK: - Relevance: an irrelevant scoped change must not strand a reload

    /// A watcher delivery names kinds this list does not project (here a guide
    /// key reaching the Events list). It must NOT mint a generation or cancel a
    /// parked initial reload: that reload completes and publishes, and no
    /// delayed refresh runs.
    @Test
    func eventsIrrelevantChangeDuringParkedReloadDoesNotStrandIt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        _ = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )
        _ = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        let counter = ReloadPostCounter(.eventsRepositoryDidReload, on: center)

        // Park the INITIAL full reload after its read (nothing published yet).
        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        let initial = Task { await repository.reload() }
        await gate.waitUntilReached()
        repository.readBarrierForTesting = nil

        // A wholly-irrelevant scoped change (a guide key) must be dropped.
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .guide, id: UUID().uuidString)]))

        // Release the parked reload; it must complete and publish {A,B}.
        gate.release()
        await initial.value

        #expect(repository.events.count == 2)          // not stranded
        #expect(repository.isLoading == false)
        #expect(counter.count == 1)                    // the reload's own post

        // The dropped change scheduled no debounce, so nothing fires later.
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 1)
        #expect(repository.events.count == 2)
    }

    /// The guides twin: an event key reaching the Guides list is irrelevant and
    /// must not strand a parked initial reload.
    @Test
    func guidesIrrelevantChangeDuringParkedReloadDoesNotStrandIt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)
        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Lisbon"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        let counter = ReloadPostCounter(.guidesRepositoryDidReload, on: center)

        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        let initial = Task { await repository.reload() }
        await gate.waitUntilReached()
        repository.readBarrierForTesting = nil

        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .event, id: UUID().uuidString)]))

        gate.release()
        await initial.value

        #expect(repository.guides.count == 2)
        #expect(repository.isLoading == false)
        #expect(counter.count == 1)

        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 1)
        #expect(repository.guides.count == 2)
    }

    // MARK: - FIX A: a scoped change during a held reload inherits full-refresh

    /// A scoped change that arrives while a DIRECT full reload is held mid-read
    /// must inherit `.fullRefresh` ownership — never patch only its own key onto
    /// the stale pre-reload base. `reload()` installs `(token, .fullRefresh)` up
    /// front (matching `ContactsRepository`), so the later scoped change's
    /// successor performs a FULL read and preserves everything the reload — and
    /// the pending change it subsumed — brought in, not just the late key.
    ///
    /// Discriminating: without FIX A the reload cleared ownership to nil, so the
    /// successor patched only C onto `{A}` and B was silently dropped.
    @Test
    func eventsScopedChangeDuringHeldReloadInheritsFullRefresh() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        // A is present when the base is first established.
        _ = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload()                     // complete base {A}, hasLoadedOnce
        await waitUntil { repository.events.count == 1 }
        #expect(repository.events.count == 1)

        // B and C now exist on disk; the repository does not know them yet.
        let b = try service.createManualEvent(
            title: "B", startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(180), isAllDay: false, location: nil
        )
        let c = try service.createManualEvent(
            title: "C", startDate: now.addingTimeInterval(240), endDate: now.addingTimeInterval(300), isAllDay: false, location: nil
        )

        // A scoped change naming B is already pending when the direct reload lands.
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .event, id: b.uuidString)]))

        // Hold the direct reload's read: it subsumes the pending B change and reads
        // the full window, then parks before publishing.
        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        let held = Task { await repository.reload() }
        await gate.waitUntilReached()

        // While the reload is parked, a scoped change naming ONLY C arrives. Under
        // FIX A it inherits the reload's `.fullRefresh` ownership; without it, its
        // successor would patch only C onto the stale `{A}` base and drop B.
        repository.readBarrierForTesting = nil
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .event, id: c.uuidString)]))

        // The successor performs a FULL read and settles to {A,B,C}.
        await waitUntil { repository.events.count == 3 }

        // Release the superseded reload; its stale snapshot must not win.
        gate.release()
        await held.value

        #expect(repository.events.count == 3)
        #expect(Set(repository.events.map(\.title)) == ["A", "B", "C"])
        #expect(repository.isLoading == false)
    }

    /// The guides twin of `eventsScopedChangeDuringHeldReloadInheritsFullRefresh`.
    @Test
    func guidesScopedChangeDuringHeldReloadInheritsFullRefresh() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        _ = try service.createGuide(from: sampleGuideSnapshot(name: "Aix"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()                     // complete base, hasLoadedOnce
        await waitUntil { repository.guides.count == 1 }
        #expect(repository.guides.count == 1)

        let b = try service.createGuide(from: sampleGuideSnapshot(name: "Bonn"), sourceURL: nil)
        let c = try service.createGuide(from: sampleGuideSnapshot(name: "Cork"), sourceURL: nil)

        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .guide, id: b.uuidString)]))

        let gate = ReadGate()
        repository.readBarrierForTesting = { await gate.arriveAndWait() }
        let held = Task { await repository.reload() }
        await gate.waitUntilReached()

        repository.readBarrierForTesting = nil
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [SidecarKey(kind: .guide, id: c.uuidString)]))

        await waitUntil { repository.guides.count == 3 }

        gate.release()
        await held.value

        #expect(repository.guides.count == 3)
        #expect(Set(repository.guides.map(\.name)) == ["Aix", "Bonn", "Cork"])
        #expect(repository.isLoading == false)
    }

    // MARK: - FIX C: a superseded scoped delta stops before subsequent scans

    /// Once a scoped delta has been superseded, it must STOP at the mid-read
    /// guard instead of running the extra link-count scan and discarding the
    /// result at the publish guard. The delta parks after its event read; a
    /// newer direct reload bumps the token; on release the guard fires and the
    /// link-scan probe is never reached.
    ///
    /// The probe (`refreshWillScanLinksForTesting`) and the pause
    /// (`refreshReadPauseForTesting`) are nil in production and are NOT touched
    /// by `reload(token:)`, so the superseding full reload runs cleanly and only
    /// the delta under test can trip either seam.
    @Test
    func eventsSupersededScopedDeltaSkipsLinkScan() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let now = Date()
        let a = try service.createManualEvent(
            title: "A", startDate: now, endDate: now.addingTimeInterval(60), isAllDay: false, location: nil
        )

        let center = NotificationCenter()
        let repository = EventsRepository(service: service, notificationCenter: center)
        await repository.reload()                     // complete base, hasLoadedOnce
        await waitUntil { repository.events.count == 1 }

        let pause = ReadGate()
        let linkScan = InvocationFlag()
        repository.refreshReadPauseForTesting = { await pause.arriveAndWait() }
        repository.refreshWillScanLinksForTesting = { linkScan.fire() }

        // A scoped change naming event A AND a link: the delta reads A (where it
        // parks) and would otherwise run a link-count scan.
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [
            SidecarKey(kind: .event, id: a.uuidString),
            SidecarKey(kind: .link, id: UUID().uuidString),
        ]))
        await pause.waitUntilReached()                // parked after the event read

        // A direct reload supersedes the parked delta. It uses neither test seam,
        // so it runs to completion cleanly.
        await repository.reload()

        // Release the parked delta; the mid-read guard must fire before the scan.
        pause.release()
        try await Task.sleep(for: .milliseconds(50))  // let the released delta run its (skipped) tail

        #expect(linkScan.didFire == false)            // scan skipped, not paid-for-then-discarded
        #expect(repository.events.count == 1)         // the reload's result stands
        #expect(repository.isLoading == false)
    }

    /// The guides twin: a superseded scoped delta stops before the link scans.
    @Test
    func guidesSupersededScopedDeltaSkipsLinkScan() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let g = try service.createGuide(from: sampleGuideSnapshot(name: "Berlin"), sourceURL: nil)

        let center = NotificationCenter()
        let repository = GuidesRepository(service: service, notificationCenter: center)
        await repository.reload()
        await waitUntil { repository.guides.count == 1 }

        let pause = ReadGate()
        let linkScan = InvocationFlag()
        repository.refreshReadPauseForTesting = { await pause.arriveAndWait() }
        repository.refreshWillScanLinksForTesting = { linkScan.fire() }

        // A scoped change naming a guide AND a link: the delta reads the guide
        // envelope (where it parks) and would otherwise run the link scans.
        repository.scheduleDebouncedReload(SidecarChangeSet(changedKeys: [
            SidecarKey(kind: .guide, id: g.uuidString),
            SidecarKey(kind: .link, id: UUID().uuidString),
        ]))
        await pause.waitUntilReached()

        await repository.reload()

        pause.release()
        try await Task.sleep(for: .milliseconds(50))

        #expect(linkScan.didFire == false)
        #expect(repository.guides.count == 1)
        #expect(repository.isLoading == false)
    }
}

// MARK: - Reentrancy test helpers

/// A one-shot barrier for `readBarrierForTesting`: the repository parks at
/// `arriveAndWait()`, the test waits for it via `waitUntilReached()`, then
/// frees it with `release()`. Everything runs on the main actor, so the plain
/// state below is race-free.
@MainActor
final class ReadGate {
    private var reached = false
    private var released = false
    private var onReached: CheckedContinuation<Void, Never>?
    private var onRelease: CheckedContinuation<Void, Never>?

    /// Called by the repository barrier: signal arrival, then wait for release.
    func arriveAndWait() async {
        reached = true
        onReached?.resume()
        onReached = nil
        guard !released else { return }
        await withCheckedContinuation { onRelease = $0 }
    }

    /// The test waits here until the repository has parked at the barrier.
    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { onReached = $0 }
    }

    /// The test frees the parked read.
    func release() {
        released = true
        onRelease?.resume()
        onRelease = nil
    }
}

/// Counts posts of a notification on a specific center, on the main actor
/// (every repository post lands there).
@MainActor
final class ReloadPostCounter {
    private(set) var count = 0
    private var observer: NSObjectProtocol?

    init(_ name: Notification.Name, on center: NotificationCenter) {
        observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    func reset() { count = 0 }
}

/// Records whether a one-shot main-actor probe ever fired. Used by the FIX C
/// tests to assert a superseded delta STOPPED before its expensive scan — the
/// probe sits right before that scan, so `didFire` staying false proves the
/// scan was skipped rather than run and then discarded.
@MainActor
final class InvocationFlag {
    private(set) var didFire = false
    func fire() { didFire = true }
}

// MARK: - Minimal store stubs

private func refreshGenStubUnused(function: String = #function) -> Never {
    fatalError("refresh-generation test stub member unexpectedly reached: \(function)")
}

/// No contacts; these tests exercise only events/guides. Only the read path is
/// touched (a repository is never built over this store).
private actor RefreshGenContactStore: ContactStoreProtocol {
    func fetchAll() async throws -> [Contact] { [] }
    func fetch(localID: String) async throws -> Contact? { nil }
    func save(_ contact: Contact) async throws { refreshGenStubUnused() }
    func delete(localID: String) async throws { refreshGenStubUnused() }
    func create(_ contact: Contact) async throws -> Contact { refreshGenStubUnused() }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .authorized }
    func requestContactsAccess() async -> StoreAccessResult { refreshGenStubUnused() }
    func changes(since token: Data?) async throws -> ContactChangeSet { refreshGenStubUnused() }
    func loadImageData(localID: String) async throws -> Data? { nil }
    func loadThumbnailImageData(localID: String) async throws -> Data? { nil }
    func setImageData(localID: String, imageData: Data?) async throws { refreshGenStubUnused() }
    func fetchAllGroups() async throws -> [ContactGroup] { [] }
    func fetchGroup(localID: String) async throws -> ContactGroup? { nil }
    func createGroup(name: String) async throws -> ContactGroup { refreshGenStubUnused() }
    func renameGroup(localID: String, to name: String) async throws { refreshGenStubUnused() }
    func deleteGroup(localID: String) async throws { refreshGenStubUnused() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { [] }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] { [] }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { refreshGenStubUnused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { refreshGenStubUnused() }
}

/// No calendar. `createManualEvent` is sidecar-only and never touches this
/// store, so every read returns empty and every write is unreachable.
private final class RefreshGenEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .notDetermined }
    func requestEventsAccess() async -> StoreAccessResult { refreshGenStubUnused() }
    func fetchEvents(in interval: DateInterval) throws -> [Event] { [] }
    func fetch(eventKitID: String) throws -> Event? { nil }
    func fetchEvents(on day: Date) throws -> [Event] { [] }
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] { [] }
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] { [] }
    func fetch(legacyEventIdentifier: String) throws -> Event? { nil }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event { refreshGenStubUnused() }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws { refreshGenStubUnused() }
}
