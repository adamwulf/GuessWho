import GuessWhoSync

/// Single source of truth for the contact-avatar placeholder color *index*.
///
/// Both the UIKit (`ContactAvatarImage`) and SwiftUI (`ContactAvatar`)
/// placeholder paths call `index(for:)` so the seed string, the `&*31 / &+`
/// hash, and the `% count` modulo math live in exactly one place — a one-sided
/// edit can no longer silently break known-vs-unknown placeholder parity. Each
/// path keeps its own same-ordered palette of framework colors (UIKit
/// `UIColor` vs. SwiftUI `Color`) and maps this index into it.
enum ContactAvatarPalette {
    /// Number of colors in each path's palette. The per-path palette arrays MUST
    /// stay this length and in the same order (blue, green, indigo, orange,
    /// pink, purple, red, teal) so a shared index lands on the matching color.
    static let count = 8

    /// Deterministic palette index for a contact, in `0..<count`. Seeded on
    /// `"\(contactType)-\(displayName)"` so the same contact always resolves to
    /// the same slot across both rendering paths.
    static func index(for contact: Contact) -> Int {
        let seed = "\(contact.contactType)-\(contact.displayName)"
        let value = seed.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        return abs(value) % count
    }
}
