import Foundation
import CryptoKit
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync

/// A device whose keychain refuses every call, as Mac Catalyst's does.
final class NoKeyBlobCrypto: SidecarBlobCrypto {
    func decrypt(_ ciphertext: Data) throws -> Data {
        throw SidecarBlobCryptoError.keychainStatus(-34018)
    }
}

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
            blobCrypto: InMemoryBlobCrypto(key: key),
            coordinatesUbiquitousAccess: false
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
    func keychainFailureNamesItsStatusInPlainLanguage() {
        let message = SidecarBlobCryptoError.keychainStatus(-34018).localizedDescription
        #expect(message.contains("-34018"))
        #expect(!message.contains("Sidecar"))
        #expect(!message.contains("GuessWhoSync"))
    }

    @Test
    func readOfMissingBlobReturnsNil() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        #expect(try store.readBlob(blobId: UUID().uuidString, for: contactKey) == nil)
    }

    // Writes a `.dat` the way older builds did: AES-GCM sealed, with no marker.
    private func writeLegacyEncryptedBlob(_ payload: Data, blobId: String, key: SymmetricKey, root: URL) throws {
        let directory = root.appendingPathComponent("contacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sealed = try InMemoryBlobCrypto(key: key).encrypt(payload)
        try sealed.write(to: directory.appendingPathComponent("\(contactKey.id).\(blobId).dat"))
    }

    @Test
    func newBlobIsNotEncrypted() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        let payload = Data("RECOGNIZABLE-PHOTO-BYTES".utf8)
        let blobId = "abababab-abab-abab-abab-abababababab"
        try store.writeBlob(payload, blobId: blobId, for: contactKey)

        let datURL = root.appendingPathComponent("contacts")
            .appendingPathComponent("\(contactKey.id).\(blobId).dat")
        #expect(try Data(contentsOf: datURL).range(of: payload) != nil)
        #expect(try store.readBlob(blobId: blobId, for: contactKey) == payload)
    }

    // These bytes are a synced format. If they changed, every file already written
    // would read as an encrypted one. Never update this test to match a new marker.
    @Test
    func shippedMarkerBytesStillReadAsPlain() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let payload = Data([0x01, 0x02])
        let blobId = UUID().uuidString
        let directory = root.appendingPathComponent("contacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (Data("GuessWhoPlainBlob1\n".utf8) + payload)
            .write(to: directory.appendingPathComponent("\(contactKey.id).\(blobId).dat"))

        #expect(try makeStore(root: root).readBlob(blobId: blobId, for: contactKey) == payload)
    }

    // The Mac case: the keychain refuses every call, and saving and reading a new
    // photo must not care.
    @Test
    func newBlobWritesAndReadsWithNoKey() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = FileSystemSidecarStore(
            root: root,
            ubiquity: FakeUbiquityProvider(),
            blobCrypto: NoKeyBlobCrypto(),
            coordinatesUbiquitousAccess: false
        )
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let blobId = UUID().uuidString
        try store.writeBlob(payload, blobId: blobId, for: contactKey)
        let read = try #require(try store.readBlob(blobId: blobId, for: contactKey))
        #expect(read == payload)
        // Callers index the bytes from zero, so the marker must not leave an offset.
        #expect(read.startIndex == 0)
    }

    @Test
    func emptyBlobRoundTrips() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        let blobId = UUID().uuidString
        try store.writeBlob(Data(), blobId: blobId, for: contactKey)
        #expect(try store.readBlob(blobId: blobId, for: contactKey) == Data())
    }

    @Test
    func olderEncryptedBlobStillDecryptsWithItsKey() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let key = SymmetricKey(size: .bits256)
        let payload = Data([0xaa, 0xbb])
        let blobId = UUID().uuidString
        try writeLegacyEncryptedBlob(payload, blobId: blobId, key: key, root: root)
        #expect(try makeStore(root: root, key: key).readBlob(blobId: blobId, for: contactKey) == payload)
    }

    @Test
    func olderEncryptedBlobWithoutItsKeyReportsCannotDecrypt() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let blobId = UUID().uuidString
        try writeLegacyEncryptedBlob(Data([0xaa, 0xbb]), blobId: blobId, key: SymmetricKey(size: .bits256), root: root)
        let wrongKey = makeStore(root: root, key: SymmetricKey(size: .bits256))
        #expect(throws: SidecarBlobCryptoError.cannotDecrypt) {
            _ = try wrongKey.readBlob(blobId: blobId, for: contactKey)
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

    @Test
    func deletingEnvelopeCascadesBlobCleanup() throws {
        let root = makeRoot()
        defer { cleanup(root) }
        let store = makeStore(root: root)
        // An envelope + two `.dat`s under the same key.
        try store.write(SidecarEnvelope(entityID: contactKey.id, fields: [:]), at: contactKey)
        try store.writeBlob(Data([0x01]), blobId: "b1", for: contactKey)
        try store.writeBlob(Data([0x02]), blobId: "b2", for: contactKey)
        #expect(Set(try store.blobIds(for: contactKey)) == Set(["b1", "b2"]))

        // Deleting the record self-cleans its `.dat`s (envelope-delete orphan
        // prevention — the global sweep is only the cross-device backstop).
        try store.delete(contactKey)
        #expect(try store.read(contactKey) == nil)
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
