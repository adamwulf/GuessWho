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

    /// A key that is equal for two strings that write the same phone number:
    /// the phone dedup key the drop of a `tel:` link and the LinkedIn import
    /// share (`ContactsRepository.phoneDedupKey`).
    ///
    /// - A number that parses gives its E.164 digits WITHOUT the `+`
    ///   (`15550100123`), plus `;ext=<digits>` when its extension has a
    ///   digit, so two extensions of one line stay apart and every spelling
    ///   of one extension (`x7`, `ext. 7`, `,7`, `,,7`) is the same. A
    ///   number with no country code is read in `region` (the device's
    ///   region when nil), so `(555) 010-0123` and `+1 555 010 0123` share a
    ///   key on a US device.
    /// - A number that does not parse gives its digits only. Because the
    ///   parsed key has no `+`, a full number that does not parse in this
    ///   region (`1-555-010-0199` on a GB device) still matches the same
    ///   number written with a `+`.
    ///
    /// The parses run in this order, and the first that succeeds wins:
    /// 1. In `region`, with the number-type check: a number the metadata
    ///    lists as valid, written nationally or with a `+`. A `+` number in a
    ///    range the metadata does not list (`+1 555 010 0199`) fails here.
    /// 2. Outside the NANP only (the region's country code is not 1), and
    ///    when there is no leading `+`: `+` and the string, with the type
    ///    check, so a full number written with its country code but no `+`
    ///    (`1-212-555-0123`) reads as that country's number, not as a long
    ///    national number of the region (which a parse with no type check
    ///    gives on a DE, IN, or BR device, among others). In the NANP this
    ///    step would split one number: a national number in an area code
    ///    the bundled metadata does not list yet (624, in service since
    ///    2023) fails step 1, and `624-271-1234` would read as `+62…`
    ///    (Indonesia) here while `(624) 271-1234` and `+1 624 271 1234`
    ///    reach step 3.
    /// 3. In `region`, without the type check (`ignoreType`), so a number in
    ///    a range the metadata does not list (a fictional 555 number, a newly
    ///    opened area code) gets a key from its country code (the one after
    ///    its `+`, else the region's) and its digits, when no earlier step
    ///    took it.
    /// 4. Else the digits.
    ///
    /// Limits:
    /// - A full number with no `+` whose digits are ALSO a valid national
    ///   number of the region (`1-212-555-0123` on an AT device) is read as
    ///   national in step 1, so it does not match the same number written
    ///   with a `+`.
    /// - Outside the NANP, a national number with no `+` in a range the
    ///   metadata does not list can be read as another country's number in
    ///   step 2, so it may not match its other spellings.
    /// - In the NANP, where step 2 does not run, a foreign full number with
    ///   no `+` whose digits look like a NANP number is read as a NANP
    ///   number in step 3, so it does not match its `+` spelling: on a US
    ///   device `47 40 61 23 45` keys `14740612345`, while the Norwegian
    ///   `+47 40 61 23 45` keys `4740612345`. Other foreign numbers with no
    ///   `+` fall to the digits in step 4, and those match.
    ///
    /// Display formatting keeps its own single parse.
    func comparisonKey(for raw: String, region: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let region = region ?? PhoneNumberUtility.defaultRegionCode()
        func parse(_ string: String, ignoreType: Bool = false) -> PhoneNumber? {
            try? utility.parse(string, withRegion: region, ignoreType: ignoreType)
        }
        let readsWithAddedPlus = !trimmed.hasPrefix("+") && utility.countryCode(for: region) != 1
        let number = parse(trimmed)
            ?? (readsWithAddedPlus ? parse("+" + trimmed) : nil)
            ?? parse(trimmed, ignoreType: true)
        guard let number else { return trimmed.filter(\.isNumber) }
        let digits = utility.format(number, toType: .e164).filter(\.isNumber)
        let extensionDigits = (number.numberExtension ?? "").filter(\.isNumber)
        return extensionDigits.isEmpty ? digits : digits + ";ext=" + extensionDigits
    }

    /// The region `comparisonKey(for:)` reads a number with no country code
    /// in, when the caller names none.
    static var deviceRegion: String { PhoneNumberUtility.defaultRegionCode() }
}
