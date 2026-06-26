import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository contact photo API")
struct ContactsRepositoryPhotoTests {
    @Test @MainActor
    func contactPhotoData_loadsThumbnailBytesByContactID() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let store = InMemoryContactStore(contacts: [contact])
        let thumbnail = Data([0xaa, 0xbb])
        await store.setImageData(Data([0x01]), thumbnail: thumbnail, for: "ada")
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        let photo = try await repository.contactPhotoData(for: id, kind: .thumbnail)

        #expect(photo?.kind == .thumbnail)
        #expect(photo?.data == thumbnail)
    }

    @Test @MainActor
    func contactPhotoData_loadsFullSizeBytesByContactID() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let store = InMemoryContactStore(contacts: [contact])
        let image = Data([0x01, 0x02, 0x03])
        await store.setImageData(image, thumbnail: Data([0xaa]), for: "ada")
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        let photo = try await repository.contactPhotoData(for: id, kind: .fullSize)

        #expect(photo?.kind == .fullSize)
        #expect(photo?.data == image)
    }

    @Test @MainActor
    func contactPhotoData_shortCircuitsWhenImageDataUnavailable() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: false)
        let store = InMemoryContactStore(contacts: [contact])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let baselineCount = await store.imageSidebandAccessCount
        let id = (try #require(repository.contact(localID: "ada"))).contactID
        let photo = try await repository.contactPhotoData(for: id, kind: .thumbnail)

        #expect(photo == nil)
        #expect(await store.imageSidebandAccessCount == baselineCount)
    }

    @Test @MainActor
    func contactPhotoData_returnsNilWhenStoreRecordWasDeleted() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let store = InMemoryContactStore(contacts: [contact])
        await store.setImageData(Data([0x01]), thumbnail: Data([0xaa]), for: "ada")
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        try await store.delete(localID: "ada")

        let photo = try await repository.contactPhotoData(for: id, kind: .thumbnail)

        #expect(photo == nil)
    }

    @Test @MainActor
    func contactPhotoData_returnsNilForUnresolvedContactID() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let store = InMemoryContactStore(contacts: [contact])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        repository.removeContact(localID: "ada")

        let photo = try await repository.contactPhotoData(for: id, kind: .fullSize)

        #expect(photo == nil)
    }

    @Test @MainActor
    func setContactPhoto_writesBytesAndFlipsImageDataAvailable() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: false)
        let store = InMemoryContactStore(contacts: [contact])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        let image = Data([0x10, 0x20, 0x30])
        let didWrite = try await repository.setContactPhoto(for: id, imageData: image)

        #expect(didWrite)
        // The refreshed record reflects the write.
        #expect(repository.contact(localID: "ada")?.imageDataAvailable == true)
        // And the bytes are now loadable through the read path.
        let photo = try await repository.contactPhotoData(for: id, kind: .fullSize)
        #expect(photo?.data == image)
    }

    @Test @MainActor
    func setContactPhoto_clearsBytesWhenPassedNil() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: true)
        let store = InMemoryContactStore(contacts: [contact])
        await store.setImageData(Data([0x01]), thumbnail: Data([0xaa]), for: "ada")
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        let didWrite = try await repository.setContactPhoto(for: id, imageData: nil)

        #expect(didWrite)
        #expect(repository.contact(localID: "ada")?.imageDataAvailable == false)
        let photo = try await repository.contactPhotoData(for: id, kind: .fullSize)
        #expect(photo == nil)
    }

    @Test @MainActor
    func setContactPhoto_returnsFalseForUnresolvedContactID() async throws {
        let contact = Contact(localID: "ada", givenName: "Ada", imageDataAvailable: false)
        let store = InMemoryContactStore(contacts: [contact])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = (try #require(repository.contact(localID: "ada"))).contactID
        repository.removeContact(localID: "ada")

        let didWrite = try await repository.setContactPhoto(for: id, imageData: Data([0x01]))

        #expect(didWrite == false)
    }
}
