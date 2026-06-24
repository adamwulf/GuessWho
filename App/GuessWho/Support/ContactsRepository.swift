import Foundation
import GuessWhoSync

/// Presentation-only projections over the package-owned contact repository.
/// Cache ownership and contact-store change handling live in GuessWhoSync;
/// search, sorting, and sectioning remain here because they are UI policy.
extension ContactsRepository {
    var peopleSearch: String {
        get { ContactRepositoryPresentationState.peopleSearch }
        set { ContactRepositoryPresentationState.peopleSearch = newValue }
    }

    var organizationsSearch: String {
        get { ContactRepositoryPresentationState.organizationsSearch }
        set { ContactRepositoryPresentationState.organizationsSearch = newValue }
    }

    var people: [Contact] {
        filtered(matching: peopleSearch, where: { $0.contactType == .person })
    }

    var organizations: [Contact] {
        filtered(matching: organizationsSearch, where: { $0.contactType == .organization })
    }

    var peopleSections: [(String, [Contact])] { sectioned(people) }
    var organizationsSections: [(String, [Contact])] { sectioned(organizations) }

    func lookupByDisplayName() -> [String: Contact] {
        var map: [String: Contact] = [:]
        for contact in contacts {
            let key = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            map[key] = contact
        }
        return map
    }

    func contactsReferencing(contact: Contact) -> [(contact: Contact, label: String)] {
        let needle = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return contacts.flatMap { other in
            guard other.localID != contact.localID else { return [] }
            return other.contactRelations.compactMap { relation in
                let name = relation.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return name == needle ? (contact: other, label: relation.label) : nil
            }
        }
    }

    private func filtered(matching query: String, where predicate: (Contact) -> Bool) -> [Contact] {
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
        Dictionary(grouping: contacts, by: \.sectionLetter)
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

/// The package repository intentionally has no search state. This temporary
/// app-owned state preserves the current per-tab UIKit behavior while the UI
/// is migrated from adapter-local IDs to GuessWho contact IDs.
@MainActor
private enum ContactRepositoryPresentationState {
    static var peopleSearch = ""
    static var organizationsSearch = ""
}
