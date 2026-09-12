import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// The candidate lists the contact editor's autocompleting fields read from
/// the repository cache. See `ContactsRepository+Suggestions.swift`.
@Suite("Contact suggestion candidates")
struct ContactSuggestionCandidatesTests {
    /// One real organization record ("Analytical Engine") with two people in
    /// it across two departments, a phantom company spelled two ways, a
    /// person with no company, and a nameless contact.
    @MainActor
    private func seededRepository() async -> ContactsRepository {
        let realOrg = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let ada = Contact(
            localID: "ada", givenName: "Ada", familyName: "Lovelace",
            departmentName: "Mathematics", organizationName: "Analytical Engine"
        )
        let charles = Contact(
            localID: "charles", givenName: "Charles", familyName: "Babbage",
            departmentName: " mathematics ", organizationName: "  analytical engine "
        )
        let luigi = Contact(
            localID: "luigi", givenName: "Luigi", familyName: "Menabrea",
            departmentName: "Engineering", organizationName: "Analytical Engine"
        )
        let grace = Contact(
            localID: "grace", givenName: "Grace", familyName: "Hopper",
            departmentName: "Cryptanalysis", organizationName: "bletchley park"
        )
        let alan = Contact(
            localID: "alan", givenName: "Alan", familyName: "Turing",
            departmentName: "Hut 8", organizationName: "Bletchley Park"
        )
        let nemo = Contact(localID: "nemo", givenName: "Nemo", familyName: "Nobody", organizationName: "   ")
        let nameless = Contact(localID: "nameless")
        let repository = ContactsRepository(
            contacts: InMemoryContactStore(contacts: [realOrg, ada, charles, luigi, grace, alan, nemo, nameless])
        )
        await repository.reload()
        return repository
    }

    @Test @MainActor
    func relatedNamesListEveryNamedContactExceptTheOneBeingEdited() async {
        let repository = await seededRepository()
        let ada = repository.contact(id: ContactID(guessWhoID: nil, localID: "ada"))

        let names = repository.relatedNameSuggestionCandidates(excluding: ada?.contactID)
        // Sorted A–Z; the organization record counts too; Ada herself and the
        // nameless "(Unnamed)" contact are absent.
        #expect(names == [
            "Alan Turing", "Analytical Engine", "Charles Babbage", "Grace Hopper",
            "Luigi Menabrea", "Nemo Nobody",
        ])
    }

    @Test @MainActor
    func relatedNamesWithNothingExcludedIncludeEveryone() async {
        let repository = await seededRepository()

        let names = repository.relatedNameSuggestionCandidates(excluding: nil)
        #expect(names.contains("Ada Lovelace"))
        #expect(!names.contains(Contact.unnamedDisplayName))
        #expect(names.count == 7)
    }

    @Test @MainActor
    func organizationNamesMergeRecordsAndPhantomsWithoutDuplicates() async {
        let repository = await seededRepository()

        // The record's spelling wins for "Analytical Engine" even though a
        // person spells it lowercase; the phantom's capitalized spelling wins
        // over its lowercase twin; the blank company is skipped.
        #expect(repository.organizationNameSuggestionCandidates() == ["Analytical Engine", "Bletchley Park"])
    }

    @Test @MainActor
    func departmentsAreScopedToTheNamedOrganization() async {
        let repository = await seededRepository()

        // Case- and whitespace-insensitive on the organization, de-duplicated
        // on the department (Ada's and Charles's "Mathematics" collapse), A–Z.
        #expect(
            repository.departmentNameSuggestionCandidates(inOrganizationNamed: " analytical ENGINE ")
                == ["Engineering", "Mathematics"]
        )
        #expect(
            repository.departmentNameSuggestionCandidates(inOrganizationNamed: "Bletchley Park")
                == ["Cryptanalysis", "Hut 8"]
        )
    }

    @Test @MainActor
    func departmentsNeedAnOrganization() async {
        let repository = await seededRepository()

        #expect(repository.departmentNameSuggestionCandidates(inOrganizationNamed: "").isEmpty)
        #expect(repository.departmentNameSuggestionCandidates(inOrganizationNamed: "   ").isEmpty)
        #expect(repository.departmentNameSuggestionCandidates(inOrganizationNamed: "Nowhere Inc").isEmpty)
    }

    @Test @MainActor
    func candidatesFeedTheFilterEndToEnd() async {
        let repository = await seededRepository()

        // Typing a surname fragment in the Related field: the word-prefix
        // match on "Babbage" is the only hit.
        let related = TextSuggestionFilter.suggestions(
            matching: "bab",
            in: repository.relatedNameSuggestionCandidates(excluding: nil)
        )
        #expect(related == ["Charles Babbage"])

        // A single letter also reaches into substrings, ranked after the
        // word-prefix hit and otherwise in the candidates' A–Z order.
        let single = TextSuggestionFilter.suggestions(
            matching: "b",
            in: repository.relatedNameSuggestionCandidates(excluding: nil)
        )
        #expect(single == ["Charles Babbage", "Luigi Menabrea", "Nemo Nobody"])

        // Typing "eng" in Department with the Company filled in.
        let departments = TextSuggestionFilter.suggestions(
            matching: "eng",
            in: repository.departmentNameSuggestionCandidates(inOrganizationNamed: "Analytical Engine")
        )
        #expect(departments == ["Engineering"])
    }
}
