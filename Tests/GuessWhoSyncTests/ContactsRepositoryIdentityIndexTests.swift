import Testing
import Foundation
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Stage 6b2 — the repository's IDENTITY lookup is now ONE `Contact` cache
/// (`contactsByLocalID`) plus a `guessWhoIDToLocalID` string→string POINTER
/// index; the fused `contactsByEffectiveID` is gone. These tests pin the
/// reconcile-stability of `contact(id:)` (guessWhoID-first, localID-fallback),
/// the clean pointer hop of `contact(guessWhoID:)` (no confirm-guard, pure
/// guessWhoID keyspace), the single-source-of-truth invariant (one `Contact`
/// struct; the guessWhoID path only chases a pointer), the reconcile-on-WRITE
/// funnel poke that updates BOTH maps, and the transient duplicate-guessWhoID
/// window. They drive ONLY the public surface, so they also document that no
/// public signature changed.
@Suite("ContactsRepository identity index (6b2)")
struct ContactsRepositoryIdentityIndexTests {

    private func reconciledContact(localID: String, uuid: String, givenName: String = "Reconciled") -> Contact {
        Contact(
            localID: localID,
            givenName: givenName,
            urlAddresses: [LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + uuid)]
        )
    }

    private func makeSync(contacts: InMemoryContactStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
    }

    // MARK: - contact(id:) is reconcile-stable for a captured pre-reconcile token

    /// A view captures a `ContactID` at navigation (guessWhoID still nil). The
    /// contact then reconciles and the funnel re-keys it (new guessWhoID pointer,
    /// same localID slot). The SAME captured token must still resolve — via the
    /// LOAD-BEARING localID branch (its `guessWhoID` is still nil, so resolution
    /// MUST go by `id.localID`). This is the test that pins the `resolvedLocalID`
    /// removal: the localID needed is ALREADY inside the captured `ContactID`.
    @Test @MainActor
    func contactByID_resolvesCapturedTokenBeforeAndAfterReconcileRekey() async {
        let preReconcile = Contact(localID: "k", givenName: "Pre", familyName: "Reconcile")
        let store = InMemoryContactStore(contacts: [preReconcile])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        // The token a view would capture at navigation — guessWhoID still nil.
        let capturedID = ContactID(contact: preReconcile)
        #expect(capturedID.guessWhoID == nil)
        #expect(capturedID.localID == "k")
        // BEFORE reconcile: resolves via the localID branch.
        #expect(repository.contact(id: capturedID)?.localID == "k")

        // The SAME localID gains a GuessWho URL — the funnel re-keys it.
        let uuid = "22222222-2222-4222-8222-222222222222"
        let postReconcile = reconciledContact(localID: "k", uuid: uuid, givenName: "Pre")
        try? await store.save(postReconcile)
        await repository.refreshContact(localID: "k")

        // AFTER reconcile: the captured token (guessWhoID STILL nil — it is an
        // immutable snapshot) keeps resolving by its stable localID. The contact
        // is now the reconciled record (carries the URL).
        #expect(capturedID.guessWhoID == nil)                       // token never mutates
        let resolved = repository.contact(id: capturedID)
        #expect(resolved?.localID == "k")
        #expect(ContactID(contact: resolved!).guessWhoID == uuid)   // it IS the reconciled record
    }

    // MARK: - contact(id:) is guessWhoID-first (no wrong-contact localID fallback)

    /// A RECONCILED token resolves via the guessWhoID branch even if a DIFFERENT
    /// contact happens to occupy the token's `localID` slot. guessWhoID-first
    /// ordering means the canonical UUID match wins and the localID branch is
    /// never reached — no wrong-contact fallback.
    @Test @MainActor
    func contactByID_reconciledToken_resolvesByGuessWhoID_notWrongLocalIDOccupant() async {
        let uuid = "abababab-abab-4bab-8bab-abababababab"
        // The reconciled contact lives at localID "real".
        let reconciled = reconciledContact(localID: "real", uuid: uuid, givenName: "Canonical")
        // A DIFFERENT, unreconciled contact occupies localID "collision".
        let collision = Contact(localID: "collision", givenName: "Other")
        let store = InMemoryContactStore(contacts: [reconciled, collision])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        // Build a reconciled token whose guessWhoID is the canonical UUID but
        // whose localID points at the OTHER contact's slot. (A pathological
        // captured token after a unification re-mints the localID — guessWhoID
        // first must still win.)
        let canonicalContactAtWrongLocalID = reconciledContact(localID: "collision", uuid: uuid)
        let trickyID = ContactID(contact: canonicalContactAtWrongLocalID)
        #expect(trickyID.guessWhoID == uuid)
        #expect(trickyID.localID == "collision")

        // guessWhoID-first wins → resolves to the CANONICAL record at "real",
        // NOT the unrelated contact sitting in the "collision" localID slot.
        let resolved = repository.contact(id: trickyID)
        #expect(resolved?.localID == "real")
        #expect(resolved?.givenName == "Canonical")
    }

    // MARK: - contact(guessWhoID:) is a clean pointer hop (dropped confirm-guard)

    /// `contact(guessWhoID:)` returns nil for a string that is only some
    /// contact's `localID` — the pure-namespace correctness the dropped confirm-
    /// guard's invariant now guarantees structurally (the pointer index is keyed
    /// ONLY on real guessWhoIDs).
    @Test @MainActor
    func contactByGuessWhoID_returnsNilForAStringThatIsOnlyALocalID() async {
        let uuid = "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd"
        let reconciled = reconciledContact(localID: "r", uuid: uuid)
        let bare = Contact(localID: "bare-local-id", givenName: "Bare")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [reconciled, bare]))
        await repository.reload()

        // The reconciled contact resolves by its UUID.
        #expect(repository.contact(guessWhoID: uuid)?.localID == "r")
        // A bare contact's localID is NOT in the guessWhoID keyspace → nil, even
        // though that exact string is a live localID in the cache.
        #expect(repository.contact(guessWhoID: "bare-local-id") == nil)
        #expect(repository.contact(localID: "bare-local-id")?.localID == "bare-local-id")
        // The reconciled contact's OWN localID is likewise not a guessWhoID.
        #expect(repository.contact(guessWhoID: "r") == nil)
    }

    // MARK: - Reconcile-on-WRITE updates BOTH maps with no intervening reload()

    /// After a write (`addNote`) reconciles+mints a previously-unreconciled
    /// contact, `contact(guessWhoID: minted)` AND `contact(id: capturedPreID)`
    /// BOTH resolve to the canonical record WITHOUT any intervening full
    /// `reload()` — the post-mint funnel poke (`refreshCacheIfMinted` →
    /// `refreshContact` → `setContacts`) updated `contactsByLocalID` AND added
    /// the `guessWhoIDToLocalID` pointer.
    @Test @MainActor
    func reconcileOnWrite_updatesBothMaps_noReload() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        // Capture the pre-reconcile token (guessWhoID nil) as a view would.
        let cached = try #require(repository.contact(localID: "TARGET"))
        let capturedID = cached.contactID
        #expect(capturedID.guessWhoID == nil)

        // A write mints — and pokes the cache through the funnel. NO reload() here.
        try await repository.addNote(for: capturedID, body: "first note")

        // The minted UUID is whatever the now-canonical record carries.
        let canonical = try #require(repository.contact(localID: "TARGET"))
        let minted = try #require(repository.guessWhoID(in: canonical))

        // Both identity paths resolve, WITHOUT an intervening reload():
        // - guessWhoID pointer was added →
        #expect(repository.contact(guessWhoID: minted)?.localID == "TARGET")
        // - the captured pre-reconcile token (guessWhoID still nil) still resolves
        //   via the localID branch (the contact struct was updated in place) →
        #expect(repository.contact(id: capturedID)?.localID == "TARGET")
        // - and a freshly-built reconciled token resolves via the guessWhoID branch.
        #expect(repository.contact(id: canonical.contactID)?.localID == "TARGET")
    }

    // MARK: - Single source of truth: one Contact struct; guessWhoID chases a pointer

    /// After an edit through the funnel, the contact fetched via `contact(id:)`
    /// (guessWhoID branch), `contact(guessWhoID:)`, and `contact(localID:)` are
    /// the SAME value — there is one `Contact` struct in `contactsByLocalID` and
    /// the guessWhoID path only chases a pointer into it, so no stale copy can
    /// drift.
    @Test @MainActor
    func singleSourceOfTruth_allPathsReturnSameValueAfterEdit() async {
        let uuid = "11111111-1111-4111-8111-111111111111"
        let original = Contact(
            localID: "c",
            givenName: "Grace",
            jobTitle: "Programmer",
            urlAddresses: [LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + uuid)]
        )
        let store = InMemoryContactStore(contacts: [original])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()
        #expect(repository.contact(localID: "c")?.jobTitle == "Programmer")

        // Edit the underlying record (keeping the same UUID) and refresh.
        let updated = Contact(
            localID: "c",
            givenName: "Grace",
            jobTitle: "Rear Admiral",
            urlAddresses: [LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + uuid)]
        )
        try? await store.save(updated)
        await repository.refreshContact(localID: "c")

        let byID = repository.contact(id: ContactID(contact: updated))       // guessWhoID branch
        let byGuessWhoID = repository.contact(guessWhoID: uuid)
        let byLocalID = repository.contact(localID: "c")

        // All three return the SAME, freshly-edited value (one struct).
        #expect(byID?.jobTitle == "Rear Admiral")
        #expect(byGuessWhoID?.jobTitle == "Rear Admiral")
        #expect(byLocalID?.jobTitle == "Rear Admiral")
        #expect(byID?.localID == byGuessWhoID?.localID)
        #expect(byGuessWhoID?.localID == byLocalID?.localID)
    }

    // MARK: - Parity with the old effectiveID index for a fully-reconciled book

    /// For a fully-reconciled book, the new index results equal what the old
    /// `effectiveID`-fused index would have returned: `contact(id:)` keyed by
    /// each contact's `ContactID` returns that contact, and a manual scan keyed
    /// on `effectiveID` (still the diffable identity on `ContactID`) agrees.
    @Test @MainActor
    func parity_withOldEffectiveIDIndex_forFullyReconciledBook() async {
        let contacts = [
            reconciledContact(localID: "1", uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", givenName: "One"),
            reconciledContact(localID: "2", uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", givenName: "Two"),
            reconciledContact(localID: "3", uuid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", givenName: "Three")
        ]
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: contacts))
        await repository.reload()

        for cached in repository.contacts {
            let cid = ContactID(contact: cached)
            // New index read.
            let byIndex = repository.contact(id: cid)
            // What the OLD fused index keyed on `effectiveID` would have found.
            let byOldEffectiveScan = repository.contacts.first {
                ContactID(contact: $0).effectiveID == cid.effectiveID
            }
            #expect(byIndex?.localID == byOldEffectiveScan?.localID)
            // And the bare-UUID resolver agrees too.
            #expect(repository.contact(guessWhoID: cid.effectiveID)?.localID == cached.localID)
        }
    }

    // MARK: - Transient duplicate-guessWhoID window (pre-Case-D-collapse)

    /// Two contacts momentarily share a guessWhoID (the window reconciliation
    /// owns before Case-D collapses them). `contact(guessWhoID:)` and the
    /// guessWhoID branch of `contact(id:)` must resolve CONSISTENTLY (last-
    /// writer-wins on the pointer — the LAST occurrence of that guessWhoID in
    /// the cache array overwrites), so the list-VC `effectiveID` dedup guard
    /// still renders ONE stable row. We do NOT hardcode which contact wins (the
    /// store's `fetchAll` returns dictionary order, so cache-array order is the
    /// store's order, not our construction order); we derive the expected winner
    /// from the cache array's LAST occurrence — exactly what `setContacts`'
    /// last-writer-wins build produces — and assert every accessor agrees.
    @Test @MainActor
    func transientDuplicateGuessWhoID_resolvesConsistentlyLastWriterWins() async {
        let sharedUUID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        // Two DISTINCT contacts (different localIDs) momentarily carry the SAME
        // guessWhoID.
        let first = reconciledContact(localID: "first", uuid: sharedUUID, givenName: "First")
        let second = reconciledContact(localID: "second", uuid: sharedUUID, givenName: "Second")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [first, second]))
        await repository.reload()

        // Last-writer-wins on the pointer == the LAST contact in the cache array
        // carrying the shared guessWhoID (the order `setContacts` iterated).
        let expectedWinner = repository.contacts
            .last { ContactID(contact: $0).guessWhoID == sharedUUID }?
            .localID
        // Both candidates are present, so a winner exists and is one of them.
        #expect(expectedWinner == "first" || expectedWinner == "second")

        // `contact(guessWhoID:)` resolves to that winner...
        let winner = repository.contact(guessWhoID: sharedUUID)?.localID
        #expect(winner == expectedWinner)

        // ...and the guessWhoID branch of `contact(id:)` resolves to the SAME
        // winner for BOTH captured tokens — consistent resolution across every
        // accessor, so the dedup guard keying on the shared effectiveID picks one
        // stable row.
        #expect(repository.contact(id: ContactID(contact: first))?.localID == winner)
        #expect(repository.contact(id: ContactID(contact: second))?.localID == winner)

        // The non-winning contact is still independently reachable by localID
        // (the localID slots never collide — only the shared guessWhoID pointer
        // does), so nothing is lost; the window just resolves to one canonical id.
        #expect(repository.contact(localID: "first")?.localID == "first")
        #expect(repository.contact(localID: "second")?.localID == "second")
    }
}
