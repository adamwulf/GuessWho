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

    /// A key that is equal for two strings that write the same phone number,
    /// or nil when `raw` does not parse as one: the number in E.164
    /// (`+15550100123`), plus `;ext=<extension>` when it has one, so two
    /// extensions of one line stay apart. A number with no country code is
    /// read in `region` (the device's region when nil), so `(555) 010-0123`
    /// and `+1 555 010 0123` share a key on a US device.
    ///
    /// The number type is not checked (`ignoreType`): a number in a range the
    /// metadata does not list (a fictional 555 number, a newly opened range)
    /// still gets a key from its country and digits. Display formatting
    /// keeps the type check.
    func comparisonKey(for raw: String, region: String? = nil) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let number = try? utility.parse(
                  trimmed,
                  withRegion: region ?? PhoneNumberUtility.defaultRegionCode(),
                  ignoreType: true
              )
        else { return nil }
        let e164 = utility.format(number, toType: .e164)
        guard let numberExtension = number.numberExtension, !numberExtension.isEmpty else { return e164 }
        return e164 + ";ext=" + numberExtension
    }

    /// The region `comparisonKey(for:)` reads a number with no country code
    /// in, when the caller names none.
    static var deviceRegion: String { PhoneNumberUtility.defaultRegionCode() }
}
