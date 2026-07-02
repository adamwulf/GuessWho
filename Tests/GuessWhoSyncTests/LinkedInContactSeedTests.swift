import Foundation
import Testing
@testable import GuessWhoSync

@Suite("LinkedInContactSeed")
struct LinkedInContactSeedTests {

    // MARK: - Full mapping

    @Test("Full profile maps name, work, emails, websites, and LinkedIn username")
    func testFullProfileMapping() {
        let profile = LinkedInProfile(
            sourceUrl: "https://www.linkedin.com/in/lydia-e-kavraki-14abb4/",
            slug: "lydia-e-kavraki-14abb4",
            fullName: "Lydia E. Kavraki",
            headline: "University Professor at Rice University",
            title: "Full-time",
            org: "Rice University",
            location: "Houston, Texas, United States",
            about: "Robotics and computational biomedicine.",
            contactInfo: .init(
                profileUrl: "https://www.linkedin.com/in/lydia-e-kavraki-14abb4",
                emails: ["kavraki@rice.edu"],
                websites: ["http://www.kavrakilab.org"]
            )
        )

        let seed = LinkedInContactSeed.contact(from: profile)

        // Name splits via PersonNameComponents: middle initial lands in
        // middleName, not familyName. The exact split is Foundation's name
        // parser, so an OS update could legitimately move the "E." — if this
        // ever fails on a new OS, re-verify the parse by hand before touching
        // the seed builder.
        #expect(seed.givenName == "Lydia")
        #expect(seed.middleName == "E.")
        #expect(seed.familyName == "Kavraki")

        #expect(seed.jobTitle == "Full-time")
        #expect(seed.organizationName == "Rice University")

        // CNContact multi-values carry the DEFAULT (empty) label, not "LinkedIn".
        #expect(seed.emailAddresses == [LabeledValue(label: "", value: "kavraki@rice.edu")])
        #expect(seed.urlAddresses == [LabeledValue(label: "", value: "http://www.kavrakilab.org")])

        // The LinkedIn social profile stores the USERNAME slug, never a URL
        // (Contacts derives the URL from the username).
        #expect(seed.socialProfiles == [
            LabeledSocialProfile(
                label: "LinkedIn",
                value: SocialProfile(urlString: "", username: "lydia-e-kavraki-14abb4", service: "LinkedIn")
            )
        ])

        // Empty localID routes the editor's Save through the adapter's
        // brand-new-contact branch.
        #expect(seed.localID.isEmpty)

        // Headline / about / location are sidecar-only — never CNContact
        // fields, so nothing in the seed carries them. (The app attaches
        // them post-save via applyLinkedIn.)
        #expect(seed.contactRelations.isEmpty)
        #expect(seed.phoneNumbers.isEmpty)
    }

    // MARK: - Name edge cases

    @Test("Missing full name yields empty name fields — the editor opens blank, by design")
    func testMissingNameLeavesNameFieldsEmpty() {
        let profile = LinkedInProfile(fullName: nil, org: "Acme")
        let seed = LinkedInContactSeed.contact(from: profile)
        #expect(seed.givenName.isEmpty)
        #expect(seed.middleName.isEmpty)
        #expect(seed.familyName.isEmpty)
        #expect(seed.organizationName == "Acme")
    }

    @Test("Whitespace-only full name is treated as missing")
    func testWhitespaceNameLeavesNameFieldsEmpty() {
        let profile = LinkedInProfile(fullName: "   ")
        let seed = LinkedInContactSeed.contact(from: profile)
        #expect(seed.givenName.isEmpty)
        #expect(seed.familyName.isEmpty)
    }

    @Test("Single-word name lands in givenName")
    func testSingleWordName() {
        let profile = LinkedInProfile(fullName: "Cher")
        let seed = LinkedInContactSeed.contact(from: profile)
        #expect(seed.givenName == "Cher")
        #expect(seed.familyName.isEmpty)
    }

    // MARK: - Dedup

    @Test("Emails dedup case-insensitively, first surface form wins, order preserved")
    func testEmailDedup() {
        let profile = LinkedInProfile(contactInfo: .init(
            emails: ["a@x.com", "  A@X.COM ", "b@x.com", ""]
        ))
        let seed = LinkedInContactSeed.contact(from: profile)
        #expect(seed.emailAddresses.map(\.value) == ["a@x.com", "b@x.com"])
    }

    @Test("Websites dedup scheme-, www-, and trailing-slash-insensitively")
    func testWebsiteDedup() {
        let profile = LinkedInProfile(contactInfo: .init(
            websites: [
                "http://kavrakilab.org",
                "https://www.kavrakilab.org/",
                "KAVRAKILAB.ORG",
                "https://rice.edu"
            ]
        ))
        let seed = LinkedInContactSeed.contact(from: profile)
        #expect(seed.urlAddresses.map(\.value) == ["http://kavrakilab.org", "https://rice.edu"])
    }

    // MARK: - LinkedIn username slug

    @Test("Slug prefers contactInfo.profileUrl, then sourceUrl, then the parsed slug")
    func testSlugSourcePreference() {
        // profileUrl wins over sourceUrl.
        let both = LinkedInProfile(
            sourceUrl: "https://www.linkedin.com/in/from-source-url/",
            contactInfo: .init(profileUrl: "https://www.linkedin.com/in/from-profile-url")
        )
        #expect(
            LinkedInContactSeed.contact(from: both).socialProfiles.first?.value.username
                == "from-profile-url"
        )

        // No URLs at all → the parser's slug field, normalized the same way
        // LinkedInURL.slug(from:) normalizes (trimmed + lowercased), so the
        // seeded username's casing doesn't depend on which source won.
        let slugOnly = LinkedInProfile(slug: "  From-Slug ")
        #expect(
            LinkedInContactSeed.contact(from: slugOnly).socialProfiles.first?.value.username
                == "from-slug"
        )

        // Nothing → no LinkedIn social profile at all.
        let none = LinkedInProfile(fullName: "No Links")
        #expect(LinkedInContactSeed.contact(from: none).socialProfiles.isEmpty)
    }

    // MARK: - Trimming

    @Test("Job title and organization are trimmed; nils become empty strings")
    func testWorkFieldTrimming() {
        let profile = LinkedInProfile(title: "  Professor ", org: nil)
        let seed = LinkedInContactSeed.contact(from: profile)
        #expect(seed.jobTitle == "Professor")
        #expect(seed.organizationName.isEmpty)
    }
}
