import SwiftUI
import Contacts
import ContactsUI

/// SwiftUI wrapper over `CNContactViewController` in editing mode. Used as
/// a sheet from `ContactDetailView` so users get Apple's full Contacts.app
/// editing experience for the underlying `CNContact` fields, without our
/// GuessWho-specific notes/links/events appearing in the editor.
///
/// Completion semantics:
/// - `contact != nil`     → Done OR Cancel-of-existing. `onDone` fires.
///                          The two aren't distinguishable cheaply; we
///                          refresh unconditionally — a Cancel just re-reads
///                          unchanged state.
/// - `contact == nil`     → observed to mean the user deleted the contact.
///                          Apple's docs only describe the non-nil cases
///                          explicitly, so the receiving side guards by
///                          re-fetching and only popping if the contact is
///                          actually gone (handles the rare case where this
///                          observation doesn't hold).
///
/// The VC does NOT auto-dismiss; the coordinator dismisses inside the
/// delegate callback before firing the closure.
struct ContactEditView: UIViewControllerRepresentable {
    let contact: CNContact
    let onDone: () -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDone: onDone, onDelete: onDelete)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let editor = CNContactViewController(for: contact)
        editor.allowsEditing = true
        editor.allowsActions = false
        editor.delegate = context.coordinator
        // Open straight into edit mode — matches the "Edit" button affordance
        // and skips the redundant read-only intermediate screen.
        editor.setEditing(true, animated: false)

        let nav = UINavigationController(rootViewController: editor)
        context.coordinator.navigationController = nav
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        weak var navigationController: UINavigationController?
        private let onDone: () -> Void
        private let onDelete: () -> Void

        init(onDone: @escaping () -> Void, onDelete: @escaping () -> Void) {
            self.onDone = onDone
            self.onDelete = onDelete
        }

        nonisolated func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            // UIKit invokes delegate methods on the main thread. Hop onto
            // the main actor explicitly so the dismiss + callback run
            // isolated.
            let didDelete = contact == nil
            MainActor.assumeIsolated {
                navigationController?.dismiss(animated: true)
                if didDelete {
                    onDelete()
                } else {
                    onDone()
                }
            }
        }
    }
}
