import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Phantom organizations: company names carried by people that have no
/// organization record of their own. See `PhantomOrganization` /
/// `ContactsRepository.phantomOrganizations` / `organizationRowSectionIDs`.
@Suite("Phantom organizations")
struct PhantomOrganizationsTests {
    /// A repository seeded with one real org record ("Analytical Engine") and
    /// people who name it, two phantom companies, and a blank-company person.
    @MainActor
    private func seededRepository() async -> ContactsRepository {
        let realOrg = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let ada = Contact(localID: "ada", givenName: "Ada", familyName: "Lovelace", organizationName: "Analytical Engine")
        let charles = Contact(localID: "charles", givenName: "Charles", familyName: "Babbage", organizationName: "  analytical engine ")
        let grace = Contact(localID: "grace", givenName: "Grace", familyName: "Hopper", organizationName: "Bletchley Park")
        let alan = Contact(localID: "alan", givenName: "Alan", familyName: "Turing", organizationName: "bletchley park")
        let mavis = Contact(localID: "mavis", givenName: "Mavis", familyName: "Batey", organizationName: "Zeta Corp")
        let nemo = Contact(localID: "nemo", givenName: "Nemo", familyName: "Nobody", organizationName: "   ")
        let repository = ContactsRepository(
            contacts: InMemoryContactStore(contacts: [realOrg, ada, charles, grace, alan, mavis, nemo])
        )
        await repository.reload()
        return repository
    }

    @Test @MainActor
    func collectsDistinctPhantomsExcludingRecordsBlanksAndCollapsingCase() async {
        let repository = await seededRepository()

        let phantoms = repository.phantomOrganizations
        // "Analytical Engine" is a record → not a phantom. Blank company ignored.
        // "Bletchley Park" (2 spellings) collapses to one; "Zeta Corp" stands alone.
        #expect(phantoms.map(\.key) == ["bletchley park", "zeta corp"])
        // Sorted by key, so order is deterministic. When a company is spelled
        // several ways ("Bletchley Park" / "bletchley park"), the capitalized
        // spelling wins the display form.
        #expect(phantoms.first?.displayName == "Bletchley Park")
        #expect(phantoms.first?.associatedCount == 2)
        #expect(phantoms.last?.associatedCount == 1)
    }

    @Test @MainActor
    func searchNarrowsPhantomsByName() async {
        let repository = await seededRepository()

        repository.organizationsSearch = "bletchley"
        #expect(repository.phantomOrganizations.map(\.key) == ["bletchley park"])

        repository.organizationsSearch = "nomatch"
        #expect(repository.phantomOrganizations.isEmpty)
    }

    @Test @MainActor
    func linkedFilterExcludesEveryPhantom() async {
        let repository = await seededRepository()

        repository.organizationsFilter = .linked
        // A phantom has no record, so it can hold no link — none qualify.
        #expect(repository.phantomOrganizations.isEmpty)
    }

    @Test @MainActor
    func matchingAccessorIsIndependentOfListSearchAndFilter() async {
        let repository = await seededRepository()
        // Put the Organizations LIST into a state that would hide phantoms.
        repository.organizationsFilter = .linked
        repository.organizationsSearch = "zeta"

        // The query-only accessor ignores both: all phantoms with blank query.
        #expect(repository.phantomOrganizations(matching: "").map(\.key) == ["bletchley park", "zeta corp"])
        // And honors ONLY its own query, not the list's search.
        #expect(repository.phantomOrganizations(matching: "bletchley").map(\.key) == ["bletchley park"])
        // The single-key lookup is likewise decoupled from the list state.
        #expect(repository.phantomOrganization(key: "bletchley park")?.associatedCount == 2)
    }

    @Test @MainActor
    func mergedRowsInterleaveRecordsAndPhantomsByName() async {
        let repository = await seededRepository()
        repository.sortOrder = .lastFirst

        let sections = repository.organizationRowSectionIDs
        #expect(sections.map(\.0) == ["A", "B", "Z"])

        // A section → the real record; B/Z → phantoms addressed by key.
        #expect(sections[0].1 == [.record(ContactID(guessWhoID: nil, localID: "org"))])
        #expect(sections[1].1 == [.phantom(key: "bletchley park")])
        #expect(sections[2].1 == [.phantom(key: "zeta corp")])
    }

    @Test @MainActor
    func phantomLookupResolvesByRawNameAndRejectsRecordsAndBlanks() async {
        let repository = await seededRepository()

        #expect(repository.phantomOrganization(key: "Bletchley PARK")?.associatedCount == 2)
        #expect(repository.phantomOrganization(key: "bletchley park")?.displayName == "Bletchley Park")
        // A real-record name is not a phantom.
        #expect(repository.phantomOrganization(key: "Analytical Engine") == nil)
        #expect(repository.phantomOrganization(key: "") == nil)
    }

    @Test @MainActor
    func associatedPeopleAndDepartmentsResolveByPhantomName() async {
        let repository = await seededRepository()

        #expect(
            repository.contactsAssociated(withOrganizationNamed: " BLETCHLEY park ").map(\.localID) == ["alan", "grace"]
        )
        #expect(repository.contactsAssociated(withOrganizationNamed: "Zeta Corp").map(\.localID) == ["mavis"])
        #expect(repository.contactsAssociated(withOrganizationNamed: "").isEmpty)
    }

    @Test @MainActor
    func timeOrderBucketsPhantomsAsEarlier() async {
        let repository = await seededRepository()
        repository.sortOrder = .lastModified

        // No sidecar timestamps exist for any of these, so every row (records
        // and phantoms alike) buckets as "Earlier".
        let sections = repository.organizationRowSectionIDs
        #expect(sections.map(\.0) == [ContactsRepository.earlierBucket])
        let rows = sections.first?.1 ?? []
        #expect(rows.contains(.phantom(key: "bletchley park")))
        #expect(rows.contains(.phantom(key: "zeta corp")))
    }
}
