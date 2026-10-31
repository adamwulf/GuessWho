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

    @Test
    func surroundingWhitespaceNeverLeaksIntoTheName() {
        let padded = Contact(contactType: .organization, givenName: "Juan", organizationName: " Acme ")
        #expect(padded.displayName == "Acme")
    }

    /// The id a never-written card previews on the wire must not move when the
    /// card becomes an organization or its company is renamed.
    @Test
    func thePreviewIDIgnoresTheOrganizationNameRule() {
        let person = Contact(localID: "1", givenName: "Juan", familyName: "Perez", organizationName: "Acme")
        var converted = person
        converted.contactType = .organization
        #expect(converted.displayName == "Acme")
        #expect(converted.deterministicGuessWhoID == person.deterministicGuessWhoID)

        var renamed = converted
        renamed.organizationName = "Acme Holdings"
        #expect(renamed.deterministicGuessWhoID == person.deterministicGuessWhoID)
    }

    /// A relation saved with the person name on the card keeps pointing at it,
    /// and so does one using the name the card is called.
    @Test @MainActor
    func relationsResolveByEitherName() async {
        let byPerson = Contact(
            localID: "byPerson",
            givenName: "Ana",
            contactRelations: [LabeledContactRelation(label: "colleague", value: ContactRelation(name: "juan perez"))]
        )
        let byOrganization = Contact(
            localID: "byOrganization",
            givenName: "Bo",
            contactRelations: [LabeledContactRelation(label: "colleague", value: ContactRelation(name: "Cy-Fair HealthCare Associates"))]
        )
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [org, byPerson, byOrganization]))
        await repository.reload()

        let lookup = repository.lookupByDisplayName()
        #expect(lookup["juan perez"]?.localID == "org")
        #expect(lookup["cy-fair healthcare associates"]?.localID == "org")

        let cachedOrg = repository.contacts.first { $0.localID == "org" }!
        #expect(Set(repository.contactsReferencing(contact: cachedOrg).map(\.contact.localID)) == ["byPerson", "byOrganization"])
        #expect(repository.contactsReferencing(id: ContactID(contact: cachedOrg)).count == 2)
    }

    /// A contact actually called the person name wins the relation over the
    /// organization card that merely carries that name.
    @Test @MainActor
    func aContactCalledThePersonNameWinsTheRelation() async {
        let realJuan = Contact(localID: "juan", givenName: "Juan", familyName: "Perez")
        let referrer = Contact(
            localID: "ana",
            givenName: "Ana",
            contactRelations: [LabeledContactRelation(label: "colleague", value: ContactRelation(name: "Juan Perez"))]
        )
        for ordered in [[org, realJuan, referrer], [realJuan, org, referrer]] {
            let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: ordered))
            await repository.reload()

            #expect(repository.lookupByDisplayName()["juan perez"]?.localID == "juan")
            let cachedOrg = repository.contacts.first { $0.localID == "org" }!
            #expect(repository.contactsReferencing(contact: cachedOrg).isEmpty)
            let cachedJuan = repository.contacts.first { $0.localID == "juan" }!
            #expect(repository.contactsReferencing(contact: cachedJuan).map(\.contact.localID) == ["ana"])
        }
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
