import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository.applyLinkedIn")
@MainActor
struct LinkedInApplyTests {
    private func makeSync(_ contacts: InMemoryContactStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
    }

    private func setup(_ person: Contact) async -> (ContactsRepository, ContactID, GuessWhoSync) {
        let store = InMemoryContactStore(contacts: [person])
        let sync = makeSync(store)
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        let id = repo.contact(localID: person.localID)!.contactID
        return (repo, id, sync)
    }

    private func profile(
        fullName: String? = nil, title: String? = nil, org: String? = nil,
        location: String? = nil, about: String? = nil,
        emails: [String] = [], websites: [String] = [], profileUrl: String? = nil
    ) -> LinkedInProfile {
        LinkedInProfile(
            fullName: fullName, title: title, org: org,
            location: location, about: about,
            contactInfo: LinkedInProfile.ContactInfo(
                profileUrl: profileUrl, emails: emails, websites: websites
            )
        )
    }

    @Test func appliesChosenCNContactFields_andReturnsUpdated() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        let result = try await repo.applyLinkedIn(
            profile: profile(fullName: "Adam Wulf", title: "Instructor", org: "Rice"),
            to: id, fields: [.name, .jobTitle, .organization]
        )
        #expect(result.givenName == "Adam")
        #expect(result.familyName == "Wulf")
        #expect(result.jobTitle == "Instructor")
        #expect(result.organizationName == "Rice")
    }

    @Test func unselectedFieldsAreUntouched() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada", jobTitle: "Keep"))
        let result = try await repo.applyLinkedIn(
            profile: profile(fullName: "Adam Wulf", title: "Instructor"),
            to: id, fields: [.name] // jobTitle NOT chosen
        )
        #expect(result.givenName == "Adam")
        #expect(result.jobTitle == "Keep")
    }

    @Test func emailsMerge_dedupCaseInsensitive_neverDelete() async throws {
        let existing = Contact(localID: "T",
            emailAddresses: [LabeledValue(label: "home", value: "Adam@AdamWulf.me")])
        let (repo, id, _) = await setup(existing)
        let result = try await repo.applyLinkedIn(
            profile: profile(emails: ["adam@adamwulf.me", "new@example.com"]),
            to: id, fields: [.emails]
        )
        let values = result.emailAddresses.map(\.value)
        #expect(values.contains("Adam@AdamWulf.me"))      // existing kept
        #expect(values.contains("new@example.com"))        // new added
        #expect(values.filter { $0.lowercased() == "adam@adamwulf.me" }.count == 1) // no dup
    }

    @Test func websitesMerge_schemeInsensitive_preservesGuessWhoURL() async throws {
        let identityURL = SidecarKey.guessWhoContactURLPrefix + "11111111-1111-1111-8111-111111111111"
        let existing = Contact(localID: "T", urlAddresses: [
            LabeledValue(label: "home", value: "adamwulf.me"),
            LabeledValue(label: "GuessWho", value: identityURL),
        ])
        let (repo, id, _) = await setup(existing)
        let result = try await repo.applyLinkedIn(
            profile: profile(websites: ["https://adamwulf.me", "https://museapp.com"]),
            to: id, fields: [.websites]
        )
        let values = result.urlAddresses.map(\.value)
        // The guesswho:// identity URL must survive.
        #expect(values.contains(identityURL))
        // https://adamwulf.me is the same as the bare one — NOT added again.
        #expect(values.filter { LinkedInURL.isLinkedIn($0) == false && $0.lowercased().contains("adamwulf.me") }.count == 1)
        // The genuinely new site is added.
        #expect(values.contains("https://museapp.com"))
    }

    @Test func linkedInURL_addedToSocialProfiles_whenMissing() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T"))
        let result = try await repo.applyLinkedIn(
            profile: profile(profileUrl: "https://www.linkedin.com/in/adamwulf"),
            to: id, fields: [.linkedInURL]
        )
        #expect(result.socialProfiles.contains {
            LinkedInURL.isLinkedIn($0.value.urlString) &&
            LinkedInURL.sameProfile($0.value.urlString, "https://www.linkedin.com/in/adamwulf")
        })
    }

    @Test func aboutAndLocation_storedAsPrefixedNotes() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(location: "Tomball, Texas", about: "My work centers on…"),
            to: id, fields: [.about, .location]
        )
        // addNote mints a guessWhoID, so read notes back via the now-reconciled
        // ContactID (the original `id` is pre-mint / stale for note reads).
        let reconciledID = repo.contact(localID: "T")!.contactID
        let bodies = repo.notes(for: reconciledID).map(\.body)
        #expect(bodies.contains { $0 == "LinkedIn About: My work centers on…" })
        #expect(bodies.contains { $0 == "LinkedIn Location: Tomball, Texas" })
    }

    @Test func emptyIncomingValues_areIgnored() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada", jobTitle: "Keep"))
        let result = try await repo.applyLinkedIn(
            profile: profile(title: "   "), // whitespace only
            to: id, fields: [.jobTitle]
        )
        #expect(result.jobTitle == "Keep")
    }
}
