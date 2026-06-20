import Foundation
import Testing
@testable import GuessWhoSync

@Suite("Contact.matches(searchQuery:)")
struct ContactSearchTests {
    private func person(
        given: String = "",
        family: String = "",
        nickname: String = "",
        organization: String = "",
        jobTitle: String = "",
        department: String = "",
        emails: [String] = [],
        phones: [String] = [],
        urls: [String] = []
    ) -> Contact {
        Contact(
            localID: UUID().uuidString,
            givenName: given,
            familyName: family,
            nickname: nickname,
            jobTitle: jobTitle,
            departmentName: department,
            organizationName: organization,
            phoneNumbers: phones.map { LabeledValue(label: "mobile", value: $0) },
            emailAddresses: emails.map { LabeledValue(label: "home", value: $0) },
            urlAddresses: urls.map { LabeledValue(label: "home", value: $0) }
        )
    }

    // MARK: - Empty query

    @Test
    func emptyQueryMatchesEveryone() {
        let c = person(given: "Jane", family: "Smith")
        #expect(c.matches(searchQuery: ""))
        #expect(c.matches(searchQuery: "   "))
        #expect(c.matches(searchQuery: "\n\t"))
    }

    // MARK: - Name fields

    @Test
    func matchesGivenName() {
        let c = person(given: "Alice", family: "Doe")
        #expect(c.matches(searchQuery: "ali"))
        #expect(c.matches(searchQuery: "ALICE"))
    }

    @Test
    func matchesFamilyName() {
        let c = person(given: "Alice", family: "Bumblebee")
        #expect(c.matches(searchQuery: "bumble"))
    }

    @Test
    func matchesNickname() {
        let c = person(given: "Robert", family: "Smith", nickname: "Bobby")
        #expect(c.matches(searchQuery: "bobby"))
    }

    @Test
    func doesNotMatchUnrelatedTerm() {
        let c = person(given: "Alice", family: "Doe", organization: "Acme")
        #expect(!c.matches(searchQuery: "globex"))
    }

    // MARK: - Org / job

    @Test
    func matchesOrganization() {
        let c = person(given: "Alice", organization: "Globex Inc")
        #expect(c.matches(searchQuery: "globex"))
    }

    @Test
    func matchesJobTitle() {
        let c = person(given: "Alice", organization: "Globex", jobTitle: "Lead Designer")
        #expect(c.matches(searchQuery: "designer"))
    }

    @Test
    func matchesDepartment() {
        let c = person(given: "Alice", department: "Engineering")
        #expect(c.matches(searchQuery: "engineering"))
    }

    // MARK: - Contact channels

    @Test
    func matchesEmail() {
        let c = person(given: "Alice", emails: ["alice@example.com"])
        #expect(c.matches(searchQuery: "example.com"))
        #expect(c.matches(searchQuery: "alice@"))
    }

    @Test
    func matchesPhone() {
        let c = person(given: "Alice", phones: ["555-0123"])
        #expect(c.matches(searchQuery: "555"))
        #expect(c.matches(searchQuery: "0123"))
    }

    @Test
    func matchesURL() {
        let c = person(given: "Alice", urls: ["https://alice.dev"])
        #expect(c.matches(searchQuery: "alice.dev"))
    }

    // MARK: - Trim + case behavior

    @Test
    func matchTrimsLeadingAndTrailingWhitespace() {
        let c = person(given: "Alice")
        #expect(c.matches(searchQuery: "  ALI  "))
    }

    @Test
    func matchIsCaseInsensitiveAcrossFieldCases() {
        let c = person(given: "ALICE", organization: "globex")
        #expect(c.matches(searchQuery: "alice"))
        #expect(c.matches(searchQuery: "GLOBEX"))
    }

    @Test
    func nicknameMatchesEvenWhenGivenNameDoesNot() {
        let c = person(given: "William", family: "Williams", nickname: "Buddy")
        #expect(c.matches(searchQuery: "buddy"))
    }

    @Test
    func partialEmailMatchInsideUsername() {
        let c = person(emails: ["jane.doe.789@example.com"])
        #expect(c.matches(searchQuery: "doe.789"))
    }
}
