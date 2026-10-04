import UIKit

extension UIViewController {
    /// Keeps the root view's safe area out of a list table's row margins. Call
    /// from `viewDidLoad` in a controller that pins its table to
    /// `view.safeAreaLayoutGuide`.
    ///
    /// On Mac Catalyst in macOS 27, a split view column's root view extends
    /// under the sidebar, and its safe area covers the sidebar's width. The
    /// table is pinned to that safe area, so it starts at the sidebar's edge and
    /// its own `safeAreaInsets` is zero. But UIKit still adds the root view's
    /// safe-area inset to the table's leading layout margin (a 220pt sidebar
    /// gives a 228pt margin), and the margin stays that large after the sidebar
    /// collapses. Row cells pin to their content view's layout margins, so each
    /// row shrinks to its icon at the trailing edge, with no visible text.
    ///
    /// The table takes its margins from the root view's margins. When the root
    /// view's margins leave out the safe area, the table gets the system 16pt
    /// margins on both sides, with the sidebar shown or hidden. The root view's
    /// own margins do not need the safe area: the table is pinned to the
    /// safe-area guide, and each empty-state view is centered on it.
    func keepSafeAreaOutOfListRowMargins() {
        view.insetsLayoutMarginsFromSafeArea = false
    }
}
