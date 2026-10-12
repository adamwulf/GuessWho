import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// `ContactsRepository.addContactValues(from:for:)`: the package side of
/// dropping a URL onto a contact. An http/https URL becomes a website row, a
/// `mailto:` URL email rows, and a `tel:` URL a phone row, each merged by the
/// LinkedIn import's dedup for that field, with the default label, in ONE
/// save; nothing new means no save and no stamp.
@Suite("ContactsRepository.addContactValues")
@MainActor
struct ContactsRepositoryContactValueTests {
    /// A reconciled identity, so the no-stamp tests can read the timestamp
    /// cells at a known key without a write minting one.
    private static let guessWhoID = "22222222-2222-4222-8222-222222222222"
    private static let identityURL = SidecarKey.guessWhoContactURLPrefix + guessWhoID

    @MainActor
    private struct Fixture {
        let store: InMemoryContactStore
        let sync: GuessWhoSync
        let repo: ContactsRepository
        let id: ContactID
        /// Change-history position after setup: any later Contacts write
        /// shows up in `store.changes(since:)`.
        let token: Data

        func contactsWrites() async throws -> [ContactChange] {
            try await store.changes(since: token).changes
        }

        /// The card's website rows. The Last Modified stamp mints a
        /// `guesswho://` identity URL on an unreconciled contact; the card
        /// never shows that one, so neither does this list.
        func values() throws -> [String] {
            try #require(repo.contact(localID: "T")).userVisibleURLAddresses.map(\.value)
        }

        func emails() throws -> [String] {
            try #require(repo.contact(localID: "T")).emailAddresses.map(\.value)
        }

        func phones() throws -> [String] {
            try #require(repo.contact(localID: "T")).phoneNumbers.map(\.value)
        }
    }

    private func setup(_ person: Contact) async throws -> Fixture {
        let store = InMemoryContactStore(contacts: [person])
        let sync = GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        let id = try #require(repo.contact(localID: person.localID)).contactID
        let token = try await store.changes(since: nil).newToken
        return Fixture(store: store, sync: sync, repo: repo, id: id, token: token)
    }

    private func urls(_ strings: String...) throws -> [URL] {
        try strings.map { try #require(URL(string: $0)) }
    }

    private func reconciledPerson(
        emailAddresses: [LabeledValue] = [],
        phoneNumbers: [LabeledValue] = [],
        urlAddresses: [LabeledValue] = []
    ) -> Contact {
        Contact(
            localID: "T",
            givenName: "Ada",
            phoneNumbers: phoneNumbers,
            emailAddresses: emailAddresses,
            urlAddresses: urlAddresses + [LabeledValue(label: "GuessWho", value: Self.identityURL)]
        )
    }

    // MARK: - Websites

    @Test func addsHTTPAndHTTPS() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("http://example.com/a", "https://example.org/b"), for: f.id
        )

        #expect(added == AddedContactValues(urlAddresses: 2))
        #expect(try f.values().contains("http://example.com/a"))
        #expect(try f.values().contains("https://example.org/b"))
        #expect(try await f.contactsWrites().isEmpty == false)
    }

    @Test(arguments: [
        "message:%3C1234@example.com%3E",
        "file:///Users/ada/Desktop/notes.txt",
        "ftp://example.com/file.txt",
        "sms:+15551234567",
    ])
    func ignoresOtherSchemes(_ string: String) async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(from: urls(string), for: f.id)

        #expect(added == AddedContactValues())
        #expect(try f.values().isEmpty)
        #expect(try f.emails().isEmpty)
        #expect(try f.phones().isEmpty)
        #expect(try await f.contactsWrites().isEmpty)
    }

    /// The existing row and the dropped URL differ only by scheme, a leading
    /// `www.`, case, or a trailing slash, so the drop adds nothing.
    @Test(arguments: [
        ("http://example.com/about", "https://example.com/about"),
        ("http://example.com/about", "http://www.example.com/about"),
        ("http://example.com/about", "HTTP://Example.COM/About"),
        ("http://example.com/about", "http://example.com/about/"),
        ("adamwulf.me", "https://www.adamwulf.me/"),
    ])
    func skipsAnAddressTheContactAlreadyHas(existing: String, dropped: String) async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            urlAddresses: [LabeledValue(label: "home", value: existing)]
        ))

        let added = try await f.repo.addContactValues(from: urls(dropped), for: f.id)

        #expect(added.total == 0)
        #expect(try f.values() == [existing])
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test func skipsADuplicateWithinTheInput() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("https://example.com", "http://www.example.com/", "https://EXAMPLE.com"),
            for: f.id
        )

        // The first spelling wins; the later ones are the same address.
        #expect(added == AddedContactValues(urlAddresses: 1))
        #expect(try f.values() == ["https://example.com"])
    }

    @Test func keepsInputOrderAfterExistingRows() async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            urlAddresses: [LabeledValue(label: "home", value: "https://first.example")]
        ))

        let added = try await f.repo.addContactValues(
            from: urls("https://c.example", "https://a.example", "https://b.example"),
            for: f.id
        )

        #expect(added == AddedContactValues(urlAddresses: 3))
        #expect(try f.values() == [
            "https://first.example", "https://c.example", "https://a.example", "https://b.example",
        ])
    }

    @Test func newRowsGetTheEmptyLabel() async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            phoneNumbers: [LabeledValue(label: "work", value: "555-0100")],
            emailAddresses: [LabeledValue(label: "work", value: "ada@work.example")],
            urlAddresses: [LabeledValue(label: "home", value: "https://home.example")]
        ))

        _ = try await f.repo.addContactValues(
            from: urls("https://new.example", "mailto:ada@new.example", "tel:555-0199"),
            for: f.id
        )

        let contact = try #require(f.repo.contact(localID: "T"))
        #expect(contact.urlAddresses.first { $0.value == "https://new.example" }?.label == "")
        #expect(contact.urlAddresses.first { $0.value == "https://home.example" }?.label == "home")
        #expect(contact.emailAddresses.first { $0.value == "ada@new.example" }?.label == "")
        #expect(contact.emailAddresses.first { $0.value == "ada@work.example" }?.label == "work")
        #expect(contact.phoneNumbers.first { $0.value == "555-0199" }?.label == "")
        #expect(contact.phoneNumbers.first { $0.value == "555-0100" }?.label == "work")
    }

    @Test func keepsTheGuessWhoIdentityURL() async throws {
        let f = try await setup(reconciledPerson())

        let added = try await f.repo.addContactValues(from: urls("https://example.com"), for: f.id)

        #expect(added == AddedContactValues(urlAddresses: 1))
        let all = try #require(f.repo.contact(localID: "T")).urlAddresses.map(\.value)
        #expect(all == [Self.identityURL, "https://example.com"])
        #expect(f.repo.contact(localID: "T")?.contactID == f.id)
    }

    // MARK: - mailto:

    @Test func mailtoAddsOneEmail() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(from: urls("mailto:ada@example.com"), for: f.id)

        #expect(added == AddedContactValues(emailAddresses: 1))
        #expect(try f.emails() == ["ada@example.com"])
        #expect(try f.values().isEmpty)
    }

    @Test func mailtoWithSeveralAddressesAddsEach() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("mailto:ada@example.com,bob@example.org"), for: f.id
        )

        #expect(added == AddedContactValues(emailAddresses: 2))
        #expect(try f.emails() == ["ada@example.com", "bob@example.org"])
    }

    /// The query (`subject=`, `cc=`, `body=`, …) is not an address, even one
    /// that names an address.
    @Test func mailtoIgnoresTheQuery() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("mailto:ada@example.com?subject=Hello%20there&cc=bob@example.org&body=Hi"),
            for: f.id
        )

        #expect(added == AddedContactValues(emailAddresses: 1))
        #expect(try f.emails() == ["ada@example.com"])
    }

    @Test func mailtoIsPercentDecoded() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("mailto:ada%2Blists@example.com,%20bob%40example.org"), for: f.id
        )

        #expect(added == AddedContactValues(emailAddresses: 2))
        #expect(try f.emails() == ["ada+lists@example.com", "bob@example.org"])
    }

    @Test func mailtoSkipsAnAddressTheContactHasInAnotherCase() async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            emailAddresses: [LabeledValue(label: "home", value: "Ada@Example.com")]
        ))

        let added = try await f.repo.addContactValues(
            from: urls("mailto:ada@example.COM", "mailto:ADA@EXAMPLE.COM"), for: f.id
        )

        #expect(added.total == 0)
        #expect(try f.emails() == ["Ada@Example.com"])
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test func mailtoSkipsADuplicateWithinTheInput() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("mailto:ada@example.com,ADA@example.com", "mailto:Ada@Example.com"), for: f.id
        )

        // The first spelling wins.
        #expect(added == AddedContactValues(emailAddresses: 1))
        #expect(try f.emails() == ["ada@example.com"])
    }

    /// An empty entry, one with no `@`, and a bare `mailto:` give no address.
    @Test func mailtoSkipsEmptyAndInvalidEntries() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("mailto:", "mailto:?subject=Hi", "mailto:not-an-address,,%20,ada@example.com"),
            for: f.id
        )

        #expect(added == AddedContactValues(emailAddresses: 1))
        #expect(try f.emails() == ["ada@example.com"])
    }

    // MARK: - tel:

    /// The number is kept as written: Contacts formats it.
    @Test func telAddsTheNumberAsWritten() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("tel:+1-555-010-0199", "tel:(555)%20010-0123"), for: f.id
        )

        #expect(added == AddedContactValues(phoneNumbers: 2))
        #expect(try f.phones() == ["+1-555-010-0199", "(555) 010-0123"])
    }

    @Test func telDropsTheParameters() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("tel:+1-555-010-0199;ext=42;phone-context=example.com"), for: f.id
        )

        #expect(added == AddedContactValues(phoneNumbers: 1))
        #expect(try f.phones() == ["+1-555-010-0199"])
    }

    /// Phone numbers compare by their digits only.
    @Test func telSkipsANumberTheContactHasWithOtherSeparators() async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            phoneNumbers: [LabeledValue(label: "mobile", value: "(555) 010-0199")]
        ))

        let added = try await f.repo.addContactValues(
            from: urls("tel:555.010.0199", "tel:555-010-0199;ext=7"), for: f.id
        )

        #expect(added.total == 0)
        #expect(try f.phones() == ["(555) 010-0199"])
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test func telSkipsANumberWithNoDigits() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addContactValues(
            from: urls("tel:", "tel:;ext=12", "tel:%2B-()"), for: f.id
        )

        #expect(added.total == 0)
        #expect(try f.phones().isEmpty)
        #expect(try await f.contactsWrites().isEmpty)
    }

    // MARK: - One drop, one save

    @Test func mixedDropAddsEveryKindInOneSave() async throws {
        let f = try await setup(reconciledPerson(
            emailAddresses: [LabeledValue(label: "home", value: "ada@example.com")]
        ))

        let added = try await f.repo.addContactValues(
            from: urls(
                "mailto:ADA@example.com,bob@example.org?subject=Hi",
                "https://example.com/about",
                "message:%3C1234@example.com%3E",
                "tel:+1-555-010-0199;ext=3",
                "http://www.example.com/about/",
                "tel:15550100199",
                "ftp://example.com/file.txt"
            ),
            for: f.id
        )

        #expect(added == AddedContactValues(emailAddresses: 1, phoneNumbers: 1, urlAddresses: 1))
        #expect(added.total == 3)
        #expect(try f.emails() == ["ada@example.com", "bob@example.org"])
        #expect(try f.phones() == ["+1-555-010-0199"])
        #expect(try f.values() == ["https://example.com/about"])
        // The card is saved once for all three fields; the stamp on a
        // reconciled contact is a sidecar write, not a Contacts write.
        #expect(try await f.contactsWrites().count == 1)
    }

    // MARK: - Save, stamp, and errors

    @Test func nothingNew_noSaveAndNoStamp() async throws {
        let f = try await setup(reconciledPerson(
            emailAddresses: [LabeledValue(label: "home", value: "ada@example.com")],
            phoneNumbers: [LabeledValue(label: "mobile", value: "555-010-0199")],
            urlAddresses: [LabeledValue(label: "home", value: "https://example.com")]
        ))

        let added = try await f.repo.addContactValues(
            from: urls("http://www.example.com/", "mailto:ADA@example.com", "tel:5550100199"), for: f.id
        )

        #expect(added.total == 0)
        #expect(try await f.contactsWrites().isEmpty)
        let key = SidecarKey(kind: .contact, id: Self.guessWhoID)
        #expect(try f.sync.contactTimestamps(at: key).lastModified == nil)
    }

    @Test func emptyInput_returnsZeroWithoutAWrite() async throws {
        let f = try await setup(reconciledPerson())

        let added = try await f.repo.addContactValues(from: [], for: f.id)

        #expect(added == AddedContactValues())
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test(arguments: ["https://example.com", "mailto:ada@example.com", "tel:555-010-0199"])
    func somethingNew_stampsLastModified(_ dropped: String) async throws {
        let f = try await setup(reconciledPerson())
        let before = Date()

        _ = try await f.repo.addContactValues(from: urls(dropped), for: f.id)

        let after = Date()
        let key = SidecarKey(kind: .contact, id: Self.guessWhoID)
        let modified = try #require(try f.sync.contactTimestamps(at: key).lastModified)
        #expect(modified.timeIntervalSince(before) >= -0.01)
        #expect(modified.timeIntervalSince(after) <= 0.01)
    }

    /// The stamp is a sidecar write, so it mints the identity of a contact
    /// that had none, like the LinkedIn import's stamp.
    @Test func somethingNew_onAnUnreconciledContact_mintsAndStamps() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        _ = try await f.repo.addContactValues(from: urls("https://example.com"), for: f.id)

        let contact = try #require(f.repo.contact(localID: "T"))
        #expect(contact.urlAddresses.contains { $0.value == "https://example.com" })
        let guessWhoID = try #require(ContactID(contact: contact).guessWhoID)
        let key = SidecarKey(kind: .contact, id: guessWhoID)
        #expect(try f.sync.contactTimestamps(at: key).lastModified != nil)
    }

    @Test func contactGoneFromContacts_throwsContactNotFound() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))
        // Deleted outside the app: the cache still resolves the id, but the
        // fresh read finds no record.
        try await f.store.delete(localID: "T")
        let dropped = try urls("mailto:ada@example.com")

        let error = await #expect(throws: ContactStoreError.self) {
            try await f.repo.addContactValues(from: dropped, for: f.id)
        }

        guard case .contactNotFound = error else {
            Issue.record("expected contactNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test func unknownContact_throwsContactNotFound() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))
        let unknown = ContactID(contact: Contact(localID: "missing"))
        let dropped = try urls("tel:555-010-0199")

        let error = await #expect(throws: ContactStoreError.self) {
            try await f.repo.addContactValues(from: dropped, for: unknown)
        }

        guard case .contactNotFound = error else {
            Issue.record("expected contactNotFound, got \(String(describing: error))")
            return
        }
    }

    /// With no value to add there is nothing to look up, so even an unknown
    /// contact returns zero instead of throwing.
    @Test func unknownContact_withNoValue_returnsZero() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))
        let unknown = ContactID(contact: Contact(localID: "missing"))

        let added = try await f.repo.addContactValues(
            from: urls("message:%3C1234@example.com%3E", "mailto:no-address", "tel:;ext=1"), for: unknown
        )

        #expect(added == AddedContactValues())
    }
}
