import Foundation
import GuessWhoSync

extension Notification.Name {
    /// Posted by `ContactsRepository.reload()` after a fetch completes.
    /// UIKit list controllers subscribe to this to re-apply a diffable
    /// snapshot; SwiftUI consumers don't need it because `@Observable`
    /// already drives recomputes for them.
    static let contactsRepositoryDidReload = Notification.Name("ContactsRepositoryDidReload")
}

/// SwiftUI-facing read repository over the system Contacts store. One
/// underlying fetch backs both the People and Organizations tabs — the
/// `people` / `organizations` computed properties partition the same
/// cached array by `Contact.contactType` and apply the per-tab
/// `searchText` filter in memory.
///
/// In-memory search is intentional: Contacts framework predicate fetching
/// is limited (no multi-field substring), and personal-scale address books
/// stay well under any size where in-memory filter cost matters. If that
/// ever stops being true, the partitioning could move into separate
/// fetches with `CNContact.predicateForContacts(matchingName:)`.
@MainActor
@Observable
final class ContactsRepository: NSObject {
    private let service: SyncService

    private(set) var contacts: [Contact] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    /// Per-tab search query for People. Read by `ContactsListViewController`
    /// (UIKit `UISearchController`) so switching tabs does not clobber
    /// the other tab's query.
    var peopleSearch: String = ""
    /// Per-tab search query for Organizations.
    var organizationsSearch: String = ""

    init(service: SyncService) {
        self.service = service
        super.init()
        // Dumb subscriber: the package's `ContactChangeWatcher` owns the
        // `.CNContactStoreDidChange` observer, the cursor, and the coalescing,
        // and posts `.guessWhoContactsDidChange` only when there is real work.
        // The selector-based registration is held weakly by NotificationCenter
        // and auto-cleaned when this repository is released (this repo lives for
        // the whole process, so that never actually happens) — no `deinit`,
        // no token bookkeeping.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contactsDidChange(_:)),
            name: .guessWhoContactsDidChange,
            object: nil
        )
    }

    func reload() async {
        isLoading = true
        contacts = await service.fetchAll()
        // Flip isLoading BEFORE posting so synchronous observers (the
        // UIKit `ContactsListViewController` subscribes via
        // `addObserver(forName:object:queue:.main, using:)`, which can
        // deliver inside this stack frame when the posting and
        // observing actors are both main) see the post-load state.
        // A `defer { isLoading = false }` would fire AFTER the observer
        // ran, leaving a UIKit list with zero contacts spinning forever
        // waiting for the second event that flips the flag.
        //
        // Load-bearing assumption: `service.fetchAll()` is non-throwing
        // (it catches internally and returns `[]` on error). If it ever
        // becomes throwing, re-introduce a `defer { isLoading = false }`
        // — or a `do/catch` that flips the flag in both branches — so
        // the empty/error path still terminates the spinner.
        isLoading = false
        postDidReload()
    }

    // MARK: - Incremental cache mutation

    /// The single shared post that wakes the UIKit list controllers. Matches
    /// the post `reload()` makes — all incremental mutators below funnel through
    /// here so there is exactly one place that names the notification.
    private func postDidReload() {
        NotificationCenter.default.post(name: .contactsRepositoryDidReload, object: self)
    }

    /// Re-read ONE contact from the store and reconcile it into the cache —
    /// replace the existing entry (matched by `localID`), append if it is new,
    /// or drop it if the store no longer has it (deleted between change events).
    /// Does NOT post; the caller decides when so a batch of changes can land
    /// under a single snapshot apply.
    ///
    /// Reads the STORE (not `contacts`) because the cache is stale for the
    /// just-changed contact — this is the post-write read.
    private func applyRefresh(localID: String) async {
        let fresh = await service.fetch(localID: localID)
        if let fresh {
            if let index = contacts.firstIndex(where: { $0.localID == localID }) {
                contacts[index] = fresh
            } else {
                contacts.append(fresh)
            }
        } else {
            contacts.removeAll { $0.localID == localID }
        }
    }

    /// Drop one contact from the cache (matched by `localID`). Pure in-memory,
    /// no store I/O. Does NOT post; the caller decides when.
    private func applyRemove(localID: String) {
        contacts.removeAll { $0.localID == localID }
    }

    /// Refresh one contact from the store and notify list controllers. For our
    /// own save of a known `localID` — re-reads ONE record, not all of them.
    func refreshContact(localID: String) async {
        await applyRefresh(localID: localID)
        postDidReload()
    }

    /// Remove one contact from the cache and notify. For our own delete. No
    /// store I/O.
    func removeContact(localID: String) {
        applyRemove(localID: localID)
        postDidReload()
    }

    // MARK: - External change subscription

    /// Handles the package's `.guessWhoContactsDidChange`. The watcher only posts
    /// when there is real work — an empty self-write delta is swallowed there and
    /// never reaches us — so every post is either an incremental delta to apply
    /// or a full-reload signal. `nonisolated` because the selector API delivers on
    /// the posting thread; we read the Sendable `userInfo` payload, then hop to
    /// the main actor to apply.
    @objc
    private nonisolated func contactsDidChange(_ note: Notification) {
        let changeSet = note.userInfo?[GuessWhoContactsDidChangeKey.changeSet] as? ContactChangeSet
        let requiresFullReload = note.userInfo?[GuessWhoContactsDidChangeKey.requiresFullReload] as? Bool ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if requiresFullReload {
                await self.reload()
            } else if let changeSet {
                await self.applyChangeSet(changeSet)
            }
        }
    }

    /// Apply an incremental external delta into the cache. Applies `changes` IN
    /// ORDER (a delete-then-readd of one localID must end present), under a
    /// SINGLE batched post — `applyRefresh`/`applyRemove` do NOT post, so the
    /// diffable lists apply one snapshot. Posts only when something changed.
    private func applyChangeSet(_ changeSet: ContactChangeSet) async {
        for change in changeSet.changes {
            switch change {
            case .updated(let localID):
                await applyRefresh(localID: localID)
            case .deleted(let localID):
                applyRemove(localID: localID)
            }
        }
        if !changeSet.changes.isEmpty {
            postDidReload()
        }
    }

    /// People (contactType == .person) matching `peopleSearch`, sorted
    /// case-insensitively by display name. An empty search returns all
    /// people.
    var people: [Contact] {
        filtered(matching: peopleSearch, where: { $0.contactType == .person })
    }

    /// Organizations (contactType == .organization) matching
    /// `organizationsSearch`, sorted case-insensitively by display name.
    var organizations: [Contact] {
        filtered(matching: organizationsSearch, where: { $0.contactType == .organization })
    }

    /// `people` grouped by section letter and sorted A-Z then "#".
    var peopleSections: [(String, [Contact])] {
        sectioned(people)
    }

    /// `organizations` grouped by section letter and sorted A-Z then "#".
    var organizationsSections: [(String, [Contact])] {
        sectioned(organizations)
    }

    func contact(localID: String) -> Contact? {
        contacts.first { $0.localID == localID }
    }

    // MARK: - Relation auto-linking

    /// Build a map keyed by `displayName` lowercased + trimmed so
    /// relation-text lookups can be O(1) per row. Multiple contacts can
    /// share a display name in pathological address books — last one wins;
    /// users with that case can disambiguate in Contacts.
    func lookupByDisplayName() -> [String: Contact] {
        var map: [String: Contact] = [:]
        for contact in contacts {
            let key = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            map[key] = contact
        }
        return map
    }

    /// Inbound relations: every OTHER contact whose `contactRelations`
    /// names this contact's display name. Self-filtering keys on
    /// `localID` — not displayName — so two distinct contacts that
    /// happen to share a name (two "Chris Smith" entries) still see each
    /// other's references. O(N·M) over the address book; fine at
    /// personal scale.
    func contactsReferencing(contact: Contact) -> [(contact: Contact, label: String)] {
        let needle = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var results: [(contact: Contact, label: String)] = []
        for other in contacts {
            if other.localID == contact.localID { continue }
            for relation in other.contactRelations {
                let key = relation.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key == needle {
                    results.append((contact: other, label: relation.label))
                }
            }
        }
        return results
    }

    // MARK: - Filtering

    private func filtered(
        matching query: String,
        where predicate: (Contact) -> Bool
    ) -> [Contact] {
        contacts
            .filter(predicate)
            .filter { $0.matches(searchQuery: query) }
            .sorted { lhs, rhs in
                let primary = lhs.lastNameSortKey.localizedCaseInsensitiveCompare(rhs.lastNameSortKey)
                if primary != .orderedSame { return primary == .orderedAscending }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func sectioned(_ contacts: [Contact]) -> [(String, [Contact])] {
        let grouped = Dictionary(grouping: contacts, by: { $0.sectionLetter })
        return grouped
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                switch (lhs.0, rhs.0) {
                case ("#", _): return false
                case (_, "#"): return true
                default: return lhs.0 < rhs.0
                }
            }
    }
}
