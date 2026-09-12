import Foundation

/// Pure ranking + filtering behind every autocompleting text field.
///
/// Lives in `GuessWhoSync` (not the app target) for the same reason
/// `ContactEditModel` does: the matching rules are exercisable from
/// `GuessWhoSyncTests` without an app-target test bundle. No UI types here —
/// the app's autocomplete field hands this a query and a candidate list and
/// renders whatever comes back.
///
/// Matching is case- and diacritic-insensitive and ranks candidates in three
/// tiers, each tier keeping the candidates' incoming order:
///
/// 1. **Prefix** — the candidate starts with the query (`"ac"` → `"Acme"`).
/// 2. **Word prefix** — some later word starts with the query
///    (`"wulf"` → `"Adam Wulf"`).
/// 3. **Substring** — the query appears anywhere else (`"cme"` → `"Acme"`).
///
/// A candidate equal to the query (after normalization) is never suggested:
/// the user has already typed it, so offering it back is noise. Blank
/// candidates are dropped and duplicates collapse to the first spelling seen.
public enum TextSuggestionFilter {
    /// Default cap on the number of suggestions returned.
    public static let defaultLimit = 8

    /// The candidates that match `query`, best first, at most `limit` of them.
    /// A blank query yields nothing — suggestions appear as the user types,
    /// not on focus.
    public static func suggestions(
        matching query: String,
        in candidates: [String],
        limit: Int = defaultLimit
    ) -> [String] {
        let needle = normalize(query)
        guard !needle.isEmpty, limit > 0 else { return [] }

        var seen: Set<String> = []
        var prefix: [String] = []
        var wordPrefix: [String] = []
        var substring: [String] = []

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(trimmed)
            guard !key.isEmpty, key != needle, seen.insert(key).inserted else { continue }

            switch match(needle: needle, in: key) {
            case .prefix: prefix.append(trimmed)
            case .wordPrefix: wordPrefix.append(trimmed)
            case .substring: substring.append(trimmed)
            case .none: continue
            }
        }

        return Array((prefix + wordPrefix + substring).prefix(limit))
    }

    /// Match quality of `needle` inside an already-normalized `haystack`.
    enum Match {
        case prefix
        case wordPrefix
        case substring
        case none
    }

    static func match(needle: String, in haystack: String) -> Match {
        if haystack.hasPrefix(needle) { return .prefix }
        // Later words: split on whitespace so "wulf" hits "adam wulf" as a
        // word start rather than a mere substring.
        let words = haystack.split(whereSeparator: { $0.isWhitespace })
        if words.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return .wordPrefix }
        if haystack.contains(needle) { return .substring }
        return .none
    }

    /// Trimmed, lowercased, diacritics folded — the comparison form of a
    /// query or candidate. Internal whitespace runs collapse to one space so
    /// `"Acme  Labs"` and `"Acme Labs"` compare equal.
    static func normalize(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
