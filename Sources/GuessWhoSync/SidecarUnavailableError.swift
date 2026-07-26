import Foundation

/// Thrown by a `ContactsRepository` WRITE when the package has no writable
/// sidecar engine — i.e. it was constructed without a `GuessWhoSync` (the
/// `.unavailable` storage state, no writable sidecar root). Reads degrade
/// silently (return empty/false); writes must NOT silently no-op, so they
/// surface this so the caller can present a "storage unavailable" state.
///
/// This is the ONE storage-unavailable error type: the app's `SyncService`
/// throws it too (its former same-named local copy was removed — two types
/// meant an app-side `catch is SidecarUnavailableError` bound one and
/// silently missed the other), so a single catch matches the error whether a
/// service or repository write surfaced it.
public struct SidecarUnavailableError: Error, LocalizedError {
    public init() {}

    /// `LocalizedError` means this string is user-facing by contract — an
    /// alert that renders `localizedDescription` (the LinkedIn import's
    /// apply-failure alert does) shows it verbatim. So it must stay in plain
    /// language: no "sidecar," no "GuessWho" as a noun for our records. The
    /// wording matches `SidecarLocationBanner`'s "Storage is unavailable." so
    /// the two surfaces name the same condition the same way.
    public var errorDescription: String? {
        "Storage is unavailable. Notes and tags can’t be read or saved right now."
    }
}

/// Thrown by the resolve-or-mint primitive when reconcile completed without
/// leaving a readable GuessWho UUID on the contact — a pathological state
/// (the reconcile neither reported an `assignedUUID` nor stamped a URL we can
/// read back). Package-internal, since the app never triggers or names
/// reconcile.
public struct ReconcileAssignmentFailedError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Could not assign an identity to this contact."
    }
}
