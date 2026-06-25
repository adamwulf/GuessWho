import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Stage 6, sub-phase 6a — the INTERNAL resolve-or-mint reconcile-on-write
/// primitive on `ContactsRepository`. These exercise the primitive through the
/// repository (engine wired in), proving the reconcile TRIGGER fires on the
/// mint path, is skipped on the already-reconciled path, and degrades when the
/// engine is nil. The four-case algorithm itself stays covered in isolation by
/// `SingleContactReconcilerTests` (direct calls) — these do NOT replace those.
@Suite("ContactsRepository resolve-or-mint (reconcile-on-write)")
struct ContactsRepositoryResolveOrMintTests {
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

    // An UNRECONCILED contact (no GuessWho URL) routed through resolve-or-mint
    // MINTS a UUID — reconcile fired via the write path — and the freshly
    // reconciled record is findable under the minted identity afterward.
    @Test @MainActor
    func resolveOrMint_onUnreconciledContact_mints() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        // Precondition: no GuessWho UUID yet.
        let cached = try #require(repository.contact(localID: "TARGET"))
        let id = repository.contactID(for: cached)
        #expect(id.guessWhoID == nil)

        let minted = try await repository.resolveOrMintGuessWhoID(for: id)
        #expect(!minted.isEmpty)
        #expect(UUID(uuidString: minted) != nil)

        // The store record now carries exactly the one minted GuessWho URL.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: saved).count == 1)
        #expect(ContactID(contact: saved).guessWhoID == minted)

        // After pulling the canonical record into the cache, the contact is
        // found under the minted GuessWho UUID (the reconcile re-key landed).
        await repository.reload()
        let reReconciled = try #require(repository.contact(guessWhoID: minted))
        #expect(reReconciled.localID == "TARGET")

        // Resolve-or-mint on the NOW-reconciled id returns the SAME UUID and
        // mints nothing further (fast path — no second URL appended).
        let again = try await repository.resolveOrMintGuessWhoID(for: repository.contactID(for: reReconciled))
        #expect(again == minted)
        let afterSecond = try #require(try await store.fetch(localID: "TARGET"))
        #expect(guessWhoURLs(in: afterSecond).count == 1)
    }

    // An ALREADY-reconciled ContactID short-circuits: returns its existing
    // guessWhoID without re-minting or re-stamping the contact's URLs.
    @Test @MainActor
    func resolveOrMint_onAlreadyReconciledContact_doesNotReMint() async throws {
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

        let resolved = try await repository.resolveOrMintGuessWhoID(for: id)
        #expect(resolved == existingUUID)

        // No re-stamp: the stored record's GuessWho URLs are byte-for-byte
        // unchanged (the fast path never touched the engine or the store).
        let saved = try #require(try await store.fetch(localID: "RECON"))
        #expect(guessWhoURLs(in: saved) == [SidecarKey.guessWhoContactURLPrefix + existingUUID])
    }

    // The DEFENSIVE re-fetch fall-through: the passed ContactID is a STALE
    // snapshot (guessWhoID nil) of a contact that ALREADY carries a valid
    // GuessWho URL on disk. The mint path runs (guessWhoID nil), but reconcile
    // sees the on-disk URL → single valid UUID → NOT Case A → assignedUUID nil
    // and no save. The primitive must fall through, re-fetch the canonical
    // record, and return the EXISTING URL's UUID — never throw, never mint a
    // second URL. Mirrors the former SyncService.reconcileIfNeeded fall-through.
    @Test @MainActor
    func resolveOrMint_whenReconcileReportsNoAssignedUUID_fallsThroughToExistingURL() async throws {
        // On-disk record carries a valid GuessWho URL.
        let onDisk = Contact(
            localID: "RECON",
            givenName: "Grace",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + existingUUID),
            ]
        )
        let store = InMemoryContactStore(contacts: [onDisk])
        let sync = makeSync(contacts: store)
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()

        // STALE snapshot of the SAME contact WITHOUT the URL → guessWhoID nil,
        // same localID. Built directly via the `package` ContactID initializer
        // (visible under @testable) to model an in-memory snapshot that predates
        // the on-disk stamp.
        let staleID = ContactID(contact: Contact(localID: "RECON", givenName: "Grace"))
        #expect(staleID.guessWhoID == nil)
        #expect(staleID.localID == "RECON")

        // Mint path runs (guessWhoID nil), but reconcile finds the existing URL
        // (single valid UUID, not Case A) → assignedUUID nil → fall through.
        let resolved = try await repository.resolveOrMintGuessWhoID(for: staleID)
        #expect(resolved == existingUUID)

        // No second URL was stamped — the fall-through read, it did not mint.
        let saved = try #require(try await store.fetch(localID: "RECON"))
        #expect(guessWhoURLs(in: saved) == [SidecarKey.guessWhoContactURLPrefix + existingUUID])
    }

    // With the engine nil (the `.unavailable` storage state), a write to an
    // unreconciled contact has nowhere to mint, so the primitive THROWS
    // `SidecarUnavailableError` rather than silently no-op.
    @Test @MainActor
    func resolveOrMint_withNilEngine_throwsSidecarUnavailable() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        // Default init — no engine wired (nil), mirroring `.unavailable`.
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "TARGET"))
        let id = repository.contactID(for: cached)
        #expect(id.guessWhoID == nil)

        await #expect(throws: SidecarUnavailableError.self) {
            _ = try await repository.resolveOrMintGuessWhoID(for: id)
        }
    }

    // Even with the engine nil, an ALREADY-reconciled id still resolves — the
    // fast path needs no engine, so a write to a reconciled contact does NOT
    // spuriously throw "unavailable".
    @Test @MainActor
    func resolveOrMint_withNilEngine_onReconciledContact_returnsExisting() async throws {
        let reconciled = Contact(
            localID: "RECON",
            givenName: "Grace",
            urlAddresses: [
                LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + existingUUID),
            ]
        )
        let store = InMemoryContactStore(contacts: [reconciled])
        let repository = ContactsRepository(contacts: store)
        await repository.reload()

        let cached = try #require(repository.contact(localID: "RECON"))
        let id = repository.contactID(for: cached)

        let resolved = try await repository.resolveOrMintGuessWhoID(for: id)
        #expect(resolved == existingUUID)
    }
}
