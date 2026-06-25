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

    public init(contacts: ContactStoreProtocol) {
        self.contactsStore = contacts
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
        let needle = id.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
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
