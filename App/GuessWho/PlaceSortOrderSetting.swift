import UIKit
import GuessWhoSync

/// Single source of truth for the guide-places-list sort order and its
/// persistence — the places-side sibling of `GuideSortOrderSetting`. The
/// chosen `PlaceSortOrder` is stored in `UserDefaults` under a stable key (its
/// `rawValue`) so a relaunch restores the user's choice, and the repository's
/// `placeSortOrder` is the live in-memory copy every guide's places list
/// reads. The order is global — the same choice applies to every guide's
/// places, like the guides-list and person-list sort orders.
///
/// There is ONE place that writes both: `apply(_:to:)`. The picker calls it,
/// `restore(into:)` reads the persisted value at launch and seeds the
/// repository before the first list renders. Setting `repository.placeSortOrder`
/// posts `.guidesRepositoryDidReload`, which the places list already observes.
enum PlaceSortOrderSetting {
    /// Stable `UserDefaults` key. Namespaced like the other app settings so it
    /// can't collide with a package or system default.
    static let key = "com.milestonemade.guesswho.settings.placeListSortOrder"

    /// The order to fall back to when nothing is persisted yet (or the stored
    /// string no longer maps to a case). Matches the repository's own default
    /// (and the list's historical guide-entry-order behavior).
    static let defaultOrder: PlaceSortOrder = .guideOrder

    /// The currently persisted order, or `defaultOrder` when absent/invalid.
    /// Reads the raw string and round-trips it through `PlaceSortOrder` so a
    /// stale or hand-edited value can't crash — an unknown string falls back.
    static var current: PlaceSortOrder {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let order = PlaceSortOrder(rawValue: raw) else {
            return defaultOrder
        }
        return order
    }

    /// Seed the repository from the persisted value. Call ONCE at launch,
    /// before the first list renders, so a relaunch restores the choice. The
    /// repository's `didSet` only posts when the value actually changes, so
    /// seeding the default-on-default case stays quiet.
    @MainActor
    static func restore(into repository: GuidesRepository) {
        repository.placeSortOrder = current
    }

    /// The ONLY setter the picker calls: persist the choice AND push it into
    /// the repository. The repository's `didSet` posts
    /// `.guidesRepositoryDidReload`, which drives the list to re-snapshot.
    @MainActor
    static func apply(_ order: PlaceSortOrder, to repository: GuidesRepository) {
        UserDefaults.standard.set(order.rawValue, forKey: key)
        repository.placeSortOrder = order
    }
}

extension UIViewController {
    /// Build the guide-places pull-down sort menu — same checkmark rule and
    /// setter discipline as `makeGuideSortMenu(repository:)`. Built fresh on
    /// each call so the checkmark reflects the live order.
    @MainActor
    func makePlaceSortMenu(repository: GuidesRepository) -> UIMenu {
        let current = repository.placeSortOrder
        let actions = PlaceSortOrder.allCases.map { order -> UIAction in
            UIAction(
                title: order.title,
                state: order == current ? .on : .off
            ) { [weak repository] _ in
                guard let repository else { return }
                PlaceSortOrderSetting.apply(order, to: repository)
            }
        }
        return UIMenu(title: "Sort By", children: actions)
    }

    /// A nav-bar pull-down button wrapping `makePlaceSortMenu`. Same glyph as
    /// the guides / events / person lists' sort button so the affordance reads
    /// identically. The list refreshes `.menu` in its reload observer so the
    /// checkmark tracks the order.
    @MainActor
    func makePlaceSortBarButtonItem(repository: GuidesRepository) -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down.circle"),
            menu: makePlaceSortMenu(repository: repository)
        )
    }
}
