import Foundation
import GuessWhoSync
// The ConflictReconcile SPI carries the `FileSystemSidecarStore` init that
// accepts a `blobCrypto` seam. Headless `swift test` has no usable keychain,
// so the production `KeychainBlobCrypto` cannot encrypt/decrypt the photo
// snapshot blob; the harness injects the SPI's `InMemoryBlobCrypto` instead —
// a test-only substitution of the crypto seam, NOT a production behavior
// change. The on-disk sidecar store, its coordinator, and every other write
// path stay exactly the production `FileSystemSidecarStore`.
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
import GuessWhoMCPCore
import GuessWhoMCPWire

// The production-backed MCP dispatch harness (parity-test refactor).
//
// Unlike `Fixture` in Fakes.swift — which stands a `FakeContactSource` and a
// `FakeFavoriteSource` that RE-IMPLEMENT the repository/favorites algorithms in
// test code — this harness wires the SAME production objects the app wires:
//
//   RecordingContactStore  →  GuessWhoSync   ┐
//         (OS boundary)         (engine)     ├─ shared instances
//   RecordingContactStore  →  ContactsRepo   ┘
//   FileSystemSidecarStore  (real on-disk sidecars, unique temp root)
//   FavoritesStore          (real on-disk Favorites.json, same temp root)
//   ToolDispatcher          (production dispatch core)
//
// Only the OS Contacts boundary is substituted: `RecordingContactStore` wraps
// an `InMemoryContactStore` (headless `swift test` has no `CNContactStore` /
// TCC) and adds recording + one-shot fault injection. Every rule that the
// parity tests assert on — identity resolve-or-mint, the previous-photo
// snapshot, favorite canonicalization/CAS, group membership — runs in
// PRODUCTION code, never re-derived here. The event/guide/gate/confirmation
// collaborators stay the existing OS-independent fakes from Fakes.swift.

// MARK: - Recording contact store (the only substituted OS boundary)

/// Error the harness throws from an injected one-shot fault when the caller
/// doesn't supply its own. Feature tests usually pass the specific error they
/// want to simulate (e.g. the Cocoa 134092 store-rejection family).
struct HarnessInjectedFailure: Error, Equatable {
    enum Site: String { case save, photo }
    let site: Site
}

/// A `ContactStoreProtocol` boundary wrapper over `InMemoryContactStore`.
///
/// It does THREE things and nothing else — it implements NO repository rules:
///   1. delegates every call straight to the wrapped in-memory store;
///   2. records the contact-record writes (save / create / delete / photo) so
///      durable + reload assertions can inspect what actually reached the
///      boundary;
///   3. injects a one-shot `save` failure at a chosen save ordinal, and a
///      one-shot photo-write failure — the latter fires INSIDE
///      `setImageData(localID:imageData:)`, i.e. AFTER
///      `ContactsRepository.setContactPhoto` has already read the prior bytes
///      and written the `previousPhoto` snapshot, which is the exact window a
///      parity test needs.
///
/// The save ordinal counts EVERY `save(_:)` that crosses the boundary — a
/// mint-stamp save (the engine writing a freshly minted `guesswho://` URL back
/// onto the card during resolve-or-mint) counts the same as an explicit
/// `saveContact`, because both are real CN writes in production. Seeding does
/// NOT count: `seed*` helpers write straight to the wrapped store, bypassing
/// the recorder and the fault gates. `create(_:)` and `delete(_:)` have their
/// own counters and never trip the save-ordinal fault.
actor RecordingContactStore: ContactStoreProtocol {
    private let inner: InMemoryContactStore

    // MARK: Recorded writes (observations)

    /// One recorded photo write attempt at the boundary.
    struct PhotoWrite: Equatable, Sendable {
        let localID: String
        /// `true` when the write CLEARS the photo (`imageData == nil`).
        let cleared: Bool
    }

    /// Count of `save(_:)` calls that crossed the boundary, including the
    /// attempt that an injected fault rejected. Seeds are excluded.
    private(set) var saveCount = 0
    /// `localID`s of saves that COMMITTED (a fault-rejected save is absent).
    private(set) var committedSaveLocalIDs: [String] = []
    /// `localID`s passed to `create(_:)`, in order (the SEED localIDs; the
    /// store re-issues a fresh identity, see `createdRecords`).
    private(set) var createSeedLocalIDs: [String] = []
    /// The records `create(_:)` returned, carrying their store-issued identity.
    private(set) var createdRecords: [Contact] = []
    /// `localID`s passed to `delete(localID:)` that COMMITTED, in order.
    private(set) var committedDeleteLocalIDs: [String] = []
    /// Every photo write ATTEMPT at the boundary (a fault-rejected attempt is
    /// still recorded — it reached the boundary before failing).
    private(set) var photoWriteAttempts: [PhotoWrite] = []
    /// Photo writes that COMMITTED to the wrapped store.
    private(set) var committedPhotoWrites: [PhotoWrite] = []

    // MARK: Fault injection (one-shot)

    private var pendingSaveFailureOrdinal: Int?
    private var pendingSaveFailureError: Error?
    private var pendingPhotoFailure = false
    private var pendingPhotoFailureError: Error?

    init(inner: InMemoryContactStore) {
        self.inner = inner
    }

    /// Arm a one-shot `save(_:)` failure. The `ordinal`-th save that crosses
    /// the boundary (1-based, seeds excluded) throws `error` and does not
    /// reach the wrapped store; the fault then disarms.
    func failSave(atOrdinal ordinal: Int, with error: Error? = nil) {
        pendingSaveFailureOrdinal = ordinal
        pendingSaveFailureError = error
    }

    /// Arm a one-shot photo-write failure. The next
    /// `setImageData(localID:imageData:)` throws `error` after the caller has
    /// already snapshotted the prior image; the fault then disarms.
    func failNextPhotoWrite(with error: Error? = nil) {
        pendingPhotoFailure = true
        pendingPhotoFailureError = error
    }

    // MARK: Seeding (non-recorded, fault-free)

    /// Insert contacts straight into the wrapped store — no recording, no
    /// fault gate. Use to establish the starting book before the run.
    func seed(_ contacts: [Contact]) async throws {
        for contact in contacts {
            try await inner.save(contact)
        }
    }

    /// Attach photo bytes straight to the wrapped store's sideband — no
    /// recording, no fault gate, and NOT counted as a photo write.
    func seedPhoto(_ image: Data?, thumbnail: Data?, forLocalID localID: String) async {
        await inner.setImageData(image, thumbnail: thumbnail, for: localID)
    }

    // MARK: ContactStoreProtocol — pure delegation + recording/faults

    func fetchAll() async throws -> [Contact] {
        try await inner.fetchAll()
    }

    func fetch(localID: String) async throws -> Contact? {
        try await inner.fetch(localID: localID)
    }

    func save(_ contact: Contact) async throws {
        saveCount += 1
        if let ordinal = pendingSaveFailureOrdinal, ordinal == saveCount {
            pendingSaveFailureOrdinal = nil
            let error = pendingSaveFailureError ?? HarnessInjectedFailure(site: .save)
            pendingSaveFailureError = nil
            throw error
        }
        try await inner.save(contact)
        committedSaveLocalIDs.append(contact.localID)
    }

    func delete(localID: String) async throws {
        try await inner.delete(localID: localID)
        committedDeleteLocalIDs.append(localID)
    }

    func create(_ contact: Contact) async throws -> Contact {
        createSeedLocalIDs.append(contact.localID)
        let created = try await inner.create(contact)
        createdRecords.append(created)
        return created
    }

    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        await inner.contactsAuthorizationStatus()
    }

    func requestContactsAccess() async -> StoreAccessResult {
        await inner.requestContactsAccess()
    }

    func changes(since token: Data?) async throws -> ContactChangeSet {
        try await inner.changes(since: token)
    }

    func loadImageData(localID: String) async throws -> Data? {
        try await inner.loadImageData(localID: localID)
    }

    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await inner.loadThumbnailImageData(localID: localID)
    }

    func setImageData(localID: String, imageData: Data?) async throws {
        photoWriteAttempts.append(PhotoWrite(localID: localID, cleared: imageData == nil))
        if pendingPhotoFailure {
            pendingPhotoFailure = false
            let error = pendingPhotoFailureError ?? HarnessInjectedFailure(site: .photo)
            pendingPhotoFailureError = nil
            throw error
        }
        try await inner.setImageData(localID: localID, imageData: imageData)
        committedPhotoWrites.append(PhotoWrite(localID: localID, cleared: imageData == nil))
    }

    func fetchAllGroups() async throws -> [ContactGroup] {
        try await inner.fetchAllGroups()
    }

    func fetchGroup(localID: String) async throws -> ContactGroup? {
        try await inner.fetchGroup(localID: localID)
    }

    func createGroup(name: String) async throws -> ContactGroup {
        try await inner.createGroup(name: name)
    }

    func renameGroup(localID: String, to name: String) async throws {
        try await inner.renameGroup(localID: localID, to: name)
    }

    func deleteGroup(localID: String) async throws {
        try await inner.deleteGroup(localID: localID)
    }

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

// MARK: - Favorite source adapter (thin delegation to the real FavoritesStore)

/// `MCPFavoriteSource` over a REAL `FavoritesStore`. A one-line pass-through
/// per method — the same shape the app's `SyncService` uses — so ALL
/// canonicalization, idempotency, and compare-and-swap logic stays in the
/// production `FavoritesStore` and is never copied into a test double.
@MainActor
final class MCPFavoriteStoreAdapter: MCPFavoriteSource {
    let store: FavoritesStore

    init(store: FavoritesStore) {
        self.store = store
    }

    func loadFavorites() throws -> [Favorite] {
        try store.loadAll()
    }

    @discardableResult
    func setFavorite(kind: FavoriteKind, id: String, favorite: Bool) throws -> Bool {
        try store.set(kind: kind, id: id, favorite: favorite, now: Date())
    }

    @discardableResult
    func reorderFavorites(expected: [Favorite], reordered: [Favorite]) throws -> Bool {
        try store.reorder(expected: expected, reordered: reordered)
    }
}

// MARK: - The production fixture

/// A ready-to-dispatch harness over the production stack, seeded with a
/// representative book: a reconciled person (already carrying an identity
/// URL), a never-reconciled person, an organization, one group with a member,
/// Build it with `await MCPProductionFixture.make()`; favorite-specific tests
/// pass `seedContactFavorite: true` to add one real on-disk favorite.
@MainActor
struct MCPProductionFixture {
    let dispatcher: ToolDispatcher
    let repository: ContactsRepository
    let store: RecordingContactStore
    let sync: GuessWhoSync
    let favoritesStore: FavoritesStore
    let favoriteSource: MCPFavoriteStoreAdapter
    let links: EngineLinkSource
    // OS-independent collaborators — the existing fakes from Fakes.swift.
    let events: FakeEventSource
    let guides: FakeGuideSource
    let gates: FakeGateSource
    let confirmations: FakeConfirmationSource
    let audit: MCPAuditLog
    /// The unique on-disk root that holds the sidecar directories and
    /// `Favorites.json`. Remove it with `cleanUp()` when the test is done.
    let root: URL

    static let helper = RequestOrigin.mcp.makeHelperId()

    // MARK: Seed identities (stable, referenceable by feature tests)

    /// The reconciled person's canonical GuessWho UUID (embedded in her
    /// `guesswho://` URL and used as the optional seeded favorite id).
    static let adaGuessWhoID = "11111111-2222-4333-8444-555566667777"
    static let adaLocalID = "harness-person-ada"
    static let blaiseLocalID = "harness-person-blaise"
    static let orgLocalID = "harness-org-engines"
    static let groupName = "Pioneers"

    /// A reconciled person carrying the identity URL and the Apple-note
    /// sentinel (so the same INV-3 leak assertions apply here).
    static func ada() -> Contact {
        Contact(
            localID: adaLocalID,
            givenName: "Ada",
            familyName: "Lovelace",
            jobTitle: "Analyst",
            organizationName: "Analytical Engines",
            note: Sentinels.appleNote,
            emailAddresses: [LabeledValue(label: "work", value: "ada@engines.example")],
            urlAddresses: [
                LabeledValue(label: "", value: SidecarKey.guessWhoContactURLPrefix + adaGuessWhoID),
            ])
    }

    /// A never-reconciled person (no identity URL — the first-write mint path).
    static func blaise() -> Contact {
        Contact(
            localID: blaiseLocalID,
            givenName: "Blaise",
            familyName: "Pascal",
            note: Sentinels.appleNote)
    }

    /// An organization matching Ada's `organizationName`.
    static func engines() -> Contact {
        Contact(
            localID: orgLocalID,
            contactType: .organization,
            organizationName: "Analytical Engines",
            note: Sentinels.appleNote)
    }

    /// A temp-file audit log, unique per fixture.
    static func makeAuditLog() -> MCPAuditLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mcp-prod-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
        return MCPAuditLog(fileURL: url)
    }

    static func make(
        writeLimitPerWindow: Int = 30,
        writeWindowSeconds: TimeInterval = 60,
        seedContactFavorite: Bool = false
    ) async -> MCPProductionFixture {
        // One unique on-disk root shared by the sidecar store and the favorites
        // store — exactly the app's layout (Favorites.json sits beside the
        // sidecar directories under the same Documents root).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mcp-prod-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The only substituted OS boundary — seeded with the starting book so
        // the first reload sees production contacts. Seeding is fail-fast: a
        // broken seed is a broken harness, so it should crash the run here
        // rather than surface as a confusing assertion failure downstream.
        let inMemory = InMemoryContactStore()
        let store = RecordingContactStore(inner: inMemory)
        try! await store.seed([ada(), blaise(), engines()])

        // The SAME store instance backs both the engine and the repository, so
        // a mint stamped through the engine is visible to the repository — the
        // app's own wiring (SyncService passes one adapter to both). The blob
        // crypto seam is the headless-safe InMemoryBlobCrypto (see the file
        // header); everything else is the production on-disk store.
        let sidecars = FileSystemSidecarStore(
            root: root,
            ubiquity: ProductionUbiquityProvider(),
            blobCrypto: InMemoryBlobCrypto())
        let sync = GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: Sentinels.deviceID)
        let favoritesStore = FavoritesStore(root: root)
        // A fresh NotificationCenter isolates this repository's observer from
        // any other repository sharing `.default` in a parallel test.
        let repository = ContactsRepository(
            contacts: store,
            sync: sync,
            favorites: favoritesStore,
            notificationCenter: NotificationCenter())

        let favoriteSource = MCPFavoriteStoreAdapter(store: favoritesStore)
        let links = EngineLinkSource(engine: sync)
        let events = FakeEventSource()
        let guides = FakeGuideSource()
        let gates = FakeGateSource()
        let confirmations = FakeConfirmationSource()
        let audit = makeAuditLog()

        let dispatcher = ToolDispatcher(
            contacts: repository, events: events, guides: guides,
            favorites: favoriteSource, links: links, gates: gates,
            confirmations: confirmations, audit: audit,
            writeLimitPerWindow: writeLimitPerWindow,
            writeWindowSeconds: writeWindowSeconds)

        let fixture = MCPProductionFixture(
            dispatcher: dispatcher, repository: repository, store: store,
            sync: sync, favoritesStore: favoritesStore,
            favoriteSource: favoriteSource, links: links, events: events,
            guides: guides, gates: gates, confirmations: confirmations,
            audit: audit, root: root)

        // Load the repository so dispatch immediately sees the seeded book +
        // groups, then seed a group and membership. Favorite-specific tests opt
        // into the on-disk seed explicitly so unrelated repository tests do not
        // depend on the operating system's file-coordination service.
        await repository.reload()
        try! await fixture.seedGroup(named: groupName, memberLocalIDs: [adaLocalID])
        if seedContactFavorite {
            try! favoritesStore.set(
                kind: .contact, id: adaGuessWhoID, favorite: true, now: Date())
        }

        return fixture
    }

    // MARK: - Seed / reload helpers

    /// Re-fetch the whole book (and groups) from the store into the repository
    /// cache — the same full refresh the app runs after an external change.
    func reload() async {
        await repository.reload()
        await repository.loadGroups()
    }

    /// Insert contacts into the store and reload so the repository sees them.
    func seedContacts(_ contacts: [Contact]) async throws {
        try await store.seed(contacts)
        await reload()
    }

    /// Create a group and add the named members, then refresh the group cache.
    @discardableResult
    func seedGroup(named name: String, memberLocalIDs: [String]) async throws -> ContactGroup {
        let group = try await store.createGroup(name: name)
        for localID in memberLocalIDs {
            try await store.addMember(contactLocalID: localID, toGroup: group.localID)
        }
        await repository.loadGroups()
        return group
    }

    /// Attach photo bytes to a contact's store record (a seed, not a write).
    func seedPhoto(_ image: Data?, forLocalID localID: String) async {
        await store.seedPhoto(image, thumbnail: image, forLocalID: localID)
        await reload()
    }

    // MARK: - On-disk inspection helpers

    /// The favorites list read back FROM DISK through the real store (a
    /// coordinated read of `Favorites.json`).
    func storedFavorites() throws -> [Favorite] {
        try favoritesStore.loadAll()
    }

    /// Live notes read back from the on-disk sidecar for a reconciled contact.
    func storedNotes(forGuessWhoID id: String) throws -> [ContactNote] {
        try sync.notes(at: SidecarKey(kind: .contact, id: id))
    }

    /// Live fields (tombstones excluded by the engine read) from the on-disk
    /// sidecar for a reconciled contact.
    func storedFields(forGuessWhoID id: String) throws -> [SidecarField] {
        try sync.fields(at: SidecarKey(kind: .contact, id: id))
    }

    /// The `previousPhoto` snapshot bytes on disk, or nil if none was written.
    func storedPreviousPhoto(forGuessWhoID id: String) throws -> Data? {
        try sync.blobFieldData(at: SidecarKey(kind: .contact, id: id), field: "previousPhoto")
    }

    /// The full-size photo bytes currently on the store record.
    func storedPhoto(forLocalID localID: String) async throws -> Data? {
        try await store.loadImageData(localID: localID)
    }

    // MARK: - Identity helpers

    /// The cached `Contact` for a store `localID`, or nil.
    func contact(localID: String) -> Contact? {
        repository.contact(localID: localID)
    }

    /// The reconciled GuessWho UUID for a store `localID`, or nil when the
    /// contact has not been reconciled yet.
    func guessWhoID(forLocalID localID: String) -> String? {
        guard let contact = repository.contact(localID: localID) else { return nil }
        return ContactID(contact: contact).guessWhoID
    }

    // MARK: - Cleanup

    /// Remove the on-disk root. Best-effort; safe to call more than once.
    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
