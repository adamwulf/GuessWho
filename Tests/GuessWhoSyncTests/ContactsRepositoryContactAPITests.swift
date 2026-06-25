import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Stage 6, sub-phase 6b — the PUBLIC `ContactID`-keyed contact API on
/// `ContactsRepository` (notes / links / event-links / favorite). These run a
/// REAL `GuessWhoSync` over an in-memory sidecar store (and a temp-directory
/// `FavoritesStore`), exercising the read/write split:
///
/// - READS (`notes(for:)`/`links(for:)`/`eventLinks(for:)`/`isFavorite(_:)`)
///   are synchronous, return empty/false on an unreconciled id, and MINT
///   NOTHING.
/// - WRITES (`addNote`/`editNote`/`deleteNote`/`addLink`/`addEventLink`/
///   `toggleFavorite`) resolve-or-mint, call the engine, then refresh the cache
///   on mint (decision B). They THROW when the engine/favorites store is nil.
///
/// The 6a `resolveOrMintGuessWhoID` primitive is covered separately by
/// `ContactsRepositoryResolveOrMintTests`; these prove the PUBLIC verbs route
/// through it and mirror the app's former `SyncService` semantics.
@Suite("ContactsRepository ContactID-keyed contact API (6b)")
struct ContactsRepositoryContactAPITests {
    private let existingUUID = "44444444-4444-4444-8444-444444444444"

    private func makeSync(
        contacts: InMemoryContactStore,
        sidecars: InMemorySidecarStore = InMemorySidecarStore()
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }

    private func makeFavoritesRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guesswho-repo-contactapi-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func guessWhoURLs(in contact: Contact) -> [String] {
        contact.urlAddresses
            .map(\.value)
            .filter { $0.hasPrefix(SidecarKey.guessWhoContactURLPrefix) }
    }

    // MARK: - Writes mint via reconcile-on-write

    // Writing a note to an UNRECONCILED ContactID mints the URL and creates the
    // note (reconcile fired through the WRITE, not a direct reconcile call), and
    // reading the note back returns it.
    @Test @MainActor
    func addNote_onUnreconciledContact_mintsAndCreatesNote() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "TARGET"))
        let id = repository.contactID(for: cached)
        #expect(id.guessWhoID == nil)

        let noteID = try await repository.addNote(for: id, body: "first note")

        // The store record now carries exactly the one minted GuessWho URL.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved).count == 1)
        let mintedUUID = try #require(ContactID(contact: saved).guessWhoID)

        // Reading the note back via a now-reconciled ContactID returns it.
        let reconciledID = repository.contactID(for: saved)
        let notes = repository.notes(for: reconciledID)
        #expect(notes.count == 1)
        #expect(notes.first?.id == noteID)
        #expect(notes.first?.body == "first note")
        #expect(mintedUUID == reconciledID.guessWhoID)
    }

    // The SAME note write on an ALREADY-reconciled ContactID does NOT re-stamp
    // the URL (the fast path returns the existing UUID and mints nothing).
    @Test @MainActor
    func addNote_onReconciledContact_doesNotReStamp() async throws {
        let reconciled = Contact(
            localID: "RECON",
            givenName: "Grace",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + existingUUID),
            ]
        )
        let store = InMemoryContactStore(contacts: [reconciled])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let id = repository.contactID(for: try #require(repository.contact(localID: "RECON")))
        #expect(id.guessWhoID == existingUUID)

        _ = try await repository.addNote(for: id, body: "a note")

        // The stored record's GuessWho URLs are byte-for-byte unchanged.
        let saved = try #require(try await store.fetch(localID: "RECON"))
        #expect(guessWhoURLs(in: saved) == [SidecarKey.guessWhoContactURLPrefix + existingUUID])

        // And the note landed under the existing UUID.
        #expect(repository.notes(for: id).count == 1)
    }

    // MARK: - Reads on an unreconciled id mint nothing

    // notes/links/eventLinks/isFavorite on an UNRECONCILED ContactID return
    // empty/false and MINT NOTHING — the contact still has no guessWhoID after
    // the reads.
    @Test @MainActor
    func reads_onUnreconciledContact_returnEmptyAndMintNothing() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let favoritesRoot = makeFavoritesRoot()
        defer { try? FileManager.default.removeItem(at: favoritesRoot) }
        let repository = ContactsRepository(
            contacts: store,
            sync: sync,
            favorites: FavoritesStore(root: favoritesRoot)
        )
        await repository.reload()

        let id = repository.contactID(for: try #require(repository.contact(localID: "TARGET")))
        #expect(id.guessWhoID == nil)

        #expect(repository.notes(for: id).isEmpty)
        #expect(repository.links(for: id).isEmpty)
        #expect(repository.eventLinks(for: id).isEmpty)
        #expect(repository.isFavorite(id) == false)

        // The on-disk contact STILL has no GuessWho URL: no read reconciled it.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved).isEmpty)
        // And the cached contact is still unreconciled.
        #expect(repository.contactID(for: try #require(repository.contact(localID: "TARGET"))).guessWhoID == nil)
    }

    // MARK: - Link write reconciles both endpoints

    // A contact-link write across TWO unreconciled ContactIDs reconciles BOTH
    // endpoints; the durable Link is keyed on their (now-minted) guessWhoIDs.
    @Test @MainActor
    func addLink_acrossTwoUnreconciledContacts_reconcilesBothEndpoints() async throws {
        let a = Contact(localID: "A", givenName: "Ada")
        let b = Contact(localID: "B", givenName: "Bob")
        let store = InMemoryContactStore(contacts: [a, b])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let idA = repository.contactID(for: try #require(repository.contact(localID: "A")))
        let idB = repository.contactID(for: try #require(repository.contact(localID: "B")))
        #expect(idA.guessWhoID == nil)
        #expect(idB.guessWhoID == nil)

        let link = try await repository.addLink(from: idA, to: idB, note: "colleagues")

        // BOTH records minted exactly one GuessWho URL.
        let savedA = try #require(try await store.fetch(localID: "A"))
        let savedB = try #require(try await store.fetch(localID: "B"))
        #expect(guessWhoURLs(in: savedA).count == 1)
        #expect(guessWhoURLs(in: savedB).count == 1)
        let mintedA = try #require(ContactID(contact: savedA).guessWhoID)
        let mintedB = try #require(ContactID(contact: savedB).guessWhoID)

        // The durable Link's endpoints are keyed on the minted GuessWho UUIDs.
        let endpoints = Set([link.endpointA, link.endpointB])
        #expect(endpoints == Set([
            SidecarKey(kind: .contact, id: mintedA),
            SidecarKey(kind: .contact, id: mintedB),
        ]))

        // Each endpoint can read the link back (excludes nothing, not deleted).
        #expect(repository.links(for: repository.contactID(for: savedA)).contains { $0.id == link.id })
        #expect(repository.links(for: repository.contactID(for: savedB)).contains { $0.id == link.id })
    }

    // MARK: - Favorite write mints then favorites

    // toggleFavorite on an UNRECONCILED ContactID mints then favorites;
    // isFavorite is then true (via a now-reconciled id).
    @Test @MainActor
    func toggleFavorite_onUnreconciledContact_mintsThenFavorites() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let favoritesRoot = makeFavoritesRoot()
        defer { try? FileManager.default.removeItem(at: favoritesRoot) }
        let repository = ContactsRepository(
            contacts: store,
            sync: sync,
            favorites: FavoritesStore(root: favoritesRoot)
        )
        await repository.reload()

        let id = repository.contactID(for: try #require(repository.contact(localID: "TARGET")))
        #expect(id.guessWhoID == nil)

        let newState = try await repository.toggleFavorite(id)
        #expect(newState == true)

        // The contact minted a GuessWho URL.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved).count == 1)

        // isFavorite is true via the now-reconciled id.
        let reconciledID = repository.contactID(for: saved)
        #expect(repository.isFavorite(reconciledID) == true)

        // Toggling again unfavorites without minting a second URL.
        let secondState = try await repository.toggleFavorite(reconciledID)
        #expect(secondState == false)
        let afterSecond = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: afterSecond).count == 1)
        #expect(repository.isFavorite(reconciledID) == false)
    }

    // MARK: - Decision B: writes update the cache on mint

    // After a mint-via-note-write, the repository cache reflects the contact's
    // new guessWhoID — `contact(id:)` with a post-mint ContactID resolves, and
    // the contact is found under its new effective (GuessWho) identity.
    @Test @MainActor
    func decisionB_cacheReflectsNewIdentityAfterMintingWrite() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let id = repository.contactID(for: try #require(repository.contact(localID: "TARGET")))
        #expect(id.guessWhoID == nil)

        _ = try await repository.addNote(for: id, body: "decision B")

        // No explicit reload here — the WRITE refreshed the cache (decision B).
        let mintedUUID = try #require(repository.contact(localID: "TARGET").map { ContactID(contact: $0).guessWhoID } ?? nil)

        // The cache resolves the contact under its NEW effective (GuessWho) id.
        let postMintID = ContactID(contact: try #require(repository.contact(localID: "TARGET")))
        #expect(postMintID.guessWhoID == mintedUUID)
        #expect(repository.contact(id: postMintID)?.localID == "TARGET")
        // And the bare-UUID resolver finds it (it's keyed under the GuessWho id).
        #expect(repository.contact(guessWhoID: mintedUUID)?.localID == "TARGET")
    }

    // MARK: - nil-engine degradation

    // With the engine nil (the `.unavailable` storage state): reads return
    // empty/false; every write throws SidecarUnavailableError.
    @Test @MainActor
    func nilEngine_readsEmpty_writesThrow() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        // No engine, no favorites store — the `.unavailable` storage state.
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let id = repository.contactID(for: try #require(repository.contact(localID: "TARGET")))

        // Reads degrade silently.
        #expect(repository.notes(for: id).isEmpty)
        #expect(repository.links(for: id).isEmpty)
        #expect(repository.eventLinks(for: id).isEmpty)
        #expect(repository.isFavorite(id) == false)

        // Writes throw.
        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.addNote(for: id, body: "x")
        }
        await #expect(throws: SidecarUnavailableError.self) {
            try await repository.editNote(for: id, id: UUID(), newBody: "x")
        }
        await #expect(throws: SidecarUnavailableError.self) {
            try await repository.deleteNote(for: id, id: UUID())
        }
        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.addLink(from: id, to: id, note: "x")
        }
        #expect(throws: SidecarUnavailableError.self) {
            try repository.setLinkNote(id: UUID(), note: "x")
        }
        #expect(throws: SidecarUnavailableError.self) {
            try repository.removeLink(id: UUID())
        }
        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.addEventLink(for: id, eventUUID: "evt", note: "x")
        }
        // toggleFavorite throws when the favorites store is nil.
        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.toggleFavorite(id)
        }
    }
}
