import UIKit
import GuessWhoSync

/// Routes a favorited row to the context menu its kind gets everywhere else, so
/// a favorite behaves the same whether it is shown in the Favorites list or as a
/// child in the Catalyst sidebar. One instance per host controller; the host
/// supplies only how a row resolves to a `FavoriteListItem`.
///
/// The routing is the whole point of the abstraction: a favorited person or
/// organization gets the "Add to Group" menu (both can hold group membership); a
/// favorited group gets Email All Members / Rename / Delete; events, guides,
/// places, and departments have no row menu today and so get none here — the
/// same nil that gates a non-contact row in `AddToGroupMenu`. When a kind gains
/// a menu in its own list, teaching this one switch surfaces it in every
/// favorites surface at once.
///
/// Both owned menus present their own alerts against `host` and are unguarded
/// (no "＋" button to disable), which is why neither takes the Groups list's
/// queue-until-visible presenter or mutation callbacks.
@MainActor
final class FavoriteContextMenuRouter {
    private let addToGroupMenu: AddToGroupMenu
    private let groupContextMenu: GroupContextMenu
    private let itemForRow: (IndexPath) -> FavoriteListItem?

    init(
        repository: ContactsRepository,
        favoritesStore: FavoritesListStore,
        host: UIViewController,
        itemForRow: @escaping (IndexPath) -> FavoriteListItem?
    ) {
        self.itemForRow = itemForRow
        self.addToGroupMenu = AddToGroupMenu(repository: repository, host: host)
        self.groupContextMenu = GroupContextMenu(
            repository: repository,
            favoritesStore: favoritesStore,
            host: host
        )
    }

    /// The configuration to return from the host's row context-menu delegate
    /// method. Nil for a row that resolves to no item (a stale index path
    /// mid-apply) or to a kind with no menu.
    func configuration(forRowAt indexPath: IndexPath) -> UIContextMenuConfiguration? {
        guard let item = itemForRow(indexPath) else { return nil }
        switch item.kind {
        case .contact:
            guard let contact = item.contact else { return nil }
            return addToGroupMenu.configuration(for: [contact])
        case .group:
            guard let group = item.group else { return nil }
            return groupContextMenu.configuration(for: group)
        case .event, .guide, .place, .department:
            return nil
        }
    }

    /// Forward the Catalyst group-Email `UICommand` (and its Option alternate)
    /// from the host's `GroupContextMenuEmailResponder` conformance to the group
    /// menu that built it.
    func handleGroupEmailCommand(_ sender: UICommand, individually: Bool) {
        groupContextMenu.handleEmailCommand(sender, individually: individually)
    }
}
