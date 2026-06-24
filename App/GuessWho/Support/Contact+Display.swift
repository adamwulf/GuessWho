import Foundation
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

}
