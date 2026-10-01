import Foundation

/// The ONE email-address normalization shared by the app (which keys the
/// contact cache) and the Mail extension (which looks senders and recipients
/// up in it). Both sides must go through `normalize(_:)`; a key built any
/// other way silently never matches.
///
/// Foundation-only: this file compiles into both the Mac Catalyst app and the
/// native macOS Mail extension.
enum MailAddressNormalizer {

    /// The longest address accepted, in UTF-8 bytes: RFC 5321's 64-octet
    /// local part, `@`, and 255-octet domain. Real addresses are far shorter
    /// (SMTP paths cap them at 254 octets); anything longer is not an
    /// address, and rejecting it bounds what a sender can make us store.
    /// Bytes, not characters, so multi-byte text can't slip past the bound.
    static let maximumUTF8Length = 320

    /// Returns the lowercased bare address (`local@domain`) from `raw`, or nil
    /// when `raw` doesn't hold a plausible address.
    ///
    /// Accepts the shapes Mail and Contacts hand us: a bare address, a
    /// display-name form (`"Name" <local@domain>`), and a `mailto:` URL
    /// string (its query is dropped). The whole address is lowercased: the
    /// local part is technically case-sensitive per RFC 5321, but no real
    /// mail provider treats it that way, and a case-sensitive key would miss
    /// the same person typed two ways.
    ///
    /// The validity check is deliberately shallow — exactly one `@`, a
    /// non-empty local part and domain, no whitespace, control characters, or
    /// angle brackets. Quoted local parts that contain `@` are rejected; they
    /// are vanishingly rare and not worth a full RFC 5322 parser here.
    static func normalize(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Display-name form: keep the LAST bracketed part, since a display
        // name may itself contain "<" in a quoted string.
        if let open = candidate.lastIndex(of: "<") {
            guard let close = candidate[open...].firstIndex(of: ">") else { return nil }
            candidate = String(candidate[candidate.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if candidate.range(of: "mailto:", options: [.caseInsensitive, .anchored]) != nil {
            candidate = String(candidate.dropFirst("mailto:".count))
            if let query = candidate.firstIndex(of: "?") {
                candidate = String(candidate[..<query])
            }
            candidate = candidate.removingPercentEncoding ?? candidate
        }

        // A fully-qualified domain may carry a trailing root dot.
        if candidate.hasSuffix(".") {
            candidate.removeLast()
        }

        let lowered = candidate.lowercased()
        guard lowered.utf8.count <= maximumUTF8Length else { return nil }
        let parts = lowered.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard !lowered.unicodeScalars.contains(where: isDisallowed) else { return nil }
        return lowered
    }

    /// The display name in `raw` (`"Jane Doe" <jane@example.com>` → `Jane
    /// Doe`), or nil when `raw` has none.
    ///
    /// The name is the text before the LAST `<`, trimmed. When it is a quoted
    /// string, the surrounding double quotes are removed and each
    /// backslash-escaped character (`\"`, `\\`) is unescaped. Then one pair of
    /// surrounding single quotes is removed too, because Outlook writes names
    /// as `'Jane Doe' <jane@example.com>`. Returns nil when `raw` has no `<`
    /// (a bare address), when the name is empty, or when it is only the
    /// address again. Best effort, not an RFC 5322 parser: comments, encoded
    /// words, and group syntax come back as written.
    static func displayName(_ raw: String) -> String? {
        guard let open = raw.lastIndex(of: "<") else { return nil }
        var name = raw[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            var unquoted = ""
            var escaped = false
            for character in name.dropFirst().dropLast() {
                if escaped || character != "\\" {
                    unquoted.append(character)
                    escaped = false
                } else {
                    escaped = true
                }
            }
            name = unquoted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") {
            name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty else { return nil }
        if let address = normalize(raw), name.caseInsensitiveCompare(address) == .orderedSame {
            return nil
        }
        return name
    }

    private static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.controlCharacters.contains(scalar)
            || scalar == "<"
            || scalar == ">"
    }
}
