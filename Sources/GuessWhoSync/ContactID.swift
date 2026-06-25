import Foundation

/// Opaque, stable identity for a contact as the UI sees it.
///
/// Equality and hashing are deliberately split so a diffable data source can
/// treat an edited contact as the *same row with changed contents* rather than
/// a delete + insert:
///
/// - `hash(into:)` combines ONLY `guessWhoID`. Two `ContactID` values for the
///   same contact — even with different display fields — land in the same
///   bucket, so a `UITableViewDiffableDataSource` keeps the row in place across
///   reloads, across a Case-D canonical-ID collapse (the package re-mints the
///   value with the surviving UUID), and across any display-field edit. No
///   flicker, no scroll jump, no delete+insert animation.
/// - `==` ALSO compares the bare display fields. An edited contact therefore
///   compares *unequal*, so the data source reports the item as changed and
///   reconfigures the cell in place. This replaces the app's hand-rolled
///   `previousByID` snapshot diff + `reconfigureItems` pass and the entire
///   `contactsByLocalID` side-dictionary.
///
/// Net effect: same `guessWhoID` → same row; any display delta → reconfigure.
///
/// The display fields ride along so the cell provider can render a row straight
/// off the `ContactID` without keeping a parallel `[ID: Contact]` dictionary.
/// They are NOT identity. Notes/tags/links are deliberately absent — they are
/// not part of a row's visual identity and change far more often.
public struct ContactID: Hashable, Sendable {
    /// Canonical lowercase bare UUID string (NOT the `guesswho://contact/` URL).
    /// Produced exclusively by `SidecarKey`'s validator/canonicalizer. The only
    /// identity the package or the UI ever compares.
    public let guessWhoID: String

    /// Apple's unified-contact identifier (`CNContact.identifier`). INTERNAL to
    /// the package's fetch path — the UI must never read, compare, or persist
    /// it. `package` visibility keeps it out of the app target's reach while
    /// still letting repository fetch methods resolve a `ContactID` back to the
    /// cached `Contact`.
    package let localID: String

    // MARK: Bare display fields
    //
    // Present so `Hashable`/`Equatable` can drive diffable change-detection.
    // These are the exact fields a list row renders (see the Catalyst/iPhone
    // contact + organization cells): the icon keys on `contactType`, the name
    // line builds from `givenName`/`familyName` (falling back to
    // `displayName`), and the subtitle is `jobTitle`/`organizationName`. The
    // photo presence flag rounds out the visual identity of the row. Raw
    // components are vended (not a single pre-rendered `secondaryText`) so row
    // policy stays in the app.

    /// Stable display label (matches `Contact.displayName`), used as the name
    /// line's fallback when given/family name are both empty.
    public let displayName: String
    public let contactType: ContactType
    public let givenName: String
    public let familyName: String
    public let jobTitle: String
    public let organizationName: String
    /// Whether the contact has photo bytes available (drives any row image).
    public let imageDataAvailable: Bool

    /// Materialize a `ContactID` from a fully-reconciled contact. Returns `nil`
    /// unless the contact carries a valid GuessWho URL — identity must be
    /// settled (exactly one distinct valid URL after reconciliation) before a
    /// value is vended, which the repository guarantees. The `guessWhoID` is
    /// built ONLY via `SidecarKey.forContact` so there is one canonicalizer,
    /// never a parallel UUID parser.
    package init?(contact: Contact) {
        guard let key = SidecarKey.forContact(contact) else { return nil }
        self.guessWhoID = key.id
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
        lhs.guessWhoID == rhs.guessWhoID
            && lhs.displayName == rhs.displayName
            && lhs.contactType == rhs.contactType
            && lhs.givenName == rhs.givenName
            && lhs.familyName == rhs.familyName
            && lhs.jobTitle == rhs.jobTitle
            && lhs.organizationName == rhs.organizationName
            && lhs.imageDataAvailable == rhs.imageDataAvailable
    }

    public func hash(into hasher: inout Hasher) {
        // Hash on identity ONLY. Two values for the same contact with different
        // display fields must land in the same bucket so a diffable snapshot
        // treats them as the same row (reconfigured), never as a delete +
        // insert. `==` then catches the field delta and the data source
        // reconfigures in place.
        hasher.combine(guessWhoID)
    }
}
