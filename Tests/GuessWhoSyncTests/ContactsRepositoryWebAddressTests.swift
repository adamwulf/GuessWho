import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// `ContactsRepository.addWebAddresses(_:for:)`: the package side of dropping
/// a web link onto a contact. Only http/https URLs are merged into the
/// Contacts record's website rows, by the LinkedIn import's scheme-insensitive
/// dedup, with the default label; nothing new means no save and no stamp.
@Suite("ContactsRepository.addWebAddresses")
@MainActor
struct ContactsRepositoryWebAddressTests {
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

    private func reconciledPerson(urlAddresses: [LabeledValue] = []) -> Contact {
        Contact(
            localID: "T",
            givenName: "Ada",
            urlAddresses: urlAddresses + [LabeledValue(label: "GuessWho", value: Self.identityURL)]
        )
    }

    @Test func addsHTTPAndHTTPS() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addWebAddresses(
            urls("http://example.com/a", "https://example.org/b"), for: f.id
        )

        #expect(added == 2)
        #expect(try f.values().contains("http://example.com/a"))
        #expect(try f.values().contains("https://example.org/b"))
        #expect(try await f.contactsWrites().isEmpty == false)
    }

    @Test(arguments: [
        "mailto:ada@example.com",
        "message:%3C1234@example.com%3E",
        "file:///Users/ada/Desktop/notes.txt",
        "ftp://example.com/file.txt",
    ])
    func ignoresOtherSchemes(_ string: String) async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addWebAddresses(urls(string), for: f.id)

        #expect(added == 0)
        #expect(try f.values().isEmpty)
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test func addsOnlyTheWebAddressesOfAMixedInput() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addWebAddresses(
            urls("mailto:ada@example.com", "https://example.com", "file:///tmp/x"),
            for: f.id
        )

        #expect(added == 1)
        #expect(try f.values() == ["https://example.com"])
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

        let added = try await f.repo.addWebAddresses(urls(dropped), for: f.id)

        #expect(added == 0)
        #expect(try f.values() == [existing])
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test func skipsADuplicateWithinTheInput() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))

        let added = try await f.repo.addWebAddresses(
            urls("https://example.com", "http://www.example.com/", "https://EXAMPLE.com"),
            for: f.id
        )

        // The first spelling wins; the later ones are the same address.
        #expect(added == 1)
        #expect(try f.values() == ["https://example.com"])
    }

    @Test func keepsInputOrderAfterExistingRows() async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            urlAddresses: [LabeledValue(label: "home", value: "https://first.example")]
        ))

        let added = try await f.repo.addWebAddresses(
            urls("https://c.example", "https://a.example", "https://b.example"),
            for: f.id
        )

        #expect(added == 3)
        #expect(try f.values() == [
            "https://first.example", "https://c.example", "https://a.example", "https://b.example",
        ])
    }

    @Test func newRowsGetTheEmptyLabel() async throws {
        let f = try await setup(Contact(
            localID: "T", givenName: "Ada",
            urlAddresses: [LabeledValue(label: "home", value: "https://home.example")]
        ))

        _ = try await f.repo.addWebAddresses(urls("https://new.example"), for: f.id)

        let rows = try #require(f.repo.contact(localID: "T")).urlAddresses
        #expect(rows.first { $0.value == "https://new.example" }?.label == "")
        #expect(rows.first { $0.value == "https://home.example" }?.label == "home")
    }

    @Test func keepsTheGuessWhoIdentityURL() async throws {
        let f = try await setup(reconciledPerson())

        let added = try await f.repo.addWebAddresses(urls("https://example.com"), for: f.id)

        #expect(added == 1)
        let all = try #require(f.repo.contact(localID: "T")).urlAddresses.map(\.value)
        #expect(all == [Self.identityURL, "https://example.com"])
        #expect(f.repo.contact(localID: "T")?.contactID == f.id)
    }

    @Test func nothingNew_noSaveAndNoStamp() async throws {
        let f = try await setup(reconciledPerson(urlAddresses: [
            LabeledValue(label: "home", value: "https://example.com"),
        ]))

        let added = try await f.repo.addWebAddresses(
            urls("http://www.example.com/", "mailto:ada@example.com"), for: f.id
        )

        #expect(added == 0)
        #expect(try await f.contactsWrites().isEmpty)
        let key = SidecarKey(kind: .contact, id: Self.guessWhoID)
        #expect(try f.sync.contactTimestamps(at: key).lastModified == nil)
    }

    @Test func emptyInput_returnsZeroWithoutAWrite() async throws {
        let f = try await setup(reconciledPerson())

        let added = try await f.repo.addWebAddresses([], for: f.id)

        #expect(added == 0)
        #expect(try await f.contactsWrites().isEmpty)
    }

    @Test func somethingNew_stampsLastModified() async throws {
        let f = try await setup(reconciledPerson())
        let before = Date()

        _ = try await f.repo.addWebAddresses(urls("https://example.com"), for: f.id)

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

        _ = try await f.repo.addWebAddresses(urls("https://example.com"), for: f.id)

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
        let dropped = try urls("https://example.com")

        let error = await #expect(throws: ContactStoreError.self) {
            try await f.repo.addWebAddresses(dropped, for: f.id)
        }

        guard case .contactNotFound = error else {
            Issue.record("expected contactNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test func unknownContact_throwsContactNotFound() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))
        let unknown = ContactID(contact: Contact(localID: "missing"))
        let dropped = try urls("https://example.com")

        let error = await #expect(throws: ContactStoreError.self) {
            try await f.repo.addWebAddresses(dropped, for: unknown)
        }

        guard case .contactNotFound = error else {
            Issue.record("expected contactNotFound, got \(String(describing: error))")
            return
        }
    }

    /// With no web address to add there is nothing to look up, so even an
    /// unknown contact returns 0 instead of throwing.
    @Test func unknownContact_withNoWebAddress_returnsZero() async throws {
        let f = try await setup(Contact(localID: "T", givenName: "Ada"))
        let unknown = ContactID(contact: Contact(localID: "missing"))

        let added = try await f.repo.addWebAddresses(urls("mailto:ada@example.com"), for: unknown)

        #expect(added == 0)
    }
}
