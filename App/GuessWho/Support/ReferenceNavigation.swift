import SwiftUI

/// SwiftUI-side hooks that hosted SwiftUI detail views call to push a
/// fresh detail onto the OUTER UIKit nav controller. Each detail is
/// hosted in a `UIHostingController` rooted in a `UINavigationController`;
/// a `NavigationLink(value:)` inside that hosted view has no SwiftUI
/// NavigationStack ancestor to push into, so the push routes through
/// these env-injected closures instead.
///
/// The SceneDelegate injects both closures on every pushed rootView (the
/// iPhone push path and the Catalyst secondary-column nav) so the new
/// detail can in turn fan out to more contacts/events without losing the
/// back stack. The default no-op closure lets SwiftUI previews and any
/// host that doesn't inject keep compiling — taps just do nothing.
extension EnvironmentValues {
    @Entry var pushContactReference: (ContactReference) -> Void = { _ in }
    @Entry var pushEventReference: (EventReference) -> Void = { _ in }
    @Entry var pushDepartmentReference: (DepartmentReference) -> Void = { _ in }
    @Entry var pushGroupReference: (GroupReference) -> Void = { _ in }
    @Entry var pushGuideReference: (GuideReference) -> Void = { _ in }
}
