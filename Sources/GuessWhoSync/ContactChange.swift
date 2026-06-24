import Foundation

/// A single entry in a contact change-history delta. Add and update both
/// collapse to `.updated` because the apply path is identical — re-read the one
/// record from the store and replace/insert it in the cache.
public enum ContactChange: Sendable, Equatable {
    /// The contact at `localID` was added or modified. Re-read it from the store.
    case updated(localID: String)
    /// The contact at `localID` was removed. Drop it from the cache.
    case deleted(localID: String)
}

/// The result of reading the contact change history since a prior cursor.
public struct ContactChangeSet: Sendable {
    /// Ordered as the history reported them — apply IN ORDER. Do NOT bucket
    /// into updated-then-deleted: a delete followed by a re-add of the same
    /// `localID` (unify/unlink in Contacts.app) must apply delete then update,
    /// so the contact ends present.
    public var changes: [ContactChange]

    /// Opaque cursor to persist after a successful apply. Pass it back as the
    /// `token` argument on the next `changes(since:)` call.
    public var newToken: Data

    /// `true` when the caller must drop its cache and re-read everything — a
    /// first run (nil prior token), a history truncation, or a token the store
    /// can no longer honor. `changes` is empty in this case; the cache is
    /// rebuilt via a full reload, and `newToken` baselines the cursor.
    public var requiresFullReload: Bool

    public init(changes: [ContactChange], newToken: Data, requiresFullReload: Bool) {
        self.changes = changes
        self.newToken = newToken
        self.requiresFullReload = requiresFullReload
    }
}
