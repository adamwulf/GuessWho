import Foundation

/// Cleans up text entered into a contact's email-address field.
///
/// Lives in `GuessWhoSync` (not the app target) for the same reason
/// `TextSuggestionFilter` does: the rules are exercisable from
/// `GuessWhoSyncTests` without an app-target test bundle.
///
/// Mail clients copy an address in display-name form —
/// `Saira Cooper <saira.cooper@rice.edu>` — so that is what lands in the
/// field when the user pastes one. Only the bracketed address belongs in an
/// email field, so that form collapses to the address alone.
public enum EmailAddressFieldInput {
    /// The bracketed address when `text` is a single display-name address,
    /// with its case kept as entered; otherwise `text` exactly as given.
    ///
    /// The field runs this on every edit, so anything that isn't a complete
    /// display-name address — a bare address, or one still being typed — must
    /// come back untouched, whitespace included.
    ///
    /// The match is deliberately narrow: the trimmed text must end with `>`,
    /// hold exactly one `<` and one `>`, and the part between them must look
    /// like an address (one `@` with text on both sides, no whitespace). A
    /// paste of several addresses (`A <a@x.com>, B <b@x.com>`) has more than
    /// one bracket pair and is left for the user to fix rather than silently
    /// cut down to one address.
    public static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(">"),
              trimmed.count(where: { $0 == "<" }) == 1,
              trimmed.count(where: { $0 == ">" }) == 1,
              let open = trimmed.firstIndex(of: "<")
        else { return text }

        let close = trimmed.index(before: trimmed.endIndex)
        let address = trimmed[trimmed.index(after: open)..<close]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !address.contains(where: \.isWhitespace)
        else { return text }
        return address
    }
}
