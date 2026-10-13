import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Photo source changes and failed saves")
@MainActor
struct ContactPhotoSourceTests {
    private func fixture() async throws -> (ContactsRepository, InMemoryContactStore, PhotoTestStore, GuessWhoSync, ContactID, UserDefaults) {
        let localID = UUID().uuidString
        let contacts = InMemoryContactStore(contacts: [Contact(localID: localID, givenName: "Ada")])
        let files = PhotoTestStore()
        let sync = GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: files, deviceID: "test")
        let defaults = try #require(UserDefaults(suiteName: "PhotoSourceTests.\(UUID().uuidString)"))
        let repo = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: NotificationCenter(), photoSourceDefaults: defaults)
        await repo.reload()
        return (repo, contacts, files, sync, try #require(repo.contact(localID: localID)).contactID, defaults)
    }

    @Test func externalReplacementAndRemovalClearCropAfterRelaunch() async throws {
        let (repo, contacts, _, sync, id, defaults) = try await fixture()
        let original = Data([1, 2, 3])
        let crop = try #require(ContactPhotoCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        try await repo.setContactPhoto(for: id, imageData: original, crop: crop)
        let contact = try #require(repo.contact(id: id))
        let key = try #require(SidecarKey.forContact(contact))
        var unrelatedEdit = contact
        unrelatedEdit.givenName = "Augusta"
        try await contacts.save(unrelatedEdit)
        await repo.reload()
        #expect(try await repo.contactPhotoData(for: id, kind: .fullSize)?.crop == crop)

        let replacement = Data([4, 5, 6])
        try await contacts.setImageData(localID: contact.localID, imageData: replacement)
        let reopened = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: NotificationCenter(), photoSourceDefaults: defaults)
        await reopened.reload()
        let adopted = try #require(try await reopened.contactPhotoData(for: id, kind: .fullSize))
        #expect(adopted.data == replacement)
        #expect(adopted.crop == nil)
        // Detection is local: it cannot race an incoming synced photo/crop.
        #expect(try sync.profilePhoto(at: key)?.photo.data == original)
        #expect(try sync.profilePhoto(at: key)?.photo.crop == crop)
        let relaunched = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: NotificationCenter(), photoSourceDefaults: defaults)
        await relaunched.reload()
        #expect(try await relaunched.contactPhotoData(for: id, kind: .fullSize)?.data == replacement)
        #expect(try await relaunched.contactPhotoData(for: id, kind: .fullSize)?.crop == nil)

        try await reopened.setContactPhotoCrop(for: id, crop: crop, originalData: replacement)
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == original)
        try await contacts.setImageData(localID: contact.localID, imageData: nil)
        await reopened.reload()
        #expect(try await reopened.contactPhotoData(for: id, kind: .fullSize) == nil)
        #expect(try sync.profilePhoto(at: key)?.photo.data == replacement)
        let afterRemoval = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: NotificationCenter(), photoSourceDefaults: defaults)
        await afterRemoval.reload()
        #expect(try await afterRemoval.contactPhotoData(for: id, kind: .fullSize) == nil)
        try await afterRemoval.setContactPhoto(for: id, imageData: nil)
        #expect(try sync.profilePhoto(at: key) == nil)
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == replacement)
    }

    @Test func staleCropEditorCannotOverwriteReplacement() async throws {
        let (repo, _, _, _, id, _) = try await fixture()
        let original = Data([1, 2])
        let replacement = Data([3, 4])
        try await repo.setContactPhoto(for: id, imageData: original)
        try await repo.setContactPhoto(for: id, imageData: replacement)
        do {
            try await repo.setContactPhotoCrop(for: id,
                crop: ContactPhotoCrop(x: 0, y: 0, width: 0.5, height: 0.5), originalData: original)
            Issue.record("A stale crop was accepted")
        } catch ContactPhotoEditError.photoChanged {}
        let current = try #require(try await repo.contactPhotoData(for: id, kind: .fullSize))
        #expect(current.data == replacement)
        #expect(current.crop == nil)
    }

    @Test func explicitReplacementRetainsTheOverriddenOriginal() async throws {
        let (repo, contacts, _, sync, id, _) = try await fixture()
        let original = Data([1, 2])
        try await repo.setContactPhoto(for: id, imageData: original)
        let contact = try #require(repo.contact(id: id))
        let key = try #require(SidecarKey.forContact(contact))
        try await contacts.setImageData(localID: contact.localID, imageData: Data([3, 4]))
        #expect(try await repo.contactPhotoData(for: id, kind: .fullSize)?.data == Data([3, 4]))
        try await repo.setContactPhoto(for: id, imageData: Data([5, 6]))
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == original)
        #expect(try await repo.contactPhotoData(for: id, kind: .fullSize)?.data == Data([5, 6]))
    }

    @Test(arguments: [false, true]) func failedStorageCommitRestoresSystemPhoto(removing: Bool) async throws {
        let (repo, contacts, files, _, id, _) = try await fixture()
        let original = Data([1, 2])
        let crop = try #require(ContactPhotoCrop(x: 0, y: 0, width: 0.5, height: 0.5))
        try await repo.setContactPhoto(for: id, imageData: original, crop: crop)
        files.failPhotoWrites = true
        do {
            try await repo.setContactPhoto(for: id, imageData: removing ? nil : Data([9, 8]))
            Issue.record("Injected storage failure was not propagated")
        } catch PhotoTestStore.Failure.injected {}
        let contact = try #require(repo.contact(id: id))
        #expect(try await contacts.loadImageData(localID: contact.localID) == original)
        let current = try #require(try await repo.contactPhotoData(for: id, kind: .fullSize))
        #expect(current.data == original)
        #expect(current.crop == crop)
    }

    @Test func pendingOriginalArrivalInvalidatesPhotoConsumers() async throws {
        let (repo, contacts, files, sync, id, defaults) = try await fixture()
        try await repo.setContactPhoto(for: id, imageData: Data([1, 2]))
        let key = try #require(SidecarKey.forContact(try #require(repo.contact(id: id))))
        let center = NotificationCenter()
        let reader = ContactsRepository(contacts: contacts, sync: sync, notificationCenter: center, photoSourceDefaults: defaults)
        await reader.reload()
        files.hideBlobs = true
        do {
            _ = try await reader.contactPhotoData(for: id, kind: .thumbnail)
            Issue.record("Expected a pending download")
        } catch SidecarStoreError.notYetDownloaded {}
        nonisolated(unsafe) var dataChanged = false
        let token = center.addObserver(forName: .contactsRepositoryDidReload, object: reader, queue: .main) { note in
            if note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool == true { dataChanged = true }
        }
        defer { center.removeObserver(token) }
        files.hideBlobs = false
        center.post(name: .guessWhoSidecarsDidChange, object: nil,
                    userInfo: [GuessWhoSidecarsDidChangeKey.changeSet: SidecarChangeSet(changedKeys: [key])])
        try await Task.sleep(for: .milliseconds(650))
        #expect(dataChanged)
        #expect(try await reader.contactPhotoData(for: id, kind: .thumbnail)?.data == Data([1, 2]))
    }

    @Test(arguments: [false, true]) func eitherSyncArrivalOrderPreservesCrop(contactsFirst: Bool) async throws {
        let (repo, contacts, _, sync, id, _) = try await fixture()
        let original = Data([1, 2])
        let incoming = Data([3, 4])
        let crop = try #require(ContactPhotoCrop(x: 0, y: 0, width: 0.5, height: 0.5))
        try await repo.setContactPhoto(for: id, imageData: original, crop: crop)
        let contact = try #require(repo.contact(id: id))
        let key = try #require(SidecarKey.forContact(contact))
        let before = try sync.profilePhoto(at: key)?.pointer
        if contactsFirst {
            try await contacts.setImageData(localID: contact.localID, imageData: incoming)
            let interim = try #require(try await repo.contactPhotoData(for: id, kind: .fullSize))
            #expect(interim.data == incoming)
            #expect(interim.crop == nil)
            #expect(try sync.profilePhoto(at: key)?.pointer == before)
        }
        try await sync.setBlobField(at: key, field: ContactsRepository.profilePhotoFieldName,
                                   data: incoming, contentType: "image/jpeg", photoCrop: crop,
                                   systemPhotoDigest: ContactPhotoSourceTracker.digest(incoming))
        let incomingPointer = try sync.profilePhoto(at: key)?.pointer
        #expect(try await repo.contactPhotoData(for: id, kind: .fullSize)?.crop == crop)
        if !contactsFirst {
            try await contacts.setImageData(localID: contact.localID, imageData: incoming)
        }
        let result = try #require(try await repo.contactPhotoData(for: id, kind: .fullSize))
        #expect(result.data == incoming)
        #expect(result.crop == crop)
        #expect(try sync.profilePhoto(at: key)?.pointer == incomingPointer)
    }

    @Test func sameOriginalRecropWaitsForExpectedSystemImage() throws {
        let defaults = try #require(UserDefaults(suiteName: "PhotoSourceTests.\(UUID().uuidString)"))
        let tracker = ContactPhotoSourceTracker(defaults: defaults)
        let key = SidecarKey(kind: .contact, id: UUID().uuidString.lowercased())
        tracker.record(key: key, original: "original", observed: "system")
        #expect(tracker.usesSystemPhoto(key: key, original: "original", blobID: "first", expected: "system", observed: "external"))
        // Replacing the system photo with identical bytes alone cannot revive an old crop.
        #expect(tracker.usesSystemPhoto(key: key, original: "original", blobID: "first", expected: "system", observed: "system"))
        // A newer crop may arrive before its expected Contacts representation.
        for _ in 0..<2 {
            #expect(tracker.usesSystemPhoto(key: key, original: "original", blobID: "second", expected: "new-system", observed: "system"))
        }
        #expect(!tracker.usesSystemPhoto(key: key, original: "original", blobID: "second", expected: "new-system", observed: "new-system"))
    }
}

private final class PhotoTestStore: SidecarStoreProtocol {
    enum Failure: Error { case injected }
    private let base = InMemorySidecarStore()
    private let lock = NSLock()
    private var failing = false
    private var hidden = false
    var failPhotoWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    var hideBlobs: Bool {
        get { lock.withLock { hidden } }
        set { lock.withLock { hidden = newValue } }
    }
    func read(_ key: SidecarKey) throws -> SidecarEnvelope? { try base.read(key) }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        if failPhotoWrites {
            let previous = try base.read(key)
            for (id, cell) in envelope.fields {
                guard case .object(let inner) = cell.value,
                      inner[SidecarField.innerFieldKey] == .string(ContactsRepository.profilePhotoFieldName) else { continue }
                if previous?.fields[id]?.value != cell.value || previous?.fields[id]?.deletedAt != cell.deletedAt {
                    throw Failure.injected
                }
            }
        }
        try base.write(envelope, at: key)
    }
    func delete(_ key: SidecarKey) throws { try base.delete(key) }
    func allKeys() throws -> [SidecarKey] { try base.allKeys() }
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus { base.downloadStatus(key) }
    func requestDownload(_ key: SidecarKey) throws {}
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws { try base.writeBlob(data, blobId: blobId, for: key) }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? { try hideBlobs ? nil : base.readBlob(blobId: blobId, for: key) }
    func deleteBlob(blobId: String, for key: SidecarKey) throws { try base.deleteBlob(blobId: blobId, for: key) }
    func blobIds(for key: SidecarKey) throws -> [String] { try base.blobIds(for: key) }
}
