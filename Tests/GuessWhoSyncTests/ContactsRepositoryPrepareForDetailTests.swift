import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Stage 6, sub-phase 6c — `prepareContactForDetail(_: ContactID) async`, the
/// on-OPEN reconcile/repair trigger the app calls BLINDLY on detail open
/// (replacing `ContactDetailView.performReconcile()`). These exercise it through
/// the repository (engine wired in over in-memory stores), proving it:
///   - stamps a never-touched contact's URL (Case A) and re-keys the cache so the
///     captured `ContactID` resolves afterward;
///   - is idempotent on an already-reconciled contact (no second URL);
///   - is a safe no-op when the engine is nil (`.unavailable` storage);
///   - repairs a duplicate-URL contact (Case D collapses to one canonical UUID).
/// It vends NO reconcile report (the debug readout is DROPPED per the plan) and
/// NEVER throws — a reconcile failure degrades to a recorded `lastError`.
@Suite("ContactsRepository prepareContactForDetail (detail-open reconcile)")
struct ContactsRepositoryPrepareForDetailTests {
    private let alpha = "11111111-1111-4111-8111-111111111111"
    private let beta = "22222222-2222-4222-8222-222222222222"
    private let existingUUID = "33333333-3333-4333-8333-333333333333"

    private func makeSync(
        contacts: InMemoryContactStore,
        sidecars: InMemorySidecarStore = InMemorySidecarStore()
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }

    private func guessWhoURLs(in contact: Contact) -> [String] {
        contact.urlAddresses
            .map(\.value)
            .filter { $0.hasPrefix(SidecarKey.guessWhoContactURLPrefix) }
    }

    // Case A: an UNRECONCILED contact (no GuessWho URL) opened for detail gets
    // its URL stamped, and the repository cache then reflects the new identity —
    // the contact carries a guessWhoID and resolves under it AND via a freshly
    // derived ContactID. No app-side reload, report, or localID involved.
    @Test @MainActor
    func prepare_onUnreconciledContact_stampsAndReKeysCache() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        // Precondition: no GuessWho UUID yet — captured ContactID is localID-only.
        let cached = try #require(repository.contact(localID: "TARGET"))
        let id = repository.contactID(for: cached)
        #expect(id.guessWhoID == nil)

        await repository.prepareContactForDetail(id)

        // The store record now carries exactly the one minted GuessWho URL.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved).count == 1)
        let minted = try #require(ContactID(contact: saved).guessWhoID)
        #expect(UUID(uuidString: minted) != nil)

        // The cache reflects the new identity WITHOUT an app-side reload: the
        // contact resolves under the minted GuessWho UUID...
        let byGuessWhoID = try #require(repository.contact(guessWhoID: minted))
        #expect(byGuessWhoID.localID == "TARGET")
        // ...and a fresh ContactID derived from the now-reconciled record resolves.
        let freshID = repository.contactID(for: byGuessWhoID)
        #expect(freshID.guessWhoID == minted)
        #expect(repository.contact(id: freshID)?.localID == "TARGET")

        // No spurious lastError on the happy path.
        #expect(repository.lastError == nil)
    }

    // The captured pre-reconcile ContactID (localID-only) still resolves AFTER
    // the on-open stamp, via 6b2's localID fallback / pointer re-key — this is
    // what lets 6d delete the view's threaded resolvedLocalID.
    @Test @MainActor
    func prepare_capturedPreReconcileID_stillResolvesAfterStamp() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "TARGET"))
        let capturedID = repository.contactID(for: cached)
        #expect(capturedID.guessWhoID == nil)

        await repository.prepareContactForDetail(capturedID)

        // The SAME captured (pre-reconcile) ContactID still resolves — the view
        // re-loads off its captured `id`, not a threaded localID.
        let resolved = try #require(repository.contact(id: capturedID))
        #expect(resolved.localID == "TARGET")
        #expect(ContactID(contact: resolved).guessWhoID != nil)
    }

    // An ALREADY-reconciled contact opened for detail is idempotent: no second
    // URL is appended and the UUID is unchanged.
    @Test @MainActor
    func prepare_onAlreadyReconciledContact_isIdempotent() async throws {
        let reconciled = Contact(
            localID: "RECON",
            givenName: "Grace",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + existingUUID),
            ]
        )
        let store = InMemoryContactStore(contacts: [reconciled])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "RECON"))
        let id = repository.contactID(for: cached)
        #expect(id.guessWhoID == existingUUID)

        await repository.prepareContactForDetail(id)

        // No re-stamp: the stored record's GuessWho URLs are byte-for-byte
        // unchanged (same single UUID, no second URL appended).
        let saved = try #require(try await store.fetch(localID: "RECON"))
        #expect(guessWhoURLs(in: saved) == [SidecarKey.guessWhoContactURLPrefix + existingUUID])

        // The cache still resolves the same identity.
        #expect(repository.contact(guessWhoID: existingUUID)?.localID == "RECON")
        #expect(repository.lastError == nil)
    }

    // With the engine nil (the `.unavailable` storage state), prepare is a safe
    // no-op: nothing to reconcile/repair, no crash, no throw, and the contact is
    // left exactly as it was (still unreconciled — no URL minted).
    @Test @MainActor
    func prepare_withNilEngine_isSafeNoOp() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        // Default init — no engine wired (nil), mirroring `.unavailable`.
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "TARGET"))
        let id = repository.contactID(for: cached)
        #expect(id.guessWhoID == nil)

        // No crash, no throw (not a `throws` method — called blindly on open).
        await repository.prepareContactForDetail(id)

        // Nothing minted: the store record is untouched, still unreconciled.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved).isEmpty)
        #expect(repository.contact(localID: "TARGET")?.localID == "TARGET")
        // No-op path records no error.
        #expect(repository.lastError == nil)
    }

    // Case D repair: a contact carrying TWO GuessWho URLs (duplicate identity)
    // opened for detail collapses onto the single canonical (lexicographically
    // first) UUID, and the cache re-keys onto it. Cheaply modeled with the
    // in-memory reconcile doubles.
    @Test @MainActor
    func prepare_onDuplicateURLContact_repairsToCanonicalUUID() async throws {
        // alpha < beta, so reconcile keeps alpha as the canonical winner.
        let target = Contact(
            localID: "TARGET",
            givenName: "Ada",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + beta),
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + alpha),
            ]
        )
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "TARGET"))
        let id = repository.contactID(for: cached)

        await repository.prepareContactForDetail(id)

        // Repaired to the single canonical URL on disk.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved) == [SidecarKey.guessWhoContactURLPrefix + alpha])

        // The cache re-keyed onto the canonical UUID; the loser no longer resolves.
        #expect(repository.contact(guessWhoID: alpha)?.localID == "TARGET")
        #expect(repository.contact(guessWhoID: beta) == nil)
        #expect(repository.lastError == nil)
    }
}
