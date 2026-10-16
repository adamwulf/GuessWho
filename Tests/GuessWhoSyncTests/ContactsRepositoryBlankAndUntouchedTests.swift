import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedSidecarReadFailure: Error {}
private struct InjectedContactsReadFailure: Error {}

/// Delegates to an in-memory store, but can report a photo-less flag on a
/// fresh fetch (the in-memory store corrects the flag from its bytes, while
/// Catalyst can leave it stuck false with a photo) and can fail the group
/// memberships read.
private actor FaultInjectingContactStore: ContactStoreProtocol {
    let base = InMemoryContactStore()
    private var reportsNoPhotoFlag = false
    private var failsGroupMemberships = false

    func reportNoPhotoFlag() { reportsNoPhotoFlag = true }
    func failGroupMemberships() { failsGroupMemberships = true }

    func fetchAll() async throws -> [Contact] { try await base.fetchAll() }
    func fetch(localID: String) async throws -> Contact? {
        guard var contact = try await base.fetch(localID: localID) else { return nil }
        if reportsNoPhotoFlag { contact.imageDataAvailable = false }
        return contact
    }
    func save(_ contact: Contact) async throws { try await base.save(contact) }
    func delete(localID: String) async throws { try await base.delete(localID: localID) }
    func create(_ contact: Contact) async throws -> Contact { try await base.create(contact) }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        await base.contactsAuthorizationStatus()
    }
    func requestContactsAccess() async -> StoreAccessResult {
        await base.requestContactsAccess()
    }
    func changes(since token: Data?) async throws -> ContactChangeSet {
        try await base.changes(since: token)
    }
    func loadImageData(localID: String) async throws -> Data? {
        try await base.loadImageData(localID: localID)
    }
    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await base.loadThumbnailImageData(localID: localID)
    }
    func setImageData(localID: String, imageData: Data?) async throws {
        try await base.setImageData(localID: localID, imageData: imageData)
    }
    func fetchAllGroups() async throws -> [ContactGroup] { try await base.fetchAllGroups() }
    func fetchGroup(localID: String) async throws -> ContactGroup? {
        try await base.fetchGroup(localID: localID)
    }
    func createGroup(name: String) async throws -> ContactGroup {
        try await base.createGroup(name: name)
    }
    func renameGroup(localID: String, to name: String) async throws {
        try await base.renameGroup(localID: localID, to: name)
    }
    func deleteGroup(localID: String) async throws { try await base.deleteGroup(localID: localID) }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        try await base.fetchMembers(ofGroup: groupLocalID)
    }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] {
        try await base.fetchMemberLocalIDs(ofGroup: groupLocalID)
    }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] {
        if failsGroupMemberships { throw InjectedContactsReadFailure() }
        return try await base.fetchGroupMemberships(contactLocalID: contactLocalID)
    }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {
        try await base.addMember(contactLocalID: contactLocalID, toGroup: groupLocalID)
    }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {
        try await base.removeMember(contactLocalID: contactLocalID, fromGroup: groupLocalID)
    }
}

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
        /// The store behind `faults`, for writes made "elsewhere".
        let contacts: InMemoryContactStore
        let faults: FaultInjectingContactStore
        let sync: GuessWhoSync
        let sidecars: ReadFailingSidecarStore
        let favorites: FavoritesStore
        let root: URL

        func key(of contact: Contact) throws -> SidecarKey {
            try #require(SidecarKey.forContact(contact))
        }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlankAndUntouched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let faults = FaultInjectingContactStore()
        let sidecars = ReadFailingSidecarStore()
        let sync = GuessWhoSync(
            contacts: faults, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
        let favorites = FavoritesStore(root: root)
        let repository = ContactsRepository(
            contacts: faults, sync: sync, favorites: favorites,
            notificationCenter: NotificationCenter())
        await repository.reload()
        return Fixture(
            repository: repository, contacts: faults.base, faults: faults, sync: sync,
            sidecars: sidecars, favorites: favorites, root: root)
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
    func thumbnailOnlyPhotoIsTouched_withTheFlagStuckFalse() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        // A thumbnail with no full-size bytes, while the record says it has
        // no photo: the flag is only a hint, so the bytes decide.
        await fixture.faults.reportNoPhotoFlag()
        await fixture.contacts.setImageData(nil, thumbnail: Data([1, 2, 3]), for: created.localID)

        #expect(try await !fixture.repository.isBlankAndUntouched(created.contactID))
    }

    @Test
    func fullSizeOnlyPhotoIsTouched_withTheFlagStuckFalse() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        await fixture.faults.reportNoPhotoFlag()
        await fixture.contacts.setImageData(Data([1]), thumbnail: nil, for: created.localID)

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
    func cellDroppedOnDecodeIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        let key = try fixture.key(of: created)
        // Only an allowed cell is left after decode; the one this build
        // couldn't read may be something a person put there.
        let json = #"""
        {
          "schemaVersion": 1,
          "entityID": "\#(key.id)",
          "fields": {
            "createdAt": {
              "value": "2026-10-15T20:15:00.000Z",
              "modifiedAt": "2026-10-15T20:15:00.000Z",
              "modifiedBy": "device-test"
            },
            "unreadable": { "value": "x", "modifiedAt": "nope", "modifiedBy": "device-other" }
          }
        }
        """#
        let envelope = try JSONDecoder().decode(SidecarEnvelope.self, from: Data(json.utf8))
        #expect(envelope.cellsDroppedOnDecode == 1)
        #expect(envelope.fields.keys.sorted() == ["createdAt"])
        try fixture.sidecars.write(envelope, at: key)

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
    func departmentFavoriteOfTheOrganizationIsTouched() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let organization = try await fixture.repository.createContact(Contact(contactType: .organization))
        let key = try fixture.key(of: organization)
        #expect(try fixture.favorites.set(kind: .department, id: "\(key.id)/Sales", favorite: true, now: Date()))

        #expect(try await !fixture.repository.isBlankAndUntouched(organization.contactID))
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
    func unreadableContactsDataThrows() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        await fixture.faults.failGroupMemberships()

        await #expect(throws: InjectedContactsReadFailure.self) {
            try await fixture.repository.isBlankAndUntouched(created.contactID)
        }
    }

    @Test
    func unreadableFavoritesThrow() async throws {
        let fixture = try await makeFixture()
        defer { cleanUp(fixture) }
        let created = try await fixture.repository.createContact(Contact())
        try Data("not favorites".utf8).write(to: fixture.favorites.fileURL)

        await #expect(throws: (any Error).self) {
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
