import Foundation
import GuessWhoSync

extension Contact {
    /// User-facing display label. Falls back through given+family →
    /// organization → nickname → "(Unnamed)". Shared by every list row
    /// and detail header so the same contact never appears under
    /// different names across screens.
    var displayName: String {
        let personName = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
        if !personName.isEmpty { return personName }
        if !organizationName.isEmpty { return organizationName }
        if !nickname.isEmpty { return nickname }
        return "(Unnamed)"
    }

    /// Field used to alphabetize contacts. Organizations may have no
    /// family name, and some people only have an org or nickname, so we
    /// fall back through familyName → organizationName → givenName →
    /// nickname before giving up.
    var lastNameSortKey: String {
        for candidate in [familyName, organizationName, givenName, nickname] {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Section header letter for the contact list. Returns the first
    /// A-Z letter of `lastNameSortKey` uppercased; anything else
    /// (digits, symbols, non-Latin scripts, empty) buckets under "#".
    var sectionLetter: String {
        guard let scalar = lastNameSortKey.unicodeScalars.first(where: { !CharacterSet.whitespaces.contains($0) }) else {
            return "#"
        }
        let upper = String(scalar).uppercased()
        guard let first = upper.first, ("A"..."Z").contains(first) else {
            return "#"
        }
        return String(first)
    }
}
