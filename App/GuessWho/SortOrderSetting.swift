import UIKit
import GuessWhoSync

/// Single source of truth for the GLOBAL contact-list sort order and its
/// persistence. The chosen `ContactSortOrder` is stored in `UserDefaults`
/// under a stable key (its `rawValue`, which the package guarantees stable for
/// exactly this reason) so a relaunch restores the user's choice, and the
/// repository's `sortOrder` is the live in-memory copy every list reads.
///
/// There is ONE place that writes both: `apply(_:to:)`. The picker calls it,
/// `restore(into:)` reads the persisted value at launch and seeds the
/// repository before the first list renders. Setting `repository.sortOrder`
/// posts `.contactsRepositoryDidReload`, which every person list already
/// observes — so a change ripples to every visible list with no extra wiring.
enum SortOrderSetting {
    /// Stable `UserDefaults` key. Namespaced like the other app settings so it
    /// can't collide with a package or system default.
    static let key = "com.milestonemade.guesswho.settings.contactListSortOrder"

    /// The order to fall back to when nothing is persisted yet (or the stored
    /// string no longer maps to a case). Matches the repository's own default
    /// so a fresh install and a launched-once install agree.
    static let defaultOrder: ContactSortOrder = .lastFirst

    /// The currently persisted order, or `defaultOrder` when absent/invalid.
    /// Reads the raw string and round-trips it through `ContactSortOrder` so a
    /// stale or hand-edited value can't crash — an unknown string falls back.
    static var current: ContactSortOrder {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let order = ContactSortOrder(rawValue: raw) else {
            return defaultOrder
        }
        return order
    }

    /// Seed the repository from the persisted value. Call ONCE at launch,
    /// before the first list renders, so a relaunch restores the choice. No-op
    /// notification cost: the repository's `didSet` only posts when the value
    /// actually changes, so seeding the default-on-default case stays quiet.
    @MainActor
    static func restore(into repository: ContactsRepository) {
        repository.sortOrder = current
    }

    /// The ONLY setter the picker calls: persist the choice AND push it into
    /// the repository. The repository's `didSet` posts
    /// `.contactsRepositoryDidReload`, which drives every list to re-snapshot
    /// and re-section — so this one call is the whole global update.
    @MainActor
    static func apply(_ order: ContactSortOrder, to repository: ContactsRepository) {
        UserDefaults.standard.set(order.rawValue, forKey: key)
        repository.sortOrder = order
    }
}

extension UIViewController {
    /// Shared two-option relationship filter used by People, Organizations,
    /// and Places. Each screen supplies its own current state and setter, so
    /// the controls are independent while presenting identical All/Linked
    /// semantics.
    @MainActor
    func makeLinkFilterMenu(
        current: LinkFilter,
        onSelect: @escaping (LinkFilter) -> Void
    ) -> UIMenu {
        let actions = LinkFilter.allCases.map { filter in
            UIAction(
                title: filter == .all ? "All" : "Linked",
                state: filter == current ? .on : .off
            ) { _ in
                onSelect(filter)
            }
        }
        return UIMenu(title: "Filter", children: actions)
    }

    /// Textual nav-bar Filter button wrapping `makeLinkFilterMenu`.
    @MainActor
    func makeLinkFilterBarButtonItem(
        current: LinkFilter,
        onSelect: @escaping (LinkFilter) -> Void
    ) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: "Filter",
            image: nil,
            primaryAction: nil,
            menu: makeLinkFilterMenu(current: current, onSelect: onSelect)
        )
        item.accessibilityLabel = "Filter"
        return item
    }

    /// Build the shared pull-down sort menu used by every person list
    /// (`ContactsListViewController`, `OrganizationsListViewController`,
    /// `GroupMembersListViewController`). Factored here so all three present an
    /// IDENTICAL menu — DRY: one list of orders, one checkmark rule, one
    /// setter. The current `repository.sortOrder` gets a checkmark; selecting
    /// any other order routes through `SortOrderSetting.apply` (persist + set),
    /// which posts the reload that re-renders every visible list.
    ///
    /// Built fresh on each call so the checkmark reflects the live order. Call
    /// it in `viewDidLoad` to install the button's menu and again in the
    /// repository-reload observer to move the checkmark after a global change.
    @MainActor
    func makeSortMenu(repository: ContactsRepository) -> UIMenu {
        let current = repository.sortOrder
        let actions = ContactSortOrder.allCases.map { order -> UIAction in
            UIAction(
                title: order.title,
                state: order == current ? .on : .off
            ) { [weak repository] _ in
                guard let repository else { return }
                SortOrderSetting.apply(order, to: repository)
            }
        }
        return UIMenu(title: "Sort By", children: actions)
    }

    /// A nav-bar pull-down button wrapping `makeSortMenu`. The
    /// `line.3.horizontal.decrease.circle` glyph reads as "sort/filter" and
    /// matches Apple's own list-sort affordances. Each list installs this as
    /// its `rightBarButtonItem` and refreshes `.menu` in its reload observer so
    /// the checkmark tracks the global order.
    @MainActor
    func makeSortBarButtonItem(repository: ContactsRepository) -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"),
            menu: makeSortMenu(repository: repository)
        )
    }
}
