import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("InMemoryContactStore")
struct InMemoryContactStoreTests {
    private func sampleContact(localID: String = "local-1") -> Contact {
        Contact(
            localID: localID,
            givenName: "Ada",
            familyName: "Lovelace",
            organizationName: "Analytical Engines Ltd.",
            phoneNumbers: [LabeledValue(label: "mobile", value: "+15555550101")],
            emailAddresses: [LabeledValue(label: "home", value: "ada@example.com")],
            postalAddresses: [
                LabeledPostalAddress(
                    label: "home",
                    value: PostalAddress(street: "1 Babbage Way", city: "London", country: "United Kingdom")
                )
            ],
            urlAddresses: [LabeledValue(label: "home", value: "https://example.com")],
            birthday: DateComponents(year: 1815, month: 12, day: 10)
        )
    }

    @Test
    func createAndFetchByLocalID() throws {
        let store = InMemoryContactStore()
        let contact = sampleContact()
        try store.save(contact)

        let fetched = try store.fetch(localID: "local-1")
        #expect(fetched == contact)
    }

    @Test
    func fetchMissingReturnsNil() throws {
        let store = InMemoryContactStore()
        #expect(try store.fetch(localID: "nope") == nil)
    }

    @Test
    func saveUpsertsByLocalID() throws {
        let store = InMemoryContactStore(contacts: [sampleContact()])

        var updated = sampleContact()
        updated.givenName = "Augusta"
        updated.phoneNumbers = [LabeledValue(label: "work", value: "+15555550199")]
        try store.save(updated)

        let all = try store.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.givenName == "Augusta")
        #expect(all.first?.phoneNumbers.first?.value == "+15555550199")
    }

    @Test
    func saveFetchRoundtripIsIdentity() throws {
        let store = InMemoryContactStore()
        let contact = sampleContact()
        try store.save(contact)
        let fetched = try #require(try store.fetch(localID: contact.localID))
        #expect(fetched == contact)
        #expect(fetched.hashValue == contact.hashValue)
    }

    @Test
    func addingURLPreservesGuessWhoURL() throws {
        let store = InMemoryContactStore()
        let guessWho = LabeledValue(label: "GuessWho", value: "guesswho://contact/550E8400-E29B-41D4-A716-446655440000")
        var contact = sampleContact()
        contact.urlAddresses = [guessWho]
        try store.save(contact)

        var withExtraURL = try #require(try store.fetch(localID: contact.localID))
        withExtraURL.urlAddresses.append(LabeledValue(label: "work", value: "https://work.example.com"))
        try store.save(withExtraURL)

        let fetched = try #require(try store.fetch(localID: contact.localID))
        #expect(fetched.urlAddresses.contains(guessWho))
        #expect(fetched.urlAddresses.count == 2)
    }

    @Test
    func removingNonGuessWhoURLPreservesGuessWhoURL() throws {
        let store = InMemoryContactStore()
        let guessWho = LabeledValue(label: "GuessWho", value: "guesswho://contact/550E8400-E29B-41D4-A716-446655440000")
        let other = LabeledValue(label: "home", value: "https://example.com")
        var contact = sampleContact()
        contact.urlAddresses = [other, guessWho]
        try store.save(contact)

        var updated = try #require(try store.fetch(localID: contact.localID))
        updated.urlAddresses.removeAll { $0 == other }
        try store.save(updated)

        let fetched = try #require(try store.fetch(localID: contact.localID))
        #expect(fetched.urlAddresses == [guessWho])
    }

    @Test
    func postalAddressStructuredComponentsRoundtrip() throws {
        let store = InMemoryContactStore()
        let postal = PostalAddress(
            street: "1 Infinite Loop",
            subLocality: "Mariani",
            city: "Cupertino",
            subAdministrativeArea: "Santa Clara",
            state: "CA",
            postalCode: "95014",
            country: "United States",
            isoCountryCode: "US"
        )
        var contact = sampleContact()
        contact.postalAddresses = [LabeledPostalAddress(label: "work", value: postal)]
        try store.save(contact)

        let fetched = try #require(try store.fetch(localID: contact.localID))
        #expect(fetched.postalAddresses == [LabeledPostalAddress(label: "work", value: postal)])
    }

    @Test
    func fetchAllReturnsEveryContact() throws {
        let a = sampleContact(localID: "a")
        let b = sampleContact(localID: "b")
        let store = InMemoryContactStore(contacts: [a, b])
        let all = try store.fetchAll()
        #expect(Set(all.map(\.localID)) == ["a", "b"])
    }
}
