import Testing
import Foundation
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Stage 1.5 — the repository's private point-lookup indexes
/// (`contactsByEffectiveID`, `contactsByLocalID`, `contactsByEmail`) must stay
/// coherent with the `contacts` array through EVERY mutation path, since all
/// mutations funnel through the single `setContacts(_:)` rebuild. These tests
/// drive each public mutation entry point and assert the O(1) reads agree with
/// a manual O(n) scan over the same array (the parity invariant), plus the
/// reconciliation re-key subtlety.
@Suite("ContactsRepository O(1) indexes")
struct ContactsRepositoryIndexTests {

    /// A contact carrying a valid GuessWho URL, so `ContactID.guessWhoID` is
    /// non-nil and the effective identity is the bare UUID, not the localID.
    private func reconciledContact(localID: String, uuid: String, givenName: String = "Reconciled") -> Contact {
        Contact(
            localID: localID,
            givenName: givenName,
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)")]
        )
    }

    // MARK: - Full reload

    @Test @MainActor
    func reloadIndexesResolveEveryContactByIDAndLocalID() async {
        let a = Contact(localID: "a", givenName: "Ada", familyName: "Lovelace")
        let b = reconciledContact(localID: "b", uuid: "11111111-1111-1111-1111-111111111111", givenName: "Babbage")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [a, b]))

        await repository.reload()

        // localID-keyed read (boundary accessor).
        #expect(repository.contact(localID: "a")?.localID == "a")
        #expect(repository.contact(localID: "b")?.localID == "b")
        #expect(repository.contact(localID: "missing") == nil)

        // effectiveID-keyed read: `a` falls back to its localID, `b` keys on UUID.
        #expect(repository.contact(id: ContactID(contact: a))?.localID == "a")
        #expect(repository.contact(id: ContactID(contact: b))?.localID == "b")
    }

    // MARK: - Incremental refresh

    @Test @MainActor
    func refreshContactUpdatesIndexedFields() async {
        let original = Contact(localID: "c", givenName: "Grace", familyName: "Hopper", jobTitle: "Programmer")
        let store = InMemoryContactStore(contacts: [original])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        #expect(repository.contact(localID: "c")?.jobTitle == "Programmer")

        // Mutate the store, then drive the incremental refresh path.
        let updated = Contact(localID: "c", givenName: "Grace", familyName: "Hopper", jobTitle: "Rear Admiral")
        try? await store.save(updated)
        await repository.refreshContact(localID: "c")

        // The index resolves to the NEW value.
        #expect(repository.contact(localID: "c")?.jobTitle == "Rear Admiral")
        #expect(repository.contact(id: ContactID(contact: updated))?.jobTitle == "Rear Admiral")
        // And the effectiveID index agrees with a manual scan over the array.
        let scan = repository.contacts.first { ContactID(contact: $0).effectiveID == ContactID(contact: updated).effectiveID }
        #expect(repository.contact(id: ContactID(contact: updated))?.localID == scan?.localID)
    }

    @Test @MainActor
    func refreshContactInsertsNewlyAppearedContact() async {
        let store = InMemoryContactStore(contacts: [])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()
        #expect(repository.contact(localID: "new") == nil)

        let fresh = Contact(localID: "new", givenName: "Katherine", familyName: "Johnson")
        try? await store.save(fresh)
        await repository.refreshContact(localID: "new")

        #expect(repository.contact(localID: "new")?.familyName == "Johnson")
        #expect(repository.contact(id: ContactID(contact: fresh))?.localID == "new")
    }

    // MARK: - Removal

    @Test @MainActor
    func removeContactDropsItFromEveryIndex() async {
        let a = Contact(localID: "a", givenName: "Ada", emailAddresses: [LabeledValue(label: "home", value: "ada@x.test")])
        let b = Contact(localID: "b", givenName: "Bert")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [a, b]))
        await repository.reload()

        repository.removeContact(localID: "a")

        #expect(repository.contact(localID: "a") == nil)
        #expect(repository.contact(id: ContactID(contact: a)) == nil)
        #expect(repository.contactIDs(matchingEmail: "ada@x.test").isEmpty)
        // `b` still resolves.
        #expect(repository.contact(localID: "b")?.localID == "b")
    }

    // MARK: - The reconciliation re-key subtlety

    @Test @MainActor
    func reconciliationTransitionRekeysEffectiveID() async {
        // Start with a contact carrying NO GuessWho URL — found under its localID.
        let preReconcile = Contact(localID: "k", givenName: "Pre", familyName: "Reconcile")
        let store = InMemoryContactStore(contacts: [preReconcile])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let localIDEffective = ContactID(contact: preReconcile)
        #expect(localIDEffective.effectiveID == "k")              // falls back to localID
        #expect(repository.contact(id: localIDEffective)?.localID == "k")

        // Now the SAME localID gains a valid GuessWho URL — identity flips to the UUID.
        let uuid = "22222222-2222-2222-2222-222222222222"
        let postReconcile = reconciledContact(localID: "k", uuid: uuid, givenName: "Pre")
        try? await store.save(postReconcile)
        await repository.refreshContact(localID: "k")

        let uuidEffective = ContactID(contact: postReconcile)
        #expect(uuidEffective.effectiveID == uuid)               // now the bare UUID

        // Found under the NEW (guessWhoID-effective) ContactID...
        #expect(repository.contact(id: uuidEffective)?.localID == "k")
        // ...and the OLD (localID-effective) ContactID no longer resolves to it.
        #expect(repository.contact(id: localIDEffective) == nil)
        // The localID boundary accessor still works (localID itself is unchanged).
        #expect(repository.contact(localID: "k")?.localID == "k")
    }

    // MARK: - Email matching semantics

    @Test @MainActor
    func matchingEmailReturnsAllMatchesCaseInsensitiveAndEmptyForBlank() async {
        let a = Contact(localID: "a", givenName: "Ada", emailAddresses: [LabeledValue(label: "home", value: "Shared@Example.com")])
        let b = Contact(localID: "b", givenName: "Bert", emailAddresses: [
            LabeledValue(label: "work", value: "shared@example.com"),
            LabeledValue(label: "alt", value: "bert@other.test")
        ])
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [a, b]))
        await repository.reload()

        // ALL matches, case-insensitive, trimmed needle.
        let shared = repository.contactIDs(matchingEmail: "  SHARED@example.com ")
        #expect(Set(shared.map(\.localID)) == Set(["a", "b"]))

        let only = repository.contactIDs(matchingEmail: "bert@other.test")
        #expect(only.map(\.localID) == ["b"])

        // Empty / whitespace query → [].
        #expect(repository.contactIDs(matchingEmail: "").isEmpty)
        #expect(repository.contactIDs(matchingEmail: "   ").isEmpty)
        // No match → [].
        #expect(repository.contactIDs(matchingEmail: "nobody@nowhere.test").isEmpty)
    }

    @Test @MainActor
    func matchingEmailDeduplicatesContactWithSameAddressUnderTwoLabels() async {
        let dup = Contact(localID: "d", givenName: "Dup", emailAddresses: [
            LabeledValue(label: "home", value: "dup@x.test"),
            LabeledValue(label: "work", value: "DUP@x.test")    // same address, different case/label
        ])
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [dup]))
        await repository.reload()

        // The contact appears ONCE, not once per label.
        #expect(repository.contactIDs(matchingEmail: "dup@x.test").map(\.localID) == ["d"])
    }

    // MARK: - Parity: index reads equal a manual O(n) scan

    @Test @MainActor
    func indexReadsMatchManualScanOverSameCache() async {
        let contacts = [
            Contact(localID: "1", givenName: "One"),
            reconciledContact(localID: "2", uuid: "33333333-3333-3333-3333-333333333333", givenName: "Two"),
            Contact(localID: "3", givenName: "Three", emailAddresses: [LabeledValue(label: "home", value: "three@x.test")]),
            reconciledContact(localID: "4", uuid: "44444444-4444-4444-4444-444444444444", givenName: "Four")
        ]
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: contacts))
        await repository.reload()

        // For every cached contact, the index read must equal a manual scan.
        for cached in repository.contacts {
            let cid = ContactID(contact: cached)

            let indexByID = repository.contact(id: cid)
            let scanByID = repository.contacts.first { ContactID(contact: $0).effectiveID == cid.effectiveID }
            #expect(indexByID?.localID == scanByID?.localID)

            let indexByLocal = repository.contact(localID: cached.localID)
            let scanByLocal = repository.contacts.first { $0.localID == cached.localID }
            #expect(indexByLocal?.localID == scanByLocal?.localID)
        }
    }

    // MARK: - Delta-apply path (change-watcher notification)

    @Test @MainActor
    func deltaApplyKeepsIndexesCoherent() async {
        // Seed two contacts. We'll delete one and update another through the
        // change-watcher notification path (`apply(_:)`, the `:236` delta site)
        // and assert the indexes stay coherent.
        let keep = Contact(localID: "keep", givenName: "Keep")
        let drop = Contact(localID: "drop", givenName: "Drop")
        let store = InMemoryContactStore(contacts: [keep, drop])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()
        #expect(repository.contact(localID: "drop")?.localID == "drop")

        // Mutate the backing store so the `.updated` re-read picks up the change.
        let keepUpdated = Contact(localID: "keep", givenName: "Keep", jobTitle: "Updated")
        try? await store.save(keepUpdated)

        // Post the delta notification (delete "drop", update "keep") and await
        // the repository's post-apply `contactsRepositoryDidReload`.
        let changeSet = ContactChangeSet(
            changes: [.deleted(localID: "drop"), .updated(localID: "keep")],
            newToken: Data(),
            requiresFullReload: false
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let center = NotificationCenter.default
            var token: NSObjectProtocol?
            token = center.addObserver(forName: .contactsRepositoryDidReload, object: repository, queue: nil) { _ in
                if let token { center.removeObserver(token) }
                continuation.resume()
            }
            center.post(
                name: .guessWhoContactsDidChange,
                object: nil,
                userInfo: [GuessWhoContactsDidChangeKey.changeSet: changeSet]
            )
        }

        // Deleted contact is gone from every index; updated contact reflects the change.
        #expect(repository.contact(localID: "drop") == nil)
        #expect(repository.contact(id: ContactID(contact: drop)) == nil)
        #expect(repository.contact(localID: "keep")?.jobTitle == "Updated")

        // Parity over the resulting cache.
        for cached in repository.contacts {
            let cid = ContactID(contact: cached)
            let scan = repository.contacts.first { ContactID(contact: $0).effectiveID == cid.effectiveID }
            #expect(repository.contact(id: cid)?.localID == scan?.localID)
        }
    }
}
