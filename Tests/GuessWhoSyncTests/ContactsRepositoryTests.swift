import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository compatibility queries")
struct ContactsRepositoryTests {
    @Test @MainActor
    func displayNameQueriesPreserveAmbiguityWhileLegacyMapKeepsCompatibility() async {
        let first = Contact(localID: "1", givenName: "Chris", familyName: "Smith")
        let second = Contact(localID: "2", givenName: "Chris", familyName: "Smith")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [first, second]))

        await repository.reload()

        #expect(repository.contacts(named: "  chris smith ").map(\.localID) == ["1", "2"])
        #expect(repository.lookupByDisplayName()["chris smith"]?.localID == "2")
    }

    @Test @MainActor
    func peopleOrganizationsAndReverseRelationsMatchExistingBehavior() async {
        let person = Contact(localID: "person", givenName: "Ada", familyName: "Lovelace")
        let organization = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let referring = Contact(
            localID: "referrer",
            givenName: "Charles",
            contactRelations: [LabeledContactRelation(label: "colleague", value: ContactRelation(name: "Ada Lovelace"))]
        )
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [person, organization, referring]))

        await repository.reload()
        repository.peopleSearch = "ada"

        #expect(repository.people.map(\.localID) == ["person"])
        #expect(repository.organizations.map(\.localID) == ["org"])
        #expect(repository.peopleSections.map(\.0) == ["L"])
        #expect(repository.contactsReferencing(contact: person).map(\.contact.localID) == ["referrer"])
    }
}
