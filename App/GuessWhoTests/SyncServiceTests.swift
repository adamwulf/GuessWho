import Foundation
import Testing
import GuessWhoSync
import GuessWhoSyncTesting
@testable import GuessWho

/// Unit tests for `SyncService` — the app target's service layer, previously
/// exercised only by launching the app. Hosted in GuessWho.app (TEST_HOST),
/// but every test constructs its OWN service through the designated
/// initializer over the package's in-memory adapter fakes and a temp-dir
/// sidecar root, so nothing here touches Contacts, EventKit, iCloud, or the
/// host app's live stores.
///
/// `@MainActor` because `SyncService` is main-actor isolated. Each test mints
/// a fresh temp root; the same root is also opened via a second
/// `FileSystemSidecarStore` / `GuessWhoSync` where a test needs to plant or
/// inspect on-disk state the service API deliberately doesn't expose — files
/// are the shared source of truth, so this is observation, not a back door.
@MainActor
@Suite("SyncService")
struct SyncServiceTests {
    // MARK: - Fixtures

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-syncservice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A service over in-memory adapters and a temp-dir root. `.iCloud` here
    /// is just "this URL is the sidecar root" — the designated init treats a
    /// test temp dir and a real ubiquity Documents URL identically.
    private func makeService(
        root: URL,
        events: InMemoryEventStore = InMemoryEventStore()
    ) -> SyncService {
        SyncService(
            contactsAdapter: InMemoryContactStore(),
            eventsAdapter: events,
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
    }

    /// A service whose storage resolved to `.unavailable` (no writable root).
    private func makeUnavailableService() -> SyncService {
        SyncService(
            contactsAdapter: InMemoryContactStore(),
            eventsAdapter: InMemoryEventStore(),
            sidecarLocation: .unavailable(reason: "test: no writable storage"),
            deviceID: "test-device",
            contactCursorURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("gw-unavailable-cursor-\(UUID().uuidString)")
        )
    }

    // MARK: - Storage resolution ladder

    @Test
    func resolveWithUbiquityContainerYieldsICloudDocuments() throws {
        let container = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: container) }

        let location = SyncService.resolveSidecarLocation(
            ubiquityContainerURL: container,
            localFallback: { Issue.record("fallback must not be consulted"); return container }
        )

        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        #expect(location == .iCloud(documents))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: documents.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test
    func resolveWithoutUbiquityFallsBackToLocal() throws {
        let fallback = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: fallback) }

        let location = SyncService.resolveSidecarLocation(
            ubiquityContainerURL: nil,
            localFallback: { fallback }
        )

        guard case .localFallback(let url, let reason) = location else {
            Issue.record("expected .localFallback, got \(location)")
            return
        }
        #expect(url == fallback)
        #expect(!reason.isEmpty)
    }

    @Test
    func resolveUnwritableContainerFallsBackToLocal() throws {
        // A container URL that points at a plain FILE: creating its
        // Documents/ subdirectory must fail, driving the unwritable rung.
        let parent = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fileAsContainer = parent.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: fileAsContainer)
        let fallback = parent.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)

        let location = SyncService.resolveSidecarLocation(
            ubiquityContainerURL: fileAsContainer,
            localFallback: { fallback }
        )

        guard case .localFallback(let url, let reason) = location else {
            Issue.record("expected .localFallback, got \(location)")
            return
        }
        #expect(url == fallback)
        #expect(reason.contains("unwritable"))
    }

    @Test
    func resolveWithNothingWritableIsUnavailable() {
        struct NoStorage: Error {}
        let location = SyncService.resolveSidecarLocation(
            ubiquityContainerURL: nil,
            localFallback: { throw NoStorage() }
        )
        guard case .unavailable(let reason) = location else {
            Issue.record("expected .unavailable, got \(location)")
            return
        }
        #expect(!reason.isEmpty)
    }

    // MARK: - Event migration (memoized single run)

    /// Plants a legacy (non-UUID-keyed) event sidecar on disk via a second
    /// engine over the same root, using the public envelope-on-demand write.
    private func plantLegacyEventSidecar(root: URL, legacyID: String) throws {
        let engine = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: FileSystemSidecarStore(root: root),
            deviceID: "planter"
        )
        try engine.addField(
            at: SidecarKey(kind: .event, id: legacyID),
            field: "note",
            type: .note,
            value: .string("planted")
        )
    }

    private func eventKeys(root: URL) throws -> [SidecarKey] {
        try FileSystemSidecarStore(root: root).allKeys().filter { $0.kind == .event }
    }

    @Test
    func migrateEventsIfNeededRunsOnceAndIsIdempotent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try plantLegacyEventSidecar(root: root, legacyID: "legacy-event-abc")

        let service = makeService(root: root)

        // Two CONCURRENT awaiters must coalesce onto one memoized run…
        async let first: Void = service.migrateEventsIfNeeded()
        async let second: Void = service.migrateEventsIfNeeded()
        _ = await (first, second)

        var keys = try eventKeys(root: root)
        #expect(keys.count == 1)
        let migrated = try #require(keys.first)
        #expect(UUID(uuidString: migrated.id) != nil)
        #expect(!keys.contains(SidecarKey(kind: .event, id: "legacy-event-abc")))

        // …and a later sequential call must be a no-op (same single key).
        await service.migrateEventsIfNeeded()
        keys = try eventKeys(root: root)
        #expect(keys.count == 1)
        #expect(keys.first == migrated)
    }

    @Test
    func fetchEventsRangeForcesMigrationBeforeWindowRead() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try plantLegacyEventSidecar(root: root, legacyID: "legacy-event-xyz")

        let service = makeService(root: root)
        // No explicit migrate call: the window read itself must never see
        // pre-migration keys, so it awaits the memoized migration first.
        _ = await service.fetchEventsRange(from: .distantPast, to: .distantFuture)

        let keys = try eventKeys(root: root)
        #expect(keys.count == 1)
        #expect(UUID(uuidString: try #require(keys.first).id) != nil)
    }

    // MARK: - Manual (sidecar-only) events

    @Test
    func createManualEventAppearsInWindowWithoutEventKit() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let uuid = try service.createManualEvent(
            title: "Coffee with Ada",
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            location: "Analytical Engine Co"
        )

        // eventsAuthorization is .notDetermined here, so the window read runs
        // sidecar-only — proving manual events need no EventKit at all.
        let events = await service.fetchEventsRange(
            from: start.addingTimeInterval(-86_400),
            to: start.addingTimeInterval(86_400)
        )
        #expect(events.count == 1)
        #expect(events.first?.title == "Coffee with Ada")
        #expect(service.event(uuid: uuid.uuidString)?.title == "Coffee with Ada")
    }

    // MARK: - Favorites plumbing

    @Test
    func favoritesToggleAndOrderRoundTrip() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)

        #expect(service.favorites().isEmpty)

        let addedA = try service.toggleFavorite(kind: .contact, id: "aaaa")
        let addedB = try service.toggleFavorite(kind: .event, id: "bbbb")
        #expect(addedA && addedB)
        #expect(service.favorites().count == 2)

        // Toggle back off removes.
        let removed = try service.toggleFavorite(kind: .contact, id: "aaaa")
        #expect(removed == false)
        #expect(service.favorites().count == 1)
        #expect(service.favorites().first?.id == "bbbb")
    }

    // MARK: - Unavailable storage degrades, never crashes

    @Test
    func unavailableStorageDegradesGracefully() async {
        let service = makeUnavailableService()

        let events = await service.fetchEventsRange(from: .distantPast, to: .distantFuture)
        #expect(events.isEmpty)
        #expect(service.event(uuid: UUID().uuidString) == nil)
        #expect(service.favorites().isEmpty)

        // Writes must throw the storage-unavailable error, asserted by its
        // stable description rather than `#expect(throws: SidecarUnavailable-
        // Error.self)`: this bundle links its own static copy of GuessWhoSync
        // (via GuessWhoSyncTesting, which the host app does not embed), so the
        // host image and test image carry separate metadata for the SAME
        // source type and a cross-image dynamic cast fails. The contract —
        // "a write surfaces storage-unavailable, never a silent no-op" — is
        // image-agnostic.
        func expectStorageUnavailable(_ body: () throws -> Void) {
            do {
                try body()
                Issue.record("expected a storage-unavailable throw")
            } catch {
                #expect(error.localizedDescription.contains("unavailable"))
            }
        }
        expectStorageUnavailable {
            _ = try service.toggleFavorite(kind: .contact, id: "aaaa")
        }
        expectStorageUnavailable {
            _ = try service.createManualEvent(
                title: "x", startDate: .now, endDate: .now,
                isAllDay: false, location: nil
            )
        }

        // Migration on an unavailable engine is a silent no-op, not a crash.
        await service.migrateEventsIfNeeded()
    }

    // MARK: - Identity passthrough

    @Test
    func deviceIDIsThePackageWriterID() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root: root)
        #expect(service.deviceID == "test-device")
    }
}
