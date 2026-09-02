import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Department favorites, like contacts and groups, resolve-or-mint the
/// organization's durable identity on the first write and key the favorite on
/// `<org uuid>/<department>`. These tests pin the write path (mint on first
/// favorite, blank refusal), the read projection (resolves / org gone /
/// department emptied), and the rename re-key (slot + `addedAt` preserved).
@Suite("ContactsRepository — department favorites", .serialized)
struct ContactsRepositoryDepartmentFavoritesTests {
    private static let deviceID = "device-A"
    private static let orgLocalID = "org-rice"
    private static let personLocalID = "person-liana"

    // MARK: - Write path

    @Test @MainActor
    func firstFavoriteMintsTheOrgIdentityAndKeysOnItsUUID() async throws {
        let fixture = try await makeLoadedFixture()
        defer { cleanup(fixture.root) }

        // The seeded organization is UNRECONCILED (no guesswho:// URL).
        let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        #expect(org.contactID.guessWhoID == nil)

        let resulting = try await fixture.repository.setDepartmentFavorite(
            true, department: "Lilie", in: org)
        #expect(resulting == true)

        // The write minted the org's identity (Case A → deterministic UUID).
        let minted = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        let mintedUUID = try #require(minted.contactID.guessWhoID)
        #expect(mintedUUID == org.deterministicGuessWhoID.lowercased())

        // Exactly one favorite, keyed on the minted org UUID + department. NO
        // second `.contact` favorite was written for the organization.
        let favorites = try fixture.favorites.loadAll()
        #expect(favorites.count == 1)
        let favorite = try #require(favorites.first)
        #expect(favorite.kind == .department)
        let key = try #require(DepartmentFavoriteKey(favoriteID: favorite.id))
        #expect(key.organizationGuessWhoID == mintedUUID)
        #expect(key.matches(department: "Lilie"))

        // `isDepartmentFavorite` reads the RECONCILED org copy.
        #expect(fixture.repository.isDepartmentFavorite("Lilie", in: minted))
        // Case-insensitive, whitespace-tolerant.
        #expect(fixture.repository.isDepartmentFavorite("  lilie ", in: minted))

        // Idempotent clear.
        #expect(try await fixture.repository.setDepartmentFavorite(false, department: "Lilie", in: minted) == false)
        #expect(!fixture.repository.isDepartmentFavorite("Lilie", in: minted))
        #expect(try fixture.favorites.loadAll().isEmpty)
    }

    @Test @MainActor
    func isDepartmentFavoriteIsFalseForAnUnreconciledOrg() async throws {
        let fixture = try await makeLoadedFixture()
        defer { cleanup(fixture.root) }
        let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        // No GuessWho UUID → no department favorite can be keyed on it → false,
        // and nothing is minted by the read.
        #expect(!fixture.repository.isDepartmentFavorite("Lilie", in: org))
        #expect(fixture.repository.contact(localID: Self.orgLocalID)?.contactID.guessWhoID == nil)
    }

    @Test @MainActor
    func aBlankDepartmentIsRefused() async throws {
        let fixture = try await makeLoadedFixture()
        defer { cleanup(fixture.root) }
        let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        await #expect(throws: BlankDepartmentError.self) {
            _ = try await fixture.repository.setDepartmentFavorite(true, department: "   ", in: org)
        }
        #expect(try fixture.favorites.loadAll().isEmpty)
    }

    // MARK: - Read projection

    @Test @MainActor
    func favoriteListItemsResolvesOrgGoneAndDepartmentEmptied() async throws {
        let fixture = try await makeLoadedFixture()
        defer { cleanup(fixture.root) }
        let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Lilie", in: org)
        let minted = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        let orgUUID = try #require(minted.contactID.guessWhoID)
        let now = Date(timeIntervalSince1970: 1)

        let liveFavorite = Favorite(
            kind: .department,
            id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "lilie").favoriteID,
            addedAt: now)
        // Case 2: no organization carries this UUID.
        let orgGoneFavorite = Favorite(
            kind: .department,
            id: DepartmentFavoriteKey(
                organizationGuessWhoID: "99999999-2222-4333-8444-555566667777",
                department: "Lilie").favoriteID,
            addedAt: now)
        // Case 3: the organization exists but no person carries this department.
        let emptiedFavorite = Favorite(
            kind: .department,
            id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Ghost").favoriteID,
            addedAt: now)

        let items = fixture.repository.favoriteListItems(
            from: [liveFavorite, orgGoneFavorite, emptiedFavorite],
            event: { _ in nil })

        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.kind == .department })
        // Case 1 resolves and restores the LIVE display casing ("Lilie", not the
        // lowercased key "lilie").
        #expect(items[0].department?.organization.localID == Self.orgLocalID)
        #expect(items[0].department?.department == "Lilie")
        // Cases 2 and 3 are unavailable (nil payload) but keep their row.
        #expect(items[1].department == nil)
        #expect(items[2].department == nil)
    }

    // MARK: - Rename re-key

    @Test @MainActor
    func renameDepartmentReKeysTheFavoritePreservingSlotAndAddedAt() async throws {
        let fixture = try await makeLoadedFixture()
        defer { cleanup(fixture.root) }
        let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        // Mint the org so it can own a department favorite.
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Lilie", in: org)
        let minted = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        let orgUUID = try #require(minted.contactID.guessWhoID)

        // Seed a known layout: an unrelated favorite BEFORE the department one, so
        // slot preservation is observable, and a fixed `addedAt`.
        let addedAt = Date(timeIntervalSince1970: 4242)
        let otherFavorite = Favorite(
            kind: .contact, id: "22222222-2222-4333-8444-555566667777", addedAt: Date(timeIntervalSince1970: 1))
        let departmentFavorite = Favorite(
            kind: .department,
            id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Lilie").favoriteID,
            addedAt: addedAt)
        try fixture.favorites.setAll([otherFavorite, departmentFavorite])

        let updated = try await fixture.repository.renameDepartment(
            from: "Lilie", to: "Innovation", in: minted)
        #expect(updated == 1)

        let reloaded = try fixture.favorites.loadAll()
        #expect(reloaded.count == 2)
        // The unrelated favorite kept its slot untouched.
        #expect(reloaded[0] == otherFavorite)
        // The department favorite kept its slot and `addedAt`, but re-keyed.
        #expect(reloaded[1].kind == .department)
        #expect(reloaded[1].addedAt == addedAt)
        let reKeyed = try #require(DepartmentFavoriteKey(favoriteID: reloaded[1].id))
        #expect(reKeyed.organizationGuessWhoID == orgUUID)
        #expect(reKeyed.matches(department: "Innovation"))
        #expect(!reKeyed.matches(department: "Lilie"))
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let contacts: InMemoryContactStore
        let sidecars: InMemorySidecarStore
        let sync: GuessWhoSync
        let favorites: FavoritesStore
        let repository: ContactsRepository
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-repo-deptfav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let org = Contact(
            localID: Self.orgLocalID,
            contactType: .organization,
            organizationName: "Rice University")
        let person = Contact(
            localID: Self.personLocalID,
            givenName: "Liana",
            departmentName: "Lilie",
            organizationName: "Rice University")
        let contacts = InMemoryContactStore(contacts: [org, person])
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
            root: root, contacts: contacts, sidecars: sidecars,
            sync: sync, favorites: favorites, repository: repository)
    }

    /// Build the fixture and load the seeded book into the repository cache — the
    /// async entry point every test uses so the org and its department-bearing
    /// person are visible before the first read.
    @MainActor
    private func makeLoadedFixture() async throws -> Fixture {
        let fixture = try makeFixture()
        await fixture.repository.reload()
        return fixture
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
