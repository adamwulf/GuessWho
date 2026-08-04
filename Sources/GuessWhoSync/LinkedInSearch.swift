import Foundation

/// Builds the LinkedIn *search* URL for a contact that carries no LinkedIn
/// profile yet, so the app can offer a "search" affordance where the profile
/// link would otherwise be. This is the mirror image of `LinkedInURL`, which
/// normalizes a profile URL the contact ALREADY has.
///
/// LinkedIn's search page takes free text in one `keywords` parameter — there
/// is no public facet parameter for a company name, so the company is folded
/// into the same keywords string (LinkedIn matches all the terms, which is the
/// intended narrowing).
public enum LinkedInSearch {
    /// Characters left unescaped in the `keywords` value. `urlQueryAllowed`
    /// minus the sub-delimiters that would change the query's structure or be
    /// read back as something else: `+` decodes to a space on most servers,
    /// and `&`/`=`/`?`/`#` would split the query. A space is not in
    /// `urlQueryAllowed`, so it becomes `%20`.
    private static let keywordsAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()

    /// `origin` tells LinkedIn where the search came from. It's telemetry, not a
    /// filter — the results page renders the same without it — but we send the
    /// value from a hand-verified working search URL rather than inventing one.
    private static let origin = "FACETED_SEARCH"

    /// The people-search results page for `keywords`. Returns nil for empty or
    /// whitespace-only keywords.
    public static func peopleURL(keywords: String) -> URL? {
        url(vertical: "people", keywords: keywords)
    }

    /// The company-search results page for `keywords`. Returns nil for empty or
    /// whitespace-only keywords.
    public static func companiesURL(keywords: String) -> URL? {
        url(vertical: "companies", keywords: keywords)
    }

    private static func url(vertical: String, keywords: String) -> URL? {
        let trimmed = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: keywordsAllowed),
              !encoded.isEmpty else {
            return nil
        }
        return URL(string: "https://www.linkedin.com/search/results/\(vertical)/?keywords=\(encoded)&origin=\(origin)")
    }

    /// The search a contact with no stored LinkedIn profile should link to:
    ///
    /// - A **person** searches people by name, narrowed by the organization
    ///   name when the contact has one.
    /// - An **organization** searches companies by the organization name only —
    ///   the record IS the company, so there is no person to look for.
    ///
    /// Returns nil when the contact has nothing to search on (no name, no
    /// nickname, no organization).
    public static func url(for contact: Contact) -> URL? {
        guard let keywords = keywords(for: contact) else { return nil }
        return contact.contactType == .organization
            ? companiesURL(keywords: keywords)
            : peopleURL(keywords: keywords)
    }

    /// The keywords `url(for:)` searches on. Split out so the app can show the
    /// user what a tap will look for, and so the two halves test separately.
    ///
    /// Deliberately NOT built from `Contact.displayName`: that falls back to
    /// "(Unnamed)", which would search for the literal placeholder.
    public static func keywords(for contact: Contact) -> String? {
        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if contact.contactType == .organization {
            return organization.isEmpty ? nil : organization
        }
        var name = "\(contact.givenName) \(contact.familyName)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A person record with no name at all but an organization still gets a
        // useful search — the company's people.
        if name.isEmpty {
            return organization.isEmpty ? nil : organization
        }
        return organization.isEmpty ? name : "\(name) \(organization)"
    }
}

extension Contact {
    /// True when this contact already carries a LinkedIn identity — a LinkedIn
    /// social profile with a username or URL, or a LinkedIn link among its
    /// websites. False means the app has nothing to link to and should offer a
    /// search instead (see `LinkedInSearch.url(for:)`).
    ///
    /// A LinkedIn social profile with NO username and NO URL doesn't count: an
    /// empty entry is not a handle.
    public var hasLinkedInProfile: Bool {
        let socialHit = socialProfiles.contains { labeled in
            let profile = labeled.value
            let isLinkedIn = profile.service.caseInsensitiveCompare("linkedin") == .orderedSame
                || labeled.label.caseInsensitiveCompare("linkedin") == .orderedSame
            guard isLinkedIn else {
                // A non-LinkedIn-labeled profile still counts when its stored
                // URL is a LinkedIn profile link.
                return LinkedInURL.isLinkedIn(profile.urlString)
            }
            let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlString = profile.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            return !username.isEmpty || !urlString.isEmpty
        }
        if socialHit { return true }
        return urlAddresses.contains { LinkedInURL.isLinkedIn($0.value) }
    }
}
