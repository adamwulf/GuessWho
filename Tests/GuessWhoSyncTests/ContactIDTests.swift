import Testing
import Foundation
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// A `ContactStoreProtocol` test double that serves a fixed seed once via
/// `fetchAll()`, then fails every subsequent store read. It exists to prove the
/// repository's `ContactID`-addressed accessors are pure cache reads: once the
/// snapshot is seeded, they must keep returning results even though the
/// underlying store can no longer satisfy a fetch. Any accessor that secretly
/// enumerated the store would surface the failure.
private actor FailAfterSeedContactStore: ContactStoreProtocol {
    private let seed: [Contact]
    private var hasServedInitialFetch = false

    init(seed: [Contact]) {
        self.seed = seed
    }

    struct StoreUnavailable: Error {}

    func fetchAll() async throws -> [Contact] {
        if hasServedInitialFetch { throw StoreUnavailable() }
        hasServedInitialFetch = true
        return seed
    }

    // The authorization surface is never consulted by these no-I/O cache tests;
    // this double models an unavailable store, so it reports "never asked".
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .notDetermined }
    func requestContactsAccess() async -> StoreAccessResult { StoreAccessResult(status: .denied) }

    func fetch(localID: String) async throws -> Contact? { throw StoreUnavailable() }
    func save(_ contact: Contact) async throws { throw StoreUnavailable() }
    func create(_ contact: Contact) async throws -> Contact { throw StoreUnavailable() }
    func delete(localID: String) async throws { throw StoreUnavailable() }
    func changes(since token: Data?) async throws -> ContactChangeSet { throw StoreUnavailable() }
    func loadImageData(localID: String) async throws -> Data? { throw StoreUnavailable() }
    func loadThumbnailImageData(localID: String) async throws -> Data? { throw StoreUnavailable() }
    func setImageData(localID: String, imageData: Data?) async throws { throw StoreUnavailable() }
    func fetchAllGroups() async throws -> [ContactGroup] { throw StoreUnavailable() }
    func fetchGroup(localID: String) async throws -> ContactGroup? { throw StoreUnavailable() }
    func createGroup(name: String) async throws -> ContactGroup { throw StoreUnavailable() }
    func renameGroup(localID: String, to name: String) async throws { throw StoreUnavailable() }
    func deleteGroup(localID: String) async throws { throw StoreUnavailable() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { throw StoreUnavailable() }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { throw StoreUnavailable() }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { throw StoreUnavailable() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { throw StoreUnavailable() }
}

/// Builds a contact carrying exactly one valid GuessWho URL so its `ContactID`
/// has a populated `guessWhoID` (the lowercased bare UUID). Models a reconciled
/// contact.
private func contact(
    localID: String,
    uuid: String,
    contactType: ContactType = .person,
    givenName: String = "",
    familyName: String = "",
    jobTitle: String = "",
    organizationName: String = "",
    imageDataAvailable: Bool = false,
    emailAddresses: [LabeledValue] = [],
    contactRelations: [LabeledContactRelation] = []
) -> Contact {
    Contact(
        localID: localID,
        contactType: contactType,
        givenName: givenName,
        familyName: familyName,
        jobTitle: jobTitle,
        organizationName: organizationName,
        emailAddresses: emailAddresses,
        urlAddresses: [LabeledValue(label: "", value: "\(SidecarKey.guessWhoContactURLPrefix)\(uuid)")],
        contactRelations: contactRelations,
        imageDataAvailable: imageDataAvailable
    )
}

/// Builds a contact with NO GuessWho URL — models a not-yet-reconciled contact.
/// Its `ContactID.guessWhoID` is nil and identity falls back to `localID`.
private func bareContact(
    localID: String,
    contactType: ContactType = .person,
    givenName: String = "",
    familyName: String = "",
    jobTitle: String = "",
    organizationName: String = "",
    imageDataAvailable: Bool = false,
    emailAddresses: [LabeledValue] = [],
    contactRelations: [LabeledContactRelation] = []
) -> Contact {
    Contact(
        localID: localID,
        contactType: contactType,
        givenName: givenName,
        familyName: familyName,
        jobTitle: jobTitle,
        organizationName: organizationName,
        emailAddresses: emailAddresses,
        contactRelations: contactRelations,
        imageDataAvailable: imageDataAvailable
    )
}

@Suite("ContactID identity")
struct ContactIDIdentityTests {
    private let uuidA = "11111111-1111-1111-1111-111111111111"
    private let uuidB = "22222222-2222-2222-2222-222222222222"

    @Test
    func guessWhoIDComesFromSidecarKeyCanonicalizer() {
        let mixedCase = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let id = ContactID(contact: contact(localID: "1", uuid: mixedCase, givenName: "Ada"))
        #expect(id.guessWhoID == mixedCase.lowercased())
    }

    @Test
    func materializesWithNilGuessWhoIDWhenNoURL() {
        // No GuessWho URL ⇒ guessWhoID nil, but the ContactID STILL materializes
        // (init never fails) and is identified by its localID fallback.
        let id = ContactID(contact: bareContact(localID: "carrier-1", givenName: "Ada", familyName: "Lovelace"))
        #expect(id.guessWhoID == nil)
        #expect(id.effectiveID == "carrier-1")
    }

    @Test
    func editedContactIsSameRowSameIdentity() {
        // An in-place edit (same effectiveID, different display content) yields
        // EQUAL ContactIDs — identity-only equality. The row keeps its place in
        // a diffable snapshot; repainting its CONTENTS is the VC's explicit
        // reconfigure pass, not ContactID's `==`.
        let original = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace", jobTitle: "Mathematician"
        ))
        let edited = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace", jobTitle: "Countess"
        ))

        #expect(original == edited)
        #expect(original.hashValue == edited.hashValue)
    }

    @Test
    func equalWhenDisplayFieldsDifferButEffectiveIDMatches() {
        // Identity-only equality: two ContactIDs built from contacts that share a
        // guessWhoID are EQUAL even when EVERY display field (name, job, org,
        // photo, contactType) and the carrier localID differ. Proves ContactID
        // carries no display content — effectiveID is the whole identity.
        let lhs = ContactID(contact: contact(
            localID: "carrier-A", uuid: uuidA, contactType: .person,
            givenName: "Ada", familyName: "Lovelace",
            jobTitle: "Mathematician", organizationName: "Analytical Engine", imageDataAvailable: false
        ))
        let rhs = ContactID(contact: contact(
            localID: "carrier-B", uuid: uuidA, contactType: .organization,
            givenName: "Augusta", familyName: "King",
            jobTitle: "Countess", organizationName: "Difference Engine", imageDataAvailable: true
        ))
        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
    }

    @Test
    func hashStableAcrossDisplayFieldEditForSameGuessWhoID() {
        // Same guessWhoID, every display field changed ⇒ identical hashes.
        let original = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace",
            jobTitle: "Mathematician", organizationName: "Engine", imageDataAvailable: false
        ))
        let churned = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Augusta", familyName: "King",
            jobTitle: "Countess", organizationName: "Ockham", imageDataAvailable: true
        ))
        #expect(original.hashValue == churned.hashValue)
    }

    @Test
    func differentGuessWhoIDsAreNotEqual() {
        let lhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada"))
        let rhs = ContactID(contact: contact(localID: "2", uuid: uuidB, givenName: "Ada"))
        #expect(lhs != rhs)
    }

    @Test
    func bareContactsIdentifiedByLocalIDFallback() {
        // Two un-reconciled contacts with the SAME display fields but different
        // localIDs are DIFFERENT rows (different effective identity).
        let lhs = ContactID(contact: bareContact(localID: "carrier-A", givenName: "Ada", familyName: "Lovelace"))
        let rhs = ContactID(contact: bareContact(localID: "carrier-B", givenName: "Ada", familyName: "Lovelace"))
        #expect(lhs.guessWhoID == nil)
        #expect(rhs.guessWhoID == nil)
        #expect(lhs != rhs)
        #expect(lhs.hashValue != rhs.hashValue)
    }

    @Test
    func reconciliationTransitionIsDeleteInsertNotReconfigure() {
        // The SAME contact (same localID) gains a GuessWho URL: its effective
        // identity flips localID → guessWhoID. By design this is a diffable
        // delete + insert, so the two ContactIDs must NOT be equal and SHOULD
        // hash differently (different buckets), even though every display field
        // is unchanged.
        let before = ContactID(contact: bareContact(
            localID: "carrier-1", givenName: "Ada", familyName: "Lovelace"
        ))
        let after = ContactID(contact: contact(
            localID: "carrier-1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace"
        ))
        #expect(before.guessWhoID == nil)
        #expect(after.guessWhoID == uuidA)
        #expect(before != after)
        #expect(before.hashValue != after.hashValue)
    }
}

@Suite("ContactsRepository ContactID-addressed reads")
struct ContactsRepositoryContactIDTests {
    private let uuidA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let uuidB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private let uuidC = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    @Test @MainActor
    func contactByIDRoundTrips() async {
        let ada = contact(localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [ada]))
        await repository.reload()

        let id = repository.peopleSectionIDs.flatMap(\.1).first
        #expect(id != nil)
        let resolved = repository.contact(id: id!)
        #expect(resolved?.localID == "1")
        #expect(resolved?.givenName == "Ada")
    }

    @Test @MainActor
    func contactByIDReturnsNilForUnknownID() async {
        // A retired / never-cached id resolves to nil — the "unavailable"
        // contract — never a wrong-contact fallback.
        let ada = contact(localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [ada]))
        await repository.reload()

        let ghost = ContactID(contact: contact(localID: "999", uuid: uuidC, givenName: "Nobody"))
        #expect(repository.contact(id: ghost) == nil)
    }

    @Test @MainActor
    func unreconciledContactStillAppearsInSectionsByLocalID() async {
        // Regression guard: a contact with NO GuessWho URL must NOT be dropped
        // from the section accessor; it appears, identified by its localID.
        let bare = bareContact(localID: "carrier-1", givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [bare]))
        await repository.reload()

        let ids = repository.peopleSectionIDs.flatMap(\.1)
        #expect(ids.count == 1)
        #expect(ids.first?.guessWhoID == nil)
        #expect(ids.first?.effectiveID == "carrier-1")
        // And it round-trips through contact(id:) on the localID fallback.
        #expect(repository.contact(id: ids.first!)?.localID == "carrier-1")
    }

    @Test @MainActor
    func duplicateDisplayNameReturnsAllMatches() async {
        let first = contact(localID: "1", uuid: uuidA, givenName: "Chris", familyName: "Smith")
        let second = contact(localID: "2", uuid: uuidB, givenName: "Chris", familyName: "Smith")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [first, second]))
        await repository.reload()

        let matches = repository.contactIDs(named: "  chris smith ")
        #expect(Set(matches.compactMap(\.guessWhoID)) == Set([uuidA, uuidB]))
    }

    @Test @MainActor
    func contactIDsMatchingEmailReturnsAllMatches() async {
        let one = contact(
            localID: "1", uuid: uuidA, givenName: "Ada",
            emailAddresses: [LabeledValue(label: "work", value: "Ada@Example.com")]
        )
        let two = contact(
            localID: "2", uuid: uuidB, givenName: "Augusta",
            emailAddresses: [LabeledValue(label: "home", value: "ada@example.com")]
        )
        let other = contact(
            localID: "3", uuid: uuidC, givenName: "Charles",
            emailAddresses: [LabeledValue(label: "work", value: "charles@example.com")]
        )
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [one, two, other]))
        await repository.reload()

        let matches = repository.contactIDs(matchingEmail: " ADA@example.com ")
        #expect(Set(matches.compactMap(\.guessWhoID)) == Set([uuidA, uuidB]))
    }

    @Test @MainActor
    func contactsReferencingExcludesSelfByEffectiveID() async {
        // The referenced contact ALSO relates to its own name. Self-exclusion is
        // by effective identity (guessWhoID here), so the self-relation must not
        // appear; only the distinct referrer does.
        let ada = contact(
            localID: "self", uuid: uuidA, givenName: "Ada", familyName: "Lovelace",
            contactRelations: [LabeledContactRelation(label: "alias", value: ContactRelation(name: "Ada Lovelace"))]
        )
        let referrer = contact(
            localID: "ref", uuid: uuidB, givenName: "Charles", familyName: "Babbage",
            contactRelations: [LabeledContactRelation(label: "colleague", value: ContactRelation(name: "Ada Lovelace"))]
        )
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [ada, referrer]))
        await repository.reload()

        let adaID = repository.contactIDs(named: "Ada Lovelace").first
        #expect(adaID != nil)
        let referencing = repository.contactsReferencing(id: adaID!)
        #expect(referencing.compactMap(\.id.guessWhoID) == [uuidB])
        #expect(referencing.map(\.label) == ["colleague"])
    }

    @Test @MainActor
    func cacheReadsSucceedAfterStoreFailsPostSeed() async {
        // Seed the snapshot, then every store fetch fails. All ContactID-
        // addressed reads must still return from the in-memory cache — proving
        // they perform NO store I/O.
        let ada = contact(localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace",
                          emailAddresses: [LabeledValue(label: "work", value: "ada@example.com")])
        let babbage = contact(localID: "2", uuid: uuidB, givenName: "Charles", familyName: "Babbage",
                             contactRelations: [LabeledContactRelation(label: "colleague", value: ContactRelation(name: "Ada Lovelace"))])
        let repository = ContactsRepository(contacts: FailAfterSeedContactStore(seed: [ada, babbage]))
        await repository.reload()
        #expect(repository.lastError == nil)

        // The store is now spent: every further `fetchAll`/`fetch` throws. The
        // accessors below must still return from the cache. If any of them
        // secretly enumerated the store, it would throw and the cache would be
        // wrong/empty.
        let peopleIDs = repository.peopleSectionIDs.flatMap(\.1)
        #expect(peopleIDs.count == 2)

        // contact(id:) — pure cache resolve.
        let adaID = repository.contactIDs(named: "Ada Lovelace").first
        #expect(repository.contact(id: adaID!)?.givenName == "Ada")

        // matchingEmail / referencing — pure cache scans.
        #expect(repository.contactIDs(matchingEmail: "ada@example.com").compactMap(\.guessWhoID) == [uuidA])
        #expect(repository.contactsReferencing(id: adaID!).compactMap(\.id.guessWhoID) == [uuidB])
    }
}

@Suite("ContactRestorationToken persistence")
struct ContactRestorationTokenTests {
    private let uuidA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let uuidC = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    /// Round-trip a token through JSON — the whole reason the type exists is to
    /// be persisted (e.g. inside a scene's `NSUserActivity`). Both sealed
    /// identifiers must survive encode → decode, and the decoded token must
    /// still rebuild the SAME `ContactID` (equal identity).
    @Test
    func codableRoundTripPreservesIdentity() throws {
        let id = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada"))
        let token = id.restorationToken
        #expect(token.guessWhoID == uuidA)
        #expect(token.localID == "1")

        let data = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(ContactRestorationToken.self, from: data)
        #expect(decoded == token)
        // Rebuilt ContactID matches the original identity, so it resolves the
        // same row.
        #expect(decoded.contactID == id)
    }

    /// A token minted from an un-reconciled contact carries nil `guessWhoID` but
    /// still round-trips on its `localID` — this is what lets restoration reopen
    /// a contact the user only VIEWED and never wrote to.
    @Test
    func bareContactTokenCarriesLocalIDOnly() throws {
        let id = ContactID(contact: bareContact(localID: "carrier-1", givenName: "Ada"))
        let token = id.restorationToken
        #expect(token.guessWhoID == nil)
        #expect(token.localID == "carrier-1")

        let data = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(ContactRestorationToken.self, from: data)
        #expect(decoded.contactID == id)
    }

    /// Resolution goes through the same reconcile-stable path as `contact(id:)`:
    /// a reconciled token resolves by its canonical `guessWhoID`.
    @Test @MainActor
    func resolvesReconciledContactByGuessWhoID() async {
        let ada = contact(localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [ada]))
        await repository.reload()

        let token = repository.peopleSectionIDs.flatMap(\.1).first!.restorationToken
        let resolved = repository.contact(restorationToken: token)
        #expect(resolved?.localID == "1")
        #expect(resolved?.givenName == "Ada")
    }

    /// The viewed-but-never-written case: an un-reconciled contact (nil
    /// `guessWhoID`) resolves via the token's `localID` fallback.
    @Test @MainActor
    func resolvesUnwrittenContactByLocalIDFallback() async {
        let bare = bareContact(localID: "carrier-1", givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [bare]))
        await repository.reload()

        let token = repository.peopleSectionIDs.flatMap(\.1).first!.restorationToken
        #expect(token.guessWhoID == nil)
        let resolved = repository.contact(restorationToken: token)
        #expect(resolved?.localID == "carrier-1")
    }

    /// A token for a contact that no longer exists (deleted since quit, or a
    /// device-local `localID` that moved) resolves to nil — the caller then
    /// restores the section without a selected record, never a wrong contact.
    @Test @MainActor
    func deletedContactTokenResolvesToNil() async {
        let ada = contact(localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [ada]))
        await repository.reload()

        let ghost = ContactID(contact: contact(localID: "999", uuid: uuidC, givenName: "Nobody"))
        #expect(repository.contact(restorationToken: ghost.restorationToken) == nil)
    }

    /// The dangerous edge: a token carries a RETIRED `guessWhoID` (`uuidC`, not
    /// in the book) whose `localID` slot has since been re-pointed by unification
    /// to a DIFFERENT person (`uuidA`). Raw `contact(id:)` would fall through to
    /// the `localID` slot and hand back the wrong contact; `contact(restoration
    /// Token:)` must reject the mismatch and return nil — reopening a stranger's
    /// card is worse than reopening nothing.
    @Test @MainActor
    func retiredGuessWhoIDWithReusedLocalIDResolvesToNil() async {
        // "carrier-1" now belongs to Ada (uuidA).
        let ada = contact(localID: "carrier-1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [ada]))
        await repository.reload()

        // A stale token: guessWhoID uuidC (retired/unknown), but the SAME localID
        // "carrier-1" that now resolves to Ada. Fabricate it via the package init
        // (mirrors a token minted before the localID was re-pointed).
        let staleID = ContactID(guessWhoID: uuidC, localID: "carrier-1")
        let staleToken = staleID.restorationToken
        // Sanity: raw contact(id:) DOES fall through and return the wrong contact…
        #expect(repository.contact(id: staleID)?.givenName == "Ada")
        // …but the restoration resolver rejects the guessWhoID mismatch.
        #expect(repository.contact(restorationToken: staleToken) == nil)
    }
}
