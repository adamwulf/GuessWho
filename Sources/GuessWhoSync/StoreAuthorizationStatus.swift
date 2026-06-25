import Foundation

/// Package-vended authorization status for a backing store (Contacts or
/// EventKit). The adapters collapse the platform-specific status values
/// (`CNAuthorizationStatus`, `EKAuthorizationStatus`) into these four neutral
/// cases so the app target never has to import `Contacts` / `EventKit` just to
/// reason about permission state.
///
/// Collapse rules applied inside the adapters:
/// - **Contacts:** `.authorized` and `.limited` → `.authorized`.
/// - **Events:** `.fullAccess` and the pre-iOS-17 `.authorized` → `.authorized`;
///   `.writeOnly` → `.denied` (write-only access cannot read events, which the
///   app treats as no access for its read-driven UI).
///
/// `.notDetermined` is the "never asked" state the app surfaces as
/// `notRequested` in its UI-facing authorization enums.
public enum StoreAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// Outcome of a permission *request*. Carries the resulting status plus an
/// optional failure description so a caller can distinguish "the user said no"
/// (`status == .denied`, `failureDescription == nil`) from "the request itself
/// threw" (`status == .denied`, `failureDescription` set to the error's
/// `localizedDescription`).
///
/// The pre-adapter `SyncService` wrote `lastError` only on a thrown request, not
/// on a plain user-denial; this type preserves that distinction so the same
/// `lastError` write survives the move behind the adapters.
public struct StoreAccessResult: Sendable, Equatable {
    public let status: StoreAuthorizationStatus
    /// Non-nil ONLY when the underlying request threw. Holds the thrown error's
    /// `localizedDescription`.
    public let failureDescription: String?

    public init(status: StoreAuthorizationStatus, failureDescription: String? = nil) {
        self.status = status
        self.failureDescription = failureDescription
    }
}
