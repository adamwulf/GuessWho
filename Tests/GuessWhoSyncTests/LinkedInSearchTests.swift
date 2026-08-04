import Foundation
import Testing
@testable import GuessWhoSync

@Suite("LinkedInSearch")
struct LinkedInSearchTests {

    // MARK: - URL building

    @Test("People search encodes spaces as %20 and carries the origin")
    func peopleURL() {
        #expect(
            LinkedInSearch.peopleURL(keywords: "marta Torralba")?.absoluteString
                == "https://www.linkedin.com/search/results/people/?keywords=marta%20Torralba&origin=FACETED_SEARCH"
        )
    }

    @Test("Companies search uses the companies vertical")
    func companiesURL() {
        #expect(
            LinkedInSearch.companiesURL(keywords: "Rice University")?.absoluteString
                == "https://www.linkedin.com/search/results/companies/?keywords=Rice%20University&origin=FACETED_SEARCH"
        )
    }

    @Test("Query-breaking characters are percent-encoded, not passed through")
    func encodesSubDelimiters() {
        let url = LinkedInSearch.peopleURL(keywords: "Ann Smith AT&T C++ ?#")?.absoluteString ?? ""
        // `&`, `=`, `?`, `#` would split the query; `+` would decode back to a
        // space. All of them must arrive escaped.
        #expect(url.hasPrefix("https://www.linkedin.com/search/results/people/?keywords="))
        #expect(url.contains("AT%26T"))
        #expect(url.contains("C%2B%2B"))
        #expect(url.contains("%3F%23"))
        // Exactly one "&" — the separator before `origin`.
        #expect(url.filter { $0 == "&" }.count == 1)
        #expect(url.hasSuffix("&origin=FACETED_SEARCH"))
    }

    @Test("Non-ASCII names survive encoding")
    func encodesNonASCII() {
        let url = LinkedInSearch.peopleURL(keywords: "José Núñez")?.absoluteString ?? ""
        #expect(url.contains("Jos%C3%A9%20N%C3%BA%C3%B1ez"))
    }

    @Test("Empty or whitespace-only keywords produce no URL")
    func emptyKeywords() {
        #expect(LinkedInSearch.peopleURL(keywords: "") == nil)
        #expect(LinkedInSearch.peopleURL(keywords: "   \n ") == nil)
        #expect(LinkedInSearch.companiesURL(keywords: "") == nil)
    }

    // MARK: - Keywords from a contact

    @Test("A person searches on name, narrowed by the organization")
    func personKeywords() {
        let contact = Contact(
            localID: "1",
            givenName: "Marta",
            familyName: "Torralba",
            organizationName: "Acme Robotics"
        )
        #expect(LinkedInSearch.keywords(for: contact) == "Marta Torralba Acme Robotics")
        #expect(
            LinkedInSearch.url(for: contact)?.absoluteString
                == "https://www.linkedin.com/search/results/people/?keywords=Marta%20Torralba%20Acme%20Robotics&origin=FACETED_SEARCH"
        )
    }

    @Test("A person with no organization searches on the name alone")
    func personWithoutOrganization() {
        let contact = Contact(localID: "1", givenName: "Marta", familyName: "Torralba")
        #expect(LinkedInSearch.keywords(for: contact) == "Marta Torralba")
    }

    @Test("A nameless person falls back to the nickname, then the organization")
    func personNameFallbacks() {
        let nicknamed = Contact(localID: "1", nickname: "Torch", organizationName: "Acme")
        #expect(LinkedInSearch.keywords(for: nicknamed) == "Torch Acme")

        let orgOnly = Contact(localID: "2", organizationName: "Acme")
        #expect(LinkedInSearch.keywords(for: orgOnly) == "Acme")

        // Nothing to search for at all.
        let empty = Contact(localID: "3")
        #expect(LinkedInSearch.keywords(for: empty) == nil)
        #expect(LinkedInSearch.url(for: empty) == nil)
    }

    @Test("An organization searches companies for the organization name only")
    func organizationKeywords() {
        let contact = Contact(
            localID: "1",
            contactType: .organization,
            // A stray given name on an org record must not leak into the query.
            givenName: "Reception",
            organizationName: "Rice University"
        )
        #expect(LinkedInSearch.keywords(for: contact) == "Rice University")
        #expect(
            LinkedInSearch.url(for: contact)?.absoluteString
                == "https://www.linkedin.com/search/results/companies/?keywords=Rice%20University&origin=FACETED_SEARCH"
        )
    }

    @Test("An organization with no organization name has nothing to search")
    func organizationWithoutName() {
        let contact = Contact(localID: "1", contactType: .organization, givenName: "Reception")
        #expect(LinkedInSearch.keywords(for: contact) == nil)
        #expect(LinkedInSearch.url(for: contact) == nil)
    }

    // MARK: - hasLinkedInProfile

    @Test("A LinkedIn social profile with a username counts as a profile")
    func socialProfileUsername() {
        let contact = Contact(
            localID: "1",
            givenName: "Adam",
            familyName: "Wulf",
            socialProfiles: [
                LabeledSocialProfile(
                    label: "LinkedIn",
                    value: SocialProfile(username: "adamwulf", service: "LinkedIn")
                )
            ]
        )
        #expect(contact.hasLinkedInProfile)
    }

    @Test("A LinkedIn social profile with only a URL counts as a profile")
    func socialProfileURLOnly() {
        let contact = Contact(
            localID: "1",
            socialProfiles: [
                LabeledSocialProfile(
                    label: "",
                    value: SocialProfile(urlString: "https://www.linkedin.com/in/adamwulf", service: "LinkedIn")
                )
            ]
        )
        #expect(contact.hasLinkedInProfile)
    }

    @Test("An untagged social profile holding a LinkedIn URL still counts")
    func socialProfileUnlabeledLinkedInURL() {
        let contact = Contact(
            localID: "1",
            socialProfiles: [
                LabeledSocialProfile(
                    label: "other",
                    value: SocialProfile(urlString: "https://www.linkedin.com/in/adamwulf", service: "Other")
                )
            ]
        )
        #expect(contact.hasLinkedInProfile)
    }

    @Test("A LinkedIn website counts as a profile")
    func websiteLinkedIn() {
        let contact = Contact(
            localID: "1",
            urlAddresses: [LabeledValue(label: "", value: "https://www.linkedin.com/in/adamwulf")]
        )
        #expect(contact.hasLinkedInProfile)
    }

    @Test("An empty LinkedIn social profile is not a profile")
    func emptyLinkedInSocialProfile() {
        let contact = Contact(
            localID: "1",
            givenName: "Adam",
            familyName: "Wulf",
            socialProfiles: [
                LabeledSocialProfile(label: "LinkedIn", value: SocialProfile(service: "LinkedIn"))
            ]
        )
        #expect(!contact.hasLinkedInProfile)
        // …so the app offers a search instead.
        #expect(LinkedInSearch.url(for: contact) != nil)
    }

    @Test("Other services and non-LinkedIn websites are not a LinkedIn profile")
    func unrelatedProfiles() {
        let contact = Contact(
            localID: "1",
            givenName: "Adam",
            familyName: "Wulf",
            urlAddresses: [LabeledValue(label: "", value: "https://adamwulf.me")],
            socialProfiles: [
                LabeledSocialProfile(
                    label: "",
                    value: SocialProfile(username: "adamwulf", service: "Twitter")
                )
            ]
        )
        #expect(!contact.hasLinkedInProfile)
    }
}
