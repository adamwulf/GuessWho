import UIKit
import GuessWhoSync
import GuessWhoLogging

/// The two-way responder-chain hook for the group Email command's Option
/// alternate.
///
/// On Mac Catalyst the "Email All Members" menu item is a `UICommand` whose
/// `UICommandAlternate` swaps it to "Email Members Separately" while Option is
/// held (see `GroupContextMenu.emailElements`). A `UICommand` fires its action
/// down the responder chain rather than through a closure, so every controller
/// that hosts a group context menu implements these two methods and forwards
/// them to its `GroupContextMenu`. The group is carried across in the command's
/// `propertyList` (its `localID`), so the forwarders stay identity-agnostic.
@MainActor
@objc
protocol GroupContextMenuEmailResponder: AnyObject {
    func emailGroupMembers(_ sender: UICommand)
    func emailGroupMembersSeparately(_ sender: UICommand)
}

/// The delete half of a group mutation: remove the Contacts.app group, then
/// (best-effort) drop it from Favorites. Split out so the two-step outcome —
/// "the group is gone but couldn't be un-favorited" — is expressible without a
/// running app. Lifted verbatim from `GroupsListViewController`, whose delete
/// path this now backs from `GroupContextMenu`.
@MainActor
struct GroupDeletionOperation {
    let deleteFromContacts: (ContactGroup) async throws -> Void
    let removeFromFavorites: (ContactGroup) async throws -> Void

    /// Returns a cleanup error only after Contacts deletion succeeded. Favorite
    /// removal is deliberately unconditional and idempotent; no UI cache is
    /// consulted before touching persistent favorites.
    func delete(_ group: ContactGroup) async throws -> Error? {
        try await deleteFromContacts(group)
        return await cleanupFavorite(for: group)
    }

    func cleanupFavorite(for group: ContactGroup) async -> Error? {
        do {
            try await removeFromFavorites(group)
            return nil
        } catch {
            return error
        }
    }
}

/// The group row context menu — Email All Members, Rename, Delete — and the
/// create/rename/delete flows behind it, shared by every surface that shows a
/// group: the Groups list, the Favorites list, and the Catalyst sidebar's
/// favorited-group rows.
///
/// One instance per host controller, exactly like `AddToGroupMenu`: the host
/// supplies only what differs between surfaces (how it presents an alert, and
/// what to disable while a mutation is in flight) and gets the menu, the name
/// prompt, the delete confirmation, the email composition, and all of the error
/// handling from here. Factored out so the Groups list and the sidebar can't
/// grow two different answers to "what does Contacts say when it refuses," and
/// so "email a group" lives in exactly one place.
///
/// Nothing here mentions the sidecar. Rename/Delete write real Contacts.app
/// groups and Email opens a real `mailto:` — the copy speaks only of contacts,
/// groups, members, and email.
@MainActor
final class GroupContextMenu {
    private let repository: ContactsRepository
    private let favoritesStore: FavoritesListStore
    /// The controller that presents alerts and owns this menu. Weak: the menu is
    /// owned BY that controller.
    private weak var host: UIViewController?
    private let deletionOperation: GroupDeletionOperation

    /// How the host puts an alert on screen. The Groups list routes this through
    /// its own queue-until-visible presenter; when nil, alerts self-present
    /// against `host` (dismissing anything already up first), the same fallback
    /// `AddToGroupMenu` uses.
    private let presentAlert: ((UIAlertController) -> Void)?

    /// Host UI to disable/re-enable around a mutation (e.g. the Groups list's
    /// "＋" button). Optional — the sidebar has nothing to gate.
    private let willBeginMutation: (() -> Void)?
    private let didEndMutation: (() -> Void)?

    /// Serializes mutations the same way `GroupsListViewController` used to:
    /// a second create/rename/delete is refused while one is in flight.
    private var isMutating = false

    /// The group whose context menu was most recently built — a fallback identity
    /// for the Catalyst Email command. A `UICommandAlternate` carries no
    /// `propertyList` of its own, so should the "Email Members Separately"
    /// alternate ever fire with a sender that lacks the base command's `localID`,
    /// the group is resolved from here instead of silently no-op'ing. Correct
    /// because only one context menu is open at a time.
    private var lastMenuGroupLocalID: String?

    private static let log = GuessWhoLog.logger("app.groups.contextmenu")

    /// Above this many recipients, "Email Members Separately" asks first — a
    /// wall of compose windows is a surprise worth confirming. Four opens
    /// silently; five or more confirms.
    private static let individualEmailConfirmationThreshold = 4

    init(
        repository: ContactsRepository,
        favoritesStore: FavoritesListStore,
        host: UIViewController,
        presentAlert: ((UIAlertController) -> Void)? = nil,
        willBeginMutation: (() -> Void)? = nil,
        didEndMutation: (() -> Void)? = nil
    ) {
        self.repository = repository
        self.favoritesStore = favoritesStore
        self.host = host
        self.presentAlert = presentAlert
        self.willBeginMutation = willBeginMutation
        self.didEndMutation = didEndMutation
        self.deletionOperation = GroupDeletionOperation(
            deleteFromContacts: { group in
                try await repository.deleteGroup(group)
            },
            removeFromFavorites: { group in
                _ = try await repository.setGroupFavorite(false, for: group)
                favoritesStore.reload()
            }
        )
    }

    // MARK: - Menu construction

    /// The configuration to return from a row's context-menu delegate method:
    /// Email All Members, then Rename and Delete below a separator. The group's
    /// name titles the menu, since Catalyst shows a plain AppKit menu with no row
    /// highlight to say which group was clicked.
    func configuration(for group: ContactGroup) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: group)
        }
    }

    private func menu(for group: ContactGroup) -> UIMenu {
        // Remember which group this menu is for, so the Catalyst Email alternate
        // can fall back to it if its command sender lacks the `localID`.
        lastMenuGroupLocalID = group.localID
        let email = UIMenu(title: "", options: .displayInline, children: emailElements(for: group))
        let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.rename(group)
        }
        let delete = UIAction(
            title: "Delete",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.confirmDelete(group)
        }
        return UIMenu(title: group.displayName, children: [email, rename, delete])
    }

    /// The Email item(s).
    ///
    /// On Mac Catalyst this is a single `UICommand` whose Option alternate swaps
    /// it to "Email Members Separately" — the idiomatic hold-Option-to-change-a-
    /// menu-item behavior (`UICommandAlternate`). The command carries the group's
    /// `localID` in its `propertyList` and fires down the responder chain to the
    /// host's `GroupContextMenuEmailResponder` methods.
    ///
    /// Elsewhere (iPhone/iPad) there is no Option key, so both choices are shown
    /// as ordinary closure-backed actions — otherwise "email separately" would be
    /// unreachable.
    private func emailElements(for group: ContactGroup) -> [UIMenuElement] {
        let envelope = UIImage(systemName: "envelope")
        #if targetEnvironment(macCatalyst)
        let separately = UICommandAlternate(
            title: "Email Members Separately",
            action: #selector(GroupContextMenuEmailResponder.emailGroupMembersSeparately(_:)),
            modifierFlags: .alternate
        )
        let emailAll = UICommand(
            title: "Email All Members",
            image: envelope,
            action: #selector(GroupContextMenuEmailResponder.emailGroupMembers(_:)),
            propertyList: group.localID,
            alternates: [separately]
        )
        return [emailAll]
        #else
        let emailAll = UIAction(title: "Email All Members", image: envelope) { [weak self] _ in
            self?.emailMembers(of: group, individually: false)
        }
        let separately = UIAction(
            title: "Email Members Separately",
            image: UIImage(systemName: "envelope.badge")
        ) { [weak self] _ in
            self?.emailMembers(of: group, individually: true)
        }
        return [emailAll, separately]
        #endif
    }

    // MARK: - Email

    /// Responder-chain entry point for the Catalyst `UICommand` and its Option
    /// alternate. The group rides in as its `localID` (the base command's
    /// `propertyList`); the alternate carries none of its own, so it falls back to
    /// the group whose menu is currently open. Its display name is resolved from
    /// the repository's warm groups cache (filled by whichever list showed the
    /// row) for the alert copy, falling back gracefully if it isn't there. The
    /// member fetch keys on the `localID` regardless, so email still works even if
    /// the name can't be resolved.
    func handleEmailCommand(_ sender: UICommand, individually: Bool) {
        guard let localID = (sender.propertyList as? String) ?? lastMenuGroupLocalID else { return }
        let name = repository.groups.first { $0.localID == localID }?.displayName
        emailMembers(localID: localID, displayName: name, individually: individually)
    }

    /// Closure entry point for the iPhone/iPad actions, which capture the whole
    /// group directly.
    private func emailMembers(of group: ContactGroup, individually: Bool) {
        emailMembers(localID: group.localID, displayName: group.displayName, individually: individually)
    }

    private func emailMembers(localID: String, displayName: String?, individually: Bool) {
        Task { await performEmail(localID: localID, displayName: displayName, individually: individually) }
    }

    private func performEmail(localID: String, displayName: String?, individually: Bool) async {
        let members = await repository.members(ofGroup: localID)
        let recipients = GroupEmailComposer.recipients(for: members)
        guard !recipients.isEmpty else {
            presentNoAddressesAlert(groupName: displayName)
            return
        }
        if individually {
            if recipients.count > Self.individualEmailConfirmationThreshold {
                confirmIndividualEmail(recipients: recipients, groupName: displayName)
            } else {
                await openIndividual(recipients)
            }
        } else {
            await openCombined(recipients)
        }
    }

    private func openCombined(_ recipients: [String]) async {
        guard let url = GroupEmailComposer.combinedMailtoURL(recipients: recipients) else { return }
        if !(await open(url)) {
            presentMailUnavailableAlert()
        }
    }

    /// Open one compose window per recipient, in order. Sequential rather than a
    /// burst so the mail app receives them cleanly instead of racing a dozen
    /// simultaneous `open` calls. The "no mail app" alert shows only when NOTHING
    /// opened — once some drafts are up, the user sees them, and warning about a
    /// stray later failure would just be noise.
    private func openIndividual(_ recipients: [String]) async {
        var anyOpened = false
        for url in GroupEmailComposer.individualMailtoURLs(recipients: recipients) {
            if await open(url) { anyOpened = true }
        }
        if !anyOpened { presentMailUnavailableAlert() }
    }

    /// `UIApplication.open` bridged to async via a continuation — the completion
    /// form is available on every OS the app targets, where the async overload's
    /// availability is fussier.
    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Rename

    func rename(_ group: ContactGroup) {
        present(GroupNamePrompt.makeAlert(
            title: "Rename Group",
            actionTitle: "Rename",
            initialName: group.name
        ) { [weak self] name in
            guard let self, name != group.name else { return }
            Task {
                guard self.beginMutation() else { return }
                defer { self.endMutation() }
                do {
                    try await self.repository.renameGroup(group, to: name)
                } catch {
                    await self.presentMutationError(action: "rename", error: error)
                }
            }
        })
    }

    // MARK: - Delete

    func confirmDelete(_ group: ContactGroup) {
        let name = group.displayName
        let alert = UIAlertController(
            title: "Delete “\(name)”?",
            message: "Contacts in this group will not be deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                guard self.beginMutation() else { return }
                defer { self.endMutation() }
                do {
                    if let cleanupError = try await self.deletionOperation.delete(group) {
                        self.presentFavoriteCleanupError(cleanupError, for: group)
                    }
                } catch {
                    await self.presentMutationError(action: "delete", error: error)
                }
            }
        })
        present(alert)
    }

    // MARK: - Create (the Groups list "＋" button)

    /// Prompt for a name and create a new group. Only the Groups list drives
    /// this; it lives here so the create flow reuses the same prompt, mutation
    /// guard, and error copy as rename and delete.
    func promptForNewGroup() {
        present(GroupNamePrompt.makeAlert(
            title: "New Group",
            actionTitle: "Add",
            initialName: nil
        ) { [weak self] name in
            guard let self else { return }
            Task {
                guard self.beginMutation() else { return }
                defer { self.endMutation() }
                do {
                    _ = try await self.repository.createGroup(name: name)
                } catch {
                    await self.presentMutationError(action: "create", error: error)
                }
            }
        })
    }

    // MARK: - Mutation guard

    private func beginMutation() -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        willBeginMutation?()
        return true
    }

    private func endMutation() {
        isMutating = false
        didEndMutation?()
    }

    // MARK: - Alerts

    private func presentNoAddressesAlert(groupName: String?) {
        let scope = groupName.map { "in “\($0)”" } ?? "in this group"
        let alert = UIAlertController(
            title: "No Email Addresses",
            message: "No one \(scope) has an email address.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    private func presentMailUnavailableAlert() {
        let alert = UIAlertController(
            title: "Couldn’t Open Mail",
            message: "No email app is set up to send this message.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    private func confirmIndividualEmail(recipients: [String], groupName: String?) {
        let count = recipients.count
        let scope = groupName.map { "“\($0)”" } ?? "this group"
        let alert = UIAlertController(
            title: "Email \(count) Members Separately?",
            message: "This opens \(count) separate email drafts — one for each member of \(scope) who has an email address.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open \(count) Drafts", style: .default) { [weak self] _ in
            Task { await self?.openIndividual(recipients) }
        })
        present(alert)
    }

    private func presentMutationError(action: String, error: Error) async {
        Self.log.error("couldn't \(action) group: \(error.localizedDescription)")
        let presentation = GroupMutationErrorPresentation.make(
            error: error,
            authorization: await repository.contactsAuthorizationStatus()
        )
        if presentation.shouldRefreshGroups {
            await repository.loadGroups()
        }
        let alert = UIAlertController(
            title: "Couldn’t \(action) group",
            message: presentation.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    private func presentFavoriteCleanupError(_ error: Error, for group: ContactGroup) {
        Self.log.error("couldn't remove deleted group from favorites: \(error.localizedDescription)")
        let alert = UIAlertController(
            title: "Group Deleted",
            message: "The group was deleted, but it couldn’t be removed from Favorites.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let retryError = await self.deletionOperation.cleanupFavorite(for: group) else {
                    return
                }
                self.presentFavoriteCleanupError(retryError, for: group)
            }
        })
        present(alert)
    }

    /// Route an alert through the host's presenter when one was supplied (the
    /// Groups list's queue-until-visible path), otherwise self-present against
    /// the host — dismissing anything already up first, since a context-menu
    /// action can fire while UIKit is still tearing the menu down. Mirrors
    /// `AddToGroupMenu.present`.
    private func present(_ alert: UIAlertController) {
        if let presentAlert {
            presentAlert(alert)
            return
        }
        guard let host, host.isViewLoaded, host.view.window != nil else {
            Self.log.error("no visible host for the group alert: \(alert.title ?? "")")
            return
        }
        if let presented = host.presentedViewController {
            presented.dismiss(animated: true) { [weak self] in
                self?.present(alert)
            }
            return
        }
        host.present(alert, animated: true)
    }
}
