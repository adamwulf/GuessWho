import Foundation

extension Contact {
    /// Stable display label shared by package queries and app presentation.
    public var displayName: String {
        let personName = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
        if !personName.isEmpty { return personName }
        if !organizationName.isEmpty { return organizationName }
        if !nickname.isEmpty { return nickname }
        return "(Unnamed)"
    }

    public var lastNameSortKey: String {
        for candidate in [familyName, organizationName, givenName, nickname] {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Sort key for the `.firstLast` order: given name first, mirroring
    /// `lastNameSortKey`'s fallback chain but leading with `givenName`. A
    /// contact with no given name (an org, a single-name nickname-only record)
    /// falls back to the organization name, then family name, then nickname, so
    /// it still sorts sensibly. Empty only when the contact has no name at all.
    public var firstNameSortKey: String {
        for candidate in [givenName, organizationName, familyName, nickname] {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    public var sectionLetter: String {
        Contact.sectionLetter(for: lastNameSortKey)
    }

    /// Section letter for the `.firstLast` order — the leading A–Z letter of
    /// `firstNameSortKey` (or "#" for anything that doesn't fold to A–Z).
    public var firstNameSectionLetter: String {
        Contact.sectionLetter(for: firstNameSortKey)
    }

    /// Leading A–Z section letter of an arbitrary sort key, folding diacritics;
    /// "#" when the key is empty or its first letter isn't A–Z. Shared by the
    /// last-name and first-name section helpers so both bucket identically.
    static func sectionLetter(for sortKey: String) -> String {
        guard let scalar = sortKey.unicodeScalars.first(where: { !CharacterSet.whitespaces.contains($0) }) else {
            return "#"
        }
        let folded = String(scalar).folding(options: .diacriticInsensitive, locale: .current).uppercased()
        guard let first = folded.first, ("A"..."Z").contains(first) else { return "#" }
        return String(first)
    }

    /// Case-insensitive substring match across every field a user would
    /// reasonably search to find a contact: every name component, the
    /// organization/department/job, and the raw values of every email,
    /// phone number, and URL.
    ///
    /// Whitespace-only queries match every contact (treated as no filter).
    /// Used by the UI layer to filter the People and Organizations tabs.
    public func matches(searchQuery query: String) -> Bool {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if needle.isEmpty { return true }

        let scalarFields: [String] = [
            namePrefix, givenName, middleName,
            familyName, previousFamilyName, nameSuffix,
            nickname, phoneticGivenName, phoneticMiddleName,
            phoneticFamilyName,
            jobTitle, departmentName,
            organizationName, phoneticOrganizationName,
        ]
        for hay in scalarFields where hay.lowercased().contains(needle) {
            return true
        }
        for labeled in emailAddresses where labeled.value.lowercased().contains(needle) {
            return true
        }
        for labeled in phoneNumbers where labeled.value.lowercased().contains(needle) {
            return true
        }
        for labeled in urlAddresses where labeled.value.lowercased().contains(needle) {
            return true
        }
        return false
    }
}
