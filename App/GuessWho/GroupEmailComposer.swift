import Foundation
import GuessWhoSync

/// Pure helpers that turn a group's members into email recipients and the
/// `mailto:` URLs that address them. UIKit-free on purpose, so the recipient
/// rule and the URL construction are unit-testable without a running app — the
/// same split as `ContactContextMenuTargets` and `AddToGroupAlertCopy`.
///
/// "Email the group" means one message per member, addressed to their PRIMARY
/// (first) email — not every address a member owns — so a member with three
/// emails still receives a single copy. Members with no email are silently
/// dropped here; the caller decides what to tell the user when the whole group
/// yields nobody to write to.
enum GroupEmailComposer {
    /// The address each member is reached at: the FIRST email on the card, in
    /// member order, with duplicates removed. Two members sharing an address —
    /// or the same member surfacing twice in the transient pre-reconciliation
    /// window — are addressed exactly once. Comparison is case-insensitive
    /// (`Ada@x.com` and `ada@x.com` are one recipient); the first spelling seen
    /// is the one kept, since that is what the user typed on the card.
    static func recipients(for members: [Contact]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for member in members {
            guard let raw = member.emailAddresses.first?.value else { continue }
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, seen.insert(address.lowercased()).inserted else { continue }
            result.append(address)
        }
        return result
    }

    /// A single `mailto:` URL addressed to every recipient (comma-separated To),
    /// so one compose window opens with the whole group already in it. Nil when
    /// there are no recipients.
    static func combinedMailtoURL(recipients: [String]) -> URL? {
        guard !recipients.isEmpty else { return nil }
        let joined = recipients.map(encoded).joined(separator: ",")
        return URL(string: "mailto:\(joined)")
    }

    /// One `mailto:` URL per recipient, in recipient order — the "email each
    /// member separately" path, one compose window each. Empty when there are no
    /// recipients.
    static func individualMailtoURLs(recipients: [String]) -> [URL] {
        recipients.compactMap { URL(string: "mailto:\(encoded($0))") }
    }

    /// Percent-encode one address for the path of a `mailto:` URL. The comma that
    /// separates addresses in the combined URL is applied by the caller and never
    /// passes through here, so it always stays a separator rather than being
    /// encoded into an address.
    private static func encoded(_ address: String) -> String {
        address.addingPercentEncoding(withAllowedCharacters: mailtoAllowed) ?? address
    }

    /// Characters left unescaped inside a `mailto:` address: alphanumerics plus
    /// the handful of punctuation marks that appear in ordinary addresses.
    /// Deliberately conservative — anything else (spaces, non-ASCII, and the
    /// URL/`mailto:`-significant `?`, `&`, `=`, `/`, `#`, `,`) is percent-encoded,
    /// which Mail decodes back on the way in. Encoding too much is harmless;
    /// leaving a `?` raw would truncate the address into a header, so it is not.
    private static let mailtoAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "@._-+")
        return set
    }()
}
