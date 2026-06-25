import Foundation

/// Opaque, stable identity for a contact as the UI sees it.
///
/// A `ContactID` wraps BOTH identifiers and always materializes:
///
/// - `localID` (Apple's `CNContact.identifier`) is ALWAYS present. It is the
///   fallback identity before a contact is reconciled — a contact with no
///   `guesswho://` URL has no sidecar data to key on, so keying the row on its
///   transient `localID` is harmless and lets it appear in the list immediately.
/// - `guessWhoID` (canonical lowercase bare UUID) is OPTIONAL: nil until the
///   contact carries a valid GuessWho URL. Once reconciliation mints/collapses
///   identity, `guessWhoID` populates and BECOMES the identity.
///
/// The *effective* identity is therefore `guessWhoID ?? localID`. Both `==` and
/// `hash(into:)` key on it (via `effectiveID`) so they cannot drift.
///
/// Equality and hashing are split so a diffable data source treats an edited
/// contact as the *same row with changed contents*, not a delete + insert:
///
/// - `hash(into:)` combines ONLY the effective identity. Two `ContactID` values
///   for the same contact — even with different display fields — land in the
///   same bucket, so a `UITableViewDiffableDataSource` keeps the row in place
///   across reloads and across any display-field edit.
/// - `==` compares the effective identity AND the (package-private) display
///   fields. An edited contact compares *unequal*, so the data source reports
///   the item as changed and reconfigures the cell in place. This replaces the
///   app's hand-rolled `previousByID` snapshot diff + `reconfigureItems` pass
///   and the `contactsByLocalID` side-dictionary. The comparison runs inside the
///   package, where the fields are visible; the app never reads them.
///
/// THE RECONCILIATION TRANSITION (localID-keyed → guessWhoID-keyed) is a
/// genuine diffable delete + insert, NOT a reconfigure: the effective identity
/// changes from `localID` to `guessWhoID`, so the old row drops and a new row
/// appears. This is correct and rare (it happens at most once per contact, when
/// it first gains a GuessWho URL) and is symmetric with how an event adopts a
/// sidecar (`Event.stableID(forEventKitID:)`). A reload does NOT reconcile, so
/// this transition is driven by the reconciler, not by `reload()` — do not
/// assume identity is "settled" merely because a value was vended.
///
/// `ContactID` is a fully OPAQUE token: every stored property is `package`, so
/// the app target can hold it, compare it (for diffing), and hand it back to the
/// repository to fetch the real `Contact` — but it CANNOT read any field off it.
/// It is deliberately NOT a "contact-light": the app must go through
/// `repository.contact(id:)` to render a row, so there is one source of truth for
/// contact data. The conformances (`Hashable`, `Sendable`) are public so the app
/// can put the token in a diffable snapshot / `Set`; the DATA stays sealed.
///
/// The display fields are carried only so the package-internal `==` can drive
/// diffable change-detection (an edit makes two tokens compare unequal → the
/// cell reconfigures). They are NOT identity and are not readable by the app.
/// Notes/tags/links are deliberately absent — they are not part of a row's
/// visual identity and change far more often.
public struct ContactID: Hashable, Sendable {
    /// Canonical lowercase bare UUID string (NOT the `guesswho://contact/` URL).
    /// Produced exclusively by `SidecarKey`'s validator/canonicalizer. Nil until
    /// the contact carries a valid GuessWho URL (i.e. is reconciled); once
    /// present it is the identity the package compares. `package` — not readable
    /// by the app.
    package let guessWhoID: String?

    /// Apple's unified-contact identifier (`CNContact.identifier`). Always
    /// present. INTERNAL to the package's fetch path — `package` visibility keeps
    /// it out of the app target's reach while still letting repository fetch
    /// methods resolve a `ContactID` back to the cached `Contact`. It is the
    /// EFFECTIVE identity only as a pre-reconciliation fallback (see
    /// `effectiveID`).
    package let localID: String

    // MARK: Display fields (package — for diffing only, never read by the app)
    //
    // Carried so the package-internal `==` can drive diffable change-detection.
    // These are the exact fields a list row renders (see the Catalyst/iPhone
    // contact + organization cells), but the app reads them off the `Contact`
    // it fetches via `repository.contact(id:)`, NOT off this token. Raw
    // components (not a pre-rendered string) so the comparison is exact.
    package let displayName: String
    package let contactType: ContactType
    package let givenName: String
    package let familyName: String
    package let jobTitle: String
    package let organizationName: String
    package let imageDataAvailable: Bool

    /// The single identity `==` and `hash(into:)` agree on: the GuessWho UUID
    /// once present, otherwise the `localID` fallback. Both members must use
    /// this — never one of the raw fields — so they cannot diverge.
    var effectiveID: String { guessWhoID ?? localID }

    /// Materialize a `ContactID` from a cached contact. ALWAYS succeeds —
    /// `localID` is always available, so a row can be vended before the contact
    /// is reconciled. `guessWhoID` is built ONLY via `SidecarKey.forContact`
    /// (the single validator/canonicalizer, never a parallel UUID parser) and is
    /// nil when the contact carries no valid GuessWho URL.
    package init(contact: Contact) {
        self.guessWhoID = SidecarKey.forContact(contact)?.id
        self.localID = contact.localID
        self.displayName = contact.displayName
        self.contactType = contact.contactType
        self.givenName = contact.givenName
        self.familyName = contact.familyName
        self.jobTitle = contact.jobTitle
        self.organizationName = contact.organizationName
        self.imageDataAvailable = contact.imageDataAvailable
    }

    public static func == (lhs: ContactID, rhs: ContactID) -> Bool {
        lhs.effectiveID == rhs.effectiveID
            && lhs.displayName == rhs.displayName
            && lhs.contactType == rhs.contactType
            && lhs.givenName == rhs.givenName
            && lhs.familyName == rhs.familyName
            && lhs.jobTitle == rhs.jobTitle
            && lhs.organizationName == rhs.organizationName
            && lhs.imageDataAvailable == rhs.imageDataAvailable
    }

    public func hash(into hasher: inout Hasher) {
        // Hash on the effective identity ONLY. Two values for the same contact
        // with different display fields must land in the same bucket so a
        // diffable snapshot treats them as the same row (reconfigured), never as
        // a delete + insert. `==` then catches the field delta and the data
        // source reconfigures in place. (The reconciliation transition changes
        // the effective identity itself — that IS a delete + insert, by design.)
        hasher.combine(effectiveID)
    }
}
