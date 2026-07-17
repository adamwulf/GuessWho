import UIKit
import GuessWhoSync

/// Single source of truth for the unified Places tab's sort order and its
/// persistence — the cross-guide sibling of `PlaceSortOrderSetting` (which
/// covers the per-guide places lists). The chosen `AllPlacesSortOrder` is
/// stored in `UserDefaults` under a stable key (its `rawValue`) so a relaunch
/// restores the user's choice, and the repository's `allPlacesSortOrder` is
/// the live in-memory copy the Places tab reads. Deliberately a SEPARATE
/// setting from the per-guide order: re-sorting the unified tab must not
/// silently reorder every guide's own places screen.
///
/// There is ONE place that writes both: `apply(_:to:)`. The picker calls it,
/// `restore(into:)` reads the persisted value at launch and seeds the
/// repository before the first list renders. Setting
/// `repository.allPlacesSortOrder` posts `.guidesRepositoryDidReload`, which
/// the Places tab already observes.
enum AllPlacesSortOrderSetting {
    /// Stable `UserDefaults` key. Namespaced like the other app settings so it
    /// can't collide with a package or system default.
    static let key = "com.milestonemade.guesswho.settings.allPlacesListSortOrder"

    /// The order to fall back to when nothing is persisted yet (or the stored
    /// string no longer maps to a case). Matches the repository's own default.
    static let defaultOrder: AllPlacesSortOrder = .byGuide

    /// The currently persisted order, or `defaultOrder` when absent/invalid.
    /// Reads the raw string and round-trips it through `AllPlacesSortOrder` so
    /// a stale or hand-edited value can't crash — an unknown string falls back.
    static var current: AllPlacesSortOrder {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let order = AllPlacesSortOrder(rawValue: raw) else {
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
        repository.allPlacesSortOrder = current
    }

    /// The ONLY setter the picker calls: persist the choice AND push it into
    /// the repository. The repository's `didSet` posts
    /// `.guidesRepositoryDidReload`, which drives the list to re-snapshot.
    @MainActor
    static func apply(_ order: AllPlacesSortOrder, to repository: GuidesRepository) {
        UserDefaults.standard.set(order.rawValue, forKey: key)
        repository.allPlacesSortOrder = order
    }
}

extension UIViewController {
    /// Build the unified Places tab's pull-down sort menu — same checkmark
    /// rule and setter discipline as `makePlaceSortMenu(repository:)`. Built
    /// fresh on each call so the checkmark reflects the live order.
    @MainActor
    func makeAllPlacesSortMenu(repository: GuidesRepository) -> UIMenu {
        let current = repository.allPlacesSortOrder
        let actions = AllPlacesSortOrder.allCases.map { order -> UIAction in
            UIAction(
                title: order.title,
                state: order == current ? .on : .off
            ) { [weak repository] _ in
                guard let repository else { return }
                AllPlacesSortOrderSetting.apply(order, to: repository)
            }
        }
        return UIMenu(title: "Sort By", children: actions)
    }

    /// A nav-bar pull-down button wrapping `makeAllPlacesSortMenu`. Same glyph
    /// as the guides / events / person lists' sort button so the affordance
    /// reads identically. The list refreshes `.menu` in its reload observer so
    /// the checkmark tracks the order.
    @MainActor
    func makeAllPlacesSortBarButtonItem(repository: GuidesRepository) -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down.circle"),
            menu: makeAllPlacesSortMenu(repository: repository)
        )
    }
}
