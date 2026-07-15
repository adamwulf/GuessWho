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

    @Test @MainActor
    func departmentsForAnOrganizationAreDistinctTrimmedAndSorted() async {
        let org = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let ada = Contact(
            localID: "ada", givenName: "Ada", familyName: "Lovelace",
            departmentName: "  Engineering ", organizationName: "Analytical Engine"
        )
        let charles = Contact(
            localID: "charles", givenName: "Charles", familyName: "Babbage",
            departmentName: "engineering", organizationName: "analytical engine"
        )
        let grace = Contact(
            localID: "grace", givenName: "Grace", familyName: "Hopper",
            departmentName: "Research", organizationName: "Analytical Engine"
        )
        // No department — contributes to associated people but not to the
        // department list.
        let alan = Contact(
            localID: "alan", givenName: "Alan", familyName: "Turing",
            organizationName: "Analytical Engine"
        )
        // Different org — its department must not leak in.
        let outsider = Contact(
            localID: "outsider", givenName: "Klara", familyName: "von Neumann",
            departmentName: "Mathematics", organizationName: "Bletchley Park"
        )
        let repository = ContactsRepository(
            contacts: InMemoryContactStore(contacts: [org, ada, charles, grace, alan, outsider])
        )

        await repository.reload()

        // Distinct (case-insensitive), trimmed to the first-seen display form,
        // sorted A–Z; blank/other-org departments excluded.
        #expect(repository.departments(in: org) == ["Engineering", "Research"])

        // People in one department: subset of the associated people, matched
        // case-insensitively on the department field, sorted by display name.
        #expect(
            repository.contactsAssociated(with: org, inDepartment: " ENGINEERING ").map(\.localID)
                == ["ada", "charles"]
        )
        #expect(repository.contactsAssociated(with: org, inDepartment: "Research").map(\.localID) == ["grace"])
        #expect(repository.contactsAssociated(with: org, inDepartment: "").isEmpty)
        #expect(repository.contactsAssociated(with: org, inDepartment: "Mathematics").isEmpty)
    }
}
