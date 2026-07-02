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
        fullName: String? = nil, headline: String? = nil,
        title: String? = nil, org: String? = nil,
        location: String? = nil, about: String? = nil,
        emails: [String] = [], websites: [String] = [], profileUrl: String? = nil
    ) -> LinkedInProfile {
        LinkedInProfile(
            fullName: fullName, headline: headline, title: title, org: org,
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

    @Test func linkedInURL_addedToSocialProfiles_asUsername_whenMissing() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T"))
        let result = try await repo.applyLinkedIn(
            profile: profile(profileUrl: "https://www.linkedin.com/in/adamwulf"),
            to: id, fields: [.linkedInURL]
        )
        // Stored as the USERNAME (slug), not the full URL — Contacts expects that.
        let linkedIns = result.socialProfiles.filter { $0.value.service.caseInsensitiveCompare("LinkedIn") == .orderedSame }
        #expect(linkedIns.count == 1)
        #expect(linkedIns[0].value.username == "adamwulf")
    }

    @Test func linkedInURL_existingUsernameOnlyProfile_isNotDuplicated() async throws {
        // The contact already has a username-only LinkedIn social profile.
        let existing = Contact(localID: "T", socialProfiles: [
            LabeledSocialProfile(label: "LinkedIn",
                value: SocialProfile(urlString: "", username: "adamwulf", service: "LinkedIn"))
        ])
        let (repo, id, _) = await setup(existing)
        let result = try await repo.applyLinkedIn(
            profile: profile(profileUrl: "https://www.linkedin.com/in/adamwulf"),
            to: id, fields: [.linkedInURL]
        )
        // Exactly one LinkedIn profile (no duplicate); username preserved.
        let linkedIns = result.socialProfiles.filter { $0.value.service.caseInsensitiveCompare("LinkedIn") == .orderedSame }
        #expect(linkedIns.count == 1)
        #expect(linkedIns[0].value.username == "adamwulf")
    }

    @Test func mergedCNContactValues_useDefaultLabel_notLinkedIn() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T"))
        let result = try await repo.applyLinkedIn(
            profile: profile(emails: ["new@example.com"], websites: ["https://museapp.com"]),
            to: id, fields: [.emails, .websites]
        )
        // Added CNContact values must NOT carry a "LinkedIn" label.
        #expect(result.emailAddresses.allSatisfy { $0.label != "LinkedIn" })
        #expect(result.urlAddresses.allSatisfy { $0.label != "LinkedIn" })
    }

    @Test func headline_storedAsNamedSidecarField_singleLineNote() async throws {
        // A free-form headline (no "<Title> at <Org>" shape) — the raw line is
        // the only carrier of the title/bio, so it must land as its own field.
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(headline: "Principal AI Consultant | Driving Sustainable Value Creation for SMEs"),
            to: id, fields: [.headline]
        )
        let rid = repo.contact(localID: "T")!.contactID
        let stored = repo.fields(for: rid).first { $0.field == "LinkedIn Headline" }
        #expect(stored?.type == .note)
        #expect(stored?.value == .string("Principal AI Consultant | Driving Sustainable Value Creation for SMEs"))
    }

    @Test func headline_reimport_updatesInPlace() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(headline: "First headline"), to: id, fields: [.headline]
        )
        let rid = repo.contact(localID: "T")!.contactID
        _ = try await repo.applyLinkedIn(
            profile: profile(headline: "Second headline"), to: rid, fields: [.headline]
        )
        let stored = repo.fields(for: rid).filter { $0.field == "LinkedIn Headline" }
        #expect(stored.count == 1)
        #expect(stored.first?.value == .string("Second headline"))
    }

    @Test func headline_notChosen_notWritten() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(headline: "CTO at Acme", about: "Bio"),
            to: id, fields: [.about] // headline NOT chosen
        )
        let rid = repo.contact(localID: "T")!.contactID
        #expect(repo.fields(for: rid).contains { $0.field == "LinkedIn Headline" } == false)
    }

    @Test func aboutAndLocation_storedAsNamedSidecarFields() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(location: "Tomball, Texas", about: "My work centers on…"),
            to: id, fields: [.about, .location]
        )
        // Stored as named key/value fields (not notes), read via the now-
        // reconciled ContactID (apply minted a guessWhoID).
        let reconciledID = repo.contact(localID: "T")!.contactID
        let byName = Dictionary(uniqueKeysWithValues: repo.fields(for: reconciledID).map { ($0.field, $0) })
        #expect(byName["LinkedIn About"]?.value == .string("My work centers on…"))
        #expect(byName["LinkedIn Location"]?.value == .string("Tomball, Texas"))
    }

    @Test func reimport_updatesFields_doesNotDuplicate() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        // First import.
        _ = try await repo.applyLinkedIn(
            profile: profile(location: "Tomball, Texas", about: "First bio"),
            to: id, fields: [.about, .location]
        )
        let reconciledID = repo.contact(localID: "T")!.contactID
        // Second import with a changed bio (simulating a later LinkedIn save).
        _ = try await repo.applyLinkedIn(
            profile: profile(location: "Austin, Texas", about: "Updated bio"),
            to: reconciledID, fields: [.about, .location]
        )
        let about = repo.fields(for: reconciledID).filter { $0.field == "LinkedIn About" }
        let location = repo.fields(for: reconciledID).filter { $0.field == "LinkedIn Location" }
        // Exactly one of each — updated, not duplicated.
        #expect(about.count == 1)
        #expect(about.first?.value == .string("Updated bio"))
        #expect(location.count == 1)
        #expect(location.first?.value == .string("Austin, Texas"))
    }

    @Test func emptyIncomingValues_areIgnored() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada", jobTitle: "Keep"))
        let result = try await repo.applyLinkedIn(
            profile: profile(title: "   "), // whitespace only
            to: id, fields: [.jobTitle]
        )
        #expect(result.jobTitle == "Keep")
    }

    @Test func editField_updatesValue() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(about: "First"), to: id, fields: [.about]
        )
        let rid = repo.contact(localID: "T")!.contactID
        let fieldID = repo.fields(for: rid).first { $0.field == "LinkedIn About" }!.id
        try await repo.editField(for: rid, id: fieldID, value: "Edited")
        let after = repo.fields(for: rid).first { $0.field == "LinkedIn About" }
        #expect(after?.value == .string("Edited"))
    }

    @Test func about_storedAsMultilineNote_location_asNote() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(location: "Tomball", about: "Line 1\nLine 2"),
            to: id, fields: [.about, .location]
        )
        let rid = repo.contact(localID: "T")!.contactID
        let byName = Dictionary(uniqueKeysWithValues: repo.fields(for: rid).map { ($0.field, $0) })
        #expect(byName["LinkedIn About"]?.type == .multilineNote)
        #expect(byName["LinkedIn Location"]?.type == .note)
        // About is multiline: its internal newline must survive the round-trip.
        #expect(byName["LinkedIn About"]?.value == .string("Line 1\nLine 2"))
    }

    @Test func multiParagraphAbout_preservesNewlines_endToEnd() async throws {
        // A realistic multi-paragraph bio (blank line between paragraphs). The
        // newlines must survive parser -> applyLinkedIn -> the .multilineNote
        // field unchanged. (The parser's textContent->innerText fix is what keeps
        // the newlines on the way in; this asserts nothing downstream drops them.)
        let bio = "First paragraph about my work.\n\nSecond paragraph with more detail.\nAnd a third line."
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(about: bio), to: id, fields: [.about]
        )
        let rid = repo.contact(localID: "T")!.contactID
        let stored = repo.fields(for: rid).first { $0.field == "LinkedIn About" }
        #expect(stored?.type == .multilineNote)
        #expect(stored?.value == .string(bio))
    }

    @Test func upsert_changingType_replacesField() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        // Create as single-line .note.
        _ = try await repo.upsertField(for: id, field: "Bio", value: "v1", type: .note)
        let rid = repo.contact(localID: "T")!.contactID
        // Upsert the same name with a DIFFERENT type — should replace, not error.
        _ = try await repo.upsertField(for: rid, field: "Bio", value: "v2", type: .multilineNote)
        let bio = repo.fields(for: rid).filter { $0.field == "Bio" }
        #expect(bio.count == 1)
        #expect(bio.first?.type == .multilineNote)
        #expect(bio.first?.value == .string("v2"))
    }

    @Test func deleteField_removesIt() async throws {
        let (repo, id, _) = await setup(Contact(localID: "T", givenName: "Ada"))
        _ = try await repo.applyLinkedIn(
            profile: profile(location: "Tomball"), to: id, fields: [.location]
        )
        let rid = repo.contact(localID: "T")!.contactID
        let fieldID = repo.fields(for: rid).first { $0.field == "LinkedIn Location" }!.id
        try await repo.deleteField(for: rid, id: fieldID)
        #expect(repo.fields(for: rid).contains { $0.field == "LinkedIn Location" } == false)
    }
}
