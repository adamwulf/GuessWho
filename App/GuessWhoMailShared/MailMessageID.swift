import Foundation

/// RFC 5322 `Message-ID` handling for the incoming-message journal.
enum MailMessageID {

    /// The longest canonical id we accept, in UTF-8 bytes (brackets
    /// included): RFC 5322's 998-octet line limit, less the `Message-ID: `
    /// field name.
    static let maximumUTF8Length = 986

    /// The canonical `<id-left@id-right>` form of a `Message-ID` header value,
    /// or nil when the value holds no usable id. This is the journal's
    /// de-duplication key, so it is intentionally lenient (it keeps ids that
    /// are unsafe to put in a URL); `mailDeepLink(for:)` applies the strict
    /// check separately.
    ///
    /// Takes the first `<…>` token when present (a header may carry comments
    /// around it); otherwise a bare token is wrapped in brackets. Case is
    /// preserved — Message-IDs are case-sensitive.
    static func normalize(_ headerValue: String) -> String? {
        let trimmed = headerValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: Substring
        if let open = trimmed.firstIndex(of: "<") {
            guard let close = trimmed[open...].firstIndex(of: ">") else { return nil }
            body = trimmed[trimmed.index(after: open)..<close]
        } else {
            body = Substring(trimmed)
        }
        guard !body.isEmpty,
              body.utf8.count + 2 <= maximumUTF8Length,
              !body.unicodeScalars.contains(where: isDisallowedInID)
        else { return nil }
        return "<\(body)>"
    }

    /// True when `messageID` (canonical `<…>` form) is plain enough to embed
    /// in a URL: exactly one `@`, and both sides RFC 5322 dot-atom text in
    /// ASCII (no quoted strings, no domain literals, no empty dot segments).
    static func isSyntacticallySafe(_ messageID: String) -> Bool {
        guard messageID.hasPrefix("<"), messageID.hasSuffix(">"),
              messageID.utf8.count <= maximumUTF8Length
        else { return false }
        let body = messageID.dropFirst().dropLast()
        let sides = body.split(separator: "@", omittingEmptySubsequences: false)
        guard sides.count == 2 else { return false }
        return sides.allSatisfy(isDotAtomText)
    }

    /// A best-effort `message://` link that asks Apple Mail to open the
    /// message with `messageID`, or nil when the id isn't syntactically safe.
    ///
    /// UNDOCUMENTED: Apple has never documented the `message:` URL scheme.
    /// Mail has long answered `message://%3C<id>%3E`, but it may change or
    /// stop working in any release, and it only finds messages Mail still has
    /// locally. Treat the link as a convenience; nothing may depend on it
    /// resolving, and recording activity must never depend on building it.
    static func mailDeepLink(for messageID: String) -> URL? {
        guard isSyntacticallySafe(messageID),
              let encoded = messageID.addingPercentEncoding(withAllowedCharacters: deepLinkAllowed)
        else { return nil }
        return URL(string: "message://\(encoded)")
    }

    // MARK: - Character classes

    /// Everything but the unreserved set and `@` is percent-encoded, so the
    /// brackets become `%3C`/`%3E` and atext punctuation (`+`, `=`, `/`, `%`,
    /// …) can't be misread as URL syntax.
    private static let deepLinkAllowed: CharacterSet = {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@")
        return allowed
    }()

    /// RFC 5322 `atext`: ASCII letters, digits, and these symbols.
    private static let atextSymbols = Set("!#$%&'*+-/=?^_`{|}~".unicodeScalars)

    private static func isAtext(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": return true
        default: return atextSymbols.contains(scalar)
        }
    }

    /// `1*atext *("." 1*atext)`
    private static func isDotAtomText(_ text: Substring) -> Bool {
        let segments = text.split(separator: ".", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy(isAtext)
        }
    }

    private static func isDisallowedInID(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.controlCharacters.contains(scalar)
            || scalar == "<"
            || scalar == ">"
    }
}
