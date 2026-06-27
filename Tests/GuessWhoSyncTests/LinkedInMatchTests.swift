import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("ContactsRepository LinkedIn matching")
@MainActor
struct LinkedInMatchTests {
    private func makeSync(_ contacts: InMemoryContactStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
    }

    private func repo(_ people: [Contact]) async -> ContactsRepository {
        let store = InMemoryContactStore(contacts: people)
        let r = ContactsRepository(contacts: store, sync: makeSync(store))
        await r.reload()
        return r
    }

    private func person(
        id: String = UUID().uuidString,
        given: String = "",
        family: String = "",
        emails: [String] = [],
        urls: [String] = [],
        linkedInSocial: String? = nil,
        linkedInUsername: String = ""
    ) -> Contact {
        var social: [LabeledSocialProfile] = []
        if linkedInSocial != nil || !linkedInUsername.isEmpty {
            social = [LabeledSocialProfile(
                label: "LinkedIn",
                value: SocialProfile(
                    urlString: linkedInSocial ?? "",
                    username: linkedInUsername,
                    service: "LinkedIn"
                )
            )]
        }
        return Contact(
            localID: id,
            givenName: given,
            familyName: family,
            emailAddresses: emails.map { LabeledValue(label: "work", value: $0) },
            urlAddresses: urls.map { LabeledValue(label: "work", value: $0) },
            socialProfiles: social
        )
    }

    private func profile(
        fullName: String? = nil,
        profileUrl: String? = nil,
        sourceUrl: String? = nil,
        emails: [String] = []
    ) -> LinkedInProfile {
        LinkedInProfile(
            sourceUrl: sourceUrl,
            fullName: fullName,
            contactInfo: LinkedInProfile.ContactInfo(profileUrl: profileUrl, emails: emails)
        )
    }

    // MARK: URL matching

    @Test func urlMatch_viaSocialProfileURL_acrossFormats() async {
        let target = person(id: "T", given: "Adam", family: "Wulf",
                            linkedInSocial: "https://www.linkedin.com/in/adamwulf/")
        let r = await repo([target, person(id: "X", given: "Other")])
        let hits = r.matchLinkedIn(profile: profile(
            profileUrl: "https://m.linkedin.com/in/adamwulf?trk=foo"
        ))
        #expect(hits.count == 1)
        #expect(r.contact(id: hits[0])?.givenName == "Adam")
    }

    @Test func urlMatch_viaUsernameOnly() async {
        let target = person(id: "T", given: "Adam", linkedInUsername: "adamwulf")
        let r = await repo([target])
        let hits = r.matchLinkedIn(profile: profile(
            profileUrl: "https://www.linkedin.com/in/adamwulf"
        ))
        #expect(hits.count == 1)
    }

    @Test func urlMatch_viaUrlAddress() async {
        let target = person(id: "T", given: "Adam",
                            urls: ["https://linkedin.com/in/adamwulf/"])
        let r = await repo([target])
        let hits = r.matchLinkedIn(profile: profile(
            sourceUrl: "https://www.linkedin.com/in/adamwulf/"
        ))
        #expect(hits.count == 1)
    }

    @Test func urlMatch_differentSlug_doesNotMatch() async {
        let target = person(id: "T", linkedInSocial: "https://www.linkedin.com/in/someoneelse")
        let r = await repo([target])
        let hits = r.matchLinkedIn(profile: profile(profileUrl: "https://www.linkedin.com/in/adamwulf"))
        #expect(hits.isEmpty)
    }

    // MARK: tier priority

    @Test func urlBeatsEmailBeatsName() async {
        // Three different contacts, each matchable by a different tier. The URL
        // match must win.
        let byURL = person(id: "URL", given: "ByURL", linkedInUsername: "adamwulf")
        let byEmail = person(id: "EMAIL", given: "ByEmail", emails: ["adam@adamwulf.me"])
        let byName = person(id: "NAME", given: "Adam", family: "Wulf")
        let r = await repo([byEmail, byName, byURL])

        let hits = r.matchLinkedIn(profile: profile(
            fullName: "Adam Wulf",
            profileUrl: "https://www.linkedin.com/in/adamwulf",
            emails: ["adam@adamwulf.me"]
        ))
        #expect(hits.count == 1)
        #expect(r.contact(id: hits[0])?.givenName == "ByURL")
    }

    @Test func emailBeatsName_whenNoURL() async {
        let byEmail = person(id: "EMAIL", given: "ByEmail", emails: ["adam@adamwulf.me"])
        let byName = person(id: "NAME", given: "Adam", family: "Wulf")
        let r = await repo([byName, byEmail])

        let hits = r.matchLinkedIn(profile: profile(
            fullName: "Adam Wulf",
            emails: ["adam@adamwulf.me"]
        ))
        #expect(hits.count == 1)
        #expect(r.contact(id: hits[0])?.givenName == "ByEmail")
    }

    @Test func nameMatch_lastResort() async {
        let byName = person(id: "NAME", given: "Adam", family: "Wulf")
        let r = await repo([byName])
        let hits = r.matchLinkedIn(profile: profile(fullName: "Adam Wulf"))
        #expect(hits.count == 1)
    }

    @Test func noMatch_returnsEmpty() async {
        let r = await repo([person(id: "X", given: "Nobody")])
        let hits = r.matchLinkedIn(profile: profile(
            fullName: "Adam Wulf",
            profileUrl: "https://www.linkedin.com/in/adamwulf",
            emails: ["adam@adamwulf.me"]
        ))
        #expect(hits.isEmpty)
    }
}
