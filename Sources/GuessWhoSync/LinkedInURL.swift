import Foundation

/// Normalization helpers for matching LinkedIn profile URLs. A LinkedIn URL is a
/// near-unique identifier, so it's the most precise match signal — but the same
/// profile can be written many ways (with/without scheme, `www.`, `m.`, a
/// trailing slash, query params, or extra path segments). These helpers reduce
/// any of those to a canonical key so stored and parsed URLs compare equal.
public enum LinkedInURL {
    /// True if the string looks like a LinkedIn profile URL or path.
    public static func isLinkedIn(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("linkedin.com/in/")
            || (lower.contains("linkedin") && lower.contains("/in/"))
    }

    /// Extract the profile slug (the `<slug>` in `/in/<slug>`), lowercased, with
    /// no trailing slash or further path. Returns nil if there's no `/in/` segment.
    /// e.g. "https://www.linkedin.com/in/AdamWulf/" -> "adamwulf".
    public static func slug(from urlOrPath: String) -> String? {
        guard let range = urlOrPath.range(of: "/in/", options: .caseInsensitive) else {
            return nil
        }
        let after = urlOrPath[range.upperBound...]
        // Take up to the next "/" , "?" or "#".
        let token = after.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let slug = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return slug.isEmpty ? nil : slug
    }

    /// A canonical comparison key for a LinkedIn URL: scheme, `www.`/`m.`,
    /// trailing slash, and query/fragment removed; lowercased. Built around the
    /// slug when present (`linkedin.com/in/<slug>`), since that's the stable
    /// identity. Returns nil if the input isn't recognizably a LinkedIn profile.
    public static func canonicalKey(_ urlOrPath: String) -> String? {
        if let slug = slug(from: urlOrPath) {
            return "linkedin.com/in/\(slug)"
        }
        return nil
    }

    /// True if two LinkedIn URL strings refer to the same profile, by either an
    /// exact canonical-URL match or a matching slug.
    public static func sameProfile(_ a: String, _ b: String) -> Bool {
        if let ka = canonicalKey(a), let kb = canonicalKey(b) { return ka == kb }
        // Fall back to slug equality if only one canonicalizes.
        if let sa = slug(from: a), let sb = slug(from: b) { return sa == sb }
        return false
    }
}
