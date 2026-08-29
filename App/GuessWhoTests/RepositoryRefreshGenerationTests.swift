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
