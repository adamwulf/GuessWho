import UIKit
import GuessWhoSync

/// Shared UIKit behavior for every table whose rows are contacts. The list
/// controllers keep ownership of their diffable data source; this helper owns
/// only the platform selection affordance and selected-row projection.
@MainActor
enum ContactMultiSelectionSupport {
    /// Selection-order bookkeeping for `selectedIDs`. Each list controller owns
    /// one instance and feeds it from its `didSelectRowAt` / `didDeselectRowAt`
    /// delegate methods.
    typealias RecencyTracker = SelectionRecencyTracker<ContactID>

    static func configure(_ tableView: UITableView) {
        #if targetEnvironment(macCatalyst)
        // Command-click extends/reduces the selection, matching Mail/Finder.
        tableView.allowsMultipleSelection = true
        #else
        // No nav-bar Select affordance on iPhone: multi-select isn't a promoted
        // feature there. A two-finger pan still enters the table's editing
        // selection, and a trackpad/keyboard can extend it, but normal taps
        // retain the established push-one-detail behavior.
        tableView.allowsMultipleSelectionDuringEditing = true
        #endif
    }

    /// The table's selected rows, MOST-RECENTLY-SELECTED FIRST — the order
    /// `ContactDetailStackView` piles them in, so the contact the user just
    /// added to the selection is the front card.
    ///
    /// The table view remains the SOURCE OF TRUTH for *which* rows are
    /// selected; `recency` only supplies *order*. The result is always exactly
    /// the set `indexPathsForSelectedRows` resolves to — ids the tracker never
    /// saw (or has since pruned) fall back to the original (section, row) order
    /// at the end rather than being dropped.
    static func selectedIDs(
        in tableView: UITableView,
        recency: RecencyTracker,
        itemIdentifier: (IndexPath) -> ContactID?
    ) -> [ContactID] {
        let inListOrder = (tableView.indexPathsForSelectedRows ?? [])
            .sorted {
                ($0.section, $0.row) < ($1.section, $1.row)
            }
            .compactMap(itemIdentifier)
            .uniqued()
        return recency.order(inListOrder)
    }

    static func selectedContacts(
        in tableView: UITableView,
        repository: ContactsRepository,
        recency: RecencyTracker,
        itemIdentifier: (IndexPath) -> ContactID?
    ) -> [Contact] {
        selectedIDs(in: tableView, recency: recency, itemIdentifier: itemIdentifier)
            .compactMap { repository.contact(id: $0) }
    }
}

/// Remembers the ORDER in which ids were selected so a multi-selection can be
/// presented most-recently-selected first.
///
/// This is deliberately NOT a record of *what* is selected — the table view owns
/// that. The tracker stores a monotonic stamp per id and `order(_:)` uses it to
/// permute a caller-supplied selection: same elements, same count, never an
/// invented or dropped id. That split is what keeps a missed callback (a
/// programmatic `selectRow`/`deselectRow` sends none, and a diffable apply can
/// drop a selected row outright) from corrupting the selection itself — the
/// worst it can do is leave an id in list-order position.
///
/// Stale entries can't linger: every `order(_:)` prunes the stamps down to the
/// ids the caller just reported as selected, and stamps only ever accumulate
/// through a selection callback that is itself followed by an `order(_:)`.
///
/// Generic over `ID` rather than hard-coded to `ContactID` so the ordering rules
/// are unit-testable — `ContactID` has no app-visible initializer (see
/// `docs/contact-identity.md`).
@MainActor
final class SelectionRecencyTracker<ID: Hashable> {
    /// Selection stamps, highest = most recently selected. Absent means "never
    /// seen, or pruned" — such ids keep the caller's own ordering.
    private var stamps: [ID: Int] = [:]

    /// Next stamp to hand out. Reset to zero whenever `stamps` empties (nothing
    /// holds a stamp to collide with), so it can't climb without bound across a
    /// long session of selecting and clearing.
    private var nextStamp = 0

    init() {}

    /// Record that `id` just entered the selection. A nil id (a row the data
    /// source can no longer resolve) is ignored — `order(_:)` falls back to
    /// list order for it.
    func recordSelection(of id: ID?) {
        guard let id else { return }
        stamps[id] = nextStamp
        nextStamp += 1
    }

    /// Record that `id` just left the selection, so a later re-selection sorts
    /// as brand new (front of the stack) rather than at its original position.
    func recordDeselection(of id: ID?) {
        guard let id else { return }
        stamps[id] = nil
    }

    /// Reorder `selected` — the live selection, in the caller's own order —
    /// most-recently-selected first.
    ///
    /// Also prunes: anything the caller no longer reports as selected is
    /// forgotten, which is what keeps rows removed by a snapshot apply (no
    /// deselect callback fires) from holding a stamp forever.
    func order(_ selected: [ID]) -> [ID] {
        prune(keeping: selected)
        // Partition on the same predicate so the two halves reassemble into a
        // pure permutation of `selected` — nothing invented, dropped, or
        // duplicated regardless of what the tracker believes.
        let known = selected
            .compactMap { id in stamps[id].map { (id: id, stamp: $0) } }
            .sorted { $0.stamp > $1.stamp }
            .map(\.id)
        let unknown = selected.filter { stamps[$0] == nil }
        return known + unknown
    }

    private func prune(keeping selected: [ID]) {
        let live = Set(selected)
        stamps = stamps.filter { live.contains($0.key) }
        if stamps.isEmpty {
            nextStamp = 0
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
