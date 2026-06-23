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

    /// Up-to-two-letter monogram for avatar fallbacks. For people, takes
    /// the first letter of givenName + the first letter of familyName.
    /// Organizations and nickname-only contacts fall back to the first
    /// one or two letters of displayName. Returns an empty string if the
    /// contact is "(Unnamed)".
    var initials: String {
        let given = givenName.trimmingCharacters(in: .whitespaces)
        let family = familyName.trimmingCharacters(in: .whitespaces)
        if !given.isEmpty || !family.isEmpty {
            let g = given.first.map { String($0) } ?? ""
            let f = family.first.map { String($0) } ?? ""
            return (g + f).uppercased()
        }
        let fallback = displayName
        if fallback == "(Unnamed)" { return "" }
        let words = fallback.split { $0.isWhitespace }
        if let first = words.first, let last = words.dropFirst().first {
            return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
        }
        return String(fallback.prefix(2)).uppercased()
    }

    /// Section header letter for the contact list. Returns the first
    /// A-Z letter of `lastNameSortKey` (diacritic-folded, uppercased);
    /// anything else (digits, symbols, non-Latin scripts, empty)
    /// buckets under "#".
    var sectionLetter: String {
        guard let scalar = lastNameSortKey.unicodeScalars.first(where: { !CharacterSet.whitespaces.contains($0) }) else {
            return "#"
        }
        let folded = String(scalar).folding(options: .diacriticInsensitive, locale: .current).uppercased()
        guard let first = folded.first, ("A"..."Z").contains(first) else {
            return "#"
        }
        return String(first)
    }
}
