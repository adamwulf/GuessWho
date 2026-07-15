import Foundation
import Testing
import GuessWhoSync
@testable import GuessWho

/// Unit tests for `SyncService` — the app target's service layer, previously
/// exercised only by launching the app. Hosted in GuessWho.app (TEST_HOST),
/// but every test constructs its OWN service through the designated
/// initializer over local protocol stubs (see the bottom of this file) and a
/// temp-dir sidecar root, so nothing here touches Contacts, EventKit, iCloud,
/// or the host app's live stores.
///
/// `@MainActor` because `SyncService` is main-actor isolated. Each test mints
/// a fresh temp root; the same root is also opened via a second
/// `FileSystemSidecarStore` / `GuessWhoSync` where a test needs to plant or
/// inspect on-disk state the service API deliberately doesn't expose — files
/// are the shared source of truth, so this is observation, not a back door.
///
/// LINKING: GuessWhoSync is a `.dynamic` package product (see Package.swift)
/// precisely so this bundle and the host app bind to ONE GuessWhoSync image —
/// with a static product the bundle carried its own copy and cross-image
/// dynamic casts on package types failed. The typed `#expect(throws:
/// SidecarUnavailableError.self)` assertions below are the canary for that
/// property. This bundle deliberately does NOT link GuessWhoSyncTesting: an
/// intra-package sibling always folds the GuessWhoSync TARGET in statically,
/// which would both re-embed a second copy and trip Xcode's same-name
/// static/dynamic conflict — so the two protocol stubs at the bottom of this
/// file stand in for the package fakes (this suite drives sidecar paths, not
/// store behavior; only `fetch(legacyEventIdentifier:)` is ever reached).
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
        events: StubEventStore = StubEventStore()
    ) -> SyncService {
        SyncService(
            contactsAdapter: StubContactStore(),
            eventsAdapter: events,
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
    }

    /// A service whose storage resolved to `.unavailable` (no writable root).
    private func makeUnavailableService() -> SyncService {
        SyncService(
            contactsAdapter: StubContactStore(),
            eventsAdapter: StubEventStore(),
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

    @Test
    func resolveUnwritableContainerAndFailingFallbackIsUnavailable() throws {
        // The last rung reachable FROM the iCloud branch: container present
        // but unwritable AND no local fallback either. Distinct from the
        // nil-container case above — this exercises the inner catch's
        // .unavailable exit, whose reason names the unwritable container.
        struct NoStorage: Error {}
        let parent = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let fileAsContainer = parent.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: fileAsContainer)

        let location = SyncService.resolveSidecarLocation(
            ubiquityContainerURL: fileAsContainer,
            localFallback: { throw NoStorage() }
        )
        guard case .unavailable(let reason) = location else {
            Issue.record("expected .unavailable, got \(location)")
            return
        }
        #expect(reason.contains("unwritable"))
    }

    // MARK: - Event migration (memoized single run)

    /// Plants a legacy (non-UUID-keyed) event sidecar on disk via a second
    /// engine over the same root, using the public envelope-on-demand write.
    private func plantLegacyEventSidecar(root: URL, legacyID: String) throws {
        let engine = GuessWhoSync(
            contacts: StubContactStore(),
            events: StubEventStore(),
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

        // Typed matches on the PACKAGE error type. These are also the
        // regression canary for the `.dynamic` GuessWhoSync/GuessWhoSyncTesting
        // product types: with static (automatic) products this bundle carried
        // its own GuessWhoSync copy, the host image and test image held
        // separate metadata for the same source type, and exactly these
        // cross-image casts failed. If they fail again, the single-image
        // linking regressed — do NOT weaken them back to description matching.
        let toggleError = #expect(throws: SidecarUnavailableError.self) {
            _ = try service.toggleFavorite(kind: .contact, id: "aaaa")
        }
        // Exact description pin on top of the type: the string is the
        // user-facing storage-unavailable copy, so a reword should be a
        // conscious choice.
        #expect(
            toggleError?.localizedDescription
                == "Sidecar storage is unavailable. Cannot read or write GuessWho data."
        )
        #expect(throws: SidecarUnavailableError.self) {
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

        // The vended property matches the injected ID…
        #expect(service.deviceID == "test-device")

        // …and, the part that matters, it IS the writer ID the engine stamps
        // on disk: a write through the service must produce cells whose
        // `modifiedBy` carries it. This is the "same source, same value"
        // contract the property doc promises (NotesStore-minted writer IDs
        // must equal the package's cell stamps).
        let uuid = try service.createManualEvent(
            title: "Stamped",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600),
            isAllDay: false,
            location: nil
        )
        let envelope = try #require(
            try FileSystemSidecarStore(root: root)
                .read(SidecarKey(kind: .event, id: uuid.uuidString))
        )
        #expect(!envelope.fields.isEmpty)
        for (_, cell) in envelope.fields {
            #expect(cell.modifiedBy == "test-device")
        }
    }
}

// MARK: - Local protocol stubs
//
// Deliberately NOT the GuessWhoSyncTesting fakes — linking that product here
// would fold a second static GuessWhoSync copy into this bundle (see the
// LINKING note in the suite header). This suite drives sidecar paths, never
// store behavior, so every member traps loudly via `unused()` EXCEPT
// `fetch(legacyEventIdentifier:)`, which the event-migration scan reaches and
// answers nil (the dead-pointer branch — exactly the permission-free case
// migration must handle). If a future test needs real fake behavior, don't
// grow these: move the test to the package suite, or lift the fakes into a
// standalone package that depends on the GuessWhoSync PRODUCT.

private func unused(_ function: StaticString = #function) -> Never {
    fatalError("\(function) is unused by SyncServiceTests; see the stub note")
}

private actor StubContactStore: ContactStoreProtocol {
    func fetchAll() async throws -> [Contact] { unused() }
    func fetch(localID: String) async throws -> Contact? { unused() }
    func save(_ contact: Contact) async throws { unused() }
    func delete(localID: String) async throws { unused() }
    func create(_ contact: Contact) async throws -> Contact { unused() }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { unused() }
    func requestContactsAccess() async -> StoreAccessResult { unused() }
    func changes(since token: Data?) async throws -> ContactChangeSet { unused() }
    func loadImageData(localID: String) async throws -> Data? { unused() }
    func loadThumbnailImageData(localID: String) async throws -> Data? { unused() }
    func setImageData(localID: String, imageData: Data?) async throws { unused() }
    func fetchAllGroups() async throws -> [ContactGroup] { unused() }
    func fetchGroup(localID: String) async throws -> ContactGroup? { unused() }
    func createGroup(name: String) async throws -> ContactGroup { unused() }
    func renameGroup(localID: String, to name: String) async throws { unused() }
    func deleteGroup(localID: String) async throws { unused() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { unused() }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { unused() }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { unused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { unused() }
}

private final class StubEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { unused() }
    func requestEventsAccess() async -> StoreAccessResult { unused() }
    func fetchEvents(in interval: DateInterval) throws -> [Event] { unused() }
    func fetch(eventKitID: String) throws -> Event? { unused() }
    func fetchEvents(on day: Date) throws -> [Event] { unused() }
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] { unused() }
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String> = [],
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] { unused() }
    // The one reachable member: the migration scan resolves each legacy key
    // best-effort; nil = "EKEvent gone / no permission" → dead-pointer write.
    func fetch(legacyEventIdentifier: String) throws -> Event? { nil }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event { unused() }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws { unused() }
}
