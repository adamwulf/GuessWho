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
            contacts = try await contactsStore.fetchAll()
            lastError = nil
        } catch {
            contacts = []
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
        contacts.first { $0.localID == localID }
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
        contacts.first { ContactID(contact: $0).effectiveID == id.effectiveID }
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
        return contacts.compactMap { contact in
            let hit = contact.emailAddresses.contains {
                $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
            }
            return hit ? ContactID(contact: contact) : nil
        }
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
        contacts.removeAll { $0.localID == localID }
        postDidReload()
    }

    private func postDidReload() {
        NotificationCenter.default.post(name: .contactsRepositoryDidReload, object: self)
    }

    private func applyRefresh(localID: String) async {
        do {
            let fresh = try await contactsStore.fetch(localID: localID)
            if let fresh {
                if let index = contacts.firstIndex(where: { $0.localID == localID }) {
                    contacts[index] = fresh
                } else {
                    contacts.append(fresh)
                }
            } else {
                contacts.removeAll { $0.localID == localID }
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
        for change in changeSet.changes {
            switch change {
            case .updated(let localID):
                await applyRefresh(localID: localID)
            case .deleted(let localID):
                contacts.removeAll { $0.localID == localID }
            }
        }
        if !changeSet.changes.isEmpty {
            postDidReload()
        }
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
