import Foundation
import CryptoKit
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync

@Suite("FileSystemSidecarStore + blob payloads")
struct FileSystemSidecarStoreBlobTests {
    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-blob-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // A store wired with a deterministic in-memory key — NEVER the real
    // keychain. The fake ubiquity provider records startDownloading calls so
    // the placeholder path can be asserted.
    private func makeStore(
        root: URL,
        ubiquity: FakeUbiquityProvider = FakeUbiquityProvider(),
        key: SymmetricKey = SymmetricKey(size: .bits256)
    ) -> FileSystemSidecarStore {
        FileSystemSidecarStore(
            root: root,
            ubiquity: ubiquity,
            blobCrypto: InMemoryBlobCrypto(key: key)
        )
    }

    private let contactKey = SidecarKey(kind: .contact, id: "11111111-1111-1111-1111-111111111111")

    @Test
    func writeThenReadRoundTripsBytes() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        let payload = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02])
        let blobId = UUID().uuidString
        try store.writeBlob(payload, blobId: blobId, for: contactKey)
        let read = try #require(try store.readBlob(blobId: blobId, for: contactKey))
        #expect(read == payload)
    }

    @Test
    func readOfMissingBlobReturnsNil() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        #expect(try store.readBlob(blobId: UUID().uuidString, for: contactKey) == nil)
    }

    @Test
    func datOnDiskIsEncryptedNotPlaintext() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        // Recognizable plaintext so a substring scan is meaningful.
        let payload = Data("SUPER-SECRET-PHOTO-BYTES".utf8)
        let blobId = "abababab-abab-abab-abab-abababababab"
        try store.writeBlob(payload, blobId: blobId, for: contactKey)

        let datURL = root.appendingPathComponent("contacts")
            .appendingPathComponent("\(contactKey.id).\(blobId).dat")
        let onDisk = try Data(contentsOf: datURL)
        // The raw file must NOT contain the plaintext (it is AES-GCM sealed).
        #expect(onDisk != payload)
        #expect(onDisk.range(of: payload) == nil)
        // And it round-trips back through the store's decrypt path.
        #expect(try store.readBlob(blobId: blobId, for: contactKey) == payload)
    }

    @Test
    func anotherDeviceWithSameKeyCanDecrypt() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        // Two stores at the SAME root sharing the SAME key model two synced
        // devices: device B can decrypt the `.dat` device A wrote.
        let sharedKey = SymmetricKey(size: .bits256)
        let deviceA = makeStore(root: root, key: sharedKey)
        let deviceB = makeStore(root: root, key: sharedKey)
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let blobId = UUID().uuidString
        try deviceA.writeBlob(payload, blobId: blobId, for: contactKey)
        #expect(try deviceB.readBlob(blobId: blobId, for: contactKey) == payload)
    }

    @Test
    func decryptWithWrongKeyThrows() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let deviceA = makeStore(root: root, key: SymmetricKey(size: .bits256))
        let blobId = UUID().uuidString
        try deviceA.writeBlob(Data([0xaa, 0xbb]), blobId: blobId, for: contactKey)
        // A store with a DIFFERENT key cannot open the sealed box.
        let deviceWrongKey = makeStore(root: root, key: SymmetricKey(size: .bits256))
        #expect(throws: (any Error).self) {
            _ = try deviceWrongKey.readBlob(blobId: blobId, for: contactKey)
        }
    }

    @Test
    func deleteRemovesBlobFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        let blobId = UUID().uuidString
        try store.writeBlob(Data([0x09]), blobId: blobId, for: contactKey)
        #expect(try store.readBlob(blobId: blobId, for: contactKey) != nil)
        try store.deleteBlob(blobId: blobId, for: contactKey)
        #expect(try store.readBlob(blobId: blobId, for: contactKey) == nil)
    }

    @Test
    func deleteOfMissingBlobIsNoOp() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        try store.deleteBlob(blobId: UUID().uuidString, for: contactKey)
    }

    @Test
    func blobIdsListsEveryDatForKey() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        let id1 = "00000000-0000-0000-0000-000000000001"
        let id2 = "00000000-0000-0000-0000-000000000002"
        try store.writeBlob(Data([0x01]), blobId: id1, for: contactKey)
        try store.writeBlob(Data([0x02]), blobId: id2, for: contactKey)

        let ids = try store.blobIds(for: contactKey)
        #expect(Set(ids) == Set([id1, id2]))
    }

    @Test
    func blobIdsScopedToKeyAndDoesNotPickUpEnvelopeJSON() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        // Write the envelope `.json` AND a `.dat` for the same key; blobIds
        // must see only the `.dat`, never the `.json`.
        try store.write(SidecarEnvelope(entityID: contactKey.id, fields: [:]), at: contactKey)
        let blobId = UUID().uuidString
        try store.writeBlob(Data([0x07]), blobId: blobId, for: contactKey)
        // A DIFFERENT key's blob must not leak into this key's listing.
        let otherKey = SidecarKey(kind: .contact, id: "22222222-2222-2222-2222-222222222222")
        try store.writeBlob(Data([0x08]), blobId: UUID().uuidString, for: otherKey)

        let ids = try store.blobIds(for: contactKey)
        #expect(ids == [blobId])
        // And allKeys() (envelope enumeration) is `.dat`-blind: only the key
        // with a written `.json` envelope surfaces. `otherKey` has a `.dat`
        // but no envelope, so it must NOT appear as an envelope key.
        let keys = try store.allKeys()
        #expect(keys == [contactKey])
    }

    @Test
    func blobIdsForKeyWithNoDirectoryReturnsEmpty() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        #expect(try store.blobIds(for: contactKey).isEmpty)
    }

    // MARK: - iCloud placeholder handling for a `.dat`

    private func plantBlobPlaceholder(in root: URL, kindDir: String, basename: String) throws {
        let dir = root.appendingPathComponent(kindDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // iCloud names a not-yet-downloaded `name.dat` as `.name.dat.icloud`.
        let placeholderName = ".\(basename).icloud"
        try Data().write(to: dir.appendingPathComponent(placeholderName))
    }

    @Test
    func readOfPlaceholderBlobReturnsNilAndRequestsDownload() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let ubiquity = FakeUbiquityProvider()
        let store = makeStore(root: root, ubiquity: ubiquity)
        let blobId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let datBasename = "\(contactKey.id).\(blobId).dat"
        try plantBlobPlaceholder(in: root, kindDir: "contacts", basename: datBasename)

        // A referenced-but-not-yet-downloaded blob is "pending," not "gone":
        // read returns nil (NOT a throw) and kicks off a download.
        #expect(try store.readBlob(blobId: blobId, for: contactKey) == nil)
        let datURL = root.appendingPathComponent("contacts").appendingPathComponent(datBasename)
        #expect(ubiquity.startDownloadingCalls.contains(datURL))
    }

    @Test
    func blobIdsIncludesPlaceholderStubs() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let ubiquity = FakeUbiquityProvider()
        let store = makeStore(root: root, ubiquity: ubiquity)
        let blobId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let datBasename = "\(contactKey.id).\(blobId).dat"
        try plantBlobPlaceholder(in: root, kindDir: "contacts", basename: datBasename)

        // The orphan sweep must SEE a not-yet-downloaded blob so it doesn't
        // delete the loser — blobIds surfaces it from the placeholder stub.
        let ids = try store.blobIds(for: contactKey)
        #expect(ids == [blobId])
    }

    @Test
    func blobIdsDeduplicatesPlaceholderAndRealFile() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        let blobId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        try store.writeBlob(Data([0x01]), blobId: blobId, for: contactKey)
        // Plant a leftover placeholder alongside the real `.dat`.
        try plantBlobPlaceholder(in: root, kindDir: "contacts", basename: "\(contactKey.id).\(blobId).dat")

        let ids = try store.blobIds(for: contactKey)
        #expect(ids == [blobId])
    }
}
