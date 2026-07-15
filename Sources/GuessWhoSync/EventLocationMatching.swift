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
}
