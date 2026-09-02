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
    private static let researcherLocalID = "person-rhea"

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
    func aBlankDepartmentIsANoOpThatMintsAndWritesNothing() async throws {
        let fixture = try await makeLoadedFixture()
        defer { cleanup(fixture.root) }
        let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
        // Blank department: returns false, mints nothing, writes nothing — never
        // throws.
        let result = try await fixture.repository.setDepartmentFavorite(
            true, department: "   ", in: org)
        #expect(result == false)
        #expect(try fixture.favorites.loadAll().isEmpty)
        // The organization was NOT minted by the no-op.
        #expect(fixture.repository.contact(localID: Self.orgLocalID)?.contactID.guessWhoID == nil)
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

    // MARK: - Phantom organization flow

    @Test @MainActor
    func favoritingADepartmentOnAPhantomCreatesTheOrgThenOwnsTheFavorite() async throws {
        // A person names "Rice University" with department "Lilie", but there is
        // NO organization record — so "Rice University" is a phantom. Favoriting
        // its department first materializes the real org (createContact mints the
        // identity), then keys a normal department favorite on that real UUID.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-repo-deptfav-phantom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }

        let person = Contact(
            localID: "person-lilie",
            givenName: "Liana",
            departmentName: "Lilie",
            organizationName: "Rice University")
        let contacts = InMemoryContactStore(contacts: [person])
        let sync = GuessWhoSync(
            contacts: contacts, events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(), deviceID: Self.deviceID)
        let favorites = FavoritesStore(root: root)
        let repository = ContactsRepository(
            contacts: contacts, sync: sync, favorites: favorites,
            notificationCenter: NotificationCenter())
        await repository.reload()

        // "Rice University" is a phantom until a record with that name exists.
        #expect(repository.phantomOrganization(key: "Rice University") != nil)

        // Materialize the real organization — createContact mints its identity.
        let created = try await repository.createContact(
            Contact(contactType: .organization, organizationName: "Rice University"))
        let createdUUID = try #require(created.contactID.guessWhoID)

        // Favorite the department on the freshly created org.
        #expect(try await repository.setDepartmentFavorite(true, department: "Lilie", in: created) == true)

        // The stored favorite resolves to that org and the live department name.
        let items = repository.favoriteListItems(from: try favorites.loadAll(), event: { _ in nil })
        #expect(items.count == 1)
        #expect(items[0].kind == .department)
        #expect(items[0].department?.organization.contactID.guessWhoID == createdUUID)
        #expect(items[0].department?.organization.localID == created.localID)
        #expect(items[0].department?.department == "Lilie")

        // The phantom is gone — a real record now carries the name.
        #expect(repository.phantomOrganization(key: "Rice University") == nil)
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

    @Test @MainActor
    func renameOntoAFavoritedSiblingMergesToOneRowKeepingTheEarliestSlot() async throws {
        // Both the renamed (source) department and its rename target are
        // favorited. After the rename they MUST merge to one row — never a
        // duplicate — and the EARLIEST participating slot survives, keeping its
        // `addedAt`.

        // Case A: the source (Lilie) is the earlier slot, so it survives.
        do {
            let fixture = try await makeLoadedFixture()
            defer { cleanup(fixture.root) }
            let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
            _ = try await fixture.repository.setDepartmentFavorite(true, department: "Lilie", in: org)
            let minted = try #require(fixture.repository.contact(localID: Self.orgLocalID))
            let orgUUID = try #require(minted.contactID.guessWhoID)
            let sourceAddedAt = Date(timeIntervalSince1970: 100)
            let targetAddedAt = Date(timeIntervalSince1970: 200)
            try fixture.favorites.setAll([
                Favorite(kind: .department,
                         id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Lilie").favoriteID,
                         addedAt: sourceAddedAt),
                Favorite(kind: .department,
                         id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Research").favoriteID,
                         addedAt: targetAddedAt),
            ])

            _ = try await fixture.repository.renameDepartment(from: "Lilie", to: "Research", in: minted)

            let reloaded = try fixture.favorites.loadAll()
            #expect(reloaded.count == 1)
            #expect(Set(reloaded.map(\.stableID)).count == reloaded.count)
            let survivor = try #require(reloaded.first)
            #expect(survivor.kind == .department)
            #expect(try #require(DepartmentFavoriteKey(favoriteID: survivor.id)).matches(department: "Research"))
            // Earliest slot (the source's) survives, keeping its addedAt.
            #expect(survivor.addedAt == sourceAddedAt)
        }

        // Case B: the pre-existing target (Research) is the earlier slot, so it
        // survives (the renamed source merges into it).
        do {
            let fixture = try await makeLoadedFixture()
            defer { cleanup(fixture.root) }
            let org = try #require(fixture.repository.contact(localID: Self.orgLocalID))
            _ = try await fixture.repository.setDepartmentFavorite(true, department: "Lilie", in: org)
            let minted = try #require(fixture.repository.contact(localID: Self.orgLocalID))
            let orgUUID = try #require(minted.contactID.guessWhoID)
            let targetAddedAt = Date(timeIntervalSince1970: 300)
            let sourceAddedAt = Date(timeIntervalSince1970: 400)
            try fixture.favorites.setAll([
                Favorite(kind: .department,
                         id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Research").favoriteID,
                         addedAt: targetAddedAt),
                Favorite(kind: .department,
                         id: DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Lilie").favoriteID,
                         addedAt: sourceAddedAt),
            ])

            _ = try await fixture.repository.renameDepartment(from: "Lilie", to: "Research", in: minted)

            let reloaded = try fixture.favorites.loadAll()
            #expect(reloaded.count == 1)
            #expect(Set(reloaded.map(\.stableID)).count == reloaded.count)
            let survivor = try #require(reloaded.first)
            #expect(try #require(DepartmentFavoriteKey(favoriteID: survivor.id)).matches(department: "Research"))
            // Earliest slot (the target's) survives, keeping its addedAt.
            #expect(survivor.addedAt == targetAddedAt)
        }
    }

    // MARK: - Dependency guards

    @Test @MainActor
    func blankDepartmentIsANoOpEvenWithNoStorageDependencies() async throws {
        // Neither the favorites store nor the engine is present. A blank
        // department still returns false and throws nothing — the blank check
        // comes BEFORE the availability guard.
        let store = InMemoryContactStore()
        let repository = ContactsRepository(
            contacts: store, sync: nil, favorites: nil, notificationCenter: NotificationCenter())
        let org = Contact(
            localID: Self.orgLocalID, contactType: .organization, organizationName: "Rice University")
        let result = try await repository.setDepartmentFavorite(true, department: "   ", in: org)
        #expect(result == false)
    }

    @Test @MainActor
    func validDepartmentThrowsWhenTheFavoritesStoreIsMissing() async throws {
        let store = InMemoryContactStore()
        let sync = GuessWhoSync(
            contacts: store, events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(), deviceID: Self.deviceID)
        let repository = ContactsRepository(
            contacts: store, sync: sync, favorites: nil, notificationCenter: NotificationCenter())
        let org = Contact(
            localID: Self.orgLocalID, contactType: .organization, organizationName: "Rice University")
        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.setDepartmentFavorite(true, department: "Lilie", in: org)
        }
    }

    @Test @MainActor
    func validDepartmentThrowsWhenTheEngineIsMissingEvenForAReconciledOrg() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-repo-deptfav-noengine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }
        let favorites = FavoritesStore(root: root)
        let store = InMemoryContactStore()
        // Engine (sync) absent; favorites store present.
        let repository = ContactsRepository(
            contacts: store, sync: nil, favorites: favorites, notificationCenter: NotificationCenter())
        // A RECONCILED org (already carries a GuessWho id): resolveOrMintGuessWhoID's
        // fast path would NOT touch the engine, so the explicit sync guard is what
        // makes this throw.
        let reconciledOrg = Contact(
            localID: Self.orgLocalID, contactType: .organization, organizationName: "Rice University",
            urlAddresses: [LabeledValue(
                label: "GuessWho",
                value: SidecarKey.guessWhoContactURLPrefix + "aaaaaaaa-2222-4333-8444-555566667777")])
        #expect(reconciledOrg.contactID.guessWhoID != nil)
        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.setDepartmentFavorite(true, department: "Lilie", in: reconciledOrg)
        }
        // The rejected write touched nothing.
        #expect(try favorites.loadAll().isEmpty)
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
        // A second department under the same org, so a rename can collide one
        // favorited department onto another favorited one.
        let researcher = Contact(
            localID: Self.researcherLocalID,
            givenName: "Rhea",
            departmentName: "Research",
            organizationName: "Rice University")
        let contacts = InMemoryContactStore(contacts: [org, person, researcher])
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
