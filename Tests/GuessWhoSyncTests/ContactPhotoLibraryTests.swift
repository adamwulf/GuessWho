import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedPhotoWriteFailure: Error {}

/// Delegates to an in-memory store. Photo writes can fail, can come back re-encoded
/// the way the real Contacts store can, and are counted.
private actor PhotoFaultContactStore: ContactStoreProtocol {
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
}

private enum FixtureError: Error { case noSuchPhoto }

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

        try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: try #require(try await fixture.current()).id)

        #expect(await fixture.contacts.photoWriteCount == writes)
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
        let envelope = try #require(try fixture.store.read(fixture.key))
        let files = try fixture.store.blobIds(for: fixture.key)

        try await fixture.repo.setContactPhoto(for: fixture.id, imageData: photoA)

        #expect(await fixture.contacts.photoWriteCount == writes)
        #expect(try fixture.store.blobIds(for: fixture.key) == files)
        let after = try #require(try fixture.store.read(fixture.key))
        #expect(after.fields.keys.sorted() == envelope.fields.keys.sorted())
        #expect(try await fixture.current()?.crop == cropA)
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
                                             now: Date(timeIntervalSinceNow: -60), deviceID: "start", to: &cells)
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

        await #expect(throws: ContactPhotoEditError.self) {
            _ = try await fixture.repo.contactPhotoData(for: fixture.id, photoID: blobID)
        }
        #expect(try await fixture.items().first { $0.id == blobID }?.isAvailable == false)
        await #expect(throws: ContactPhotoEditError.self) {
            try await fixture.repo.setCurrentContactPhoto(for: fixture.id, photoID: blobID)
        }
        await #expect(throws: ContactPhotoEditError.self) {
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
        await #expect(throws: ContactPhotoEditError.self) {
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
        await #expect(throws: ContactPhotoEditError.self) {
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
        #expect(throws: ContactPhotoEditError.self) {
            try fixture.sync.deleteContactPhoto(at: fixture.key, blobID: blobID)
        }

        #expect(try fixture.envelopeBytes() == envelope)
    }

    @Test func thePendingErrorSaysToTryAgain() {
        let message = ContactPhotoEditError.photoPending.localizedDescription
        #expect(message.contains("still downloading"))
        #expect(message.contains("try again"))
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
        nonisolated(unsafe) var dataChanged = false
        let token = fixture.center.addObserver(forName: .contactsRepositoryDidReload, object: fixture.repo, queue: nil) { note in
            if note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool == true { dataChanged = true }
        }
        defer { fixture.center.removeObserver(token) }

        try fixture.sync.removeProfilePhoto(at: fixture.key)
        fixture.center.post(name: .guessWhoSidecarsDidChange, object: nil,
                            userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [fixture.key])])
        try await Task.sleep(for: .milliseconds(650))

        #expect(dataChanged)
    }
}
