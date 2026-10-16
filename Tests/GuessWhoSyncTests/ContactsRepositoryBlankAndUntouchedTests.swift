import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedSidecarReadFailure: Error {}

/// An in-memory sidecar store whose reads can be made to fail.
private final class ReadFailingSidecarStore: SidecarStoreProtocol {
    private let inner = InMemorySidecarStore()
    var failsReads = false

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        if failsReads { throw InjectedSidecarReadFailure() }
        return try inner.read(key)
    }

    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        try inner.write(envelope, at: key)
    }

    func delete(_ key: SidecarKey) throws {
        try inner.delete(key)
    }

    func allKeys() throws -> [SidecarKey] {
        try inner.allKeys()
    }

    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        inner.downloadStatus(key)
    }

    func requestDownload(_ key: SidecarKey) throws {
        try inner.requestDownload(key)
    }
}

/// `ContactsRepository.isBlankAndUntouched(_:)` — the check the app's "+"
/// flow makes before it deletes the blank record it created. Anything a
/// person put on the record, here or elsewhere, must read as touched, and a
/// read that fails must throw so the caller keeps the record.
@Suite("ContactsRepository.isBlankAndUntouched")
@MainActor
struct ContactsRepositoryBlankAndUntouchedTests {
    private struct Fixture {
        let repository: ContactsRepository
        let contacts: InMemoryContactStore
        let sync: GuessWhoSync
        let sidecars: ReadFailingSidecarStore
        let root: URL

        func key(of contact: Contact) throws -> SidecarKey {
            try #require(SidecarKey.forContact(contact))
        }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlankAndUntouched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contacts = InMemoryContactStore()
        let sidecars = ReadFailingSidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
        let repository = ContactsRepository(
            contacts: contacts, sync: sync, favorites: FavoritesStore(root: root),
            notificationCenter: NotificationCenter())
        await repository.reload()
        return Fixture(repository: repository, contacts: contacts, sync: sync, sidecars: sidecars, root: root)
    }

    private func cleanUp(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test
    func newRecordIsBlankAndUntouched_evenOnceViewed() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let person = try await fixture.repository.createContact(Contact())
        let organization = try await fixture.repository.createContact(Contact(contactType: .organization))

        #expect(try await fixture.repository.isBlankAndUntouched(person.contactID))
        #expect(try await fixture.repository.isBlankAndUntouched(organization.contactID))

        try await fixture.repository.stampViewed(person.contactID)
        #expect(try await fixture.repository.isBlankAndUntouched(person.contactID))
    }

    @Test
    func savedFieldIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        var edited = try #require(try await fixture.repository.editableContact(id: created.contactID))
        edited.givenName = "Ada"
        try await fixture.repository.saveContact(edited, for: created.contactID)

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func fieldWrittenBehindTheCacheIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        // Another writer changes the record; the cache hasn't heard yet.
        var elsewhere = try #require(try await fixture.contacts.fetch(localID: created.localID))
        elsewhere.jobTitle = "Engineer"
        try await fixture.contacts.save(elsewhere)

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func photoIsTouched_evenThumbnailOnly() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        // A thumbnail with no full-size bytes, and the availability flag left
        // false: the flag is only a hint.
        await fixture.contacts.setImageData(nil, thumbnail: Data([1, 2, 3]), for: created.localID)

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func groupMembershipIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        let group = try await fixture.contacts.createGroup(name: "Friends")
        try await fixture.contacts.addMember(contactLocalID: created.localID, toGroup: group.localID)

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func datedNoteIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        _ = try await fixture.repository.addNote(for: created.contactID, body: "Met at the conference")

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func anyOtherCellIsTouched_evenARemovedOne() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        let key = try fixture.key(of: created)
        let field = try fixture.sync.addField(at: key, field: "Badge", type: .note, value: .string("42"))
        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))

        try fixture.sync.deleteField(at: key, id: field)
        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func interactionStampIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        try await fixture.repository.stampInteracted(created.contactID)

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func favoriteIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        #expect(try await fixture.repository.toggleFavorite(created.contactID))

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func linkIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        let other = try await fixture.repository.createContact(Contact(givenName: "Grace"))
        _ = try await fixture.repository.addLink(from: other.contactID, to: created.contactID, note: "")

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func goneRecordIsNotBlank() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        #expect(try await fixture.repository.deleteContact(id: created.contactID))

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func unreadableGuessWhoDataThrows() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        fixture.sidecars.failsReads = true

        await #expect(throws: InjectedSidecarReadFailure.self) {
            try await fixture.repository.isBlankAndUntouched(created.contactID)
        }
    }

    @Test
    func unavailableStorageThrowsForARecordWithAnIdentity() async throws {
        let identified = Contact(
            localID: "identified",
            urlAddresses: [LabeledValue(
                label: "",
                value: "\(SidecarKey.guessWhoContactURLPrefix)40000000-0000-0000-0000-000000000001")]
        )
        let contacts = InMemoryContactStore(contacts: [identified])
        let repository = ContactsRepository(contacts: contacts, notificationCenter: NotificationCenter())
        await repository.reload()
        let id = try #require(repository.contact(localID: "identified")).contactID

        await #expect(throws: SidecarUnavailableError.self) {
            try await repository.isBlankAndUntouched(id)
        }
    }
}
