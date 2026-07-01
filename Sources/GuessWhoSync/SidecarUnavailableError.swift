import Foundation

/// Thrown by a `ContactsRepository` WRITE when the package has no writable
/// sidecar engine — i.e. it was constructed without a `GuessWhoSync` (the
/// `.unavailable` storage state, no writable sidecar root). Reads degrade
/// silently (return empty/false); writes must NOT silently no-op, so they
/// surface this so the caller can present a "storage unavailable" state.
///
/// The app target still declares its own same-named `SidecarUnavailableError`
/// (in `SyncService`). While both types coexist, an app-side
/// `catch is SidecarUnavailableError` binds the LOCAL type and silently misses
/// the package error this primitive throws — so a caller relying on this
/// package error must import and match THIS type. When the app fully migrates
/// onto the package write API, remove the app's local copy in favor of this one.
public struct SidecarUnavailableError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Sidecar storage is unavailable. Cannot read or write GuessWho data."
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
