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

    func fetch(localID: String) async throws -> Contact? { throw StoreUnavailable() }
    func save(_ contact: Contact) async throws { throw StoreUnavailable() }
    func delete(localID: String) async throws { throw StoreUnavailable() }
    func changes(since token: Data?) async throws -> ContactChangeSet { throw StoreUnavailable() }
    func loadImageData(localID: String) async throws -> Data? { throw StoreUnavailable() }
    func loadThumbnailImageData(localID: String) async throws -> Data? { throw StoreUnavailable() }
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

/// Builds a contact carrying exactly one valid GuessWho URL so the repository
/// can mint a `ContactID` for it. `uuid` is stored on the URL; the canonical
/// `guessWhoID` is the lowercased bare UUID.
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

@Suite("ContactID identity")
struct ContactIDIdentityTests {
    // Two distinct random UUIDs, one with mixed case to also exercise the
    // SidecarKey canonicalizer.
    private let uuidA = "11111111-1111-1111-1111-111111111111"
    private let uuidB = "22222222-2222-2222-2222-222222222222"

    @Test
    func guessWhoIDComesFromSidecarKeyCanonicalizer() {
        let mixedCase = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let id = ContactID(contact: contact(localID: "1", uuid: mixedCase, givenName: "Ada"))
        #expect(id?.guessWhoID == mixedCase.lowercased())
    }

    @Test
    func materializesNilWithoutGuessWhoURL() {
        // No GuessWho URL ⇒ identity not settled ⇒ no ContactID.
        let bare = Contact(localID: "1", givenName: "Ada", familyName: "Lovelace")
        #expect(ContactID(contact: bare) == nil)
    }

    @Test
    func editedContactIsSameRowChangedContents() {
        // An edited contact: NOT `==` (display delta) but HASH-equal (same
        // bucket). This is the "same row, changed contents" contract a diffable
        // data source relies on.
        let original = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace", jobTitle: "Mathematician"
        ))!
        let edited = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace", jobTitle: "Countess"
        ))!

        // NOT equal (display delta) but HASH-equal (same guessWhoID ⇒ same
        // bucket). A diffable data source reads this as "same row, reconfigure"
        // rather than delete + insert.
        #expect(original != edited)
        #expect(original.hashValue == edited.hashValue)
    }

    @Test
    func equalsFalseWhenNameDiffers() {
        let lhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace"))!
        let rhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Augusta", familyName: "Lovelace"))!
        #expect(lhs != rhs)
    }

    @Test
    func equalsFalseWhenJobDiffers() {
        let lhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada", jobTitle: "Mathematician"))!
        let rhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada", jobTitle: "Engineer"))!
        #expect(lhs != rhs)
    }

    @Test
    func equalsFalseWhenOrgDiffers() {
        let lhs = ContactID(contact: contact(
            localID: "1", uuid: uuidA, contactType: .organization, organizationName: "Analytical Engine"
        ))!
        let rhs = ContactID(contact: contact(
            localID: "1", uuid: uuidA, contactType: .organization, organizationName: "Difference Engine"
        ))!
        #expect(lhs != rhs)
    }

    @Test
    func equalsFalseWhenPhotoPresenceDiffers() {
        let lhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada", imageDataAvailable: false))!
        let rhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada", imageDataAvailable: true))!
        #expect(lhs != rhs)
    }

    @Test
    func equalsTrueWhenAllDisplayFieldsMatch() {
        // Same identity AND all display fields ⇒ ==. localID differing must NOT
        // break equality (identity is the GuessWho UUID, not the carrier).
        let lhs = ContactID(contact: contact(
            localID: "carrier-A", uuid: uuidA, givenName: "Ada", familyName: "Lovelace",
            jobTitle: "Mathematician", organizationName: "Analytical Engine", imageDataAvailable: true
        ))!
        let rhs = ContactID(contact: contact(
            localID: "carrier-B", uuid: uuidA, givenName: "Ada", familyName: "Lovelace",
            jobTitle: "Mathematician", organizationName: "Analytical Engine", imageDataAvailable: true
        ))!
        #expect(lhs == rhs)
    }

    @Test
    func hashStableAcrossDisplayFieldEditForSameGuessWhoID() {
        // Same guessWhoID, every display field changed ⇒ identical hashes.
        let original = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Ada", familyName: "Lovelace",
            jobTitle: "Mathematician", organizationName: "Engine", imageDataAvailable: false
        ))!
        let churned = ContactID(contact: contact(
            localID: "1", uuid: uuidA, givenName: "Augusta", familyName: "King",
            jobTitle: "Countess", organizationName: "Ockham", imageDataAvailable: true
        ))!
        #expect(original.hashValue == churned.hashValue)
    }

    @Test
    func differentGuessWhoIDsAreNotEqual() {
        let lhs = ContactID(contact: contact(localID: "1", uuid: uuidA, givenName: "Ada"))!
        let rhs = ContactID(contact: contact(localID: "2", uuid: uuidB, givenName: "Ada"))!
        #expect(lhs != rhs)
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
    func duplicateDisplayNameReturnsAllMatches() async {
        let first = contact(localID: "1", uuid: uuidA, givenName: "Chris", familyName: "Smith")
        let second = contact(localID: "2", uuid: uuidB, givenName: "Chris", familyName: "Smith")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [first, second]))
        await repository.reload()

        let matches = repository.contactIDs(named: "  chris smith ")
        #expect(Set(matches.map(\.guessWhoID)) == Set([uuidA, uuidB]))
    }

    @Test @MainActor
    func contactsMatchingEmailReturnsAllMatches() async {
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

        let matches = repository.contacts(matchingEmail: " ADA@example.com ")
        #expect(Set(matches.map(\.guessWhoID)) == Set([uuidA, uuidB]))
    }

    @Test @MainActor
    func contactsReferencingExcludesSelfByGuessWhoID() async {
        // The referenced contact ALSO relates to its own name. Self-exclusion is
        // by guessWhoID, so the self-relation must not appear; only the distinct
        // referrer does.
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
        #expect(referencing.map(\.id.guessWhoID) == [uuidB])
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
        #expect(repository.contacts(matchingEmail: "ada@example.com").map(\.guessWhoID) == [uuidA])
        #expect(repository.contactsReferencing(id: adaID!).map(\.id.guessWhoID) == [uuidB])
    }
}
