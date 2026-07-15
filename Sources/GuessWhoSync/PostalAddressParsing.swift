import Foundation

extension PostalAddress {
    /// Parse free-form pasted text ("1 Infinite Loop, Cupertino, CA 95014",
    /// or the same across multiple lines) into structured components using
    /// `NSDataDetector`'s address detection.
    ///
    /// Returns `nil` unless the text yields at least two distinct
    /// components — a bare street line (i.e. normal typing in a street
    /// field) never qualifies, so callers can safely run every text-field
    /// update through this and only act when a genuine full address shows up.
    ///
    /// `isoCountryCode` is always left empty: the detector reports a
    /// display-name country only, and a stale ISO code paired with a new
    /// country name would be worse than none.
    public static func parse(fromFullAddress text: String) -> PostalAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.address.rawValue
        ) else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              let components = match.addressComponents else { return nil }

        let parsed = PostalAddress(
            street: components[.street] ?? "",
            subLocality: components[.subLocality] ?? "",
            city: components[.city] ?? "",
            subAdministrativeArea: components[.subAdministrativeArea] ?? "",
            state: components[.state] ?? "",
            postalCode: components[.zip] ?? "",
            country: components[.country] ?? "",
            isoCountryCode: ""
        )

        let filledCount = [
            parsed.street, parsed.subLocality, parsed.city,
            parsed.subAdministrativeArea, parsed.state,
            parsed.postalCode, parsed.country,
        ].filter { !$0.isEmpty }.count
        guard filledCount >= 2 else { return nil }
        return parsed
    }
}
