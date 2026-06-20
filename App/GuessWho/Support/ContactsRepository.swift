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

    func contact(localID: String) -> Contact? {
        contacts.first { $0.localID == localID }
    }

    // MARK: - Filtering

    private func filtered(
        matching query: String,
        where predicate: (Contact) -> Bool
    ) -> [Contact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = contacts.filter(predicate)
        let matched: [Contact]
        if trimmed.isEmpty {
            matched = base
        } else {
            matched = base.filter { Self.matches($0, query: trimmed) }
        }
        return matched.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Substring search across the fields a user would reasonably search
    /// to find someone: every name component, the organization+job, and
    /// the raw values of every email / phone / URL. Case-insensitive.
    static func matches(_ contact: Contact, query: String) -> Bool {
        let needle = query.lowercased()
        var haystack: [String] = [
            contact.namePrefix, contact.givenName, contact.middleName,
            contact.familyName, contact.previousFamilyName, contact.nameSuffix,
            contact.nickname, contact.phoneticGivenName, contact.phoneticMiddleName,
            contact.phoneticFamilyName,
            contact.jobTitle, contact.departmentName,
            contact.organizationName, contact.phoneticOrganizationName,
        ]
        haystack.append(contentsOf: contact.emailAddresses.map(\.value))
        haystack.append(contentsOf: contact.phoneNumbers.map(\.value))
        haystack.append(contentsOf: contact.urlAddresses.map(\.value))
        for hay in haystack where hay.lowercased().contains(needle) { return true }
        return false
    }
}
