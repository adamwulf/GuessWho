import UIKit

extension UIViewController {
    /// Match UITableViewController's push/pop selection clearing for plain
    /// UIViewController-hosted tables while preserving expanded split-view
    /// selection, where the highlighted row represents the visible detail pane.
    func deselectSelectedTableRowOnNavigationReturn(
        in tableView: UITableView,
        animated: Bool
    ) {
        guard shouldDeselectListSelectionOnNavigationReturn,
              let selectedIndexPaths = tableView.indexPathsForSelectedRows,
              !selectedIndexPaths.isEmpty else { return }

        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: { _ in
                for indexPath in selectedIndexPaths {
                    tableView.deselectRow(at: indexPath, animated: animated)
                }
            }, completion: { context in
                if context.isCancelled {
                    for indexPath in selectedIndexPaths {
                        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
                    }
                }
            })
        } else {
            for indexPath in selectedIndexPaths {
                tableView.deselectRow(at: indexPath, animated: animated)
            }
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
