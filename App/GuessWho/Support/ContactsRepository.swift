import Foundation
import GuessWhoSync

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
        defer { isLoading = false }
        contacts = service.fetchAll()
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
                case ("#", "#"): return false
                case ("#", _): return false
                case (_, "#"): return true
                default: return lhs.0 < rhs.0
                }
            }
    }
}
