import Foundation
import CryptoKit
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting

/// A photo file's name includes its contact's key, so an identity merge has to
/// carry the loser's files over to the winner.
@Suite("Identity merge keeps photo files")
struct IdentityMergePhotoFileTests {
    private let winner = "11111111-1111-4111-8111-111111111111"
    private let loser = "22222222-2222-4222-8222-222222222222"
    private var winnerKey: SidecarKey { SidecarKey(kind: .contact, id: winner) }
    private var loserKey: SidecarKey { SidecarKey(kind: .contact, id: loser) }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("identity-merge-\(UUID().uuidString)")
    }

    private func makeFileStore(root: URL, ubiquity: FakeUbiquityProvider = FakeUbiquityProvider()) -> FileSystemSidecarStore {
        FileSystemSidecarStore(root: root, ubiquity: ubiquity, blobCrypto: NoKeyBlobCrypto(),
                               coordinatesUbiquitousAccess: false)
    }

    /// A contact carrying both IDs, as two devices that each minted one leave it.
    private func makeContacts() -> InMemoryContactStore {
        InMemoryContactStore(contacts: [Contact(localID: "C1", urlAddresses: [
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + winner),
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + loser),
        ])])
    }

    private func makeSync(_ contacts: InMemoryContactStore, _ sidecars: SidecarStoreProtocol) -> GuessWhoSync {
        GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "test")
    }

    @Test(arguments: [false, true])
    func loserPhotoIsReadableUnderTheWinner(onDisk: Bool) async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecars: SidecarStoreProtocol = onDisk ? makeFileStore(root: root) : InMemorySidecarStore()
        let contacts = makeContacts()
        let sync = makeSync(contacts, sidecars)
        let bytes = Data([1, 2, 3])
        let blobID: String = try await sync.setBlobField(at: loserKey, field: ContactsRepository.profilePhotoFieldName,
                                                         data: bytes, contentType: "image/jpeg")

        let outcome = try await sync.reconcileContactIdentity(localID: "C1")

        #expect(outcome.mergedLoserUUIDs == [loser])
        #expect(try sync.profilePhoto(at: winnerKey)?.photo.data == bytes)
        #expect(try sidecars.blobIds(for: winnerKey).contains(blobID))
        #expect(try sidecars.blobIds(for: loserKey).isEmpty)
        #expect(try sidecars.read(loserKey) == nil)
    }

    @Test func olderEncryptedFileMovesWithoutBeingOpened() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeFileStore(root: root)
        let contacts = makeContacts()
        let sync = makeSync(contacts, store)
        let blobID: String = try await sync.setBlobField(at: loserKey, field: ContactsRepository.profilePhotoFieldName,
                                                         data: Data([1]), contentType: "image/jpeg")
        let directory = root.appendingPathComponent("contacts")
        let sealed = try InMemoryBlobCrypto().encrypt(Data([9, 9]))
        try sealed.write(to: directory.appendingPathComponent("\(loser).\(blobID).dat"))

        _ = try await sync.reconcileContactIdentity(localID: "C1")

        #expect(try Data(contentsOf: directory.appendingPathComponent("\(winner).\(blobID).dat")) == sealed)
        #expect(try store.blobIds(for: loserKey).isEmpty)
    }

    /// Nothing is destroyed: the merge stops before any write. The second call shows
    /// the engine can finish once the file arrives. Production only makes that call
    /// while the cached contact has no GuessWho ID, as the repository test below shows.
    @Test func undownloadedLoserFileStopsTheMergeBeforeAnyWrite() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ubiquity = FakeUbiquityProvider()
        let store = makeFileStore(root: root, ubiquity: ubiquity)
        let contacts = makeContacts()
        let sync = makeSync(contacts, store)
        let localBytes = Data([1, 2])
        let localID: String = try await sync.setBlobField(at: loserKey, field: "attachment",
                                                          data: localBytes, contentType: "image/jpeg")
        let pendingID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let directory = root.appendingPathComponent("contacts")
        let pendingName = "\(loser).\(pendingID).dat"
        let placeholder = directory.appendingPathComponent(".\(pendingName).icloud")
        try Data().write(to: placeholder)
        let loserCellsBefore = try #require(try store.read(loserKey)).fields.keys.sorted()

        await #expect(throws: SidecarStoreError.notYetDownloaded(loserKey)) {
            _ = try await sync.reconcileContactIdentity(localID: "C1")
        }

        #expect(ubiquity.startDownloadingCalls.contains(directory.appendingPathComponent(pendingName)))
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
        #expect(try store.read(winnerKey) == nil)
        #expect(try store.read(loserKey)?.fields.keys.sorted() == loserCellsBefore)
        #expect(try store.readBlob(blobId: localID, for: loserKey) == localBytes)
        #expect(try store.blobIds(for: winnerKey).isEmpty)
        let saved = try #require(try await contacts.fetch(localID: "C1"))
        #expect(saved.urlAddresses.count == 2)

        // The download finishes.
        try FileManager.default.removeItem(at: placeholder)
        let arrived = Data([7, 8])
        try store.writeBlob(arrived, blobId: pendingID, for: loserKey)

        let outcome = try await sync.reconcileContactIdentity(localID: "C1")

        #expect(outcome.mergedLoserUUIDs == [loser])
        #expect(try store.readBlob(blobId: pendingID, for: winnerKey) == arrived)
        #expect(try store.readBlob(blobId: localID, for: winnerKey) == localBytes)
        #expect(try store.blobIds(for: loserKey).isEmpty)
    }

    @Test func moveLeavesAPlaceholderAloneAndRequestsItsDownload() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ubiquity = FakeUbiquityProvider()
        let store = makeFileStore(root: root, ubiquity: ubiquity)
        let blobID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let directory = root.appendingPathComponent("contacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(loser).\(blobID).dat"
        let placeholder = directory.appendingPathComponent(".\(name).icloud")
        try Data().write(to: placeholder)

        #expect(try store.pendingBlobIds(for: loserKey) == [blobID])
        #expect(throws: SidecarStoreError.notYetDownloaded(loserKey)) {
            try store.moveBlob(blobId: blobID, from: loserKey, to: winnerKey)
        }

        #expect(FileManager.default.fileExists(atPath: placeholder.path))
        #expect(ubiquity.startDownloadingCalls.contains(directory.appendingPathComponent(name)))
    }

    @Test func moveOfAMissingFileIsANoOp() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeFileStore(root: root)
        try store.moveBlob(blobId: UUID().uuidString.lowercased(), from: loserKey, to: winnerKey)
        #expect(try store.blobIds(for: winnerKey).isEmpty)
    }

    /// A blobId never names two different files, so a copy already there is the same photo.
    @Test(arguments: [false, true]) func moveOntoAnExistingFileKeepsItAndRemovesTheSource(coordinated: Bool) throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemSidecarStore(root: root, ubiquity: FakeUbiquityProvider(), blobCrypto: NoKeyBlobCrypto(),
                                           coordinatesUbiquitousAccess: coordinated)
        let blobID = UUID().uuidString.lowercased()
        try store.writeBlob(Data([1]), blobId: blobID, for: loserKey)
        try store.writeBlob(Data([1]), blobId: blobID, for: winnerKey)

        try store.moveBlob(blobId: blobID, from: loserKey, to: winnerKey)

        #expect(try store.blobIds(for: loserKey).isEmpty)
        #expect(try store.readBlob(blobId: blobID, for: winnerKey) == Data([1]))
    }

    /// Through `ProductionSidecarFileCoordinator`, on a local folder.
    @Test func moveThroughTheRealFileCoordinator() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemSidecarStore(root: root, ubiquity: FakeUbiquityProvider(), blobCrypto: NoKeyBlobCrypto(),
                                           coordinatesUbiquitousAccess: true)
        let blobID = UUID().uuidString.lowercased()
        try store.writeBlob(Data([1, 2, 3]), blobId: blobID, for: loserKey)

        try store.moveBlob(blobId: blobID, from: loserKey, to: winnerKey)

        #expect(try store.blobIds(for: loserKey).isEmpty)
        #expect(try store.readBlob(blobId: blobID, for: winnerKey) == Data([1, 2, 3]))
    }

    // MARK: - Older data

    /// As an older build wrote it: `profilePhoto` alone, with no `contactPhoto` cell.
    private func plantOlderCurrent(_ data: Data, at key: SidecarKey, in store: SidecarStoreProtocol,
                                   stamp: Date) throws -> String {
        let blobID = UUID().uuidString.lowercased()
        try store.writeBlob(data, blobId: blobID, for: key)
        let pointer = BlobPointer(blobId: blobID, contentType: "image/jpeg", byteCount: data.count)
        let inner = SidecarField.makeInnerValue(field: ContactsRepository.profilePhotoFieldName, type: .blob,
                                                value: pointer.jsonValue, createdAt: stamp)
        try store.write(SidecarEnvelope(schemaVersion: 1, entityID: key.id, fields: [
            ContactPhotoCells.profileCellID: SidecarCell(value: inner, modifiedAt: stamp, modifiedBy: "older-build"),
        ]), at: key)
        return blobID
    }

    /// Both identities use the fixed `profilePhoto` cell, so one pointer loses the
    /// merge. The losing pointer's moved file must still be named by something.
    @Test(arguments: [false, true], [false, true])
    func mergingTwoOlderCurrentPhotosKeepsBoth(onDisk: Bool, winnerIsLater: Bool) async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecars: SidecarStoreProtocol = onDisk ? makeFileStore(root: root) : InMemorySidecarStore()
        let sync = makeSync(makeContacts(), sidecars)
        let winnerStamp = Date(timeIntervalSinceNow: winnerIsLater ? -100 : -200)
        let loserStamp = Date(timeIntervalSinceNow: winnerIsLater ? -200 : -100)
        let winnerPhoto = try plantOlderCurrent(Data([1]), at: winnerKey, in: sidecars, stamp: winnerStamp)
        let loserPhoto = try plantOlderCurrent(Data([2]), at: loserKey, in: sidecars, stamp: loserStamp)

        _ = try await sync.reconcileContactIdentity(localID: "C1")

        let stored = try sync.storedContactPhotos(at: winnerKey)
        #expect(Set(stored.photos.map(\.pointer.blobId)) == [winnerPhoto, loserPhoto])
        #expect(stored.current?.blobId == (winnerIsLater ? winnerPhoto : loserPhoto))
        #expect(try sync.storedContactPhoto(at: winnerKey, blobID: winnerPhoto)?.data == Data([1]))
        #expect(try sync.storedContactPhoto(at: winnerKey, blobID: loserPhoto)?.data == Data([2]))
    }

    // MARK: - A merge that fails partway

    private func makeFaultFixture() async throws -> (MergeFaultStore, GuessWhoSync, InMemoryContactStore, [String]) {
        let store = MergeFaultStore()
        let contacts = makeContacts()
        let sync = makeSync(contacts, store)
        let first: String = try await sync.setBlobField(at: loserKey, field: "first", data: Data([1]), contentType: "image/jpeg")
        let second: String = try await sync.setBlobField(at: loserKey, field: "second", data: Data([2]), contentType: "image/jpeg")
        return (store, sync, contacts, [first, second])
    }

    @Test func aFailedWinnerWriteMovesTheFilesBack() async throws {
        let (store, sync, contacts, files) = try await makeFaultFixture()
        store.failingWrites = (winnerKey, MergeFaultStore.Failure.injected)

        await #expect(throws: MergeFaultStore.Failure.injected) {
            _ = try await sync.reconcileContactIdentity(localID: "C1")
        }

        #expect(Set(try store.blobIds(for: loserKey)) == Set(files))
        #expect(try store.blobIds(for: winnerKey).isEmpty)
        #expect(try store.read(loserKey) != nil)
        #expect(try await contacts.fetch(localID: "C1")?.urlAddresses.count == 2)
    }

    @Test func aFailedMoveMovesTheEarlierFilesBack() async throws {
        let (store, sync, _, files) = try await makeFaultFixture()
        store.failingMoveNumber = 2

        await #expect(throws: MergeFaultStore.Failure.injected) {
            _ = try await sync.reconcileContactIdentity(localID: "C1")
        }

        #expect(Set(try store.blobIds(for: loserKey)) == Set(files))
        #expect(try store.blobIds(for: winnerKey).isEmpty)
        #expect(try store.read(winnerKey) == nil)
    }

    /// Best-effort: the merge's own error is what's reported, and no file is destroyed.
    @Test func aFailedMoveBackLeavesTheFileUnderTheWinner() async throws {
        let (store, sync, _, files) = try await makeFaultFixture()
        store.failingWrites = (winnerKey, MergeFaultStore.Failure.injected)
        store.failsMovesToLoser = true

        await #expect(throws: MergeFaultStore.Failure.injected) {
            _ = try await sync.reconcileContactIdentity(localID: "C1")
        }

        #expect(Set(try store.blobIds(for: winnerKey)) == Set(files))
        #expect(try store.read(loserKey) != nil)
    }

    /// The store stopped waiting, but the winner's envelope can still land, and it
    /// needs the files where they are.
    @Test func aTimedOutWinnerWriteLeavesTheFilesMoved() async throws {
        let (store, sync, _, files) = try await makeFaultFixture()
        store.failingWrites = (winnerKey, SidecarStoreError.timedOut(winnerKey))

        await #expect(throws: SidecarStoreError.timedOut(winnerKey)) {
            _ = try await sync.reconcileContactIdentity(localID: "C1")
        }

        #expect(Set(try store.blobIds(for: winnerKey)) == Set(files))
        #expect(try store.read(loserKey) != nil)
    }

    // MARK: - Through the repository

    /// The record gains both IDs after the cache loaded it, as sync can do.
    @MainActor private func makeRepositoryWithUnloadedIDs(
        store: SidecarStoreProtocol
    ) async throws -> (ContactsRepository, InMemoryContactStore, GuessWhoSync, ContactID) {
        let contacts = InMemoryContactStore(contacts: [Contact(localID: "C1", givenName: "Ada")])
        let sync = makeSync(contacts, store)
        let repo = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: NotificationCenter())
        await repo.reload()
        let id = try #require(repo.contact(localID: "C1")).contactID
        #expect(id.guessWhoID == nil)
        try await contacts.save(Contact(localID: "C1", givenName: "Ada", urlAddresses: [
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + winner),
            LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + loser),
        ]))
        return (repo, contacts, sync, id)
    }

    @Test @MainActor func aWriteWithNoCachedIdentityMergesAndKeepsTheLosersPhoto() async throws {
        let store = InMemorySidecarStore()
        let (repo, contacts, sync, id) = try await makeRepositoryWithUnloadedIDs(store: store)
        let older = try plantOlderCurrent(Data([1]), at: loserKey, in: store, stamp: Date(timeIntervalSinceNow: -100))

        try await repo.setContactPhoto(for: id, imageData: Data([2]))

        #expect(try await contacts.fetch(localID: "C1")?.urlAddresses.count == 1)
        #expect(try store.read(loserKey) == nil)
        #expect(try sync.storedContactPhoto(at: winnerKey, blobID: older)?.data == Data([1]))
    }

    /// A merge that stopped is retried only while the cache still has no ID. After a
    /// reload the fast path skips it, and the loser's data stays out of view for good.
    @Test @MainActor func aStoppedMergeIsNotRetriedAfterAReload() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeFileStore(root: root)
        let (repo, contacts, sync, id) = try await makeRepositoryWithUnloadedIDs(store: store)
        let older = try plantOlderCurrent(Data([1]), at: loserKey, in: store, stamp: Date(timeIntervalSinceNow: -100))
        try sync.addField(at: loserKey, field: "Nickname", type: .note, value: .string("Ace"))
        let placeholder = root.appendingPathComponent("contacts")
            .appendingPathComponent(".\(loser).dddddddd-dddd-4ddd-8ddd-dddddddddddd.dat.icloud")
        try Data().write(to: placeholder)

        await #expect(throws: SidecarStoreError.notYetDownloaded(loserKey)) {
            try await repo.setContactPhoto(for: id, imageData: Data([2]))
        }
        #expect(try await contacts.loadImageData(localID: "C1") == nil)

        await repo.reload()
        let reloaded = try #require(repo.contact(localID: "C1")).contactID
        try await repo.setContactPhoto(for: reloaded, imageData: Data([2]))

        // The write went to the ID the contact carries first, and no merge ran.
        #expect(try await contacts.fetch(localID: "C1")?.urlAddresses.count == 2)
        #expect(try sync.storedContactPhotos(at: winnerKey).photos.count == 1)
        // Nothing is destroyed, but the loser's photo and field are out of view.
        #expect(try store.readBlob(blobId: older, for: loserKey) == Data([1]))
        #expect(try store.read(loserKey) != nil)
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
        #expect(try await !repo.contactPhotos(for: reloaded).contains { $0.id == older })
        #expect(!repo.fields(for: reloaded).contains { $0.field == "Nickname" })
    }
}

/// An in-memory store whose writes and moves can fail on demand during a merge.
private final class MergeFaultStore: SidecarStoreProtocol, @unchecked Sendable {
    enum Failure: Error { case injected }

    private let base = InMemorySidecarStore()
    var failingWrites: (key: SidecarKey, error: Error)?
    var failingMoveNumber: Int?
    var failsMovesToLoser = false
    private var moves = 0

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? { try base.read(key) }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        if let failingWrites, failingWrites.key == key { throw failingWrites.error }
        try base.write(envelope, at: key)
    }
    func delete(_ key: SidecarKey) throws { try base.delete(key) }
    func allKeys() throws -> [SidecarKey] { try base.allKeys() }
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws { try base.writeBlob(data, blobId: blobId, for: key) }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? { try base.readBlob(blobId: blobId, for: key) }
    func deleteBlob(blobId: String, for key: SidecarKey) throws { try base.deleteBlob(blobId: blobId, for: key) }
    func blobIds(for key: SidecarKey) throws -> [String] { try base.blobIds(for: key) }
    func moveBlob(blobId: String, from source: SidecarKey, to destination: SidecarKey) throws {
        moves += 1
        if moves == failingMoveNumber { throw Failure.injected }
        if failsMovesToLoser, destination.id == "22222222-2222-4222-8222-222222222222" { throw Failure.injected }
        try base.moveBlob(blobId: blobId, from: source, to: destination)
    }
}
