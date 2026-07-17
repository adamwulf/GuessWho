import Foundation
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
    func linkedFiltersComposeIndependentlyWithSearchAndSort() async throws {
        let amyID = "11111111-1111-1111-1111-111111111111"
        let zedID = "22222222-2222-2222-2222-222222222222"
        let orgID = "33333333-3333-3333-3333-333333333333"
        func identifiedContact(
            localID: String,
            uuid: String,
            givenName: String = "",
            familyName: String = "",
            type: ContactType = .person,
            organizationName: String = ""
        ) -> Contact {
            Contact(
                localID: localID,
                contactType: type,
                givenName: givenName,
                familyName: familyName,
                organizationName: organizationName,
                urlAddresses: [
                    LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)")
                ]
            )
        }

        let amy = identifiedContact(localID: "amy", uuid: amyID, givenName: "Amy", familyName: "Able")
        let zed = identifiedContact(localID: "zed", uuid: zedID, givenName: "Zed", familyName: "Zero")
        let bob = Contact(localID: "bob", givenName: "Bob", familyName: "Baker")
        let linkedOrg = identifiedContact(
            localID: "linked-org", uuid: orgID, type: .organization, organizationName: "Acme"
        )
        let unlinkedOrg = Contact(
            localID: "unlinked-org", contactType: .organization, organizationName: "Beta"
        )

        let store = InMemoryContactStore(contacts: [zed, bob, linkedOrg, amy, unlinkedOrg])
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-A"
        )
        _ = try sync.addLink(
            from: SidecarKey(kind: .contact, id: amyID),
            to: SidecarKey(kind: .event, id: UUID().uuidString),
            note: ""
        )
        _ = try sync.addLink(
            from: SidecarKey(kind: .place, id: UUID().uuidString),
            to: SidecarKey(kind: .contact, id: zedID),
            note: ""
        )
        _ = try sync.addLink(
            from: SidecarKey(kind: .contact, id: orgID),
            to: SidecarKey(kind: .contact, id: amyID),
            note: ""
        )

        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()
        repository.sortOrder = .firstLast
        repository.peopleFilter = .linked

        #expect(repository.people.map(\.localID) == ["amy", "zed"])
        repository.peopleSearch = "zed"
        #expect(repository.people.map(\.localID) == ["zed"])

        repository.organizationsFilter = .linked
        #expect(repository.organizations.map(\.localID) == ["linked-org"])
        #expect(repository.people.map(\.localID) == ["zed"])

        repository.peopleSearch = ""
        repository.peopleFilter = .all
        #expect(repository.people.map(\.localID) == ["amy", "bob", "zed"])
        #expect(repository.organizations.map(\.localID) == ["linked-org"])
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

    @Test @MainActor
    func renamingADepartmentRewritesOnlyTheMatchingAssociatedContacts() async throws {
        let org = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let ada = Contact(
            localID: "ada", givenName: "Ada", familyName: "Lovelace",
            departmentName: "Engineering", organizationName: "Analytical Engine"
        )
        let charles = Contact(
            localID: "charles", givenName: "Charles", familyName: "Babbage",
            departmentName: "  ENGINEERING ", organizationName: "Analytical Engine"
        )
        // Same department name but a DIFFERENT org — must not be rewritten.
        let outsider = Contact(
            localID: "outsider", givenName: "Klara", familyName: "von Neumann",
            departmentName: "Engineering", organizationName: "Bletchley Park"
        )
        // Same org, different department — must not be rewritten.
        let grace = Contact(
            localID: "grace", givenName: "Grace", familyName: "Hopper",
            departmentName: "Research", organizationName: "Analytical Engine"
        )
        let repository = ContactsRepository(
            contacts: InMemoryContactStore(contacts: [org, ada, charles, outsider, grace])
        )

        await repository.reload()

        // Blank new name is a no-op (the invariant "a department never becomes
        // nameless" holds at the package boundary).
        let noopCount = try await repository.renameDepartment(from: "Engineering", to: "   ", in: org)
        #expect(noopCount == 0)
        #expect(repository.departments(in: org) == ["Engineering", "Research"])

        // Case-insensitive match, trimmed new value, both members rewritten.
        let count = try await repository.renameDepartment(from: " engineering ", to: "  R&D ", in: org)
        #expect(count == 2)

        #expect(repository.contact(localID: "ada")?.departmentName == "R&D")
        #expect(repository.contact(localID: "charles")?.departmentName == "R&D")
        // Different org / different department left untouched.
        #expect(repository.contact(localID: "outsider")?.departmentName == "Engineering")
        #expect(repository.contact(localID: "grace")?.departmentName == "Research")

        #expect(repository.departments(in: org) == ["R&D", "Research"])
        #expect(repository.contactsAssociated(with: org, inDepartment: "R&D").map(\.localID) == ["ada", "charles"])
    }
}
