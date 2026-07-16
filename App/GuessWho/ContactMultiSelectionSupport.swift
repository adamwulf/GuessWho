import UIKit
import GuessWhoSync

/// Shared UIKit behavior for every table whose rows are contacts. The list
/// controllers keep ownership of their diffable data source; this helper owns
/// only the platform selection affordance and selected-row projection.
@MainActor
enum ContactMultiSelectionSupport {
    static func configure(_ tableView: UITableView) {
        #if targetEnvironment(macCatalyst)
        // Command-click extends/reduces the selection, matching Mail/Finder.
        tableView.allowsMultipleSelection = true
        #else
        // Touch platforms enter the table's explicit Select mode. Normal taps
        // retain the established push-one-detail behavior.
        tableView.allowsMultipleSelectionDuringEditing = true
        #endif
    }

    static func selectionButton(action: @escaping @MainActor () -> Void) -> UIBarButtonItem? {
        #if targetEnvironment(macCatalyst)
        nil
        #else
        UIBarButtonItem(title: "Select", primaryAction: UIAction { _ in action() })
        #endif
    }

    static func updateSelectionButton(_ item: UIBarButtonItem?, isEditing: Bool) {
        item?.title = isEditing ? "Done" : "Select"
        item?.accessibilityLabel = isEditing ? "Finish Selecting Contacts" : "Select Contacts"
    }

    static func selectedIDs(
        in tableView: UITableView,
        itemIdentifier: (IndexPath) -> ContactID?
    ) -> [ContactID] {
        (tableView.indexPathsForSelectedRows ?? [])
            .sorted {
                ($0.section, $0.row) < ($1.section, $1.row)
            }
            .compactMap(itemIdentifier)
            .uniqued()
    }

    static func selectedContacts(
        in tableView: UITableView,
        repository: ContactsRepository,
        itemIdentifier: (IndexPath) -> ContactID?
    ) -> [Contact] {
        selectedIDs(in: tableView, itemIdentifier: itemIdentifier)
            .compactMap { repository.contact(id: $0) }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
