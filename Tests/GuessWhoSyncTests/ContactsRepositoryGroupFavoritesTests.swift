import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository — durable group favorites", .serialized)
struct ContactsRepositoryGroupFavoritesTests {
    private static let deviceID = "device-A"

    @Test @MainActor
    func favoriteRoundTripsThroughGroupIdentityUUID() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "Work")
        await fixture.repository.loadGroups()

        #expect(try await fixture.repository.setGroupFavorite(true, for: group))
        #expect(fixture.repository.isGroupFavorite(group))

        let favorite = try #require(fixture.favorites.loadAll().first)
        #expect(favorite.kind == .group)
        #expect(UUID(uuidString: favorite.id) != nil)
        #expect(favorite.id != group.localID.lowercased())

        let loadedIdentity = try fixture.sync.groupIdentity(id: favorite.id)
        let identity = try #require(loadedIdentity)
        #expect(identity.deviceLocalIDs[Self.deviceID] == group.localID)
        let item = try #require(fixture.repository.favoriteListItems(from: [favorite]) { _ in nil }.first)
        #expect(item.group == group)

        #expect(try await fixture.repository.setGroupFavorite(false, for: group) == false)
        #expect(fixture.repository.isGroupFavorite(group) == false)
        #expect(try fixture.favorites.loadAll().isEmpty)
    }

    @Test @MainActor
    func resolveUsesLiveCurrentDeviceSlotWithoutFallbackMatching() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "Current Name")
        await fixture.repository.loadGroups()
        let identity = GroupIdentity(
            id: UUID().uuidString,
            name: "a different name",
            memberCount: 99,
            memberHash: "stale",
            hashedMemberCount: 99,
            deviceLocalIDs: [Self.deviceID: group.localID])
        try fixture.sync.writeGroupIdentity(identity)

        #expect(try await fixture.repository.resolveGroupIdentity(id: identity.id) == group)
        let loadedIdentity = try fixture.sync.groupIdentity(id: identity.id)
        let stored = try #require(loadedIdentity)
        #expect(stored.name == "a different name")
        #expect(stored.memberCount == 99)
    }

    @Test @MainActor
    func resolvePrunesDeadOwnSlotThenAdoptsAndPreservesPeerSlot() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "Family")
        await fixture.repository.loadGroups()
        let identity = GroupIdentity(
            id: UUID().uuidString,
            name: GroupIdentity.normalizedName(group.name),
            memberCount: 0,
            memberHash: emptyHash,
            hashedMemberCount: 0,
            deviceLocalIDs: [Self.deviceID: "deleted-local-id", "device-B": "peer-local-id"])
        try fixture.sync.writeGroupIdentity(identity)
        let peerSync = GuessWhoSync(
            contacts: fixture.contacts,
            events: InMemoryEventStore(),
            sidecars: fixture.sidecars,
            deviceID: "device-B")
        try peerSync.writeGroupIdentity(identity)

        #expect(try await fixture.repository.resolveGroupIdentity(id: identity.id) == group)
        let loadedIdentity = try fixture.sync.groupIdentity(id: identity.id)
        let stored = try #require(loadedIdentity)
        #expect(stored.deviceLocalIDs[Self.deviceID] == group.localID)
        #expect(stored.deviceLocalIDs["device-B"] == "peer-local-id")
    }

    @Test @MainActor
    func resolveAdoptsSoleNameMatchDespiteFingerprintMismatch() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "  Friends  ")
        await fixture.repository.loadGroups()
        let identity = GroupIdentity(
            id: UUID().uuidString,
            name: "friends",
            memberCount: 42,
            memberHash: "does-not-match",
            hashedMemberCount: 17,
            deviceLocalIDs: ["device-B": "remote"])
        try fixture.sync.writeGroupIdentity(identity)

        #expect(try await fixture.repository.resolveGroupIdentity(id: identity.id) == group)
        #expect(try fixture.sync.groupIdentity(id: identity.id)?.deviceLocalIDs[Self.deviceID] == group.localID)
    }

    @Test @MainActor
    func resolveDisambiguatesDuplicateNamesByCountAndHash() async throws {
        let firstContact = contact(localID: "contact-1", guessWhoID: "11111111-1111-1111-8111-111111111111")
        let secondContact = contact(localID: "contact-2", guessWhoID: "22222222-2222-2222-8222-222222222222")
        let fixture = try makeFixture(contacts: [firstContact, secondContact])
        defer { cleanup(fixture.root) }
        let first = try await fixture.contacts.createGroup(name: "Team")
        let second = try await fixture.contacts.createGroup(name: "team")
        try await fixture.contacts.addMember(contactLocalID: firstContact.localID, toGroup: first.localID)
        try await fixture.contacts.addMember(contactLocalID: secondContact.localID, toGroup: second.localID)
        await fixture.repository.reload()
        await fixture.repository.loadGroups()
        let expected = GroupIdentity.fingerprint(forGuessWhoIDs: ["22222222-2222-2222-8222-222222222222"])
        let identity = GroupIdentity(
            id: UUID().uuidString,
            name: "team",
            memberCount: 1,
            memberHash: expected.memberHash,
            hashedMemberCount: expected.hashedMemberCount,
            deviceLocalIDs: [:])
        try fixture.sync.writeGroupIdentity(identity)

        #expect(try await fixture.repository.resolveGroupIdentity(id: identity.id) == second)
        #expect(try fixture.sync.groupIdentity(id: identity.id)?.deviceLocalIDs[Self.deviceID] == second.localID)
    }

    @Test @MainActor
    func resolveDuplicateTieChoosesLowestLocalIdentifier() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        let first = try await fixture.contacts.createGroup(name: "Team")
        let second = try await fixture.contacts.createGroup(name: "team")
        await fixture.repository.loadGroups()
        let identity = GroupIdentity(
            id: UUID().uuidString,
            name: "team",
            memberCount: 0,
            memberHash: emptyHash,
            hashedMemberCount: 0,
            deviceLocalIDs: [:])
        try fixture.sync.writeGroupIdentity(identity)

        let expected = [first, second].min { $0.localID < $1.localID }
        #expect(try await fixture.repository.resolveGroupIdentity(id: identity.id) == expected)
    }

    @Test @MainActor
    func resolveWithNoNameMatchProjectsUnavailable() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        _ = try await fixture.contacts.createGroup(name: "Present")
        await fixture.repository.loadGroups()
        let identity = GroupIdentity(
            id: UUID().uuidString,
            name: "missing",
            memberCount: 0,
            memberHash: emptyHash,
            hashedMemberCount: 0,
            deviceLocalIDs: [:])
        try fixture.sync.writeGroupIdentity(identity)

        #expect(try await fixture.repository.resolveGroupIdentity(id: identity.id) == nil)
        let favorite = Favorite(kind: .group, id: identity.id, addedAt: Date())
        let item = try #require(fixture.repository.favoriteListItems(from: [favorite]) { _ in nil }.first)
        #expect(item.group == nil)
    }

    @Test @MainActor
    func legacyRawLocalIDFavoriteRemainsUnavailable() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "Legacy")
        await fixture.repository.loadGroups()
        let legacy = Favorite(kind: .group, id: group.localID, addedAt: Date())

        let item = try #require(fixture.repository.favoriteListItems(from: [legacy]) { _ in nil }.first)
        #expect(item.group == nil)
    }

    @Test @MainActor
    func membershipWriteRefreshesExistingIdentityWithoutMintingMemberID() async throws {
        let reconciled = contact(localID: "contact-1", guessWhoID: "11111111-1111-1111-8111-111111111111")
        let unreconciled = Contact(localID: "contact-2", givenName: "No ID")
        let fixture = try makeFixture(contacts: [reconciled, unreconciled])
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "Members")
        await fixture.repository.reload()
        await fixture.repository.loadGroups()
        let initialFingerprint = GroupIdentity.fingerprint(forGuessWhoIDs: [])
        let identity = try fixture.sync.mintGroupIdentity(
            name: group.name,
            account: nil,
            memberCount: 0,
            memberHash: initialFingerprint.memberHash,
            hashedMemberCount: 0,
            localID: group.localID)
        _ = try await fixture.repository.resolveGroupIdentity(id: identity.id)

        try await fixture.repository.addContacts([reconciled, unreconciled], toGroup: group)
        let loadedIdentity = try fixture.sync.groupIdentity(id: identity.id)
        let stored = try #require(loadedIdentity)
        let expected = GroupIdentity.fingerprint(forGuessWhoIDs: ["11111111-1111-1111-8111-111111111111"])
        #expect(stored.memberCount == 2)
        #expect(stored.memberHash == expected.memberHash)
        #expect(stored.hashedMemberCount == 1)
        #expect(try await fixture.contacts.fetch(localID: unreconciled.localID)?.contactID.guessWhoID == nil)
    }

    @Test @MainActor
    func loadGroupsRefreshesFingerprintForExistingIdentity() async throws {
        let member = contact(localID: "contact-1", guessWhoID: "11111111-1111-1111-8111-111111111111")
        let fixture = try makeFixture(contacts: [member])
        defer { cleanup(fixture.root) }
        let group = try await fixture.contacts.createGroup(name: "Members")
        await fixture.repository.reload()
        await fixture.repository.loadGroups()
        let initialFingerprint = GroupIdentity.fingerprint(forGuessWhoIDs: [])
        let identity = try fixture.sync.mintGroupIdentity(
            name: group.name,
            account: nil,
            memberCount: 0,
            memberHash: initialFingerprint.memberHash,
            hashedMemberCount: 0,
            localID: group.localID)

        try await fixture.contacts.addMember(contactLocalID: member.localID, toGroup: group.localID)
        await fixture.repository.loadGroups()

        let loadedIdentity = try fixture.sync.groupIdentity(id: identity.id)
        let stored = try #require(loadedIdentity)
        let expected = GroupIdentity.fingerprint(forGuessWhoIDs: ["11111111-1111-1111-8111-111111111111"])
        #expect(stored.memberCount == 1)
        #expect(stored.memberHash == expected.memberHash)
        #expect(stored.hashedMemberCount == 1)
    }

    private struct Fixture {
        let root: URL
        let contacts: InMemoryContactStore
        let sidecars: InMemorySidecarStore
        let sync: GuessWhoSync
        let favorites: FavoritesStore
        let repository: ContactsRepository
    }

    @MainActor
    private func makeFixture(contacts initialContacts: [Contact] = []) throws -> Fixture {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-repo-groupfav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contacts = InMemoryContactStore(contacts: initialContacts)
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: Self.deviceID)
        let favorites = FavoritesStore(root: root)
        let repository = ContactsRepository(
            contacts: contacts,
            sync: sync,
            favorites: favorites,
            notificationCenter: NotificationCenter())
        return Fixture(
            root: root,
            contacts: contacts,
            sidecars: sidecars,
            sync: sync,
            favorites: favorites,
            repository: repository)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func contact(localID: String, guessWhoID: String) -> Contact {
        Contact(
            localID: localID,
            givenName: localID,
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + guessWhoID)
            ])
    }

    private var emptyHash: String {
        GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash
    }
}
