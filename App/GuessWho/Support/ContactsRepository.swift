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
final class ContactsRepository {
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

    /// Guards `applyExternalChanges()` against overlapping invocations. Two
    /// `.CNContactStoreDidChange` notifications can land back-to-back; without
    /// this, the second could interleave a half-applied delta. `@MainActor`
    /// makes the check-and-set atomic.
    private var isApplyingExternalChanges = false

    /// Set when a `.CNContactStoreDidChange` arrives while a run is already in
    /// flight. Without it, a write that commits AFTER the in-flight run's
    /// `contactChanges(since:)` read but whose notification lands DURING the
    /// apply would be stranded until the next unrelated store change — because
    /// the cursor advances past it. Draining this flag in the `defer` re-runs
    /// once more to pick up exactly that window. Coalesces multiple rejected
    /// notifications into a single re-run.
    private var externalChangesPending = false

    init(service: SyncService) {
        self.service = service
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

    /// Apply the external contact-store delta since our last cursor — the
    /// response to `.CNContactStoreDidChange`. Our own writes are tagged with a
    /// `transactionAuthor` and excluded by the adapter, so this only sees edits
    /// made in Contacts.app (or another app/device). Re-reads only the changed
    /// records, not all ~1500.
    ///
    /// Contract (see plans/contact-reload-optimization.md):
    /// - On `requiresFullReload` (first run / DropEverything / throw) → full
    ///   `reload()`, then persist the fresh baseline cursor.
    /// - Otherwise apply `changes` IN ORDER (a delete-then-readd of one localID
    ///   must end present), under a SINGLE batched post — no per-change snapshot
    ///   storm. An empty delta posts NOTHING (a self-write still fires
    ///   `.CNContactStoreDidChange`, but its delta is empty after author
    ///   exclusion) while still advancing the cursor.
    /// - Persist the cursor ONLY after a successful apply, on BOTH branches, so a
    ///   crash mid-apply re-processes rather than skips.
    ///
    /// Overlap handling: if a notification arrives mid-run, `externalChangesPending`
    /// is set and drained by a single extra pass after the current one finishes,
    /// so a write whose notification lands during the apply is never stranded.
    func applyExternalChanges() async {
        guard !isApplyingExternalChanges else {
            // A run is in flight. Mark that another pass is needed rather than
            // dropping this notification — the in-flight run advances the cursor,
            // so without a re-run a write that committed after its history read
            // would be stranded until the next unrelated store change.
            externalChangesPending = true
            return
        }
        isApplyingExternalChanges = true
        defer { isApplyingExternalChanges = false }

        // Run at least once; re-run while a notification arrived mid-apply.
        repeat {
            externalChangesPending = false
            await applyExternalChangesOnce()
        } while externalChangesPending
    }

    private func applyExternalChangesOnce() async {
        let token = service.loadContactCursor()
        let changeSet: ContactChangeSet
        do {
            changeSet = try await service.contactChanges(since: token)
        } catch {
            // Auth / I-O failure reading history → safest recovery is a full
            // reload; leave the cursor untouched so the next attempt retries
            // from the same point.
            lastError = "contact change read failed: \(error.localizedDescription)"
            await reload()
            return
        }

        if changeSet.requiresFullReload {
            await reload()
            service.saveContactCursor(changeSet.newToken)
            return
        }

        // Apply in history order so delete-then-readd of the same localID ends
        // with the contact present. applyRefresh/applyRemove do NOT post — we
        // post once at the end so the diffable lists apply a single snapshot.
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
        // Advance the cursor even on an empty delta — the history position moved
        // (e.g. our own excluded writes), so the next read should start after it.
        service.saveContactCursor(changeSet.newToken)
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
