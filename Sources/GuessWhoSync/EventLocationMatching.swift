import Foundation

/// Best-effort matcher between a contact's structured street address and an
/// event's free-text `location` string.
///
/// An `Event.location` is whatever the calendar carried verbatim
/// ("1 Infinite Loop, Cupertino, CA 95014", "Conference Room B", a Zoom URL,
/// or nothing), while a contact address is structured. To decide whether a
/// contact "belongs" at an event's location we look for the contact's street
/// line as a contiguous run of words inside the event location text — a street
/// line ("1 Infinite Loop") is specific enough to be a strong signal, whereas
/// city/state alone would sweep in every unrelated venue in the same town.
///
/// Matching is token-based (not raw substring) so word boundaries are
/// respected: needle "1 Main" does NOT match haystack "21 Main St". Needles
/// shorter than two tokens are ignored — a single word ("Broadway") is too
/// generic to match safely.
public enum EventLocationMatcher {
    /// Lowercase `text` and split it into word tokens on any run of
    /// non-alphanumeric characters. "1 Infinite Loop, Cupertino" →
    /// `["1", "infinite", "loop", "cupertino"]`.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// True iff `needle` occurs as a contiguous run within `haystack`.
    static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let lastStart = haystack.count - needle.count
        var start = 0
        while start <= lastStart {
            var matched = true
            for offset in needle.indices where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
            start += 1
        }
        return false
    }

    /// True iff `location` contains any street line in `needles` as a
    /// contiguous run of words (case-insensitive). Needles that tokenize to
    /// fewer than two words are skipped. Returns false for a nil/empty
    /// location or an empty needle set.
    public static func matches(location: String?, anyOf needles: Set<String>) -> Bool {
        guard let location, !needles.isEmpty else { return false }
        let haystack = tokens(location)
        guard !haystack.isEmpty else { return false }
        for needle in needles {
            let needleTokens = tokens(needle)
            guard needleTokens.count >= 2 else { continue }
            if containsRun(haystack, needleTokens) { return true }
        }
        return false
    }

    /// Known video-call / meeting hosts. An `Event.location` that reads as one
    /// of these — with or without a scheme ("https://zoom.us/j/123", but also a
    /// bare "meet.google.com/abc-defg") — is a virtual join link, not a place.
    private static let videoCallHosts: [String] = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "gotomeeting.com",
        "gotomeet.me",
        "bluejeans.com",
        "whereby.com",
        "meet.jit.si",
        "chime.aws",
        "skype.com",
    ]

    /// True iff `location` names a real, physical place: non-empty AND not a
    /// web/video-call link. Powers the Events list's "Physical Location"
    /// filter. Excludes anything that reads as a URL — a `scheme://…` link (any
    /// scheme, so `zoommtg://` and custom join schemes count), a bare
    /// "https"-less web address whose sole content is a domain/path, or a
    /// string carrying a known video-call host. A normal street address or
    /// venue name ("1 Infinite Loop, Cupertino", "Conference Room B") is kept.
    public static func isPhysicalLocation(_ location: String?) -> Bool {
        guard let location else { return false }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !isURLLike(trimmed)
    }

    /// True iff `text` reads as a URL / video-call link rather than a place.
    /// `text` is assumed already trimmed and non-empty.
    static func isURLLike(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Any explicit scheme ("scheme://…") reads as a link. Guard against a
        // false "://" hiding mid-address by requiring the scheme to sit at the
        // start of the (single-token) string.
        if let schemeRange = lower.range(of: "://"),
           !lower[..<schemeRange.lowerBound].contains(where: { $0 == " " }) {
            return true
        }

        // A known video-call host anywhere in the text is a join link even
        // without a scheme (calendars often store a bare "meet.google.com/…").
        for host in videoCallHosts where lower.contains(host) {
            return true
        }

        // A bare web address with no scheme: the WHOLE trimmed string is one
        // token (no spaces) that looks like "host.tld" or "host.tld/path".
        // Requiring single-token form keeps "1 Infinite Loop, Cupertino, CA"
        // (which contains dots/commas but also spaces) classified as a place.
        if !lower.contains(where: { $0 == " " }),
           lower.contains("."),
           looksLikeBareWebAddress(lower) {
            return true
        }

        return false
    }

    /// True iff a single-token, space-free `text` looks like "host.tld" or
    /// "host.tld/path" — a domain label, a dot, a top-level-domain-like label
    /// of at least two letters, optionally followed by a "/path". Rejects plain
    /// decimals and "Room 2.1"-style tokens (no letter-only TLD after the dot).
    private static func looksLikeBareWebAddress(_ text: String) -> Bool {
        // Strip any path so we validate only the host portion.
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Need at least a "name.tld" shape.
        guard labels.count >= 2 else { return false }
        // Every label must be a non-empty run of URL-ish characters, and the
        // final label (the TLD) must be at least two letters — that letter-only
        // TLD is what separates "meet.google.com" from "Room 2.1".
        guard let tld = labels.last,
              tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}
