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

        #expect(Set(repository.contacts(named: "  chris smith ").map(\.localID)) == Set(["1", "2"]))
        #expect(["1", "2"].contains(repository.lookupByDisplayName()["chris smith"]?.localID ?? ""))
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

    @Test @MainActor
    func inferredOrganizationAssociationsMatchByCompanyName() async {
        let org = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let rivalOrg = Contact(localID: "rival", contactType: .organization, organizationName: "Difference Engine")
        let ada = Contact(localID: "ada", givenName: "Ada", familyName: "Lovelace", organizationName: "  analytical engine ")
        let charles = Contact(localID: "charles", givenName: "Charles", familyName: "Babbage", organizationName: "Analytical Engine")
        let outsider = Contact(localID: "outsider", givenName: "Alan", familyName: "Turing", organizationName: "Bletchley Park")
        let repository = ContactsRepository(
            contacts: InMemoryContactStore(contacts: [org, rivalOrg, ada, charles, outsider])
        )

        await repository.reload()

        // Person→org: trimmed, case-insensitive, organizations only.
        #expect(repository.organizationContact(named: " analytical ENGINE ")?.localID == "org")
        #expect(repository.organizationContact(named: "") == nil)
        #expect(repository.organizationContact(named: "Ada Lovelace") == nil)

        // Org→people: company-field match, people only, sorted by display name.
        #expect(repository.contactsAssociated(with: org).map(\.localID) == ["ada", "charles"])
        #expect(repository.contactsAssociated(with: rivalOrg).isEmpty)
    }
}
