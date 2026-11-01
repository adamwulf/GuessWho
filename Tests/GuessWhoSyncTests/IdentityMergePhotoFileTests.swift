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

    /// Nothing is destroyed: the merge stops before any write, and a later attempt
    /// finishes once the file has arrived.
    @Test func undownloadedLoserFileStopsTheMergeUntilItArrives() async throws {
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
}
