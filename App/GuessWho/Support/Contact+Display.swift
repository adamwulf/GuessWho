import Foundation
import UIKit
import GuessWhoSync

extension Contact {
    /// Up-to-two-letter monogram for avatar fallbacks. For people, takes
    /// the first letter of givenName + the first letter of familyName.
    /// Organizations and nickname-only contacts fall back to the first
    /// one or two letters of displayName. Returns an empty string if the
    /// contact is "(Unnamed)".
    var initials: String {
        let given = givenName.trimmingCharacters(in: .whitespaces)
        let family = familyName.trimmingCharacters(in: .whitespaces)
        if !isNamedByOrganization, !given.isEmpty || !family.isEmpty {
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

    /// The nickname in quotes, ready to sit between the given and family names
    /// — `"Kathy"` for Kejing "Kathy" Zhang. Empty when there's no nickname, or
    /// when it only repeats a name already standing next to it, so nobody reads
    /// `Kathy "Kathy" Zhang`.
    private var quotedNickname: String {
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        guard !nick.isEmpty else { return "" }
        let neighbors = [givenName, familyName].map { $0.trimmingCharacters(in: .whitespaces) }
        guard !neighbors.contains(where: { nick.localizedCaseInsensitiveCompare($0) == .orderedSame }) else {
            return ""
        }
        return "\"\(nick)\""
    }

    /// The nickname quoted between the given and family names — `Kejing "Kathy"
    /// Zhang`. Empty for a card with neither a given nor a family name, where a
    /// lone quoted nickname would read as a scare quote rather than an alias.
    var personNameWithNickname: String {
        let given = givenName.trimmingCharacters(in: .whitespaces)
        let family = familyName.trimmingCharacters(in: .whitespaces)
        guard !given.isEmpty || !family.isEmpty else { return "" }
        return [given, quotedNickname, family]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `personNameWithNickname`, or `displayName` for an organization named by
    /// its organization name and for a card with no person name.
    var displayNameWithNickname: String {
        let personName = personNameWithNickname
        guard !isNamedByOrganization, !personName.isEmpty else { return displayName }
        return personName
    }

    /// The name a relation row shows after the relation's `relationName` resolved
    /// to this contact: what the contact is called, unless the relation found an
    /// organization through the person name on its card, which keeps showing that
    /// person.
    func nameForRelation(named relationName: String) -> String {
        let key = relationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let called = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return called == key ? displayName : relationName
    }

    /// The contact editor's title: what the card is called so far, or a
    /// placeholder while a new card has no name.
    var editorTitle: String {
        if isNamedByOrganization { return displayName }
        let name = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if !organizationName.isEmpty { return organizationName }
        return contactType == .organization ? "New Organization" : "New Contact"
    }

    /// `displayNameWithNickname` at the body text style, with the family name
    /// bold so it's the one heavier run in a list row — the given name and the
    /// quoted nickname share the regular weight. Shared by every contact-row
    /// cell so the lists stay typographically identical.
    var nameAttributedString: NSAttributedString {
        let given = givenName.trimmingCharacters(in: .whitespaces)
        let family = familyName.trimmingCharacters(in: .whitespaces)
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? bodyFont.fontDescriptor
        let boldFont = UIFont(descriptor: boldDescriptor, size: bodyFont.pointSize)

        guard !isNamedByOrganization, !given.isEmpty || !family.isEmpty else {
            return NSAttributedString(string: displayName, attributes: [.font: bodyFont])
        }

        let attributed = NSMutableAttributedString()
        let lead = [given, quotedNickname].filter { !$0.isEmpty }.joined(separator: " ")
        if !lead.isEmpty {
            attributed.append(NSAttributedString(
                string: family.isEmpty ? lead : lead + " ",
                attributes: [.font: bodyFont]
            ))
        }
        if !family.isEmpty {
            attributed.append(NSAttributedString(string: family, attributes: [.font: boldFont]))
        }
        return attributed
    }
}
