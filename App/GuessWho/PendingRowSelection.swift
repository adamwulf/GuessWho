import UIKit

/// One list's outstanding "highlight this row" request.
///
/// The Catalyst sidebar's favorite children ask a section list to select a row
/// in the same turn they build it — long before the list's first reload lands,
/// so the row usually doesn't exist yet. The request is held here and retried
/// after every snapshot apply, so the row is selected when its data arrives
/// rather than dropped. It is retired the moment the user takes over.
///
/// Selecting programmatically sends no delegate callback, so the caller stays
/// responsible for whatever its own `didSelectRowAt` would have done — the two
/// contact lists stamp their `SelectionRecencyTracker` from the returned id.
/// That split is why this owns only the row, never the surrounding behavior.
///
/// Generic over the list's diffable item id so all four section lists share one
/// implementation (`ContactID`, `UUID`, and a group's `localID` string).
@MainActor
final class PendingRowSelection<ID: Hashable> {
    private var pending: ID?

    init() {}

    /// Ask for `id`'s row, replacing any earlier unfulfilled request.
    func request(_ id: ID) {
        pending = id
    }

    /// Drop the request because the user is now driving — a row they picked
    /// themselves, or a list they scrolled by hand. Without this, a reload
    /// minutes later would yank the selection (and the scroll position) back to
    /// a row they have long since moved on from.
    func cancel() {
        pending = nil
    }

    /// Select the requested row if it exists in `tableView` now, scrolling it
    /// into view, and return the id that was consumed.
    ///
    /// Returns nil when there is no request, or when its row hasn't arrived yet
    /// — in which case the request stays pending for the next apply. The table's
    /// own counts are checked, not just the data source's, so a lookup that
    /// races an in-flight apply can't select an index path the table doesn't
    /// have.
    @discardableResult
    func applyIfPossible(
        in tableView: UITableView,
        indexPath: (ID) -> IndexPath?
    ) -> ID? {
        guard let id = pending,
              let target = indexPath(id),
              target.section < tableView.numberOfSections,
              target.row < tableView.numberOfRows(inSection: target.section)
        else { return nil }
        pending = nil
        tableView.selectRow(at: target, animated: false, scrollPosition: .middle)
        return id
    }
}
