import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// `ContactsRepository.createContact(_:)` — the create-returning-identity
/// entry point behind the app's "+" add-contact flow and the LinkedIn
/// no-match import. Unlike `save` (which also inserts on an unknown
/// `localID` but returns nothing), `createContact` hands back the cached
/// record carrying the store-issued identity so the caller can open it or
/// apply follow-up writes.
@Suite("ContactsRepository.createContact")
struct ContactsRepositoryCreateContactTests {
    @MainActor
    private func makeRepo() async -> (ContactsRepository, InMemoryContactStore) {
        let store = InMemoryContactStore()
        let sync = GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        return (repo, store)
    }

    @Test @MainActor
    func blankSeed_createsRecordAndReturnsCachedIdentity() async throws {
        let (repo, store) = await makeRepo()
        let created = try await repo.createContact(Contact())

        // Store issued a real identity...
        #expect(!created.localID.isEmpty)
        // ...the record is in the backing store...
        #expect(try await store.fetch(localID: created.localID) != nil)
        // ...and already in the repository cache, addressable both ways.
        #expect(repo.contact(localID: created.localID) != nil)
        #expect(repo.contact(id: created.contactID) != nil)
    }

    @Test @MainActor
    func seededFields_carryThroughToTheCreatedRecord() async throws {
        let (repo, _) = await makeRepo()
        let seed = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            emailAddresses: [LabeledValue(label: "", value: "ada@example.com")]
        )
        let created = try await repo.createContact(seed)
        #expect(created.givenName == "Ada")
        #expect(created.familyName == "Lovelace")
        #expect(created.emailAddresses.map(\.value) == ["ada@example.com"])
        // The new record is findable through the normal match indexes.
        #expect(repo.contactIDs(matchingEmail: "ada@example.com") == [created.contactID])
    }

    @Test @MainActor
    func seedLocalID_isIgnored_storeIssuesItsOwn() async throws {
        let (repo, _) = await makeRepo()
        let created = try await repo.createContact(Contact(localID: "STALE-SEED-ID"))
        #expect(created.localID != "STALE-SEED-ID")
        #expect(repo.contact(localID: "STALE-SEED-ID") == nil)
    }

    @Test @MainActor
    func create_isAContactWrite_mintsNoGuessWhoID() async throws {
        // Creating a card must NOT stamp a guesswho:// URL — the GuessWho ID
        // mints on the first SIDECAR write, per the identity contract.
        let (repo, _) = await makeRepo()
        let created = try await repo.createContact(Contact(givenName: "Ada"))
        #expect(ContactID(contact: created).guessWhoID == nil)
    }
}
