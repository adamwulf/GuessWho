import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedPhotoWriteFailure: Error {}

/// Delegates to an in-memory store. Photo writes can fail, can come back re-encoded
/// the way the real Contacts store can, and are counted.
actor PhotoFaultContactStore: ContactStoreProtocol {
    let base: InMemoryContactStore
    private(set) var photoWriteCount = 0
    private var failuresLeft = 0
    private var failsAfter = 0
    private var reencodes = false

    init(contacts: [Contact]) { base = InMemoryContactStore(contacts: contacts) }

    /// The next `count` photo writes fail, after `skipping` of them succeed.
    func failPhotoWrites(_ count: Int = 1, skipping: Int = 0) {
        failuresLeft = count
        failsAfter = skipping
    }
    func reencodeWrites() { reencodes = true }
    func seedPhoto(_ data: Data?, thumbnail: Data? = nil, for localID: String) async {
        await base.setImageData(data, thumbnail: thumbnail ?? data, for: localID)
    }

    func setImageData(localID: String, imageData: Data?) async throws {
        photoWriteCount += 1
        if failuresLeft > 0 {
            if failsAfter > 0 {
                failsAfter -= 1
            } else {
                failuresLeft -= 1
                throw InjectedPhotoWriteFailure()
            }
        }
        // A marker no test's bytes contain, standing in for a re-encoded image.
        let stored = reencodes ? imageData.map { $0 + Data([0xEE]) } : imageData
        try await base.setImageData(localID: localID, imageData: stored)
    }

    func fetchAll() async throws -> [Contact] { try await base.fetchAll() }
    func fetch(localID: String) async throws -> Contact? { try await base.fetch(localID: localID) }
    func save(_ contact: Contact) async throws { try await base.save(contact) }
    func delete(localID: String) async throws { try await base.delete(localID: localID) }
    func create(_ contact: Contact) async throws -> Contact { try await base.create(contact) }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        await base.contactsAuthorizationStatus()
    }
    func requestContactsAccess() async -> StoreAccessResult { await base.requestContactsAccess() }
    func changes(since token: Data?) async throws -> ContactChangeSet { try await base.changes(since: token) }
    func loadImageData(localID: String) async throws -> Data? { try await base.loadImageData(localID: localID) }
    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await base.loadThumbnailImageData(localID: localID)
    }
    func fetchAllGroups() async throws -> [ContactGroup] { try await base.fetchAllGroups() }
    func fetchGroup(localID: String) async throws -> ContactGroup? { try await base.fetchGroup(localID: localID) }
    func createGroup(name: String) async throws -> ContactGroup { try await base.createGroup(name: name) }
    func renameGroup(localID: String, to name: String) async throws {
        try await base.renameGroup(localID: localID, to: name)
    }
    func deleteGroup(localID: String) async throws { try await base.deleteGroup(localID: localID) }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        try await base.fetchMembers(ofGroup: groupLocalID)
    }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] {
        try await base.fetchMemberLocalIDs(ofGroup: groupLocalID)
    }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] {
        try await base.fetchGroupMemberships(contactLocalID: contactLocalID)
    }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {
        try await base.addMember(contactLocalID: contactLocalID, toGroup: groupLocalID)
    }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {
        try await base.removeMember(contactLocalID: contactLocalID, fromGroup: groupLocalID)
    }
}

/// Once armed, fails an envelope write that changes the `profilePhoto` cell. A write
/// that only adds another photo's cell still works.
private final class CommitFailingSidecarStore: SidecarStoreProtocol, @unchecked Sendable {
    struct Failure: Error {}
    let base: SidecarStoreProtocol
    private let lock = NSLock()
    private var failing = false
    var failsPhotoCommits: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    init(base: SidecarStoreProtocol) { self.base = base }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? { try base.read(key) }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        if failsPhotoCommits {
            let before = try base.read(key)?.fields[ContactPhotoCells.profileCellID]
            let after = envelope.fields[ContactPhotoCells.profileCellID]
            if before?.value != after?.value || before?.deletedAt != after?.deletedAt { throw Failure() }
        }
        try base.write(envelope, at: key)
    }
    func delete(_ key: SidecarKey) throws { try base.delete(key) }
    func allKeys() throws -> [SidecarKey] { try base.allKeys() }
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus { base.downloadStatus(key) }
    func requestDownload(_ key: SidecarKey) throws { try base.requestDownload(key) }
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws {
        try base.writeBlob(data, blobId: blobId, for: key)
    }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? { try base.readBlob(blobId: blobId, for: key) }
    func deleteBlob(blobId: String, for key: SidecarKey) throws { try base.deleteBlob(blobId: blobId, for: key) }
    func blobIds(for key: SidecarKey) throws -> [String] { try base.blobIds(for: key) }
    func pendingBlobIds(for key: SidecarKey) throws -> [String] { try base.pendingBlobIds(for: key) }
    func blobPresence(blobId: String, for key: SidecarKey) throws -> SidecarBlobPresence {
        try base.blobPresence(blobId: blobId, for: key)
    }
}

@MainActor
private final class Fixture {
    static let localID = "ada"
    static let guessWhoID = "33333333-3333-4333-8333-333333333333"

    let contacts: PhotoFaultContactStore
    let ubiquity = FakeUbiquityProvider()
    let store: CommitFailingSidecarStore
    let sync: GuessWhoSync
    let repo: ContactsRepository
    let center = NotificationCenter()
    let root: URL
    let defaults: UserDefaults
    let onDisk: Bool
    let key = SidecarKey(kind: .contact, id: Fixture.guessWhoID)

    var id: ContactID { repo.contact(localID: Self.localID)!.contactID }

    init(onDisk: Bool, contactsPhoto: Data? = nil) async throws {
        self.onDisk = onDisk
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-library-\(UUID().uuidString)")
        let contacts = PhotoFaultContactStore(contacts: [Contact(localID: Self.localID, givenName: "Ada", urlAddresses: [
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + Self.guessWhoID),
        ])])
        if let contactsPhoto { await contacts.seedPhoto(contactsPhoto, for: Self.localID) }
        self.contacts = contacts
        let base: SidecarStoreProtocol = onDisk
            ? FileSystemSidecarStore(root: root, ubiquity: ubiquity, blobCrypto: NoKeyBlobCrypto(),
                                     coordinatesUbiquitousAccess: false)
            : InMemorySidecarStore()
        store = CommitFailingSidecarStore(base: base)
        sync = GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: store, deviceID: "test")
        defaults = try #require(UserDefaults(suiteName: "PhotoLibraryTests.\(UUID().uuidString)"))
        repo = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: center,
                                  photoSourceDefaults: defaults)
        await repo.reload()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func items() async throws -> [ContactPhotoItem] { try await repo.contactPhotos(for: id) }

    func current() async throws -> ContactPhotoItem? { try await items().first { $0.isCurrent } }

    func bytes(_ item: ContactPhotoItem?) async throws -> Data? {
        guard let item else { return nil }
        return try await repo.contactPhotoData(for: id, photoID: item.id)?.data
    }

    /// The bytes of every stored photo, in list order.
    func storedBytes() async throws -> [Data] {
        var result: [Data] = []
        for item in try await items() where !item.isContactsOnly {
            if let data = try await bytes(item) { result.append(data) }
        }
        return result
    }

    func item(with data: Data) async throws -> ContactPhotoItem {
        for item in try await items() {
            if try await bytes(item) == data { return item }
        }
        throw FixtureError.noSuchPhoto
    }

    func contactsBytes() async throws -> Data? { try await contacts.loadImageData(localID: Self.localID) }

    func cells(named name: String) throws -> [(id: String, cell: SidecarCell)] {
        try (store.read(key)?.fields ?? [:]).compactMap { id, cell in
            guard case .object(let inner) = cell.value,
                  inner[SidecarField.innerFieldKey] == .string(name) else { return nil }
            return (id, cell)
        }
    }

    /// A cell as an earlier build wrote it, with no `contactPhoto` cell beside it.
    @discardableResult
    func plantOlderCell(field: String, data: Data, cellID: String = UUID().uuidString,
                        crop: ContactPhotoCrop? = nil, createdAt: Date, digest: String? = nil) throws -> String {
        let blobID = UUID().uuidString.lowercased()
        try store.writeBlob(data, blobId: blobID, for: key)
        let pointer = BlobPointer(blobId: blobID, contentType: "image/jpeg", byteCount: data.count,
                                  photoCrop: crop, systemPhotoDigest: digest)
        let inner = SidecarField.makeInnerValue(field: field, type: .blob, value: pointer.jsonValue, createdAt: createdAt)
        var fields = try store.read(key)?.fields ?? [:]
        fields[cellID] = SidecarCell(value: inner, modifiedAt: createdAt, modifiedBy: "older-build")
        try store.write(SidecarEnvelope(schemaVersion: 1, entityID: key.id, fields: fields), at: key)
        return blobID
    }

    /// Overwrites a stored file with one sealed under a key this device lacks.
    func sealFile(blobID: String) throws {
        let url = root.appendingPathComponent("contacts").appendingPathComponent("\(key.id).\(blobID).dat")
        try InMemoryBlobCrypto().encrypt(Data([9, 9])).write(to: url)
    }

    /// Turns a stored file into an iCloud placeholder, as on a device it hasn't
    /// reached. Returns the file's real URL and the placeholder's.
    @discardableResult
    func makeFilePlaceholder(blobID: String) throws -> (file: URL, placeholder: URL) {
        let directory = root.appendingPathComponent("contacts")
        let name = "\(key.id).\(blobID).dat"
        let file = directory.appendingPathComponent(name)
        try FileManager.default.removeItem(at: file)
        let placeholder = directory.appendingPathComponent(".\(name).icloud")
        try Data().write(to: placeholder)
        return (file, placeholder)
    }

    /// Every cell, stamps included, to prove nothing was written.
    func envelopeBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(try #require(try store.read(key)))
    }

    /// Delivers a change, by default to this contact's files as the watcher would, and
    /// says whether photo consumers were told to drop what they've cached.
    func deliverChange(_ changeSet: SidecarChangeSet? = nil) async throws -> Bool {
        nonisolated(unsafe) var dataChanged = false
        let token = center.addObserver(forName: .contactsRepositoryDidReload, object: repo, queue: nil) { note in
            if note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool == true { dataChanged = true }
        }
        defer { center.removeObserver(token) }
        center.post(name: .guessWhoSidecarsDidChange, object: nil, userInfo: [
            GuessWhoSidecarsDidChangeKey.changeSet: changeSet ?? SidecarChangeSet(changedKeys: [key]),
        ])
        try await Task.sleep(for: .milliseconds(650))
        return dataChanged
    }
}

/// Two devices that start with the same data and each write without seeing the
/// other. Each holds its own copy of every file.
private struct TwoDevices {
    let key = SidecarKey(kind: .contact, id: Fixture.guessWhoID)
    let storeA = InMemorySidecarStore()
    let storeB = InMemorySidecarStore()
    let a: GuessWhoSync
    let b: GuessWhoSync

    init() {
        a = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: storeA, deviceID: "a")
        b = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: storeB, deviceID: "b")
    }

    /// Both devices start with this photo, as an older build wrote it: `profilePhoto`
    /// alone, with no `contactPhoto` cell.
    func startWithOlderCurrent(_ data: Data, blobID: String = UUID().uuidString.lowercased()) throws -> String {
        let pointer = BlobPointer(blobId: blobID, contentType: "image/jpeg", byteCount: data.count)
        let stamp = Date(timeIntervalSinceNow: -60)
        let inner = SidecarField.makeInnerValue(field: ContactsRepository.profilePhotoFieldName, type: .blob,
                                                value: pointer.jsonValue, createdAt: stamp)
        let cell = SidecarCell(value: inner, modifiedAt: stamp, modifiedBy: "older-build")
        for store in [storeA, storeB] {
            try store.writeBlob(data, blobId: blobID, for: key)
            try store.write(SidecarEnvelope(schemaVersion: 1, entityID: key.id,
                                            fields: [ContactPhotoCells.profileCellID: cell]), at: key)
        }
        return blobID
    }

    /// Copies A's envelope and its photo files to B, so both start the same.
    func copyAToB() throws {
        try storeB.write(try #require(try storeA.read(key)), at: key)
        for blobID in try storeA.blobIds(for: key) {
            try storeB.writeBlob(try #require(try storeA.readBlob(blobId: blobID, for: key)), blobId: blobID, for: key)
        }
    }

    /// B's changes reach A: the envelopes merge, and A stays without any file it deleted.
    func mergeBIntoA() throws -> SidecarEnvelope {
        let merged = try merge(try #require(try storeA.read(key)), try #require(try storeB.read(key))).get()
        try storeA.write(merged, at: key)
        return merged
    }
}

private enum FixtureError: Error { case noSuchPhoto }

/// Holds an envelope write inside its coordination claim until released, so the store
/// gives up waiting on a write that later lands.
private final class HoldingEnvelopeWritesCoordinator: SidecarFileCoordinating, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    func coordinateReading(at url: URL, _ body: @escaping (URL) -> Void) throws { body(url) }

    func coordinateWriting(at url: URL, options: NSFileCoordinator.WritingOptions,
                           _ body: @escaping (URL) -> Void) throws {
        guard url.pathExtension == "json" else { return body(url) }
        release.wait()
        body(url)
        finished.signal()
    }
}

@Suite("Multiple photos on a contact")
@MainActor
struct ContactPhotoLibraryTests {
    private let photoA = Data([0xFF, 0xD8, 0xFF, 0x0A])
    private let photoB = Data([0xFF, 0xD8, 0xFF, 0x0B, 0x0B])
    private let photoC = Data([0xFF, 0xD8, 0xFF, 0x0C, 0x0C, 0x0C])
    private let cropA = ContactPhotoCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5)!
    private let cropB = ContactPhotoCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4)!

    /// `createdAt` has millisecond precision, so tests that assert order wait it out.
    private func tick() async throws { try await Task.sleep(for: .milliseconds(3)) }

    // MARK: - The four rules

    @Test(arguments: [false, true]) func replacingKeepsTheOldPhotoWithItsCrop(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await tick()
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB, crop: cropB)

        let items = try await fixture.items()
        #expect(items.count == 2)
        #expect(items.map(\.isCurrent) == [true, false])
        #expect(items.map(\.crop) == [cropB, cropA])
        #expect(try await fixture.storedBytes() == [photoB, photoA])
        #expect(try await fixture.contactsBytes() == photoB)
        #expect(items.allSatisfy { $0.isAvailable && $0.addedAt != nil && !$0.isContactsOnly })
    }

    @Test(arguments: [false, true]) func addingDoesNotChangeTheCurrentPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let writes = await fixture.contacts.photoWriteCount
        try await tick()

        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: cropB)

        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try await fixture.contactsBytes() == photoA)
        #expect(try await fixture.bytes(fixture.current()) == photoA)
        let added = try await fixture.item(with: photoB)
        #expect(added.crop == cropB)
        #expect(!added.isCurrent)
        #expect(try await fixture.items().first?.id == added.id, "newest first")
    }

    @Test(arguments: [false, true]) func addingToAContactWithNoPhotoMakesItCurrent(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }

        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)

        #expect(try await fixture.contactsBytes() == photoA)
        let current = try #require(try await fixture.current())
        #expect(current.crop == cropA)
        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize)?.crop == cropA)
    }

    @Test(arguments: [false, true]) func swappingWritesContactsAndRestoresThatCrop(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB, crop: cropB)
        let older = try await fixture.item(with: photoA)
        let filesBefore = try fixture.store.blobIds(for: fixture.key).sorted()

        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: older.id)

        #expect(try await fixture.contactsBytes() == photoA)
        let shown = try #require(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize))
        #expect(shown.data == photoA)
        #expect(shown.crop == cropA)
        #expect(try await fixture.current()?.id == older.id)
        #expect(try fixture.store.blobIds(for: fixture.key).sorted() == filesBefore)
        #expect(try await fixture.item(with: photoB).crop == cropB)
    }

    @Test(arguments: [false, true]) func swappingToTheCurrentPhotoWritesNothing(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let writes = await fixture.contacts.photoWriteCount
        let envelope = try fixture.envelopeBytes()

        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: try #require(try await fixture.current()).id)

        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try fixture.envelopeBytes() == envelope)
    }

    @Test(arguments: [false, true]) func deletingRemovesTheFileAndCells(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        let older = try await fixture.item(with: photoA)

        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: older.id)

        #expect(try await fixture.storedBytes() == [photoB])
        #expect(try await fixture.contactsBytes() == photoB)
        #expect(try await fixture.bytes(fixture.current()) == photoB)
        #expect(try !fixture.store.blobIds(for: fixture.key).contains(older.id))
        let tombstone = try #require(try fixture.store.read(fixture.key)?.fields[older.id.uppercased()])
        #expect(tombstone.deletedAt != nil)
    }

    // MARK: - Remove and delete

    @Test(arguments: [false, true]) func removePhotoKeepsThePhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)

        #expect(try await fixture.contactsBytes() == nil)
        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize) == nil)
        let items = try await fixture.items()
        #expect(items.count == 1)
        #expect(items.first?.isCurrent == false)
        #expect(items.first?.crop == cropA)
        #expect(try await fixture.storedBytes() == [photoA])
    }

    @Test(arguments: [false, true]) func deletingTheCurrentPhotoClearsContactsAndPicksNoOther(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        let current = try #require(try await fixture.current())

        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: current.id)

        #expect(try await fixture.contactsBytes() == nil)
        #expect(try await fixture.current() == nil)
        #expect(try await fixture.storedBytes() == [photoA])
        #expect(try fixture.sync.profilePhoto(at: fixture.key) == nil)
    }

    @Test(arguments: [false, true]) func deletingTheContactsOnlyPhotoClearsContacts(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        let item = try #require(try await fixture.current())
        #expect(item.isContactsOnly)

        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: item.id)

        #expect(try await fixture.contactsBytes() == nil)
        #expect(try await fixture.items().isEmpty)
    }

    // MARK: - Photos only Contacts holds

    @Test(arguments: [false, true]) func aContactsOnlyPhotoIsKeptOnChange(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        let before = try await fixture.items()
        #expect(before.map(\.isContactsOnly) == [true])
        #expect(before.first?.isCurrent == true)
        #expect(before.first?.addedAt == nil)
        #expect(try await fixture.bytes(before.first) == photoA)
        try await tick()

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)

        let after = try await fixture.items()
        #expect(after.allSatisfy { !$0.isContactsOnly })
        #expect(try await fixture.storedBytes() == [photoB, photoA])
        #expect(try await fixture.bytes(fixture.current()) == photoB)
    }

    @Test(arguments: [false, true]) func removingAContactsOnlyPhotoKeepsIt(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)

        #expect(try await fixture.contactsBytes() == nil)
        #expect(try await fixture.storedBytes() == [photoA])
        #expect(try await fixture.current() == nil)
    }

    @Test(arguments: [false, true]) func anExternalContactsChangeKeepsBothPhotos(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: photoB)

        let listed = try await fixture.items()
        #expect(listed.count == 2)
        #expect(listed.first?.isContactsOnly == true)
        #expect(listed.first?.isCurrent == true)
        #expect(listed.last?.isCurrent == false)
        #expect(listed.last?.crop == cropA)
        try await tick()

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoC)

        #expect(try await Set(fixture.storedBytes()) == [photoA, photoB, photoC])
        #expect(try await fixture.item(with: photoA).crop == cropA)
        #expect(try await fixture.bytes(fixture.current()) == photoC)
    }

    @Test(arguments: [false, true]) func swappingBackFromAnExternalChangeKeepsItAndRestoresTheCrop(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: photoB)
        let stored = try #require(try await fixture.items().first { !$0.isContactsOnly })

        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: stored.id)

        #expect(try await fixture.contactsBytes() == photoA)
        let shown = try #require(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize))
        #expect(shown.crop == cropA)
        #expect(try await fixture.current()?.id == stored.id)
        #expect(try await Set(fixture.storedBytes()) == [photoA, photoB])
    }

    /// Choosing a photo again reuses its blob ID, so another device that had set it
    /// aside must still return to it once the matching Contacts image arrives.
    @Test func swapBackOnAnotherDeviceClearsItsExternalOverride() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let otherDefaults = try #require(UserDefaults(suiteName: "PhotoLibraryTests.\(UUID().uuidString)"))
        let otherDevice = ContactsRepository(contacts: fixture.contacts, sync: fixture.sync,
                                             notificationCenter: NotificationCenter(),
                                             photoSourceDefaults: otherDefaults)
        await otherDevice.reload()
        let otherID = try #require(otherDevice.contact(localID: Fixture.localID)).contactID
        #expect(try await otherDevice.contactPhotoData(for: otherID, kind: .fullSize)?.crop == cropA)

        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: photoB)
        #expect(try await otherDevice.contactPhotoData(for: otherID, kind: .fullSize)?.data == photoB)
        let stored = try #require(try await fixture.items().first { !$0.isContactsOnly })
        try await tick()

        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: stored.id)

        let shown = try #require(try await otherDevice.contactPhotoData(for: otherID, kind: .fullSize))
        #expect(shown.data == photoA)
        #expect(shown.crop == cropA)
        #expect(try await otherDevice.contactPhotos(for: otherID).allSatisfy { !$0.isContactsOnly })
    }

    @Test(arguments: [false, true]) func adoptingAnExternalChangeKeepsTheOriginalAsAPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: photoB)
        _ = try await fixture.items()

        try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropB, originalData: photoB)

        let current = try #require(try await fixture.current())
        #expect(current.crop == cropB)
        #expect(try await fixture.bytes(current) == photoB)
        #expect(try await fixture.item(with: photoA).crop == cropA)
    }

    // MARK: - Dedup

    @Test(arguments: [false, true]) func theSameBytesAreReused(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        let files = try fixture.store.blobIds(for: fixture.key).sorted()

        // Choosing it again makes it current, with its own crop.
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        #expect(try await fixture.bytes(fixture.current()) == photoA)
        #expect(try await fixture.current()?.crop == cropA)

        // Adding one already on the contact changes nothing but a crop it brings.
        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: nil)
        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: cropB)

        #expect(try fixture.store.blobIds(for: fixture.key).sorted() == files)
        #expect(try await fixture.items().count == 2)
        #expect(try await fixture.bytes(fixture.current()) == photoA)
        #expect(try await fixture.item(with: photoB).crop == cropB)
    }

    @Test(arguments: [false, true]) func repeatingTheCurrentPhotoWritesNothing(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        // Contacts hands back different bytes than it was given.
        await fixture.contacts.reencodeWrites()
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let writes = await fixture.contacts.photoWriteCount
        let envelope = try fixture.envelopeBytes()
        let files = try fixture.store.blobIds(for: fixture.key)

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)

        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try fixture.store.blobIds(for: fixture.key) == files)
        #expect(try fixture.envelopeBytes() == envelope)
        #expect(try await fixture.current()?.crop == cropA)
    }

    /// Older data can hold the same bytes under two blobIds. Which one a repeat import
    /// finds first must not depend on dictionary order, or it can match the uncropped
    /// duplicate, rewrite Contacts, and move current off the cropped photo.
    private func makeFixtureWithDuplicateOfCurrent() async throws -> (Fixture, current: String) {
        let fixture = try await Fixture(onDisk: false)
        let reencoded = photoA + Data([0xEE])
        await fixture.contacts.seedPhoto(reencoded, for: Fixture.localID)
        let current = try fixture.plantOlderCell(field: ContactsRepository.profilePhotoFieldName, data: photoA,
                                                 cellID: ContactPhotoCells.profileCellID, crop: cropA,
                                                 createdAt: Date(timeIntervalSinceNow: -100),
                                                 digest: ContactPhotoSourceTracker.digest(reencoded))
        try fixture.plantOlderCell(field: ContactsRepository.previousPhotoFieldName, data: photoA,
                                   createdAt: Date(timeIntervalSinceNow: -200))
        return (fixture, current)
    }

    @Test func aRepeatOfTheCurrentPhotoMatchesItOverADuplicate() async throws {
        for _ in 0..<40 {
            let (fixture, current) = try await makeFixtureWithDuplicateOfCurrent()
            defer { fixture.cleanUp() }
            let envelope = try fixture.envelopeBytes()

            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)

            #expect(await fixture.contacts.photoWriteCount == 0)
            #expect(try fixture.envelopeBytes() == envelope)
            #expect(try fixture.sync.currentContactPhotoCell(at: fixture.key)?.pointer.blobId == current)
        }
    }

    @Test func aRepeatLinkedInImportMatchesTheCurrentPhotoOverADuplicate() async throws {
        let profile = LinkedInProfile(photo: .init(
            dataURL: "data:image/jpeg;base64," + photoA.base64EncodedString(),
            contentType: "image/jpeg",
            byteLength: photoA.count
        ))
        for _ in 0..<40 {
            let (fixture, current) = try await makeFixtureWithDuplicateOfCurrent()
            defer { fixture.cleanUp() }

            _ = try await fixture.repo.applyLinkedIn(profile: profile, to: fixture.id, fields: [.photo])

            #expect(await fixture.contacts.photoWriteCount == 0)
            let cell = try #require(try fixture.sync.currentContactPhotoCell(at: fixture.key))
            #expect(cell.pointer.blobId == current)
            #expect(cell.pointer.photoCrop == cropA)
        }
    }

    /// A device can trust the pointer while Contacts holds something else, as on its
    /// first look at this photo. Choosing the photo again puts Contacts right.
    @Test(arguments: [false, true]) func choosingTheCurrentPhotoAgainHealsContactsThatDrifted(viaSwap: Bool) async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: photoB)
        let otherDefaults = try #require(UserDefaults(suiteName: "PhotoLibraryTests.\(UUID().uuidString)"))
        let otherDevice = ContactsRepository(contacts: fixture.contacts, sync: fixture.sync,
                                             notificationCenter: NotificationCenter(),
                                             photoSourceDefaults: otherDefaults)
        await otherDevice.reload()
        let id = try #require(otherDevice.contact(localID: Fixture.localID)).contactID
        let current = try #require(try fixture.sync.currentContactPhotoCell(at: fixture.key))
        #expect(try await otherDevice.contactPhotoData(for: id, kind: .fullSize)?.data == photoA, "it trusts the pointer")

        if viaSwap {
            try await otherDevice.setCurrentContactPhoto(for: id, photoID: current.pointer.blobId)
        } else {
            try await otherDevice.setContactPhoto(for: id, imageData: photoA)
        }

        #expect(try await fixture.contactsBytes() == photoA)
        let healed = try #require(try fixture.sync.currentContactPhotoCell(at: fixture.key))
        #expect(healed.pointer.blobId == current.pointer.blobId)
        #expect(healed.pointer.photoCrop == cropA)
        #expect(healed.pointer.systemPhotoDigest == ContactPhotoSourceTracker.digest(photoA))
    }

    @Test(arguments: [false, true]) func repeatingTheCurrentPhotoWithANewCropUpdatesIt(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let files = try fixture.store.blobIds(for: fixture.key)

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropB)

        #expect(try fixture.store.blobIds(for: fixture.key) == files)
        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize)?.crop == cropB)
    }

    @Test(arguments: [false, true]) func keepingContactsBytesReusesAMatchingPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)
        // The same image comes back through Contacts.
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: photoA)

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)

        #expect(try await Set(fixture.storedBytes()) == [photoA, photoB])
        #expect(try await fixture.items().count == 2)
    }

    // MARK: - Crop

    @Test(arguments: [false, true]) func aCropEditWritesNoNewFile(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let files = try fixture.store.blobIds(for: fixture.key)
        let blobID = try #require(files.first)
        let writes = await fixture.contacts.photoWriteCount

        try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropB, originalData: photoA)

        #expect(try fixture.store.blobIds(for: fixture.key) == files)
        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try fixture.sync.profilePhoto(at: fixture.key)?.pointer.photoCrop == cropB)
        #expect(try fixture.sync.profilePhoto(at: fixture.key)?.pointer.blobId == blobID)
        let library = try #require(try fixture.cells(named: ContactsRepository.contactPhotoFieldName).first)
        #expect(library.id == blobID.uppercased())
        guard case .object(let inner) = library.cell.value else { throw FixtureError.noSuchPhoto }
        #expect(BlobPointer(from: inner[SidecarField.innerValueKey] ?? .null)?.photoCrop == cropB)

        // Swapping away and back restores the edit.
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        #expect(try await fixture.current()?.crop == cropB)
    }

    @Test(arguments: [false, true]) func aFirstCropStoresAContactsOnlyPhotoInOneWrite(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }

        try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropA, originalData: photoA)

        let items = try await fixture.items()
        #expect(items.count == 1)
        #expect(items.first?.isCurrent == true)
        #expect(items.first?.crop == cropA)
        #expect(!items.contains { $0.isContactsOnly })
    }

    // MARK: - Existing data, no migration

    @Test(arguments: [false, true]) func existingProfilePhotoAlone(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        await fixture.contacts.seedPhoto(photoA, for: Fixture.localID)
        let blobID = try fixture.plantOlderCell(field: ContactsRepository.profilePhotoFieldName, data: photoA,
                                                cellID: ContactPhotoCells.profileCellID, crop: cropA,
                                                createdAt: Date(timeIntervalSinceNow: -100),
                                                digest: ContactPhotoSourceTracker.digest(photoA))

        let items = try await fixture.items()
        #expect(items.map(\.id) == [blobID])
        #expect(items.first?.isCurrent == true)
        #expect(items.first?.crop == cropA)
        #expect(try fixture.cells(named: ContactsRepository.contactPhotoFieldName).isEmpty, "reading writes nothing")

        // Replacing it gives it a cell of its own and deletes nothing.
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)

        let library = try fixture.cells(named: ContactsRepository.contactPhotoFieldName)
        #expect(library.contains { $0.id == blobID.uppercased() })
        #expect(try await fixture.item(with: photoA).crop == cropA)
        #expect(try fixture.store.blobIds(for: fixture.key).contains(blobID))
    }

    @Test(arguments: [false, true]) func existingProfilePhotoWithPreviousPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        await fixture.contacts.seedPhoto(photoA, for: Fixture.localID)
        let firstPhotoDate = Date(timeIntervalSinceNow: -300)
        let current = try fixture.plantOlderCell(field: ContactsRepository.profilePhotoFieldName, data: photoA,
                                                 cellID: ContactPhotoCells.profileCellID,
                                                 createdAt: firstPhotoDate,
                                                 digest: ContactPhotoSourceTracker.digest(photoA))
        // The slot keeps the first photo's date across repoints, so a build that
        // only read createdAt would sort the current photo below this one.
        let previous = try fixture.plantOlderCell(field: ContactsRepository.previousPhotoFieldName, data: photoB,
                                                  createdAt: Date(timeIntervalSinceNow: -200))
        var fields = try #require(try fixture.store.read(fixture.key)).fields
        let cell = try #require(fields[ContactPhotoCells.profileCellID])
        fields[ContactPhotoCells.profileCellID] = SidecarCell(value: cell.value, modifiedAt: Date(timeIntervalSinceNow: -100),
                                                              modifiedBy: "older-build")
        try fixture.store.write(SidecarEnvelope(schemaVersion: 1, entityID: fixture.key.id, fields: fields), at: fixture.key)

        let items = try await fixture.items()
        #expect(items.map(\.id) == [current, previous])
        #expect(items.map(\.isCurrent) == [true, false])

        // It can become current, and deleting it tombstones the older cell too.
        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: previous)
        #expect(try await fixture.contactsBytes() == photoB)
        #expect(try await fixture.current()?.id == previous)
        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: previous)
        #expect(try await fixture.items().map(\.id) == [current])
        let older = try #require(try fixture.cells(named: ContactsRepository.previousPhotoFieldName).first)
        #expect(older.cell.deletedAt != nil)
        #expect(try await fixture.contactsBytes() == nil)
    }

    @Test(arguments: [false, true]) func previousPhotoIsNeverWritten(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB, crop: cropA)
        try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropB, originalData: photoB)
        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoC, crop: nil)
        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: try await fixture.item(with: photoA).id)
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: Data([0xFF, 0x01]))
        try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: nil, originalData: Data([0xFF, 0x01]))
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)

        #expect(try fixture.cells(named: ContactsRepository.previousPhotoFieldName).isEmpty)
    }

    // MARK: - Races

    /// Two devices each change the current photo from the same starting point.
    @Test(arguments: [false, true]) func mergingTwoChangesToCurrentLosesNoPhoto(startsOlder: Bool) async throws {
        let firstStore = InMemorySidecarStore()
        let secondStore = InMemorySidecarStore()
        let first = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: firstStore, deviceID: "a")
        let second = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: secondStore, deviceID: "b")
        let key = SidecarKey(kind: .contact, id: Fixture.guessWhoID)

        // A starting photo both devices hold, with or without its own cell.
        let startID = UUID().uuidString.lowercased()
        let pointer = BlobPointer(blobId: startID, contentType: "image/jpeg", byteCount: photoA.count)
        var cells = [ContactPhotoCells.profileCellID: SidecarCell(
            value: SidecarField.makeInnerValue(field: ContactsRepository.profilePhotoFieldName, type: .blob,
                                               value: pointer.jsonValue, createdAt: Date(timeIntervalSinceNow: -60)),
            modifiedAt: Date(timeIntervalSinceNow: -60), modifiedBy: "start")]
        if !startsOlder {
            ContactPhotoCells.addLibraryCell(blobID: startID, value: pointer.jsonValue, createdAt: Date(timeIntervalSinceNow: -60),
                                             stamp: Date(timeIntervalSinceNow: -60), deviceID: "start", to: &cells)
        }
        for store in [firstStore, secondStore] {
            try store.writeBlob(photoA, blobId: startID, for: key)
            try store.write(SidecarEnvelope(schemaVersion: 1, entityID: key.id, fields: cells), at: key)
        }

        let writeB = try first.storeContactPhoto(at: key, data: photoB, crop: .exactly(cropB), makeCurrent: true, systemPhotoDigest: nil)
        let writeC = try second.storeContactPhoto(at: key, data: photoC, crop: .existingOrNone, makeCurrent: true, systemPhotoDigest: nil)

        let a = try #require(try firstStore.read(key))
        let b = try #require(try secondStore.read(key))
        let merged = try merge(a, b).get()
        let mergedOther = try merge(b, a).get()
        for envelope in [merged, mergedOther] {
            let names = Set(ContactPhotoCells.live(in: envelope.fields).map(\.blobID))
            #expect(names == [startID, writeB.pointer.blobId, writeC.pointer.blobId])
        }

        // Every file and the merged envelope arrive on the first device.
        try firstStore.writeBlob(photoC, blobId: writeC.pointer.blobId, for: key)
        try firstStore.write(merged, at: key)
        let stored = try first.storedContactPhotos(at: key)
        #expect(stored.photos.count == 3)
        #expect(stored.photos.first { $0.pointer.blobId == writeB.pointer.blobId }?.pointer.photoCrop == cropB)
        #expect([writeB.pointer.blobId, writeC.pointer.blobId].contains(stored.current?.blobId))
        for photo in stored.photos {
            #expect(try first.storedContactPhoto(at: key, blobID: photo.pointer.blobId) != nil)
        }
    }

    // MARK: - Failures

    @Test(arguments: [false, true]) func aFailedContactsWriteLeavesStorageUnchanged(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: nil)
        let before = try await fixture.items()
        let files = try fixture.store.blobIds(for: fixture.key).sorted()
        let target = try await fixture.item(with: photoB)
        let current = try #require(try await fixture.current())

        await fixture.contacts.failPhotoWrites(4)
        await #expect(throws: InjectedPhotoWriteFailure.self) {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoC)
        }
        await #expect(throws: InjectedPhotoWriteFailure.self) {
            try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: target.id)
        }
        await #expect(throws: InjectedPhotoWriteFailure.self) {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)
        }
        await #expect(throws: InjectedPhotoWriteFailure.self) {
            try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: current.id)
        }

        #expect(try await fixture.items() == before)
        #expect(try fixture.store.blobIds(for: fixture.key).sorted() == files)
        #expect(try await fixture.contactsBytes() == photoA)
    }

    /// A timeout means the store stopped waiting. The write still runs, so the envelope
    /// can land after the error, and it needs its file.
    @Test func aTimedOutEnvelopeWriteKeepsItsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = HoldingEnvelopeWritesCoordinator()
        let store = FileSystemSidecarStore(root: root, ubiquity: FakeUbiquityProvider(), blobCrypto: NoKeyBlobCrypto(),
                                           coordinatesUbiquitousAccess: true, fileCoordinator: coordinator,
                                           busyHandler: { _, _, _ in .fail }, perAttemptTimeout: 0.05)
        let sync = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: store, deviceID: "test")
        let key = SidecarKey(kind: .contact, id: Fixture.guessWhoID)

        #expect(throws: SidecarStoreError.timedOut(key)) {
            try sync.storeContactPhoto(at: key, data: photoA, crop: .existingOrNone, makeCurrent: true,
                                       systemPhotoDigest: nil)
        }

        let files = try store.blobIds(for: key)
        #expect(files.count == 1)

        coordinator.release.signal()
        #expect(coordinator.finished.wait(timeout: .now() + 5) == .success)

        // The envelope landed after the error, and its photo can be read.
        let current = try #require(try sync.storedContactPhotos(at: key).current)
        #expect([current.blobId] == files)
        #expect(try sync.storedContactPhoto(at: key, blobID: current.blobId)?.data == photoA)
    }

    /// A kept Contacts photo stands for what Contacts still holds, so a failed change
    /// must not leave it listed twice.
    @Test(arguments: [false, true]) func aFailedContactsWriteUndoesTheKeptPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        await fixture.contacts.failPhotoWrites()

        await #expect(throws: InjectedPhotoWriteFailure.self) {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        }

        let items = try await fixture.items()
        #expect(items.map(\.isContactsOnly) == [true])
        #expect(try fixture.store.blobIds(for: fixture.key).isEmpty)
        #expect(try await fixture.contactsBytes() == photoA)
    }

    @Test(arguments: [false, true]) func aFailedStorageWriteRestoresContacts(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: nil)
        let before = try await fixture.items()
        let files = try fixture.store.blobIds(for: fixture.key).sorted()
        let target = try await fixture.item(with: photoB)
        let current = try #require(try await fixture.current())

        fixture.store.failsPhotoCommits = true
        await #expect(throws: CommitFailingSidecarStore.Failure.self) {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoC)
        }
        await #expect(throws: CommitFailingSidecarStore.Failure.self) {
            try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: target.id)
        }
        await #expect(throws: CommitFailingSidecarStore.Failure.self) {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)
        }
        await #expect(throws: CommitFailingSidecarStore.Failure.self) {
            try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: current.id)
        }
        fixture.store.failsPhotoCommits = false

        #expect(try await fixture.contactsBytes() == photoA)
        #expect(try await fixture.items() == before)
        #expect(try fixture.store.blobIds(for: fixture.key).sorted() == files, "a failed commit leaves no new file")
    }

    @Test(arguments: [false, true]) func aFailedStorageWriteUndoesTheKeptPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        fixture.store.failsPhotoCommits = true

        await #expect(throws: CommitFailingSidecarStore.Failure.self) {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        }
        fixture.store.failsPhotoCommits = false

        #expect(try await fixture.contactsBytes() == photoA)
        #expect(try await fixture.items().map(\.isContactsOnly) == [true])
        #expect(try fixture.store.blobIds(for: fixture.key).isEmpty)
    }

    /// When the restore fails too, the kept photo is the only copy left.
    @Test(arguments: [false, true]) func aFailedRestoreKeepsTheKeptPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        fixture.store.failsPhotoCommits = true
        // The new photo reaches Contacts, then restoring the old one fails.
        await fixture.contacts.failPhotoWrites(1, skipping: 1)

        do {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
            Issue.record("the commit should have failed")
        } catch ContactPhotoEditError.restoreFailed {
        }
        fixture.store.failsPhotoCommits = false

        #expect(try await fixture.contactsBytes() == photoB)
        #expect(try await fixture.storedBytes().contains(photoA))
    }

    // MARK: - Files this device can't read, or doesn't have yet

    @Test func anUnreadableFileIsListedUnavailableAndStaysThroughReplacement() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.sealFile(blobID: blobID)
        let sealedURL = fixture.root.appendingPathComponent("contacts").appendingPathComponent("\(fixture.key.id).\(blobID).dat")
        let sealed = try Data(contentsOf: sealedURL)

        // Still the current one, showing Contacts' copy, with no Contacts-only item.
        let listed = try await fixture.items()
        #expect(listed.map(\.id) == [blobID])
        #expect(listed.first?.isCurrent == true)
        #expect(listed.first?.isAvailable == false)

        // Replacing it keeps the file, and doesn't store Contacts' copy too.
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        #expect(try Data(contentsOf: sealedURL) == sealed)
        let after = try await fixture.items()
        #expect(after.count == 2)
        let older = try #require(after.first { $0.id == blobID })
        #expect(!older.isCurrent)
        #expect(!older.isAvailable)
        #expect(older.crop == cropA)
    }

    @Test func anUnreadablePhotoCanBeNeitherSwappedNorDeleted() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        try fixture.sealFile(blobID: blobID)
        let writes = await fixture.contacts.photoWriteCount

        await #expect(throws: ContactPhotoEditError.storedPhotoUnreadable) {
            _ = try await fixture.repo.contactPhotoData(for: fixture.id, photoID: blobID)
        }
        #expect(try await fixture.items().first { $0.id == blobID }?.isAvailable == false)
        await #expect(throws: ContactPhotoEditError.storedPhotoUnreadable) {
            try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: blobID)
        }
        await #expect(throws: ContactPhotoEditError.storedPhotoUnreadable) {
            try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)
        }

        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try fixture.store.blobIds(for: fixture.key).contains(blobID))
        #expect(try await fixture.bytes(fixture.current()) == photoB)
    }

    @Test func aFileThatArrivesLaterStopsBeingUnavailable() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        try fixture.sealFile(blobID: blobID)
        await #expect(throws: ContactPhotoEditError.storedPhotoUnreadable) {
            _ = try await fixture.repo.contactPhotoData(for: fixture.id, photoID: blobID)
        }

        // Its key syncs, modeled by the file reading normally again.
        try fixture.store.writeBlob(photoA, blobId: blobID, for: fixture.key)

        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, photoID: blobID)?.data == photoA)
        #expect(try await fixture.items().first { $0.id == blobID }?.isAvailable == true)
    }

    /// A file that's gone with no placeholder, as when an older build deleted it. It
    /// reads like one still downloading, and it can still be cleared.
    @Test(arguments: [false, true]) func aMissingFileReadsAsNilAndCanStillBeDeleted(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)
        let writes = await fixture.contacts.photoWriteCount

        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, photoID: blobID) == nil)
        #expect(try await fixture.items().first { $0.id == blobID }?.isAvailable == true)
        await #expect(throws: ContactPhotoEditError.photoPending) {
            try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: blobID)
        }
        #expect(await fixture.contacts.photoWriteCount == writes)

        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)
        #expect(try await fixture.items().count == 1)
        #expect(try fixture.store.read(fixture.key)?.fields[blobID.uppercased()]?.deletedAt != nil)
        #expect(try await fixture.bytes(fixture.current()) == photoB)
    }

    @Test(arguments: [false, true]) func aMissingCurrentFileIsStillCurrentAndCanBeDeleted(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)

        let items = try await fixture.items()
        #expect(items.map(\.id) == [blobID])
        #expect(items.first?.isCurrent == true)

        // Deleting it clears Contacts, like any current photo.
        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)
        #expect(try await fixture.contactsBytes() == nil)
        #expect(try await fixture.items().isEmpty)
    }

    /// Delete promises the photo is gone from every device, and a placeholder can't
    /// be removed, so the file would stay in iCloud. Nothing changes until it arrives.
    @Test func deletingAnUndownloadedPhotoIsRefusedUntilItArrives() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        let urls = try fixture.makeFilePlaceholder(blobID: blobID)
        let envelope = try fixture.envelopeBytes()
        let writes = await fixture.contacts.photoWriteCount
        let items = try await fixture.items()
        fixture.ubiquity.startDownloadingCalls.removeAll()

        do {
            try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)
            Issue.record("the delete should have been refused")
        } catch ContactPhotoEditError.photoPending {
        }

        #expect(fixture.ubiquity.startDownloadingCalls.contains(urls.file))
        #expect(FileManager.default.fileExists(atPath: urls.placeholder.path))
        #expect(try fixture.envelopeBytes() == envelope)
        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try await fixture.contactsBytes() == photoB)
        #expect(try await fixture.items() == items)

        // The download finishes, and the same delete now goes through.
        try FileManager.default.removeItem(at: urls.placeholder)
        try fixture.store.writeBlob(photoA, blobId: blobID, for: fixture.key)

        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)

        #expect(!FileManager.default.fileExists(atPath: urls.file.path))
        #expect(try await fixture.storedBytes() == [photoB])
        #expect(try fixture.store.read(fixture.key)?.fields[blobID.uppercased()]?.deletedAt != nil)
    }

    /// The check comes before Contacts is cleared, so nothing has to be restored.
    @Test func aRefusedDeleteOfTheCurrentPhotoLeavesContactsAndEveryCellAlone() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        let urls = try fixture.makeFilePlaceholder(blobID: blobID)
        let envelope = try fixture.envelopeBytes()
        let writes = await fixture.contacts.photoWriteCount
        let items = try await fixture.items()
        #expect(items.map(\.id) == [blobID])
        #expect(items.first?.isCurrent == true)

        do {
            try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)
            Issue.record("the delete should have been refused")
        } catch ContactPhotoEditError.photoPending {
        }

        #expect(await fixture.contacts.photoWriteCount == writes, "Contacts was never written, not even to restore")
        #expect(try await fixture.contactsBytes() == photoA)
        #expect(try fixture.envelopeBytes() == envelope)
        #expect(FileManager.default.fileExists(atPath: urls.placeholder.path))
        #expect(try await fixture.items() == items)
    }

    /// The engine holds the same rule under its lock, in case a file becomes a
    /// placeholder after the repository's check.
    @Test func theEngineRefusesToDeleteAPlaceholderToo() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.makeFilePlaceholder(blobID: blobID)
        let envelope = try fixture.envelopeBytes()

        #expect(try fixture.sync.isContactPhotoFilePending(at: fixture.key, blobID: blobID))
        #expect(throws: ContactPhotoEditError.photoPending) {
            try fixture.sync.deleteContactPhoto(at: fixture.key, blobID: blobID)
        }

        #expect(try fixture.envelopeBytes() == envelope)
    }

    @Test func thePendingErrorSaysToTryAgain() {
        let message = ContactPhotoEditError.photoPending.localizedDescription
        #expect(message.contains("still downloading"))
        #expect(message.contains("try again"))
    }

    // MARK: - What an alert says

    /// These reach alerts, through All Photos and the crop editor.
    @Test func storeErrorsReadPlainly() {
        let key = SidecarKey(kind: .contact, id: Fixture.guessWhoID)
        let pending = SidecarStoreError.notYetDownloaded(key).localizedDescription
        #expect(pending.contains("still downloading"))
        #expect(pending.contains("try again"))
        let busy = SidecarStoreError.timedOut(key).localizedDescription
        #expect(busy.contains("busy"))
        #expect(busy.contains("try again"))
        for error: SidecarStoreError in [.notYetDownloaded(key), .timedOut(key),
                                         .typeValueMismatch(expected: .note, got: .string("a private value"))] {
            let message = error.localizedDescription
            #expect(!message.contains("SidecarStoreError"))
            #expect(!message.contains(key.id))
            #expect(!message.contains("a private value"))
        }
    }

    /// The contact's own record hasn't downloaded yet: nothing can be read or written,
    /// and what the user sees is plain.
    @Test func anUndownloadedEnvelopeGivesAPlainError() async throws {
        let fixture = try await Fixture(onDisk: true, contactsPhoto: photoA)
        defer { fixture.cleanUp() }
        let directory = fixture.root.appendingPathComponent("contacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent(".\(fixture.key.id).json.icloud"))
        let writes = await fixture.contacts.photoWriteCount

        do {
            _ = try await fixture.items()
            Issue.record("the list should have reported the download")
        } catch {
            #expect(error.localizedDescription.contains("still downloading"))
            #expect(!error.localizedDescription.contains("SidecarStoreError"))
        }
        do {
            try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
            Issue.record("the write should have reported the download")
        } catch {
            #expect(error.localizedDescription.contains("still downloading"))
            #expect(!error.localizedDescription.contains("SidecarStoreError"))
        }
        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try await fixture.contactsBytes() == photoA)
    }

    /// A stale choice in All Photos mustn't talk about a crop editor it never opened.
    @Test func aStaleChoiceInAllPhotosPointsBackThere() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        let older = try await fixture.item(with: photoA)
        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: older.id)

        do {
            try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: older.id)
            Issue.record("the deleted photo should have been refused")
        } catch ContactPhotoEditError.photoListChanged {
            #expect(ContactPhotoEditError.photoListChanged.localizedDescription == "This photo changed. Check All Photos and try again.")
        }
        // The photo only Contacts holds is no longer there to delete.
        do {
            try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: ContactPhotoItem.contactsPhotoID)
            Issue.record("the stale item should have been refused")
        } catch ContactPhotoEditError.photoListChanged {
        }
        // The engine's own check, for a photo deleted after the repository looked.
        #expect(throws: ContactPhotoEditError.photoListChanged) {
            try fixture.sync.setCurrentContactPhoto(at: fixture.key, blobID: older.id, systemPhotoDigest: nil)
        }
    }

    // MARK: - No storage

    @Test func withNoStorageTheListIsOnlyTheContactsPhoto() async throws {
        let contacts = PhotoFaultContactStore(contacts: [Contact(localID: "ada", givenName: "Ada")])
        await contacts.seedPhoto(photoA, for: "ada")
        let repo = ContactsRepository(contacts: contacts)
        await repo.reload()
        let id = try #require(repo.contact(localID: "ada")).contactID

        let items = try await repo.contactPhotos(for: id)
        #expect(items.map(\.isContactsOnly) == [true])
        let item = try #require(items.first)
        #expect(try await repo.contactPhotoData(for: id, photoID: item.id)?.data == photoA)
        #expect(try await repo.contactPhotoData(for: id, photoID: "some-other-photo") == nil)

        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.addContactPhoto(for: id, imageData: photoB, crop: nil)
        }
        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.setCurrentContactPhoto(for: id, photoID: "some-other-photo")
        }
        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.deleteContactPhoto(for: id, photoID: "some-other-photo")
        }
        #expect(try await contacts.loadImageData(localID: "ada") == photoA)

        // The photo only Contacts holds is not stored, so it can still go.
        try await repo.deleteContactPhoto(for: id, photoID: item.id)
        #expect(try await contacts.loadImageData(localID: "ada") == nil)
        #expect(try await repo.contactPhotos(for: id).isEmpty)
    }

    // MARK: - Other walkers and the refresh

    @Test(arguments: [false, true]) func photoCellsStayOutOfCustomFields(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        _ = try await fixture.repo.upsertField(for: fixture.id, field: "Nickname", value: "Ace", type: .note)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)

        #expect(fixture.repo.fields(for: fixture.id).map(\.field) == ["Nickname"])
        #expect(ContactsRepository.isReservedFieldName(ContactsRepository.contactPhotoFieldName))
    }

    @Test(arguments: [false, true]) func theOrphanSweepKeepsEveryPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil)

        let report = try fixture.sync.sweepOrphanBlobs()

        #expect(report.deleted.isEmpty)
        #expect(try await Set(fixture.storedBytes()) == [photoA, photoB])
    }

    @Test func everyChangePostsTheRefresh() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        nonisolated(unsafe) var posts = 0
        let token = fixture.center.addObserver(forName: .contactsRepositoryDidReload, object: fixture.repo, queue: nil) { note in
            if note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool == true { posts += 1 }
        }
        defer { fixture.center.removeObserver(token) }

        func expectPost(_ change: () async throws -> Void) async throws {
            let before = posts
            try await change()
            #expect(posts > before)
        }
        try await expectPost { try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA) }
        try await expectPost { try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: nil) }
        let added = try await fixture.item(with: photoB)
        try await expectPost { try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: added.id) }
        try await expectPost { try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropA, originalData: photoB) }
        let older = try await fixture.item(with: photoA)
        try await expectPost { try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: older.id) }
        try await expectPost { try await fixture.repo.setContactPhoto(for: fixture.id, imageData: nil) }
    }

    @Test func aRemovalFromAnotherDeviceInvalidatesPhotoConsumers() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)

        try fixture.sync.removeProfilePhoto(at: fixture.key)

        #expect(try await fixture.deliverChange())
    }

    // MARK: - Telling photo consumers what changed

    /// Contacts.app changes a photo, another device picks the original again, and
    /// Contacts arrives first here. The JSON's pointer is identical, so only the
    /// cell's stamp shows a new choice was made.
    @Test func aNewRevisionWithAnIdenticalPointerInvalidatesPhotoConsumers() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        let before = try #require(try fixture.sync.currentContactPhotoCell(at: fixture.key))
        #expect(try await !fixture.deliverChange(), "nothing has changed yet")
        try await tick()

        try fixture.sync.setCurrentContactPhoto(at: fixture.key, blobID: before.pointer.blobId,
                                                systemPhotoDigest: before.pointer.systemPhotoDigest)

        let after = try #require(try fixture.sync.currentContactPhotoCell(at: fixture.key))
        #expect(after.pointer == before.pointer)
        #expect(after.modifiedAt != before.modifiedAt)
        #expect(try await fixture.deliverChange())
    }

    /// Reading for the list or before a write must not count as the loader having
    /// seen the change: it still holds the old image.
    @Test func theListDoesNotHideAPointerChangeFromPhotoConsumers() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        try await tick()

        try fixture.sync.storeContactPhoto(at: fixture.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                           systemPhotoDigest: ContactPhotoSourceTracker.digest(photoB))
        _ = try await fixture.items()

        #expect(try await fixture.deliverChange())

        // The loader reading it is what settles things.
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        #expect(try await !fixture.deliverChange())
    }

    /// A contact changed elsewhere and now off screen: nothing reads it again, so it
    /// must not drop the whole photo cache on every later delivery.
    @Test func aStaleEntryInvalidatesOnce() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        try await tick()
        try fixture.sync.storeContactPhoto(at: fixture.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                           systemPhotoDigest: nil)
        let coarse = SidecarChangeSet(changedKeys: nil, changedKinds: [.contact])

        var deliveries: [Bool] = []
        for _ in 0..<3 { deliveries.append(try await fixture.deliverChange(coarse)) }

        #expect(deliveries == [true, false, false])

        // A consumer that reads it again is tracked again.
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        try await tick()
        try fixture.sync.storeContactPhoto(at: fixture.key, data: photoC, crop: .existingOrNone, makeCurrent: true,
                                           systemPhotoDigest: nil)
        #expect(try await fixture.deliverChange(coarse))
    }

    /// A pass that a newer delivery supersedes posts nothing, so it must leave its
    /// findings for that delivery, or photo consumers never hear about the change.
    @Test func aSupersededPassDoesNotLoseThePointerChange() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        try await tick()
        try fixture.sync.storeContactPhoto(at: fixture.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                           systemPhotoDigest: nil)

        // Park the first pass partway through, past where it finds the change.
        nonisolated(unsafe) var firstPassParked = false
        nonisolated(unsafe) var releaseFirstPass: CheckedContinuation<Void, Never>?
        fixture.repo.sidecarReadBarrierForTesting = {
            guard !firstPassParked else { return }
            firstPassParked = true
            await withCheckedContinuation { releaseFirstPass = $0 }
        }
        nonisolated(unsafe) var dataChanged = false
        let token = fixture.center.addObserver(forName: .contactsRepositoryDidReload, object: fixture.repo, queue: nil) { note in
            if note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool == true { dataChanged = true }
        }
        defer { fixture.center.removeObserver(token) }
        let changeSet = SidecarChangeSet(changedKeys: [fixture.key])
        fixture.center.post(name: .guessWhoSidecarsDidChange, object: nil,
                            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: changeSet])
        while !firstPassParked { try await Task.sleep(for: .milliseconds(20)) }

        // A newer delivery supersedes it, and the parked pass then finishes.
        fixture.center.post(name: .guessWhoSidecarsDidChange, object: nil,
                            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: changeSet])
        releaseFirstPass?.resume()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!dataChanged, "the superseded pass posts nothing")

        try await Task.sleep(for: .milliseconds(650))
        #expect(dataChanged)
    }

    @Test func aStaleCropCommitDoesNotHideAPointerChangeFromPhotoConsumers() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        try await tick()

        try fixture.sync.storeContactPhoto(at: fixture.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                           systemPhotoDigest: ContactPhotoSourceTracker.digest(photoB))
        do {
            try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropA, originalData: photoA)
            Issue.record("the stale crop should have been refused")
        } catch ContactPhotoEditError.photoChanged {
        }

        #expect(try await fixture.deliverChange())
    }

    // MARK: - A file that isn't here

    @Test(arguments: [false, true]) func aMissingCurrentFileShowsTheContactsPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)

        let shown = try #require(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize))

        #expect(shown.data == photoA)
        #expect(shown.crop == nil)
    }

    /// With the pointer never marked loaded, every delivery would drop the loader's
    /// whole cache. Once the file does arrive, consumers must hear about it.
    @Test(arguments: [false, true]) func aMissingFileStopsInvalidatingUntilItArrives(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA, crop: cropA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)

        #expect(try await !fixture.deliverChange())
        #expect(try await !fixture.deliverChange())

        try fixture.store.writeBlob(photoA, blobId: blobID, for: fixture.key)

        #expect(try await fixture.deliverChange())
        let shown = try #require(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail))
        #expect(shown.crop == cropA)
        #expect(try await !fixture.deliverChange())
    }

    /// Reading a photo happens on display paths, so it must not ask iCloud for every
    /// contact's files. The folder holds all of them.
    @Test func readingAPhotoRequestsOnlyItsOwnDownload() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        let directory = fixture.root.appendingPathComponent("contacts")
        for _ in 0..<25 {
            let other = "\(UUID().uuidString.lowercased()).\(UUID().uuidString.lowercased()).dat"
            try Data().write(to: directory.appendingPathComponent(".\(other).icloud"))
        }

        // The file is missing, with no placeholder of its own.
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)
        fixture.ubiquity.startDownloadingCalls.removeAll()
        _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        #expect(try !fixture.sync.hasContactPhotoFile(at: fixture.key, blobID: blobID))
        #expect(fixture.ubiquity.startDownloadingCalls.isEmpty)

        // The file is on its way.
        let name = "\(fixture.key.id).\(blobID).dat"
        try Data().write(to: directory.appendingPathComponent(".\(name).icloud"))
        await #expect(throws: SidecarStoreError.notYetDownloaded(fixture.key)) {
            _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail)
        }
        #expect(try fixture.sync.hasContactPhotoFile(at: fixture.key, blobID: blobID))
        #expect(fixture.ubiquity.startDownloadingCalls == [directory.appendingPathComponent(name)])
    }

    @Test func listingAContactsFilesRequestsOnlyTheirDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-listing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ubiquity = FakeUbiquityProvider()
        let store = FileSystemSidecarStore(root: root, ubiquity: ubiquity, blobCrypto: NoKeyBlobCrypto(),
                                           coordinatesUbiquitousAccess: false)
        let key = SidecarKey(kind: .contact, id: Fixture.guessWhoID)
        let directory = root.appendingPathComponent("contacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<25 {
            let other = "\(UUID().uuidString.lowercased()).\(UUID().uuidString.lowercased()).dat"
            try Data().write(to: directory.appendingPathComponent(".\(other).icloud"))
        }
        let blobID = UUID().uuidString.lowercased()
        let name = "\(key.id).\(blobID).dat"
        try Data().write(to: directory.appendingPathComponent(".\(name).icloud"))

        #expect(try store.blobIds(for: key) == [blobID])
        #expect(ubiquity.startDownloadingCalls == [directory.appendingPathComponent(name)])
        ubiquity.startDownloadingCalls.removeAll()
        #expect(try store.pendingBlobIds(for: key) == [blobID])
        #expect(ubiquity.startDownloadingCalls == [directory.appendingPathComponent(name)])
    }

    @Test func aRealPlaceholderStaysPending() async throws {
        let fixture = try await Fixture(onDisk: true)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.makeFilePlaceholder(blobID: blobID)

        await #expect(throws: SidecarStoreError.notYetDownloaded(fixture.key)) {
            _ = try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize)
        }
    }

    /// The file may be gone for good, so Contacts' copy could be the last one left.
    @Test(arguments: [false, true]) func changingAPhotoWhoseFileIsMissingKeepsTheContactsCopy(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoB)

        #expect(try await Set(fixture.storedBytes()) == [photoA, photoB])
        #expect(try await fixture.bytes(fixture.current()) == photoB)
    }

    @Test(arguments: [false, true]) func croppingAPhotoWhoseFileIsMissingAdoptsTheContactsCopy(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)

        try await fixture.repo.setContactPhotoCrop(for: fixture.id, crop: cropA, originalData: photoA)

        let current = try #require(try await fixture.current())
        #expect(current.id != blobID)
        #expect(current.crop == cropA)
        #expect(try await fixture.bytes(current) == photoA)
    }

    @Test(arguments: [false, true]) func aMissingFileWithNoContactsPhotoShowsNoPhoto(onDisk: Bool) async throws {
        let fixture = try await Fixture(onDisk: onDisk)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let blobID = try #require(try fixture.store.blobIds(for: fixture.key).first)
        try fixture.store.deleteBlob(blobId: blobID, for: fixture.key)
        try await fixture.contacts.base.setImageData(localID: Fixture.localID, imageData: nil)

        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize) == nil)
        let items = try await fixture.items()
        #expect(items.map(\.id) == [blobID])
        #expect(items.first?.isCurrent == false)

        // So adding one makes it current, and the placeholder can still be cleared.
        try await fixture.repo.addContactPhoto(for: fixture.id, imageData: photoB, crop: nil)
        #expect(try await fixture.contactsBytes() == photoB)
        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: blobID)
        #expect(try await fixture.storedBytes() == [photoB])
    }

    // MARK: - Races with a delete

    /// A deletes X, then B, which hasn't seen that, makes X current.
    @Test func deleteThenSwapOnAnotherDeviceStaysDeleted() throws {
        let devices = TwoDevices()
        let x = try devices.a.storeContactPhoto(at: devices.key, data: photoA, crop: .exactly(cropA), makeCurrent: false,
                                                systemPhotoDigest: nil).pointer.blobId
        let y = try devices.a.storeContactPhoto(at: devices.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                                systemPhotoDigest: nil).pointer.blobId
        try devices.copyAToB()

        try devices.a.deleteContactPhoto(at: devices.key, blobID: x)
        Thread.sleep(forTimeInterval: 0.003)
        try devices.b.setCurrentContactPhoto(at: devices.key, blobID: x, systemPhotoDigest: nil)

        let merged = try devices.mergeBIntoA()
        // B's later write wins the slot, so it still names X.
        let slot = try #require(merged.fields[ContactPhotoCells.profileCellID])
        #expect(slot.deletedAt == nil)

        let stored = try devices.a.storedContactPhotos(at: devices.key)
        #expect(stored.photos.map(\.pointer.blobId) == [y])
        #expect(stored.current == nil)
        #expect(try devices.a.profilePhoto(at: devices.key) == nil)
        #expect(try devices.a.currentContactPhotoCell(at: devices.key) == nil)
        #expect(try devices.a.storedContactPhoto(at: devices.key, blobID: x) == nil)
        // And a first crop isn't refused as if something were still current.
        try devices.a.storeContactPhoto(at: devices.key, data: photoC, crop: .exactly(cropB), makeCurrent: true,
                                        systemPhotoDigest: nil, expectation: .absent)
    }

    /// B crops X before A deletes it: the delete has the later stamp, and wins.
    @Test func cropThenDeleteOnAnotherDeviceStaysDeleted() throws {
        let devices = TwoDevices()
        let x = try devices.a.storeContactPhoto(at: devices.key, data: photoA, crop: .existingOrNone, makeCurrent: true,
                                                systemPhotoDigest: nil).pointer.blobId
        try devices.copyAToB()

        try devices.b.setCurrentContactPhotoCrop(at: devices.key, blobID: x, crop: cropA, systemPhotoDigest: nil)
        Thread.sleep(forTimeInterval: 0.003)
        try devices.a.deleteContactPhoto(at: devices.key, blobID: x)

        _ = try devices.mergeBIntoA()

        let stored = try devices.a.storedContactPhotos(at: devices.key)
        #expect(stored.photos.isEmpty)
        #expect(stored.current == nil)
    }

    /// A deletes X, then B, which hasn't seen that, crops it. Merge is whole-cell
    /// last-writer-wins, so B's later cell beats the tombstone and X comes back with
    /// its file gone. It shows as a placeholder, and deleting again clears it.
    @Test func deleteThenCropOnAnotherDeviceComesBackAsAClearablePlaceholder() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let x = try #require(try fixture.store.blobIds(for: fixture.key).first)
        let otherStore = InMemorySidecarStore()
        try otherStore.write(try #require(try fixture.store.read(fixture.key)), at: fixture.key)
        try otherStore.writeBlob(photoA, blobId: x, for: fixture.key)
        let other = GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(), sidecars: otherStore, deviceID: "b")

        try fixture.sync.deleteContactPhoto(at: fixture.key, blobID: x)
        try await tick()
        try other.setCurrentContactPhotoCrop(at: fixture.key, blobID: x, crop: cropA, systemPhotoDigest: nil)
        let merged = try merge(try #require(try fixture.store.read(fixture.key)), try #require(try otherStore.read(fixture.key))).get()
        try fixture.store.write(merged, at: fixture.key)

        // Contacts still has the photo here, and shows it.
        #expect(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .fullSize)?.data == photoA)
        let items = try await fixture.items()
        #expect(items.map(\.id) == [x])
        #expect(try await fixture.bytes(items.first) == nil)

        try await fixture.repo.deleteContactPhoto(for: fixture.id, photoID: x)

        #expect(try await fixture.items().isEmpty)
        #expect(try await fixture.contactsBytes() == nil)
    }

    /// B crops X, then A, which hasn't seen that, makes Y current. Both survive.
    @Test func cropThenSwapOnAnotherDeviceKeepsBoth() throws {
        let devices = TwoDevices()
        let y = try devices.a.storeContactPhoto(at: devices.key, data: photoB, crop: .existingOrNone, makeCurrent: false,
                                                systemPhotoDigest: nil).pointer.blobId
        let x = try devices.a.storeContactPhoto(at: devices.key, data: photoA, crop: .existingOrNone, makeCurrent: true,
                                                systemPhotoDigest: nil).pointer.blobId
        try devices.copyAToB()

        try devices.b.setCurrentContactPhotoCrop(at: devices.key, blobID: x, crop: cropA, systemPhotoDigest: nil)
        Thread.sleep(forTimeInterval: 0.003)
        try devices.a.setCurrentContactPhoto(at: devices.key, blobID: y, systemPhotoDigest: nil)

        _ = try devices.mergeBIntoA()

        let stored = try devices.a.storedContactPhotos(at: devices.key)
        #expect(stored.current?.blobId == y)
        #expect(stored.photos.count == 2)
        #expect(stored.photos.first { $0.pointer.blobId == x }?.pointer.photoCrop == cropA)
    }

    /// The swap, then a crop of the old photo on a device that hasn't seen it. The
    /// crop writes `profilePhoto` too, so the old photo ends up current again.
    @Test func swapThenCropOnAnotherDeviceMakesTheCroppedPhotoCurrent() throws {
        let devices = TwoDevices()
        let y = try devices.a.storeContactPhoto(at: devices.key, data: photoB, crop: .existingOrNone, makeCurrent: false,
                                                systemPhotoDigest: nil).pointer.blobId
        let x = try devices.a.storeContactPhoto(at: devices.key, data: photoA, crop: .existingOrNone, makeCurrent: true,
                                                systemPhotoDigest: nil).pointer.blobId
        try devices.copyAToB()

        try devices.a.setCurrentContactPhoto(at: devices.key, blobID: y, systemPhotoDigest: nil)
        Thread.sleep(forTimeInterval: 0.003)
        try devices.b.setCurrentContactPhotoCrop(at: devices.key, blobID: x, crop: cropA, systemPhotoDigest: nil)

        _ = try devices.mergeBIntoA()

        let stored = try devices.a.storedContactPhotos(at: devices.key)
        #expect(stored.current?.blobId == x)
        #expect(stored.current?.photoCrop == cropA)
        #expect(stored.photos.count == 2)
    }

    /// Older data has no `contactPhoto` cell to tombstone, so the delete writes one.
    @Test func aReplaceThenDeleteOfOlderDataStaysDeleted() throws {
        let devices = TwoDevices()
        let x = try devices.startWithOlderCurrent(photoA)

        let y = try devices.b.storeContactPhoto(at: devices.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                                systemPhotoDigest: nil).pointer.blobId
        try devices.storeA.writeBlob(photoB, blobId: y, for: devices.key)
        Thread.sleep(forTimeInterval: 0.003)
        try devices.a.deleteContactPhoto(at: devices.key, blobID: x)
        #expect(try devices.storeA.read(devices.key)?.fields[x.uppercased()]?.deletedAt != nil)

        _ = try devices.mergeBIntoA()

        let stored = try devices.a.storedContactPhotos(at: devices.key)
        #expect(stored.photos.map(\.pointer.blobId) == [y])
        // The delete's later stamp also tombstones the slot, so nothing is current.
        #expect(stored.current == nil)
    }

    /// B's new cell for X takes X's old stamp, so a delete B hadn't seen still beats it.
    @Test func aDeleteThenReplaceOfOlderDataStaysDeleted() throws {
        let devices = TwoDevices()
        let x = try devices.startWithOlderCurrent(photoA)

        try devices.a.deleteContactPhoto(at: devices.key, blobID: x)
        Thread.sleep(forTimeInterval: 0.003)
        let y = try devices.b.storeContactPhoto(at: devices.key, data: photoB, crop: .existingOrNone, makeCurrent: true,
                                                systemPhotoDigest: nil).pointer.blobId
        try devices.storeA.writeBlob(photoB, blobId: y, for: devices.key)

        _ = try devices.mergeBIntoA()

        let stored = try devices.a.storedContactPhotos(at: devices.key)
        #expect(stored.photos.map(\.pointer.blobId) == [y])
        #expect(stored.current?.blobId == y)
    }

    /// With a photo deleted but still named by `profilePhoto`, the pointer must not
    /// keep reading as changed, or every delivery drops the loader's cache.
    @Test func aDeletedPhotoStillNamedByTheSlotShowsContactsAndSettles() async throws {
        let fixture = try await Fixture(onDisk: false)
        defer { fixture.cleanUp() }
        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)
        let x = try #require(try fixture.store.blobIds(for: fixture.key).first)
        // What a merge leaves: the slot live, and the photo's own key a tombstone.
        var fields = try #require(try fixture.store.read(fixture.key)).fields
        let cell = try #require(fields[x.uppercased()])
        fields[x.uppercased()] = SidecarCell(value: cell.value, modifiedAt: Date(), modifiedBy: "a", deletedAt: Date())
        try fixture.store.write(SidecarEnvelope(schemaVersion: 1, entityID: fixture.key.id, fields: fields), at: fixture.key)
        try fixture.store.deleteBlob(blobId: x, for: fixture.key)

        let shown = try #require(try await fixture.repo.contactPhotoData(for: fixture.id, kind: .thumbnail))
        #expect(shown.data == photoA)
        let items = try await fixture.items()
        #expect(items.map(\.isContactsOnly) == [true])

        #expect(try await !fixture.deliverChange())
    }
}
