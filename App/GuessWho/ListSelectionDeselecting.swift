import UIKit

protocol ScrollsToTop: AnyObject {
    func scrollToTop(animated: Bool)
}

extension UIScrollView {
    func scrollToTopRespectingAdjustedInset(animated: Bool) {
        let topOffset = CGPoint(x: -adjustedContentInset.left, y: -adjustedContentInset.top)
        setContentOffset(topOffset, animated: animated)
    }
}

extension UIViewController {
    /// Match UITableViewController's push/pop selection clearing for plain
    /// UIViewController-hosted tables while preserving expanded split-view
    /// selection, where the highlighted row represents the visible detail pane.
    func deselectSelectedTableRowOnNavigationReturn(
        in tableView: UITableView,
        animated: Bool
    ) {
        guard shouldDeselectListSelectionOnNavigationReturn,
              let selectedIndexPath = tableView.indexPathForSelectedRow else { return }

        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: { _ in
                tableView.deselectRow(at: selectedIndexPath, animated: animated)
            }, completion: { context in
                if context.isCancelled {
                    tableView.selectRow(at: selectedIndexPath, animated: false, scrollPosition: .none)
                }
            })
        } else {
            tableView.deselectRow(at: selectedIndexPath, animated: animated)
        }
    }

    private var shouldDeselectListSelectionOnNavigationReturn: Bool {
        if let splitViewController, !splitViewController.isCollapsed {
            return false
        }
        guard let navigationController else {
            return false
        }
        return navigationController.topViewController === self
    }
}
