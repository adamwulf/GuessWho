import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository — group memberships")
struct ContactsRepositoryGroupsTests {
    @Test @MainActor
    func groupsContainingReturnsEveryContainingGroupSortedByName() async throws {
        let person = Contact(localID: "person", givenName: "Ada", familyName: "Lovelace")
        let store = InMemoryContactStore(contacts: [person])
        // Create out of alphabetical order so the sort is exercised, plus one
        // unrelated group the person is NOT in.
        let work = try await store.createGroup(name: "Work")
        let family = try await store.createGroup(name: "Family")
        let unrelated = try await store.createGroup(name: "Hobbies")
        try await store.addMember(contactLocalID: person.localID, toGroup: work.localID)
        try await store.addMember(contactLocalID: person.localID, toGroup: family.localID)

        let repository = ContactsRepository(contacts: store)

        let groups = await repository.groups(containing: person)
        // Sorted by name ("Family" before "Work"), unrelated group excluded.
        #expect(groups.map(\.name) == ["Family", "Work"])
        #expect(!groups.map(\.localID).contains(unrelated.localID))
    }

    @Test @MainActor
    func groupsContainingReturnsEmptyWhenInNoGroups() async {
        // Organizations are Contacts too: a group can hold either, so the same
        // query serves the org detail screen.
        let organization = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [organization]))

        let groups = await repository.groups(containing: organization)
        #expect(groups.isEmpty)
    }

    @Test @MainActor
    func groupsContainingDegradesToEmptyAndRecordsErrorForMissingContact() async {
        // The store throws `contactNotFound` for an unknown localID; the
        // repository must degrade to an empty list and record `lastError`
        // rather than propagating, matching `members(ofGroup:)`.
        let ghost = Contact(localID: "ghost", givenName: "Nobody")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: []))

        let groups = await repository.groups(containing: ghost)
        #expect(groups.isEmpty)
        #expect(repository.lastError != nil)
    }
}
