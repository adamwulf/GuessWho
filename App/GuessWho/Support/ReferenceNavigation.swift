import SwiftUI

/// SwiftUI-side hooks that hosted SwiftUI detail views call to push a
/// fresh detail onto the OUTER UIKit nav controller. The Phase 5
/// iPhone shell hosts each detail in a `UIHostingController` rooted in
/// a `UINavigationController`; a `NavigationLink(value:)` inside that
/// hosted view has no SwiftUI NavigationStack ancestor to push into,
/// so we route the push through these env-injected closures instead.
///
/// `SceneDelegate.pushContactDetail` / `pushEventDetail` set both
/// closures on every pushed rootView so the new detail can in turn
/// fan out to more contacts/events without losing the back stack.
/// The default no-op closure means SwiftUI previews and any
/// non-pushable host (Catalyst's column-replace path, which for now
/// intentionally doesn't inject) keep compiling — taps just do
/// nothing, matching Catalyst's pre-bridge silent behaviour.
extension EnvironmentValues {
    @Entry var pushContactReference: (ContactReference) -> Void = { _ in }
    @Entry var pushEventReference: (EventReference) -> Void = { _ in }
}
