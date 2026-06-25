import Foundation

/// Opaque, stable IDENTITY for a contact as the UI sees it.
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
/// `hash(into:)` key on it (via `effectiveID`) and ONLY on it, so they cannot
/// drift — `ContactID` is a consistent `Hashable`.
///
/// `ContactID` is a PURE IDENTITY token: it carries no display content. Two
/// `ContactID` values with the same effective identity are EQUAL regardless of
/// what the underlying contact looks like — repainting a row whose CONTENTS
/// changed is the view controller's job, not this token's.
///
/// WHY no display fields. An earlier design carried the row's display fields
/// (name, job, org, photo) on `ContactID` and made `==` compare them while
/// `hash` stayed identity-only, on the assumption that a diffable data source's
/// `apply(_:)` re-checks `==` on a same-identity item and reconfigures the cell
/// when it differs. Apple's docs are explicit that it does NOT: `apply(_:)`
/// identifies items SOLELY by their `Hashable` identifier; to repaint an
/// existing row's contents you MUST call `reconfigureItems(_:)` /
/// `reloadItems(_:)` yourself. So that `==` did nothing for reconfigure (the
/// row stayed stale) and left `ContactID` with an inconsistent `Hashable`
/// (`a == b` could be false while `a.hashValue == b.hashValue`), which violates
/// the `Hashable` contract and risked subtle `Set`/`Dictionary` bugs.
/// `ContactsListViewController` / `OrganizationsListViewController` now drive
/// reconfigure explicitly by comparing the `Contact` they last rendered against
/// the freshly-fetched one (keyed by `ContactID`), which is the documented path.
///
/// THE RECONCILIATION TRANSITION (localID-keyed → guessWhoID-keyed) is a
/// genuine diffable delete + insert: the effective identity changes from
/// `localID` to `guessWhoID`, so the old-identity row drops and a new-identity
/// row appears. This is correct and rare (it happens at most once per contact,
/// when it first gains a GuessWho URL) and is symmetric with how an event adopts
/// a sidecar (`Event.stableID(forEventKitID:)`). A reload does NOT reconcile, so
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

    /// The single identity `==` and `hash(into:)` agree on: the GuessWho UUID
    /// once present, otherwise the `localID` fallback. Both members must use
    /// this — never `guessWhoID`/`localID` independently — so they cannot diverge.
    var effectiveID: String { guessWhoID ?? localID }

    /// Materialize a `ContactID` from a cached contact. ALWAYS succeeds —
    /// `localID` is always available, so a row can be vended before the contact
    /// is reconciled. `guessWhoID` is built ONLY via `SidecarKey.forContact`
    /// (the single validator/canonicalizer, never a parallel UUID parser) and is
    /// nil when the contact carries no valid GuessWho URL. No display content is
    /// copied — this is an identity token (see the type doc).
    package init(contact: Contact) {
        self.guessWhoID = SidecarKey.forContact(contact)?.id
        self.localID = contact.localID
    }

    public static func == (lhs: ContactID, rhs: ContactID) -> Bool {
        // Identity ONLY. Two values for the same contact are equal regardless of
        // display content; a content change is repainted by the VC's explicit
        // reconfigure pass, not here. A reconciliation transition changes the
        // effective identity itself — that IS a delete + insert, by design.
        lhs.effectiveID == rhs.effectiveID
    }

    public func hash(into hasher: inout Hasher) {
        // Hash on the effective identity ONLY — consistent with `==`. Two values
        // for the same contact land in the same bucket so a diffable snapshot
        // treats them as the same row across reloads. (The reconciliation
        // transition changes the effective identity itself — different bucket,
        // a delete + insert, by design.)
        hasher.combine(effectiveID)
    }
}
