import UIKit
import GuessWhoSync

/// Single source of truth for the events-list sort order and its
/// persistence — the events-side sibling of `SortOrderSetting`. The chosen
/// `EventSortOrder` is stored in `UserDefaults` under a stable key (its
/// `rawValue`, which the package guarantees stable for exactly this reason)
/// so a relaunch restores the user's choice, and the repository's
/// `sortOrder` is the live in-memory copy the list reads.
///
/// There is ONE place that writes both: `apply(_:to:)`. The picker calls it,
/// `restore(into:)` reads the persisted value at launch and seeds the
/// repository before the first list renders. Setting `repository.sortOrder`
/// posts `.eventsRepositoryDidReload`, which the events list already
/// observes — so a change ripples to every visible list with no extra wiring.
enum EventSortOrderSetting {
    /// Stable `UserDefaults` key. Namespaced like the other app settings so it
    /// can't collide with a package or system default.
    static let key = "com.milestonemade.guesswho.settings.eventListSortOrder"

    /// The order to fall back to when nothing is persisted yet (or the stored
    /// string no longer maps to a case). Matches the repository's own default
    /// so a fresh install and a launched-once install agree.
    static let defaultOrder: EventSortOrder = .chronological

    /// The currently persisted order, or `defaultOrder` when absent/invalid.
    /// Reads the raw string and round-trips it through `EventSortOrder` so a
    /// stale or hand-edited value can't crash — an unknown string falls back.
    static var current: EventSortOrder {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let order = EventSortOrder(rawValue: raw) else {
            return defaultOrder
        }
        return order
    }

    /// Seed the repository from the persisted value. Call ONCE at launch,
    /// before the first list renders, so a relaunch restores the choice. No-op
    /// notification cost: the repository's `didSet` only posts when the value
    /// actually changes, so seeding the default-on-default case stays quiet.
    @MainActor
    static func restore(into repository: EventsRepository) {
        repository.sortOrder = current
    }

    /// The ONLY setter the picker calls: persist the choice AND push it into
    /// the repository. The repository's `didSet` posts
    /// `.eventsRepositoryDidReload`, which drives the list to re-snapshot —
    /// so this one call is the whole update.
    @MainActor
    static func apply(_ order: EventSortOrder, to repository: EventsRepository) {
        UserDefaults.standard.set(order.rawValue, forKey: key)
        repository.sortOrder = order
    }
}

extension UIViewController {
    /// Build the events-list pull-down sort menu — same checkmark rule and
    /// setter discipline as `makeSortMenu(repository:)` for the person lists.
    /// Built fresh on each call so the checkmark reflects the live order. Call
    /// it in `viewDidLoad` to install the button's menu and again in the
    /// repository-reload observer to move the checkmark after a change.
    @MainActor
    func makeEventSortMenu(repository: EventsRepository) -> UIMenu {
        let current = repository.sortOrder
        let actions = EventSortOrder.allCases.map { order -> UIAction in
            UIAction(
                title: order.title,
                state: order == current ? .on : .off
            ) { [weak repository] _ in
                guard let repository else { return }
                EventSortOrderSetting.apply(order, to: repository)
            }
        }
        return UIMenu(title: "Sort By", children: actions)
    }

    /// A nav-bar pull-down button wrapping `makeEventSortMenu`. Same glyph as
    /// the person lists' sort button so the affordance reads identically
    /// across tabs. The list installs this in its nav bar and refreshes
    /// `.menu` in its reload observer so the checkmark tracks the order.
    @MainActor
    func makeEventSortBarButtonItem(repository: EventsRepository) -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down.circle"),
            menu: makeEventSortMenu(repository: repository)
        )
    }
}
