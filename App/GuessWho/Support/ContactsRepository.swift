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

    /// Per-tab search query for People. Bound by the PeopleListView via
    /// `.searchable($repository.peopleSearch)` so switching tabs does not
    /// clobber the other tab's query.
    var peopleSearch: String = ""
    /// Per-tab search query for Organizations.
    var organizationsSearch: String = ""

    init(service: SyncService) {
        self.service = service
    }

    func reload() async {
        isLoading = true
        contacts = await service.fetchAll()
        // Flip isLoading BEFORE posting so synchronous observers (the
        // UIKit `ContactsListViewController` subscribes via
        // `addObserver(self, selector:, …)`, which delivers on the
        // posting thread before this function's stack frame unwinds)
        // see the post-load state. A `defer { isLoading = false }`
        // would fire AFTER the observer ran, leaving a UIKit list with
        // zero contacts spinning forever waiting for the second event
        // that flips the flag.
        isLoading = false
        NotificationCenter.default.post(name: .contactsRepositoryDidReload, object: self)
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
