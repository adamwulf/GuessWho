import Foundation
import Observation

public extension Notification.Name {
    /// Posted after a `ContactsRepository` cache mutation completes.
    /// Consumers that do not use Observation (for example UIKit diffable data
    /// sources) can observe this notification and apply one new snapshot.
    static let contactsRepositoryDidReload = Notification.Name("ContactsRepositoryDidReload")
}

/// Package-owned in-memory read repository for Contacts.
///
/// The repository is deliberately a read-model cache, not a second source of
/// truth: Contacts remains authoritative. It owns the full reload and
/// incremental-change mechanics so all UI clients observe one coherent view
/// of the address book. It currently also preserves the app's established list
/// query behavior as a transitional compatibility API.
@MainActor
@Observable
public final class ContactsRepository: NSObject {
    private let contactsStore: ContactStoreProtocol

    // The sidecar write engine and the standalone favorites store. BOTH are
    // Optional and nil in the `.unavailable` storage state (no writable
    // sidecar root) — exactly mirroring `SyncService.sync` / `.favoritesStore`.
    // They are wired in here (Stage 6, Step 0) so the repository can reconcile
    // and write a sidecar itself; pre-Stage-6 it held ONLY `contactsStore` and
    // could not. Both are reference-type classes; holding them on this
    // `@MainActor`-isolated repository is what keeps access race-free —
    // `GuessWhoSync` is additionally `@unchecked Sendable` so the stored
    // reference crosses no isolation boundary diagnostic. New methods that
    // depend on either MUST degrade when nil: reads return empty/false, writes
    // throw `SidecarUnavailableError`.
    private let sync: GuessWhoSync?
    private let favorites: FavoritesStore?

    public private(set) var contacts: [Contact] = []
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public var peopleSearch = ""
    public var organizationsSearch = ""

    // MARK: - Point-lookup indexes (private; rebuilt from `contacts`)
    //
    // These make `contact(id:)`, `contact(localID:)`, and
    // `contactIDs(matchingEmail:)` O(1) synchronous main-actor reads. They are
    // NEVER mutated directly — every `contacts` assignment routes through
    // `setContacts(_:)`, which reassigns the array AND rebuilds all three
    // indexes wholesale, so the array and indexes cannot drift. A wholesale
    // rebuild (rather than an in-place patch) is what makes the reconciliation
    // transition — a contact's effective identity flipping `localID →
    // guessWhoID` — re-key automatically: the new array yields the new key and
    // the old key simply isn't reproduced.

    /// Keyed on `ContactID(contact:).effectiveID` (`guessWhoID ?? localID`).
    /// One entry per contact; backs `contact(id:)`.
    private var contactsByEffectiveID: [String: Contact] = [:]

    /// Keyed on `localID` (Apple's `CNContact.identifier`). One entry per
    /// contact; backs the `contact(localID:)` Contacts-boundary accessor.
    private var contactsByLocalID: [String: Contact] = [:]

    /// Keyed on each lowercased+trimmed email address a contact carries; a
    /// contact appears under EVERY email it has, and one email can map to
    /// MULTIPLE contacts (duplicates are preserved). Backs
    /// `contactIDs(matchingEmail:)`.
    private var contactsByEmail: [String: [Contact]] = [:]

    public init(
        contacts: ContactStoreProtocol,
        sync: GuessWhoSync? = nil,
        favorites: FavoritesStore? = nil
    ) {
        self.contactsStore = contacts
        self.sync = sync
        self.favorites = favorites
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contactsDidChange(_:)),
            name: .guessWhoContactsDidChange,
            object: nil
        )
    }

    /// Rebuild the cache from Contacts. A failed fetch leaves an empty cache
    /// and records the error; this preserves the existing app behavior for a
    /// denied permission or a transient Contacts failure.
    public func reload() async {
        isLoading = true
        do {
            setContacts(try await contactsStore.fetchAll())
            lastError = nil
        } catch {
            setContacts([])
            lastError = "Contacts fetch failed: \(error.localizedDescription)"
        }
        // NotificationCenter can deliver synchronously. Consumers must observe
        // the settled loading state when they apply their post-reload snapshot.
        isLoading = false
        postDidReload()
    }

    /// Returns a currently-cached contact for an adapter-local refresh token.
    /// `localID` is intentionally confined to this Contacts-boundary API; it
    /// must not be persisted or used as application identity.
    public func contact(localID: String) -> Contact? {
        contactsByLocalID[localID]
    }

    // MARK: - ContactID-addressed reads
    //
    // All accessors below are synchronous main-actor reads over the in-memory
    // `contacts` cache. NONE of them enumerate `CNContactStore` — the cache is
    // the read model and Contacts is refreshed only via `reload()` /
    // `refreshContact(localID:)`. The UI keys exclusively on `ContactID`; the
    // `localID` carrier inside the value is consumed only by `contact(id:)`.

    /// Resolves a `ContactID` back to its cached `Contact` by EFFECTIVE identity
    /// (`guessWhoID ?? localID`), never by raw `localID` alone: a stale `localID`
    /// could re-resolve to the wrong contact after a unification / Case-D change,
    /// whereas the GuessWho UUID is stable once minted. Returns `nil` when no
    /// cached contact matches (deleted, or a retired/unknown id) — the
    /// "unavailable" contract the UI renders, never a wrong-contact fallback.
    public func contact(id: ContactID) -> Contact? {
        contactsByEffectiveID[id.effectiveID]
    }

    /// The reconciled GuessWho UUID carried by `contact`, or `nil` when the
    /// contact has no valid `guesswho://` URL yet (un-reconciled). This is the
    /// EFFECTIVE GuessWho identity — `ContactID(contact:).guessWhoID` — NOT the
    /// `localID` fallback: a contact with no GuessWho URL has no sidecar data to
    /// key on, so callers binding favorites/notes/links/tags must get `nil` (and
    /// stand down) rather than a transient `localID`.
    ///
    /// A PURE function of the passed contact — no cache read — so it reads the
    /// UUID off the live record the caller already holds, with no cache-miss
    /// window. Identity comes from `SidecarKey` exactly as `contactID(for:)` and
    /// `contact(id:)` resolve it. The sanctioned way for the app to read an OPENED
    /// contact's own GuessWho UUID without reaching into `ContactID.guessWhoID`
    /// (which is `package`): the detail view holds the loaded `Contact` and binds
    /// its sidecar stores on this. Semantics match the former
    /// `SyncService.guessWhoUUID(in:)` byte-for-byte (it walked the same
    /// `urlAddresses` via the same `SidecarKey` parser).
    public func guessWhoID(in contact: Contact) -> String? {
        ContactID(contact: contact).guessWhoID
    }

    /// Vends the `ContactID` for a `Contact` the caller already holds — the
    /// only sanctioned way for the app to obtain a navigation/identity token
    /// from a `Contact`, since `ContactID.init(contact:)` is `package` and the
    /// app cannot mint one itself. Used by the navigation layer to re-key a
    /// `ContactReference` off a list-selected `Contact` and by detail views
    /// that hold a `Contact` and need to push to it. Pure function of the
    /// passed contact (no cache read); identity comes from `SidecarKey` exactly
    /// as `contact(id:)` resolves it back.
    public func contactID(for contact: Contact) -> ContactID {
        ContactID(contact: contact)
    }

    /// Resolves a BARE GuessWho UUID (a `SidecarKey` endpoint id, a
    /// `Favorite.id`, etc.) to its cached `Contact`. A reconciled contact's
    /// EFFECTIVE identity IS its `guessWhoID`, so this hits the same O(1)
    /// `contactsByEffectiveID` index `contact(id:)` uses, then CONFIRMS the
    /// resolved contact's `guessWhoID` actually equals the input. The confirm
    /// matters: `effectiveID` is `guessWhoID ?? localID`, so a not-yet-reconciled
    /// contact is keyed under its `localID`; without the guard, a query string
    /// coinciding with some bare contact's `localID` would wrongly resolve to it.
    /// We promise `guessWhoID` semantics, so only a true `guessWhoID` match
    /// returns a contact. Input is lowercased to match the canonical lowercase
    /// keys (`SidecarKey` / `Favorite` already lowercase their ids — defensive).
    /// Returns `nil` for an unknown/retired UUID, or for a string that is only a
    /// `localID` — the "unavailable" contract, never a wrong-contact fallback.
    /// The bridge that lets the app resolve a link endpoint / favorite (keyed by
    /// bare UUID) without re-introducing an app-side `uuid → Contact` map.
    public func contact(guessWhoID: String) -> Contact? {
        let needle = guessWhoID.lowercased()
        guard let candidate = contactsByEffectiveID[needle],
              ContactID(contact: candidate).guessWhoID == needle else { return nil }
        return candidate
    }

    // MARK: - Reconcile-on-write (resolve-or-mint)
    //
    // The INTERNAL plumbing every WRITE entry point (notes/links/favorite —
    // landing in sub-phase 6b) routes through to obtain the GuessWho UUID it
    // writes the sidecar at. Reconcile is a package-INTERNAL side effect of a
    // write: the app never triggers, sees, or names it.

    /// Resolves the GuessWho UUID a sidecar WRITE for `id` must key on, MINTING
    /// one via reconcile IFF the contact has none yet.
    ///
    /// - If `id.guessWhoID` is already present, returns it directly — NO
    ///   reconcile, no re-stamp. An already-reconciled contact's identity is
    ///   stable; a write must not perturb it.
    /// - Otherwise reconcile fires on `id.localID`. With no valid GuessWho URL
    ///   on the contact, reconcile hits Case A and mints a fresh UUID
    ///   (`assignedUUID`). The defensive fall-through re-reads the now-canonical
    ///   record's URL for the pathological Case B/C/D path where reconcile
    ///   stamped a URL without populating `assignedUUID` (mirrors the app's
    ///   former `SyncService.reconcileIfNeeded`).
    ///
    /// DEGRADES when the engine is nil (the `.unavailable` storage state): a
    /// write to an unreconciled contact has nowhere to mint, so it THROWS
    /// `SidecarUnavailableError` rather than silently no-op — matching the
    /// existing app write behavior the caller expects.
    ///
    /// CONCURRENCY — accepts a rare double-mint by design; does NOT serialize.
    /// Two truly-concurrent writes to the SAME never-reconciled `ContactID`
    /// could each mint before the other's write lands, because resolve-or-mint
    /// must `await` the reconcile (which `await`s `contacts.fetch`) and the
    /// engine's per-key locks (`PerKeyLockTable`) are SYNCHRONOUS `NSLock`s that
    /// CANNOT be held across that `await`. This is accepted as a practical
    /// non-event (it needs a never-reconciled contact AND two simultaneous
    /// writes from different surfaces — effectively only Catalyst multi-window);
    /// no async-serialization machinery is added here. See the Stage 6
    /// "CONCURRENCY (decision: ACCEPT double-mint...)" paragraph in
    /// `plans/package-vended-contact-identity.md` for the full rationale,
    /// including why single-device last-write-wins orphans a sidecar (harmless)
    /// and only the multi-device case self-heals via Case-D.
    internal func resolveOrMintGuessWhoID(for id: ContactID) async throws -> String {
        // Fast path: already reconciled — return the stable UUID, mint nothing.
        if let existing = id.guessWhoID {
            return existing
        }
        // Mint path: a write needs the engine. Nil ⇒ no writable sidecar root,
        // so a write cannot proceed (no place to mint or persist) → throw.
        guard let sync else {
            throw SidecarUnavailableError()
        }
        let outcome = try await sync.reconcileContactIdentity(localID: id.localID)
        if let assigned = outcome.assignedUUID {
            return assigned
        }
        // Reconcile finished without an `assignedUUID` — Cases B/C/D may stamp
        // the on-disk contact's URL without populating that field (e.g. a stale
        // in-memory snapshot of a contact that already carried a valid URL).
        // Re-fetch the single record post-write so we read the freshly written
        // UUID, then derive it via the same `SidecarKey` parser `ContactID` uses.
        if let fresh = try? await contactsStore.fetch(localID: id.localID),
           let stamped = ContactID(contact: fresh).guessWhoID {
            return stamped
        }
        throw ReconcileAssignmentFailedError()
    }

    /// People rows addressed by `ContactID`, sectioned A–Z. Mirrors
    /// `peopleSections`. EVERY cached person yields a row — a contact without a
    /// GuessWho URL is still vended, identified by its `localID` fallback, so
    /// nothing is silently dropped before reconciliation runs.
    public var peopleSectionIDs: [(String, [ContactID])] { sectionedIDs(people) }

    /// Organization rows addressed by `ContactID`, sectioned A–Z. Mirrors
    /// `organizationsSections`.
    public var organizationsSectionIDs: [(String, [ContactID])] { sectionedIDs(organizations) }

    /// Every cached contact whose display name matches `displayName`, addressed
    /// by `ContactID`. Returns ALL matches (no silent last-writer pick) — the
    /// UI owns disambiguation. The `ContactID` parallel to `contacts(named:)`.
    public func contactIDs(named displayName: String) -> [ContactID] {
        contacts(named: displayName).map { ContactID(contact: $0) }
    }

    /// Cached contacts that list `email` among their addresses, addressed by
    /// `ContactID`. Matching is case-insensitive on the trimmed address; an
    /// empty query returns nothing. Returns ALL matches. Named `contactIDs(...)`
    /// for consistency with `contactIDs(named:)`.
    public func contactIDs(matchingEmail email: String) -> [ContactID] {
        let needle = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        // O(1) index hit. `contactsByEmail` lists matches in cache-array order
        // (the funnel appends per contact as it walks the array), so this
        // preserves the previous `contacts.compactMap` ordering and returns
        // ALL matches.
        return (contactsByEmail[needle] ?? []).map { ContactID(contact: $0) }
    }

    /// Cached contacts that reference the contact identified by `id` through a
    /// name-only `CNContactRelation`, addressed by `ContactID`. Self is excluded
    /// by EFFECTIVE identity (`guessWhoID ?? localID`) — never by raw `localID` —
    /// so a contact that relates to its own name doesn't appear in its own
    /// reverse-relation list.
    public func contactsReferencing(id: ContactID) -> [(id: ContactID, label: String)] {
        // ContactID is identity-only, so resolve it to its cached Contact (O(1)
        // index hit) to read the display name we match relations against.
        guard let needle = contact(id: id)?.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !needle.isEmpty else { return [] }
        return contacts.flatMap { other -> [(id: ContactID, label: String)] in
            let otherID = ContactID(contact: other)
            guard otherID.effectiveID != id.effectiveID else { return [] }
            return other.contactRelations.compactMap { relation in
                let name = relation.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return name == needle ? (id: otherID, label: relation.label) : nil
            }
        }
    }

    public var people: [Contact] {
        filtered(matching: peopleSearch, where: { $0.contactType == .person })
    }

    public var organizations: [Contact] {
        filtered(matching: organizationsSearch, where: { $0.contactType == .organization })
    }

    public var peopleSections: [(String, [Contact])] { sectioned(people) }
    public var organizationsSections: [(String, [Contact])] { sectioned(organizations) }

    /// Transitional compatibility lookup. Duplicate display names collapse to
    /// the last cached contact; new callers should use `contacts(named:)`.
    public func lookupByDisplayName() -> [String: Contact] {
        var map: [String: Contact] = [:]
        for contact in contacts {
            let key = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            map[key] = contact
        }
        return map
    }

    /// Returns every cached contact whose display name matches `displayName`.
    /// Unlike the legacy `lookupByDisplayName()`, this preserves ambiguity.
    public func contacts(named displayName: String) -> [Contact] {
        let needle = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contacts.filter {
            $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    public func contactsReferencing(contact: Contact) -> [(contact: Contact, label: String)] {
        let needle = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contacts.flatMap { other in
            guard other.localID != contact.localID else {
                return [(contact: Contact, label: String)]()
            }
            return other.contactRelations.compactMap { relation in
                let name = relation.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return name == needle ? (contact: other, label: relation.label) : nil
            }
        }
    }

    /// Re-read one Contacts record and reconcile it into the cache.
    public func refreshContact(localID: String) async {
        await applyRefresh(localID: localID)
        postDidReload()
    }

    /// Remove a just-deleted record from the in-memory cache.
    public func removeContact(localID: String) {
        var updated = contacts
        updated.removeAll { $0.localID == localID }
        setContacts(updated)
        postDidReload()
    }

    private func postDidReload() {
        NotificationCenter.default.post(name: .contactsRepositoryDidReload, object: self)
    }

    /// The SINGLE funnel for every `contacts` mutation. Reassigns the array
    /// (preserving `@Observable` tracking of the stored property) and rebuilds
    /// all three point-lookup indexes from the new array so they can never
    /// drift from it. Incremental sites (refresh / remove / delta-apply) mutate
    /// a local copy and call this once; a wholesale index rebuild at v1
    /// address-book scale is cheap and eliminates a whole class of patch-drift
    /// bugs — including the reconciliation re-key, which is automatic here
    /// because the new array yields the new effective-id key and never
    /// reproduces the stale one.
    private func setContacts(_ newValue: [Contact]) {
        contacts = newValue

        var byEffectiveID: [String: Contact] = [:]
        var byLocalID: [String: Contact] = [:]
        var byEmail: [String: [Contact]] = [:]
        byEffectiveID.reserveCapacity(newValue.count)
        byLocalID.reserveCapacity(newValue.count)
        // byEmail intentionally omits reserveCapacity: its key count is the
        // number of DISTINCT email addresses across the book, not the contact
        // count, so newValue.count is the wrong hint.
        for contact in newValue {
            // Last-writer-wins on a duplicate effectiveID: if two cached contacts
            // somehow share an effectiveID, the later one in the array overwrites.
            // This diverges from the old `contacts.first { … }` (first-match-wins)
            // ONLY inside a transient, un-collapsed duplicate-guessWhoID window
            // that reconciliation owns and resolves onto one canonical id — so the
            // divergence is user-invisible and acceptable.
            byEffectiveID[ContactID(contact: contact).effectiveID] = contact
            byLocalID[contact.localID] = contact
            // Index under each DISTINCT email key the contact carries. A contact
            // listing the same address under two labels must still appear only
            // once per key — matching the old `contacts.compactMap` semantics
            // where a per-contact `.contains` yielded one row, not one per label.
            var seenKeys: Set<String> = []
            for email in contact.emailAddresses {
                let key = email.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
                byEmail[key, default: []].append(contact)
            }
        }
        contactsByEffectiveID = byEffectiveID
        contactsByLocalID = byLocalID
        contactsByEmail = byEmail
    }

    private func applyRefresh(localID: String) async {
        var updated = contacts
        await refetch(localID: localID, into: &updated)
        setContacts(updated)
    }

    /// Re-reads ONE Contacts record and applies the result to `working` WITHOUT
    /// committing (no `setContacts`). Splitting the fetch from the commit lets
    /// the batch `apply(_:)` path apply many changes to one local copy and
    /// rebuild the indexes exactly once. A successful fetch replaces/inserts the
    /// fresh record (or removes it when the store reports it gone); a thrown
    /// re-read leaves the prior cached projection in place — error is isolated to
    /// this one `localID`, never aborting a batch or leaving indexes half-built.
    private func refetch(localID: String, into working: inout [Contact]) async {
        do {
            let fresh = try await contactsStore.fetch(localID: localID)
            if let fresh {
                if let index = working.firstIndex(where: { $0.localID == localID }) {
                    working[index] = fresh
                } else {
                    working.append(fresh)
                }
            } else {
                working.removeAll { $0.localID == localID }
            }
            lastError = nil
        } catch {
            // A failed individual re-read cannot establish whether the record
            // changed or disappeared, so retain the prior cached projection.
            lastError = "Contact fetch failed: \(error.localizedDescription)"
        }
    }

    @objc
    private nonisolated func contactsDidChange(_ note: Notification) {
        let changeSet = note.userInfo?[GuessWhoContactsDidChangeKey.changeSet] as? ContactChangeSet
        let requiresFullReload = note.userInfo?[GuessWhoContactsDidChangeKey.requiresFullReload] as? Bool ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if requiresFullReload {
                await self.reload()
            } else if let changeSet {
                await self.apply(changeSet)
            }
        }
    }

    private func apply(_ changeSet: ContactChangeSet) async {
        guard !changeSet.changes.isEmpty else { return }
        // Coalesce the whole delta into ONE index rebuild: apply every change to
        // a single local copy (re-fetching `.updated` records from the store as
        // we go, in history order — a delete then re-add of the same localID must
        // settle as present), then commit once. A delta of M changes costs one
        // rebuild per BATCH, not M.
        var updated = contacts
        for change in changeSet.changes {
            switch change {
            case .updated(let localID):
                await refetch(localID: localID, into: &updated)
            case .deleted(let localID):
                updated.removeAll { $0.localID == localID }
            }
        }
        setContacts(updated)
        postDidReload()
    }

    private func filtered(matching query: String, where predicate: (Contact) -> Bool) -> [Contact] {
        contacts.filter(predicate).filter { $0.matches(searchQuery: query) }.sorted {
            let primary = $0.lastNameSortKey.localizedCaseInsensitiveCompare($1.lastNameSortKey)
            if primary != .orderedSame { return primary == .orderedAscending }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func sectioned(_ contacts: [Contact]) -> [(String, [Contact])] {
        Dictionary(grouping: contacts, by: \.sectionLetter).map { ($0.key, $0.value) }.sorted {
            switch ($0.0, $1.0) {
            case ("#", _): return false
            case (_, "#"): return true
            default: return $0.0 < $1.0
            }
        }
    }

    /// Sections the contacts exactly like `sectioned(_:)`, then maps each row to
    /// its `ContactID`. EVERY row is kept — `ContactID(contact:)` never fails, so
    /// a contact with no GuessWho URL still vends a `localID`-identified row and
    /// no section can become empty by dropping. Section order and the
    /// within-section sort are inherited from the `Contact` list passed in
    /// (already sorted by `filtered(matching:where:)`).
    private func sectionedIDs(_ contacts: [Contact]) -> [(String, [ContactID])] {
        sectioned(contacts).map { letter, rows in
            (letter, rows.map { ContactID(contact: $0) })
        }
    }

}
