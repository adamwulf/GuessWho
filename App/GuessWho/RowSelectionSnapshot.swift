import UIKit

/// A list that can record its selected rows for the scene to put back later.
/// Returns nil before the list's view has loaded.
@MainActor
protocol RowSelectionRecording: AnyObject {
    func rowSelectionSnapshot() -> RowSelectionSnapshot?
}

/// The rows a table or collection view had selected, by item identity, with a
/// way to select exactly those rows again. Identity, not index paths, because
/// rows move in between: a "Recently Viewed" sort moves the opened contact to
/// the top a moment after it opens.
///
/// Selecting from code sends no delegate callback, so putting a selection back
/// never opens anything. A row that is gone by then is skipped.
///
/// The Mac's "Discard changes?" question uses it (`DetailReplacementGate`): by
/// the time a click reaches the question the click has already moved the
/// highlight, so Keep Editing puts back the selection the scene recorded when
/// editing began.
@MainActor
struct RowSelectionSnapshot {
    /// The list the rows belong to, so the scene can tell this list from one
    /// that came on screen later.
    private(set) weak var owner: AnyObject?
    private let restoreRows: () -> Void
    private let clearRows: () -> Void

    init<Section: Hashable & Sendable, Item: Hashable & Sendable>(
        of tableView: UITableView,
        dataSource: UITableViewDiffableDataSource<Section, Item>,
        owner: AnyObject
    ) {
        let selected = (tableView.indexPathsForSelectedRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
        self.owner = owner
        restoreRows = { [weak tableView, weak dataSource] in
            guard let tableView, let dataSource else { return }
            Self.select(selected.compactMap { dataSource.indexPath(for: $0) }, in: tableView)
        }
        clearRows = { [weak tableView] in
            guard let tableView else { return }
            Self.select([], in: tableView)
        }
    }

    init<Section: Hashable & Sendable, Item: Hashable & Sendable>(
        of collectionView: UICollectionView,
        dataSource: UICollectionViewDiffableDataSource<Section, Item>,
        owner: AnyObject
    ) {
        let selected = (collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
        self.owner = owner
        restoreRows = { [weak collectionView, weak dataSource] in
            guard let collectionView, let dataSource else { return }
            Self.select(selected.compactMap { dataSource.indexPath(for: $0) }, in: collectionView)
        }
        clearRows = { [weak collectionView] in
            guard let collectionView else { return }
            Self.select([], in: collectionView)
        }
    }

    /// Select exactly the recorded rows that still exist.
    func restore() {
        restoreRows()
    }

    /// Select no rows at all.
    func deselectAll() {
        clearRows()
    }

    // The data source can be ahead of its view while an apply is in flight,
    // so each index path is checked against the view's own counts first —
    // the same guard as `PendingRowSelection`.

    private static func select(_ targets: [IndexPath], in tableView: UITableView) {
        let rows = Set(targets.filter { indexPath in
            indexPath.section < tableView.numberOfSections
                && indexPath.row < tableView.numberOfRows(inSection: indexPath.section)
        })
        for indexPath in tableView.indexPathsForSelectedRows ?? [] where !rows.contains(indexPath) {
            tableView.deselectRow(at: indexPath, animated: false)
        }
        for indexPath in rows {
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        }
    }

    private static func select(_ targets: [IndexPath], in collectionView: UICollectionView) {
        let items = Set(targets.filter { indexPath in
            indexPath.section < collectionView.numberOfSections
                && indexPath.item < collectionView.numberOfItems(inSection: indexPath.section)
        })
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] where !items.contains(indexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        for indexPath in items {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }
}
