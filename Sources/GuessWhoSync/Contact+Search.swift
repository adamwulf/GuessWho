import Foundation

extension Contact {
    /// The `displayName` of a contact with no name at all. Exposed so callers
    /// that build lists of names (autocomplete candidates) can skip it instead
    /// of matching the literal.
    public static let unnamedDisplayName = "(Unnamed)"

    /// True for an organization record that has an organization name. That name
    /// is what the record is called; a given or family name on the same card
    /// (the person to ask for at the company, say) never replaces it.
    public var isNamedByOrganization: Bool {
        contactType == .organization
            && !organizationName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The given and family names joined. Empty when the card has neither.
    var personName: String {
        "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
    }

    /// Stable display label shared by package queries and app presentation.
    public var displayName: String {
        if isNamedByOrganization { return organizationName.trimmingCharacters(in: .whitespaces) }
        return personFirstName
    }

    /// The person name, else the organization name, else the nickname. This is
    /// `displayName` for every record but an organization named by its
    /// organization name, and the name `deterministicGuessWhoID` hashes, so
    /// marking a named person's card as an organization can't change that id.
    var personFirstName: String {
        if !personName.isEmpty { return personName }
        if !organizationName.isEmpty { return organizationName }
        if !nickname.isEmpty { return nickname }
        return Self.unnamedDisplayName
    }

    public var lastNameSortKey: String {
        if isNamedByOrganization { return organizationName.trimmingCharacters(in: .whitespaces) }
        for candidate in [familyName, organizationName, givenName, nickname] {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Sort key for the `.firstLast` order: given name first, mirroring
    /// `lastNameSortKey`'s fallback chain but leading with `givenName`. A
    /// contact with no given name (a single-name nickname-only record) falls
    /// back to the organization name, then family name, then nickname, so it
    /// still sorts sensibly. An organization named by its organization name
    /// sorts by that name, as it does in the `.lastFirst` order. Empty only when
    /// the contact has no name at all.
    public var firstNameSortKey: String {
        if isNamedByOrganization { return organizationName.trimmingCharacters(in: .whitespaces) }
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
    /// The query is split on whitespace into terms, and the contact matches
    /// only when **every** term is found in **some** field — the fields need
    /// not be the same. This lets "Adam Wulf" match a contact whose given name
    /// is "Adam" and family name is "Wulf", where neither field on its own
    /// contains the whole phrase.
    ///
    /// Whitespace-only queries match every contact (treated as no filter).
    /// Used by the UI layer to filter the People and Organizations tabs.
    public func matches(searchQuery query: String) -> Bool {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if terms.isEmpty { return true }

        let scalarFields: [String] = [
            namePrefix, givenName, middleName,
            familyName, previousFamilyName, nameSuffix,
            nickname, phoneticGivenName, phoneticMiddleName,
            phoneticFamilyName,
            jobTitle, departmentName,
            organizationName, phoneticOrganizationName,
        ]
        let haystacks: [String] =
            scalarFields.map { $0.lowercased() }
            + emailAddresses.map { $0.value.lowercased() }
            + phoneNumbers.map { $0.value.lowercased() }
            + urlAddresses.map { $0.value.lowercased() }

        // AND across terms: every term must appear in at least one field.
        return terms.allSatisfy { term in
            haystacks.contains { $0.contains(term) }
        }
    }
}
