import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// The previous-photo snapshot on the contact-image write path. Setting a photo
/// on a contact that already has one captures the OLD bytes into a single-slot
/// `previousPhoto` `.blob`; setting again overwrites the slot and reclaims the
/// superseded `.dat`. The app needs no change — it calls `setContactPhoto` and
/// gets the snapshot for free.
@Suite("ContactsRepository previous-photo snapshot")
struct ContactsRepositoryPreviousPhotoTests {
    private func makeSync(contacts: InMemoryContactStore, sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }

    // Resolve the contact's minted GuessWho key so the test can read the
    // snapshot blob directly off the engine.
    @MainActor
    private func contactKey(_ repository: ContactsRepository, localID: String) throws -> SidecarKey {
        let contact = try #require(repository.contact(localID: localID))
        let guessWhoID = try #require(ContactID(contact: contact).guessWhoID)
        return SidecarKey(kind: .contact, id: guessWhoID)
    }

    @Test @MainActor
    func setPhotoOnContactWithExistingPhotoSnapshotsOldBytes() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let oldBytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02]) // JPEG-ish header
        await contactStore.setImageData(oldBytes, thumbnail: oldBytes, for: "ada")
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        let newBytes = Data([0x10, 0x20, 0x30])
        let didWrite = try await repository.setContactPhoto(for: id, imageData: newBytes)
        #expect(didWrite)

        // The new photo is live on the contact.
        let livePhoto = try await repository.contactPhotoData(for: id, kind: .fullSize)
        #expect(livePhoto?.data == newBytes)

        // The OLD bytes are retrievable as the previousPhoto snapshot blob.
        let key = try contactKey(repository, localID: "ada")
        let snapshot = try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName)
        #expect(snapshot == oldBytes)
    }

    @Test @MainActor
    func snapshotContentTypeReflectsImageMagicBytes() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAB])
        await contactStore.setImageData(pngBytes, thumbnail: pngBytes, for: "ada")
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        _ = try await repository.setContactPhoto(for: id, imageData: Data([0x10]))

        let key = try contactKey(repository, localID: "ada")
        let field = try #require(try sync.fields(at: key).first { $0.field == ContactsRepository.previousPhotoFieldName })
        let pointer = try #require(BlobPointer(from: field.value))
        #expect(pointer.contentType == "image/png")
        #expect(pointer.byteCount == pngBytes.count)
    }

    @Test @MainActor
    func settingAgainOverwritesSlotAndReclaimsSupersededDat() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let firstPhoto = Data([0xFF, 0xD8, 0xFF, 0xAA])
        await contactStore.setImageData(firstPhoto, thumbnail: firstPhoto, for: "ada")
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID

        // First replacement: snapshot is `firstPhoto`.
        let secondPhoto = Data([0xFF, 0xD8, 0xFF, 0xBB])
        _ = try await repository.setContactPhoto(for: id, imageData: secondPhoto)
        let key = try contactKey(repository, localID: "ada")
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == firstPhoto)
        let firstBlobIds = try sidecars.blobIds(for: key)
        #expect(firstBlobIds.count == 1)

        // Second replacement: snapshot now holds `secondPhoto`; still exactly
        // ONE `.dat` on disk (the superseded one was reclaimed) and ONE live
        // previousPhoto field.
        let thirdPhoto = Data([0xFF, 0xD8, 0xFF, 0xCC])
        _ = try await repository.setContactPhoto(for: id, imageData: thirdPhoto)
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == secondPhoto)
        let secondBlobIds = try sidecars.blobIds(for: key)
        #expect(secondBlobIds.count == 1)
        #expect(secondBlobIds != firstBlobIds) // fresh blobId per snapshot
        let live = try sync.fields(at: key).filter { $0.deletedAt == nil && $0.field == ContactsRepository.previousPhotoFieldName }
        #expect(live.count == 1)
    }

    @Test @MainActor
    func noSnapshotWhenContactHasNoCurrentPhoto() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: false)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        // First-ever photo: nothing to snapshot.
        _ = try await repository.setContactPhoto(for: id, imageData: Data([0x10, 0x20]))

        // No previousPhoto field exists, and no `.dat` was written.
        guard let guessWhoID = ContactID(contact: try #require(repository.contact(localID: "ada"))).guessWhoID else {
            // An unreconciled contact never minted — equally proves "no snapshot."
            return
        }
        let key = SidecarKey(kind: .contact, id: guessWhoID)
        #expect(try sync.fields(at: key).filter { $0.field == ContactsRepository.previousPhotoFieldName }.isEmpty)
        #expect(try sidecars.blobIds(for: key).isEmpty)
    }

    @Test @MainActor
    func clearingPhotoStillSnapshotsTheReplacedBytes() async throws {
        // Setting nil (clear) on a contact that HAS a photo still preserves the
        // replaced bytes as the previous photo.
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let oldBytes = Data([0xFF, 0xD8, 0xFF, 0x77])
        await contactStore.setImageData(oldBytes, thumbnail: oldBytes, for: "ada")
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        _ = try await repository.setContactPhoto(for: id, imageData: nil)

        #expect(repository.contact(localID: "ada")?.imageDataAvailable == false)
        let key = try contactKey(repository, localID: "ada")
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == oldBytes)
    }

    @Test @MainActor
    func photoWriteSucceedsWhenSyncEngineUnavailable() async throws {
        // No sync engine → snapshot is silently skipped; the photo write still
        // proceeds (the snapshot must never block it).
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        await contactStore.setImageData(Data([0xFF, 0xD8, 0xFF]), thumbnail: Data([0xFF]), for: "ada")
        let repository = ContactsRepository(contacts: contactStore) // sync == nil
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        let didWrite = try await repository.setContactPhoto(for: id, imageData: Data([0x10]))
        #expect(didWrite)
        let photo = try await repository.contactPhotoData(for: id, kind: .fullSize)
        #expect(photo?.data == Data([0x10]))
    }
}
