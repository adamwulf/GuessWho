import Foundation
import PhoneNumberKit

/// Renders a stored phone-number string the way the OS's Phone/Contacts UI
/// would — with the region's grouping (parentheses, dashes, spaces) — instead
/// of the raw value the user typed.
///
/// Contacts persists a phone number as `CNPhoneNumber.stringValue`, i.e. the
/// literal characters entered, which may be an unformatted digit run
/// (`5551234567`). This wraps PhoneNumberKit's libphonenumber-backed parser to
/// turn that into the familiar `(555) 123-4567` form for display.
///
/// `PhoneNumberUtility` parses the bundled metadata into memory on init and is
/// comparatively expensive to allocate, so this type is meant to be created
/// once and reused — prefer ``shared``.
public final class PhoneNumberDisplayFormatter {
    /// Shared, reusable instance. `PhoneNumberUtility` is costly to allocate;
    /// share one rather than minting per call.
    public static let shared = PhoneNumberDisplayFormatter()

    private let utility = PhoneNumberUtility()

    public init() {}

    /// A display-formatted version of `raw`, or the trimmed original when it
    /// can't be parsed as a phone number.
    ///
    /// Partial numbers, extensions, short codes, and free text that libphonenumber
    /// rejects pass through unchanged, so nothing a user stored is ever lost or
    /// mangled. Numbers written with an explicit country code (leading `+`) render
    /// in international format (`+44 20 7946 0958`); everything else renders in
    /// national format for the device's region (`(555) 123-4567`).
    public func string(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        do {
            let number = try utility.parse(trimmed)
            let format: PhoneNumberFormat = trimmed.hasPrefix("+") ? .international : .national
            return utility.format(number, toType: format)
        } catch {
            return trimmed
        }
    }
}
