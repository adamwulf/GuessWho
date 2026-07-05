import Foundation

/// A **persistable** contact identity, built from a `ContactID`, for UI state
/// restoration (e.g. a scene's `NSUserActivity`) — and NOTHING else.
///
/// ## Why this type exists (and why it is not `ContactID`)
///
/// `ContactID` is deliberately NOT `Codable`: it is the app's opaque identity
/// token, and making the token *itself* persistable would invite app code to
/// store identity casually in places where the transient `localID` it carries
/// would later dangle (see `docs/contact-identity.md`). That is a policy
/// guardrail, not a technical limit.
///
/// State restoration is the one legitimate place to persist contact identity
/// across launches, so we expose a SEPARATE, purpose-named `Codable` type for
/// it. The name documents intent at every call site: you persist a
/// `ContactRestorationToken`, never a `ContactID`, so nobody stores identity by
/// accident. The guardrail on `ContactID` stays intact.
///
/// ## What it carries, and why both identifiers
///
/// The token snapshots BOTH identifiers a `ContactID` holds:
///
/// - `guessWhoID` — the durable, cross-device GuessWho UUID (nil until the
///   contact has been written to / reconciled). Preferred key: it survives sync
///   and a fresh device.
/// - `localID` — Apple's `CNContact.identifier`. Always present. Not durable
///   across devices, but STABLE ON ONE DEVICE in practice, so carrying it lets
///   restoration reopen a contact the user only *viewed* (never wrote to) and
///   which therefore has no `guessWhoID` yet.
///
/// On restore the repository resolves `guessWhoID` first (canonical identity
/// wins), then falls back to `localID`; if neither resolves — the contact was
/// deleted, or its `localID` moved on another device — resolution returns nil
/// and the caller lands on the section without a selected record. This is the
/// same reconcile-stable path as `ContactsRepository.contact(id:)`.
///
/// ## Still opaque
///
/// Like `ContactID`, the payload is SEALED: both stored properties are
/// `package`, so the app can encode/decode and round-trip the token but cannot
/// read a raw `guessWhoID` / `localID` off it. It hands the token back to
/// `ContactsRepository.contact(restorationToken:)` to resolve the real
/// `Contact`.
public struct ContactRestorationToken: Codable, Hashable, Sendable {
    /// Canonical lowercase GuessWho UUID, or nil if the contact carried no
    /// `guesswho://` URL when the token was minted. `package` — not readable by
    /// the app; only the repository resolves it.
    package let guessWhoID: String?

    /// Apple's unified `CNContact.identifier` at mint time. Always present.
    /// `package` — the same sealed handle `ContactID` carries.
    package let localID: String

    /// Snapshot the identity carried by `id` into a persistable token. Reads the
    /// sealed identifiers off the token (both are `package`), so this lives in
    /// the package alongside `ContactID`.
    package init(_ id: ContactID) {
        self.guessWhoID = id.guessWhoID
        self.localID = id.localID
    }

    /// Rebuild an opaque `ContactID` from the persisted identifiers so the
    /// repository can resolve it through the existing reconcile-stable path.
    /// `package` — resolution is the repository's job, never the app's.
    package var contactID: ContactID {
        ContactID(guessWhoID: guessWhoID, localID: localID)
    }
}
