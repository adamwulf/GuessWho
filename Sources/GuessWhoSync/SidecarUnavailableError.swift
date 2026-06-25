import Foundation

/// Thrown by a `ContactsRepository` WRITE when the package has no writable
/// sidecar engine — i.e. it was constructed without a `GuessWhoSync` (the
/// `.unavailable` storage state, no writable sidecar root). Reads degrade
/// silently (return empty/false); writes must NOT silently no-op, so they
/// surface this so the caller can present a "storage unavailable" state.
///
/// This is the package twin of the app's existing `SidecarUnavailableError`.
/// As Stage 6 migrates the app's contact-sidecar callers onto the repository
/// (sub-phase 6d), they converge on this package type; until then both exist
/// (the app's local copy shadows this within the app target without collision).
///
/// 6d CHECKLIST: when the app migrates onto the package write API, REMOVE the
/// app's local same-named `SidecarUnavailableError` in favor of this one.
/// Otherwise an app-side `catch is SidecarUnavailableError` binds the LOCAL
/// type and silently misses the package error this primitive throws.
public struct SidecarUnavailableError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Sidecar storage is unavailable. Cannot read or write GuessWho data."
    }
}

/// Thrown by the resolve-or-mint primitive when reconcile completed without
/// leaving a readable GuessWho UUID on the contact — a pathological state
/// (the reconcile neither reported an `assignedUUID` nor stamped a URL we can
/// read back). The package twin of the app's `ReconcileAssignmentFailedError`.
public struct ReconcileAssignmentFailedError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Could not assign an identity to this contact."
    }
}
