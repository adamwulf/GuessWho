import UIKit
import GuessWhoSync

/// Shared presentation pieces for every surface that creates, renames, or
/// changes the membership of a Contacts.app group — the Groups list and the
/// contact lists' "Add to Group" context menu.
///
/// These started life inside `GroupsListViewController`. They live here because
/// a second caller needs the SAME name validation, the SAME disabled-until-valid
/// prompt, and the SAME error copy; a copy in each file would drift into two
/// different answers to "what does Contacts say when it refuses."

enum GroupNameInput {
    static func normalized(_ value: String?) -> String? {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}

/// Builds the one-field "name this group" alert.
///
/// The confirm action starts disabled for a blank/whitespace-only field and
/// re-evaluates on every keystroke, so a group can never be created or renamed
/// to an empty name. That enable/disable behavior is the reason this is a shared
/// builder rather than a string constant: it is easy to forget and easy to get
/// subtly wrong (trimming, the initial state, the clear button).
@MainActor
enum GroupNamePrompt {
    /// - Parameters:
    ///   - title: Alert title, e.g. "New Group".
    ///   - actionTitle: Confirm button title, e.g. "Add" / "Rename".
    ///   - initialName: Pre-filled text; nil for a fresh group (which starts the
    ///     confirm action disabled).
    ///   - completion: Receives the NORMALIZED name — never blank.
    static func makeAlert(
        title: String,
        actionTitle: String,
        initialName: String?,
        completion: @escaping (String) -> Void
    ) -> UIAlertController {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        // Built before `addTextField` so the field's editing-changed handler can
        // capture it; UIKit lays text fields out above the actions regardless of
        // the order they are added in.
        let confirm = UIAlertAction(title: actionTitle, style: .default) { [weak alert] _ in
            guard let name = GroupNameInput.normalized(alert?.textFields?.first?.text) else { return }
            completion(name)
        }
        confirm.isEnabled = GroupNameInput.normalized(initialName) != nil

        alert.addTextField { textField in
            textField.placeholder = "Group Name"
            textField.text = initialName
            textField.clearButtonMode = .whileEditing
            // A `UIAction` rather than target/action: the control owns the
            // closure, so this needs no long-lived target object. Both captures
            // are weak — the field retains the action, and the alert retains
            // both the field and `confirm`.
            textField.addAction(
                UIAction { [weak confirm, weak textField] _ in
                    confirm?.isEnabled = GroupNameInput.normalized(textField?.text) != nil
                },
                for: .editingChanged
            )
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(confirm)
        return alert
    }
}

struct GroupMutationErrorPresentation {
    let message: String
    let shouldRefreshGroups: Bool

    static func make(
        error: Error,
        authorization: StoreAuthorizationStatus
    ) -> GroupMutationErrorPresentation {
        if let contactStoreError = error as? ContactStoreError,
           case .groupNotFound = contactStoreError {
            return GroupMutationErrorPresentation(
                message: "This group was already removed. The Groups list has been refreshed.",
                shouldRefreshGroups: true
            )
        }

        switch authorization {
        case .denied, .restricted:
            return GroupMutationErrorPresentation(
                message: "Allow Guess Who to access Contacts in Settings, then try again.",
                shouldRefreshGroups: false
            )
        case .notDetermined, .authorized:
            return GroupMutationErrorPresentation(
                message: "Contacts couldn’t complete this change. Please try again.",
                shouldRefreshGroups: false
            )
        }
    }
}

extension ContactGroup {
    /// The user-facing name for a group, falling back to a neutral placeholder
    /// for an (effectively never) empty name. Shared so a group reads the same
    /// in a list row, a menu item, and an alert.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(Unnamed Group)" : trimmed
    }
}
