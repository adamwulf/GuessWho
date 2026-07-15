import UIKit

/// Keyboard ergonomics for the searchable lists (People, Events,
/// Organizations). On iPhone the software keyboard otherwise has no way out —
/// `UISearchController` only dismisses it on Cancel/return — and it covers the
/// bottom rows of the list. Each list VC calls this once from its
/// `configureSearch()`, and pins its table's bottom to
/// `view.keyboardLayoutGuide.topAnchor` (not the safe area) so the visible rows
/// shrink above the keyboard instead of sliding under it.
extension UISearchController {
    /// Two ways to put the keyboard away without cancelling the search (the
    /// filter text and Cancel button stay put — only the keyboard goes):
    ///
    /// 1. Swipe: `.interactive` dismiss on the table, so dragging down over the
    ///    list pulls the keyboard down with the finger. The keyboard layout
    ///    guide tracks the gesture, so a table pinned to it resizes in step.
    /// 2. Tap: an input accessory bar over the keyboard with a right-aligned
    ///    dismiss button, for users who won't discover the swipe.
    ///
    /// On Catalyst there's no software keyboard, so the accessory bar never
    /// appears and `.interactive` is inert — safe to call unconditionally.
    func installKeyboardDismissal(for tableView: UITableView) {
        tableView.keyboardDismissMode = .interactive

        let dismissItem = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            primaryAction: UIAction { [weak self] _ in
                self?.searchBar.searchTextField.resignFirstResponder()
            }
        )
        dismissItem.accessibilityLabel = "Hide Keyboard"

        // UIToolbar sizes itself from an initial nonzero frame + sizeToFit;
        // a zero frame triggers unsatisfiable-constraint spew at present time.
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.items = [.flexibleSpace(), dismissItem]
        toolbar.sizeToFit()
        searchBar.searchTextField.inputAccessoryView = toolbar
    }
}
