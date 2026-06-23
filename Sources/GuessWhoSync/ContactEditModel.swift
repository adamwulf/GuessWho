import Foundation

/// Pure model for the SwiftUI contact editor.
///
/// Lives in `GuessWhoSync` (not the app target) so all editor data
/// logic — URL partition + re-merge, birthday hasYear conversion,
/// save-error categorization — is exercisable from `GuessWhoSyncTests`
/// without an app-target test bundle.
///
/// No SwiftUI imports, no `CNContact` types: the model only sees
/// `Contact` and standard-library types. The SwiftUI editor view
/// holds this as `@State` (a value-type wrapping by `@Observable`
/// would also work; struct keeps it tidy here).
public struct ContactEditModel: Equatable {
    /// The contact as initially loaded — used as the carry-through
    /// source for fields the editor never surfaces, and as the URL
    /// merge reference (preserves ordering, see `mergedURLAddresses`).
    public private(set) var original: Contact

    /// The user's working copy. Bindings in the editor's SwiftUI rows
    /// mutate this directly; on Save, the whole struct is handed to
    /// `CNContactStoreAdapter.save` after `mergedURLAddresses` patches
    /// the `urlAddresses` field.
    public var edited: Contact

    /// Flipped explicitly by row authors on user input. Not a deep
    /// `Equatable` compare against `original` — the adapter normalizes
    /// labels (`label.isEmpty ? nil : label`), which would let
    /// load → save → load flip equality in subtle ways. An explicit
    /// flag is more predictable.
    public var isDirty: Bool

    /// Birthday-year visibility: tracks whether the user wants the
    /// `birthday` to round-trip with a year component or month/day
    /// only. The SwiftUI `DatePicker` always needs a full `Date`, so
    /// the row converts to a sentinel-year `Date` when `hasYear` is
    /// false and drops the year on save.
    public var birthdayHasYear: Bool

    public init(original: Contact) {
        self.original = original
        self.edited = original
        self.isDirty = false
        self.birthdayHasYear = (original.birthday?.year != nil)
    }

    /// Seed-initializer for brand-new contacts. The editor's Save button is
    /// gated on `isDirty`, so a pre-filled (but otherwise untouched) seed
    /// would force the user to wiggle a field before the button enabled.
    /// Marking the model dirty up front lets Save fire immediately on the
    /// seed values — the saved CNContact ends up exactly what the caller
    /// prefilled with no further interaction required.
    public init(newContactSeed seed: Contact) {
        self.original = seed
        self.edited = seed
        self.isDirty = true
        self.birthdayHasYear = (seed.birthday?.year != nil)
    }

    // MARK: - URL partition

    /// The URLs the editor's URL section should show. Filters out any
    /// entry whose value starts with `SidecarKey.guessWhoContactURLPrefix`
    /// — well-formed AND malformed. The hidden entries are carried
    /// through verbatim via `mergedURLAddresses` on save.
    ///
    /// This is the BROAD prefix-match. Not the same as
    /// `ContactDetailView`'s narrower `parseGuessWhoContactURL == nil`
    /// filter (which is correct for display but would let a user
    /// edit/delete a malformed `guesswho://` entry — orphaning the
    /// sidecar binding).
    public var visibleURLAddresses: [LabeledValue] {
        get {
            edited.urlAddresses.filter {
                !$0.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
            }
        }
        set {
            edited.urlAddresses = Self.mergeURLAddresses(
                original: original.urlAddresses,
                visible: newValue
            )
        }
    }

    /// Re-mix the visible bucket back with the carried-through
    /// GuessWho URLs on save, preserving the user's manually-imposed
    /// URL ordering.
    ///
    /// Algorithm: walk `original.urlAddresses` in order. For each slot
    /// matching the GuessWho prefix → carry the original entry. For
    /// each non-matching slot → consume the next entry from the
    /// edited visible bucket (paired by visible-bucket position) and
    /// write it to the result. Any visible entries beyond the
    /// original visible count are *new user URLs* — append them at
    /// the end.
    ///
    /// This guarantees that:
    /// - GuessWho URLs sit at their original index.
    /// - User URLs the user reordered stay in the user's new order.
    /// - Added URLs append after the originals.
    /// - Deleted user URLs vanish; their slots collapse.
    public static func mergeURLAddresses(
        original: [LabeledValue],
        visible: [LabeledValue]
    ) -> [LabeledValue] {
        var result: [LabeledValue] = []
        result.reserveCapacity(max(original.count, visible.count))
        var visibleIndex = 0
        let originalVisibleCount = original.filter {
            !$0.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix)
        }.count

        for entry in original {
            if entry.value.hasPrefix(SidecarKey.guessWhoContactURLPrefix) {
                result.append(entry)
            } else if visibleIndex < visible.count {
                result.append(visible[visibleIndex])
                visibleIndex += 1
            }
            // else: original had a user URL the user deleted; skip.
        }
        // New entries (the user added more than the original had).
        if visible.count > originalVisibleCount {
            result.append(contentsOf: visible.suffix(visible.count - originalVisibleCount))
        }
        return result
    }

    // MARK: - Birthday conversion

    /// Sentinel year used when the user has opted out of year tracking.
    /// Any reasonable middle-of-the-road year works; 2000 is a leap
    /// year so Feb 29 is representable.
    public static let birthdaySentinelYear: Int = 2000

    /// Convert the edited birthday `DateComponents` to a `Date` suitable
    /// for SwiftUI's `DatePicker`. Substitutes a sentinel year whenever
    /// the underlying components lack one — regardless of
    /// `birthdayHasYear` — so the picker always has a usable `Date` to
    /// bind to. The save path (`setBirthday`) is what decides whether
    /// the year ends up in the persisted `DateComponents`. This split
    /// keeps the toggle's false→true transition safe: if the user flips
    /// "Include year" on, `birthdayAsDate()` still resolves and
    /// `setBirthday(from:)` then writes a real `year` value to
    /// `edited.birthday`.
    public func birthdayAsDate(calendar: Calendar = .current) -> Date? {
        var components = edited.birthday ?? DateComponents()
        if components.year == nil {
            components.year = Self.birthdaySentinelYear
        }
        return calendar.date(from: components)
    }

    /// Write a `DatePicker`-sourced `Date` back into `edited.birthday`,
    /// dropping the year when `birthdayHasYear` is false.
    public mutating func setBirthday(from date: Date, calendar: Calendar = .current) {
        let dc = calendar.dateComponents([.year, .month, .day], from: date)
        if birthdayHasYear {
            edited.birthday = dc
        } else {
            var stripped = DateComponents()
            stripped.month = dc.month
            stripped.day = dc.day
            edited.birthday = stripped
        }
        isDirty = true
    }

    /// Clear the birthday entirely (used by the "Remove" affordance).
    public mutating func clearBirthday() {
        edited.birthday = nil
        isDirty = true
    }

    // MARK: - Save error categorization

    /// Categories the save / delete pipeline maps adapter errors to,
    /// so the editor can render category-specific alert text without
    /// the row code having to switch on `CNError` codes.
    public enum SaveErrorCategory: Equatable {
        /// Contacts access was revoked between load and save.
        case authorizationDenied
        /// The system rejected one of the field values (e.g. malformed
        /// data). The associated string is the underlying
        /// `localizedDescription` so the user sees specifics.
        case invalidField(String)
        /// Another client deleted the contact between load and save.
        /// For the save path this is an error; for delete it should be
        /// treated as success by the caller.
        case recordDoesNotExist
        /// Anything else; carries the underlying error's
        /// `localizedDescription`.
        case unknown(String)
    }

    /// Map an arbitrary `Error` (typically `CNError`) into a category.
    /// Works without importing `Contacts` by matching the
    /// `CNErrorDomain` constant and the documented integer codes — so
    /// this module stays buildable on platforms where `Contacts`
    /// might be unavailable.
    public static func saveErrorCategory(_ error: Error) -> SaveErrorCategory {
        let ns = error as NSError
        // CNErrorDomain — match by string so we don't have to import Contacts.
        // Apple documents this as a stable domain identifier.
        guard ns.domain == "CNErrorDomain" else {
            return .unknown(ns.localizedDescription)
        }
        // CNError.Code raw values per Apple's headers.
        switch ns.code {
        case 100:
            // CNErrorCode.authorizationDenied
            return .authorizationDenied
        case 200:
            // CNErrorCode.recordDoesNotExist
            return .recordDoesNotExist
        case 201, 202:
            // CNErrorCode.insertedRecordAlreadyExists / containmentCycle
            return .invalidField(ns.localizedDescription)
        case 1700, 1701:
            // CNErrorCode.validationConfigurationError /
            // validationMultipleErrors-ish; these are the "system
            // rejected a field" family.
            return .invalidField(ns.localizedDescription)
        default:
            return .unknown(ns.localizedDescription)
        }
    }
}
