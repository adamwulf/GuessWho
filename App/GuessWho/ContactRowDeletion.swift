import UIKit
import GuessWhoSync

/// The trailing-swipe "Delete" on a person or organization row. Shared by the
/// People and Organizations lists so both confirm, delete, and report a
/// failure the same way.
///
/// The swipe is a shortcut to the same write as "Delete Contact" in the
/// detail view's edit mode: the record is removed from Contacts on every
/// device. So it always confirms first, names the record it is about to
/// delete, and never deletes on a full swipe.
///
/// Row removal is not done here. A successful delete makes the repository
/// post `.contactsRepositoryDidReload`, and the list's observer re-applies
/// its snapshot, which animates the row out. That is also why the contextual
/// action reports `false` to its completion before the confirmation shows:
/// `true` on a destructive action tells the table the row is already gone,
/// and the table would collapse a row its data source still holds — wrong
/// both while the alert is up and when the user taps Cancel.
@MainActor
final class ContactRowDeletion {
    private let repository: ContactsRepository
    private weak var host: UIViewController?
    private let didDelete: (ContactID) -> Void

    /// - Parameters:
    ///   - host: the list controller; alerts present from it.
    ///   - didDelete: runs after the record is gone (or was found already
    ///     gone), so the shell can retire a detail that showed it.
    init(
        repository: ContactsRepository,
        host: UIViewController,
        didDelete: @escaping (ContactID) -> Void
    ) {
        self.repository = repository
        self.host = host
        self.didDelete = didDelete
    }

    /// A configuration with no actions. Return this — never nil — for a row
    /// that must not offer Delete: nil hands the row to UIKit's default
    /// delete, which the diffable data source never carries out.
    static var noActions: UISwipeActionsConfiguration {
        UISwipeActionsConfiguration(actions: [])
    }

    func swipeConfiguration(for contact: Contact) -> UISwipeActionsConfiguration {
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            // Close the swipe first (see the type comment), then ask.
            completion(false)
            self?.confirmDelete(contact)
        }
        delete.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        // A full swipe would run the handler without a tap on the button;
        // the confirmation still gates the write, but the gesture must not
        // read as "swipe far enough and it is gone".
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    // MARK: - Confirm

    private func confirmDelete(_ contact: Contact) {
        guard let host else { return }
        let noun = contact.contactType == .organization ? "organization" : "contact"
        let alert = UIAlertController(
            title: "Delete “\(contact.displayName)”?",
            message: "This removes the \(noun) from Contacts on all your devices.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            Task { await self?.performDelete(contact) }
        })
        host.present(alert, animated: true)
    }

    // MARK: - Delete

    private func performDelete(_ contact: Contact) async {
        let id = contact.contactID
        do {
            // `false` means the id no longer resolves in the cache — the row
            // is on its way out with the reload that dropped it, so there is
            // nothing to delete and nothing to report.
            guard try await repository.deleteContact(id: id) else { return }
            didDelete(id)
        } catch {
            let category = ContactEditModel.saveErrorCategory(error)
            // Deleted elsewhere between the swipe and the confirmation: that
            // is the outcome the user asked for. Drop it from the cache so the
            // row leaves now instead of at the next reload.
            if category == .recordDoesNotExist {
                repository.removeContact(id: id)
                didDelete(id)
            } else {
                presentFailure(category)
            }
        }
    }

    private func presentFailure(_ category: ContactEditModel.SaveErrorCategory) {
        guard let host else { return }
        let alert = UIAlertController(
            title: "Couldn't delete",
            message: category.deleteFailureMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        if category == .authorizationDenied {
            alert.addAction(UIAlertAction(title: ContactsSettingsLink.buttonTitle, style: .default) { _ in
                ContactsSettingsLink.open()
            })
        }
        host.present(alert, animated: true)
    }
}
