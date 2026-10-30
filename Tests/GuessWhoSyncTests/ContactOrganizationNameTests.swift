import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// An organization record is called by its organization name, even when the same
/// card also carries a given or family name.
@Suite("Organization record names")
struct ContactOrganizationNameTests {
    private let org = Contact(
        localID: "org",
        contactType: .organization,
        givenName: "Juan",
        familyName: "Perez",
        organizationName: "Cy-Fair HealthCare Associates"
    )

    @Test
    func organizationNameWinsOverAPersonName() {
        #expect(org.isNamedByOrganization)
        #expect(org.displayName == "Cy-Fair HealthCare Associates")
    }

    @Test
    func sortsAndSectionsByOrganizationNameInBothNameOrders() {
        #expect(org.lastNameSortKey == "Cy-Fair HealthCare Associates")
        #expect(org.firstNameSortKey == "Cy-Fair HealthCare Associates")
        #expect(org.sectionLetter == "C")
        #expect(org.firstNameSectionLetter == "C")
    }

    @Test
    func aBlankOrganizationNameFallsBackToThePersonName() {
        let blank = Contact(contactType: .organization, givenName: "Juan", familyName: "Perez", organizationName: "   ")
        #expect(!blank.isNamedByOrganization)
        #expect(blank.displayName == "Juan Perez")
        #expect(blank.lastNameSortKey == "Perez")
        #expect(blank.firstNameSortKey == "Juan")
    }

    @Test
    func aPersonKeepsTheirOwnNameBesideACompany() {
        let person = Contact(givenName: "Juan", familyName: "Perez", organizationName: "Acme")
        #expect(!person.isNamedByOrganization)
        #expect(person.displayName == "Juan Perez")
        #expect(person.lastNameSortKey == "Perez")
        #expect(person.firstNameSortKey == "Juan")
    }

    /// People naming the company associate with the record, rather than the
    /// company also appearing as a second, record-less organization row.
    @Test @MainActor
    func peopleNamingTheCompanyAssociateWithTheRecord() async {
        let person = Contact(
            localID: "ada",
            givenName: "Ada",
            familyName: "Lovelace",
            organizationName: "cy-fair healthcare associates"
        )
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [org, person]))
        await repository.reload()

        #expect(repository.phantomOrganizations.isEmpty)
        #expect(repository.organizationContact(named: "Cy-Fair HealthCare Associates")?.localID == "org")
        #expect(repository.contactsAssociated(with: org).map(\.localID) == ["ada"])
    }
}
