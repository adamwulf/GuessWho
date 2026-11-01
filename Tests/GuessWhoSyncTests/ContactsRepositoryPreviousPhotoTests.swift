import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Replacing a contact's photo on the contact-image write path keeps the OLD bytes
/// as another photo on the contact. The app needs no change: it calls
/// `setContactPhoto` and gets that for free.
@Suite("ContactsRepository keeps the previous photo")
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
    // stored photos directly off the engine.
    @MainActor
    private func contactKey(_ repository: ContactsRepository, localID: String) throws -> SidecarKey {
        let contact = try #require(repository.contact(localID: localID))
        let guessWhoID = try #require(ContactID(contact: contact).guessWhoID)
        return SidecarKey(kind: .contact, id: guessWhoID)
    }

    /// The bytes of every stored photo on the contact.
    private func storedBytes(_ sync: GuessWhoSync, key: SidecarKey) throws -> Set<Data> {
        Set(try sync.storedContactPhotos(at: key).photos.compactMap {
            try sync.storedContactPhoto(at: key, blobID: $0.pointer.blobId)?.data
        })
    }

    @Test @MainActor
    func setPhotoOnContactWithExistingPhotoKeepsOldBytes() async throws {
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

        // The OLD bytes are retrievable as another stored photo.
        let key = try contactKey(repository, localID: "ada")
        #expect(try storedBytes(sync, key: key) == [oldBytes, newBytes])
    }

    @Test @MainActor
    func keptPhotoContentTypeReflectsImageMagicBytes() async throws {
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
        let pointer = try #require(try sync.storedContactPhotos(at: key).photos.first {
            $0.pointer.byteCount == pngBytes.count
        }).pointer
        #expect(pointer.contentType == "image/png")
    }

    @Test @MainActor
    func settingAgainKeepsEveryPhotoAndItsFile() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let firstPhoto = Data([0xFF, 0xD8, 0xFF, 0xAA])
        await contactStore.setImageData(firstPhoto, thumbnail: firstPhoto, for: "ada")
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID

        let secondPhoto = Data([0xFF, 0xD8, 0xFF, 0xBB])
        _ = try await repository.setContactPhoto(for: id, imageData: secondPhoto)
        let key = try contactKey(repository, localID: "ada")
        #expect(try storedBytes(sync, key: key) == [firstPhoto, secondPhoto])
        #expect(try sidecars.blobIds(for: key).count == 2)

        let thirdPhoto = Data([0xFF, 0xD8, 0xFF, 0xCC])
        _ = try await repository.setContactPhoto(for: id, imageData: thirdPhoto)
        #expect(try storedBytes(sync, key: key) == [firstPhoto, secondPhoto, thirdPhoto])
        #expect(try sidecars.blobIds(for: key).count == 3)
        #expect(try sync.fields(at: key).filter { $0.field == ContactsRepository.previousPhotoFieldName }.isEmpty)
    }

    @Test @MainActor
    func nothingExtraWhenContactHasNoCurrentPhoto() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: false)
        let contactStore = InMemoryContactStore(contacts: [contact])
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        // First-ever photo: nothing else to keep.
        _ = try await repository.setContactPhoto(for: id, imageData: Data([0x10, 0x20]))

        let key = try contactKey(repository, localID: "ada")
        #expect(try sync.fields(at: key).filter { $0.field == ContactsRepository.previousPhotoFieldName }.isEmpty)
        #expect(try sidecars.blobIds(for: key).count == 1)
    }

    @Test @MainActor
    func clearingPhotoKeepsTheReplacedBytes() async throws {
        // Setting nil (clear) on a contact that HAS a photo still preserves the
        // replaced bytes as a stored photo.
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
        #expect(try storedBytes(sync, key: key) == [oldBytes])
    }

    @Test @MainActor
    func photoCellsAreHiddenFromUserVisibleFields() async throws {
        // REGRESSION: photo cells are internal infrastructure and must NOT surface
        // in `fields(for:)` (which drives the user-facing custom-fields UI) —
        // otherwise a phantom row appears once a photo is replaced (a
        // product-principle violation). User-added text/date/checkbox fields
        // still show; only `.blob` is filtered.
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let contactStore = InMemoryContactStore(contacts: [contact])
        await contactStore.setImageData(Data([0xFF, 0xD8, 0xFF, 0x01]), thumbnail: Data([0xFF]), for: "ada")
        let sidecars = InMemorySidecarStore()
        let sync = makeSync(contacts: contactStore, sidecars: sidecars)
        let repository = ContactsRepository(contacts: contactStore, sync: sync)
        await repository.reload()

        let id = try #require(repository.contact(localID: "ada")).contactID
        // Add a normal user field, then replace the photo (which stores the old one).
        _ = try await repository.upsertField(for: id, field: "Nickname", value: "Ace", type: .note)
        _ = try await repository.setContactPhoto(for: id, imageData: Data([0x10, 0x20]))

        // Re-resolve the id (a sidecar write may have minted the GuessWho UUID).
        let freshID = try #require(repository.contact(localID: "ada")).contactID
        let visible = repository.fields(for: freshID)
        // The user field is visible; the photo cells are NOT.
        #expect(visible.contains { $0.field == "Nickname" && $0.type == .note })
        #expect(!visible.contains { $0.field == ContactsRepository.contactPhotoFieldName })
        #expect(!visible.contains { $0.type == .blob })

        // But the photos are still retrievable through the typed accessor
        // (filtering hides them from the field LIST, not from reads).
        let key = try contactKey(repository, localID: "ada")
        #expect(try storedBytes(sync, key: key).count == 2)
    }

    @Test @MainActor
    func photoWriteSucceedsWhenSyncEngineUnavailable() async throws {
        // No sync engine → nothing is stored; the photo write still proceeds.
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
