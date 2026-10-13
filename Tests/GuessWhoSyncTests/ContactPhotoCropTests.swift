import Foundation
import CoreGraphics
import CryptoKit
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Normalized photo crop")
struct ContactPhotoCropTests {
    @Test func squareFitsPortraitAndLandscape() throws {
        let landscape = try #require(ContactPhotoCrop.square(imageSize: CGSize(width: 1200, height: 800)))
        #expect(abs(landscape.x - 1.0 / 6) < 0.000001)
        #expect(landscape.y == 0)
        #expect(landscape.rectangle(in: CGSize(width: 1200, height: 800)).size == CGSize(width: 800, height: 800))
        let portrait = try #require(ContactPhotoCrop.square(imageSize: CGSize(width: 800, height: 1200)))
        #expect(portrait.x == 0)
        #expect(abs(portrait.y - 1.0 / 6) < 0.000001)
    }

    @Test func zoomAndPanCannotExposeOutsideImage() throws {
        let size = CGSize(width: 1600, height: 800)
        let topLeft = try #require(ContactPhotoCrop.square(imageSize: size, zoom: 2, center: CGPoint(x: -10, y: -10)))
        #expect(topLeft == ContactPhotoCrop(x: 0, y: 0, width: 0.25, height: 0.5))
        let bottomRight = try #require(ContactPhotoCrop.square(imageSize: size, zoom: 2, center: CGPoint(x: 10, y: 10)))
        #expect(bottomRight == ContactPhotoCrop(x: 0.75, y: 0.5, width: 0.25, height: 0.5))
        #expect(ContactPhotoCrop.square(imageSize: size, zoom: 0.1) == ContactPhotoCrop.square(imageSize: size))
    }

    @Test func cropDoesNotDependOnResolution() throws {
        let crop = try #require(ContactPhotoCrop.square(imageSize: CGSize(width: 400, height: 800), zoom: 3,
                                                      center: CGPoint(x: 0.3, y: 0.7)))
        #expect(crop == ContactPhotoCrop.square(imageSize: CGSize(width: 4000, height: 8000), zoom: 3,
                                               center: CGPoint(x: 0.3, y: 0.7)))
        #expect(try JSONDecoder().decode(ContactPhotoCrop.self, from: JSONEncoder().encode(crop)) == crop)
    }

    @Test func rejectsInvalidRectangles() {
        #expect(ContactPhotoCrop(x: -0.1, y: 0, width: 1, height: 1) == nil)
        #expect(ContactPhotoCrop(x: 0, y: 0, width: 0, height: 1) == nil)
        #expect(ContactPhotoCrop(x: 0.8, y: 0, width: 0.3, height: 1) == nil)
        #expect(ContactPhotoCrop(x: .nan, y: 0, width: 1, height: 1) == nil)
        #expect(ContactPhotoCrop.square(imageSize: .zero) == nil)
        #expect(ContactPhotoCrop.square(imageSize: CGSize(width: 1, height: 1), zoom: .infinity) == nil)
    }
}

@Suite("Original photo and crop persistence")
struct ContactPhotoCropPersistenceTests {
    @Test @MainActor func originalSurvivesSaveReloadReframeAndReset() async throws {
        let contacts = InMemoryContactStore(contacts: [Contact(localID: "ada", givenName: "Ada")])
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "test")
        let repository = ContactsRepository(contacts: contacts, sync: sync)
        await repository.reload()
        let id = try #require(repository.contact(localID: "ada")).contactID
        let original = Data((0..<255).map(UInt8.init))
        let crop = try #require(ContactPhotoCrop(x: 0.25, y: 0.125, width: 0.5, height: 0.25))
        #expect(try await repository.setContactPhoto(for: id, imageData: original, crop: crop))
        #expect(try await contacts.loadImageData(localID: "ada") == original)
        let savedContact = try #require(repository.contact(id: id))
        let key = try #require(SidecarKey.forContact(savedContact))
        // Exercise the on-disk JSON shape, not just in-memory value equality.
        let envelope = try #require(try sidecars.read(key))
        let roundTripped = try JSONDecoder().decode(SidecarEnvelope.self, from: JSONEncoder().encode(envelope))
        try sidecars.write(roundTripped, at: key)

        let reopened = ContactsRepository(contacts: contacts, sync: sync)
        await reopened.reload()
        let reopenedID = try #require(reopened.contact(localID: "ada")).contactID
        for kind in [ContactPhotoKind.fullSize, .thumbnail] {
            let photo = try #require(try await reopened.contactPhotoData(for: reopenedID, kind: kind))
            #expect(photo.data == original)
            #expect(photo.crop == crop)
        }
        let reframed = try #require(ContactPhotoCrop(x: 0, y: 0, width: 0.4, height: 0.2))
        try await reopened.setContactPhotoCrop(for: reopenedID, crop: reframed)
        #expect(try await reopened.contactPhotoData(for: reopenedID, kind: .fullSize)?.crop == reframed)
        #expect(try await reopened.contactPhotoData(for: reopenedID, kind: .fullSize)?.data == original)
        try await reopened.setContactPhotoCrop(for: reopenedID, crop: nil)
        let reset = try #require(try await reopened.contactPhotoData(for: reopenedID, kind: .fullSize))
        #expect(reset.crop == nil)
        #expect(reset.data == original)
        #expect(reopened.fields(for: reopenedID).isEmpty)

        let replacement = Data([7, 8, 9])
        try await reopened.setContactPhoto(for: reopenedID, imageData: replacement)
        #expect(try await reopened.contactPhotoData(for: reopenedID, kind: .fullSize)?.crop == nil)
        #expect(try sync.blobFieldData(at: key, field: ContactsRepository.previousPhotoFieldName) == original)
        try await reopened.setContactPhoto(for: reopenedID, imageData: nil)
        #expect(try await reopened.contactPhotoData(for: reopenedID, kind: .fullSize) == nil)
    }

    @Test func originalAndCropRoundTripThroughEncryptedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cryptoKey = SymmetricKey(size: .bits256)
        func makeSync() -> GuessWhoSync {
            let store = FileSystemSidecarStore(root: root, ubiquity: FakeUbiquityProvider(),
                                               blobCrypto: InMemoryBlobCrypto(key: cryptoKey),
                                               coordinatesUbiquitousAccess: false)
            return GuessWhoSync(contacts: InMemoryContactStore(), events: InMemoryEventStore(),
                                sidecars: store, deviceID: "test")
        }
        let key = SidecarKey(kind: .contact, id: UUID().uuidString.lowercased())
        let original = Data([0, 1, 2, 3, 254, 255])
        let crop = try #require(ContactPhotoCrop(x: 0.25, y: 0.125, width: 0.5, height: 0.25))
        try makeSync().setBlobField(at: key, field: ContactsRepository.profilePhotoFieldName,
                                   data: original, contentType: "image/jpeg", photoCrop: crop)
        let loaded = try #require(try makeSync().profilePhoto(at: key))
        #expect(loaded.photo.data == original)
        #expect(loaded.photo.crop == crop)
    }

    @Test @MainActor func existingPhotoHasNoCropAndIsPreservedWhenFirstCropped() async throws {
        let contacts = InMemoryContactStore(contacts: [Contact(localID: "ada", givenName: "Ada")])
        let original = Data([1, 2, 3, 4])
        await contacts.setImageData(original, thumbnail: Data([5]), for: "ada")
        let sync = GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: InMemorySidecarStore(), deviceID: "test")
        let repository = ContactsRepository(contacts: contacts, sync: sync)
        await repository.reload()
        let id = try #require(repository.contact(localID: "ada")).contactID
        #expect(try await repository.contactPhotoData(for: id, kind: .fullSize)?.crop == nil)
        let crop = try #require(ContactPhotoCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        try await repository.setContactPhotoCrop(for: id, crop: crop)
        #expect(try await repository.contactPhotoData(for: id, kind: .fullSize)?.data == original)
        #expect(try await contacts.loadImageData(localID: "ada") == original)
    }
}
