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
