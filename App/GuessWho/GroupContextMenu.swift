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
/// (best-effort) drop it from Favorites and from its folder. Split out so the
/// multi-step outcome — "the group is gone but couldn't be un-favorited", "the
/// group is gone but is still filed in its folder" — is expressible without a
/// running app. Lifted from `GroupsListViewController`, whose delete path this
/// now backs from `GroupContextMenu`.
///
/// Generic over the token that says what folder cleanup is still owed, so the
/// logic is testable without the package's own (deliberately opaque) type.
/// `Sendable` because the token crosses into the async cleanup closure.
@MainActor
struct GroupDeletionOperation<PendingFolderCleanup: Sendable> {
    /// What is left to tidy up after a deletion that SUCCEEDED.
    struct Outcome {
        var favoriteCleanupError: Error?
        var pendingFolderCleanup: PendingFolderCleanup?
    }

    /// Throws when the group was not deleted. Returns non-nil when it was, and
    /// taking it out of its folder is still owed.
    let deleteFromContacts: (ContactGroup) async throws -> PendingFolderCleanup?
    let removeFromFavorites: (ContactGroup) async throws -> Void
    let finishFolderCleanup: (PendingFolderCleanup) async throws -> Void

    /// Throws only when the Contacts deletion itself failed. Favorite removal
    /// is deliberately unconditional and idempotent; no UI cache is consulted
    /// before touching persistent favorites.
    func delete(_ group: ContactGroup) async throws -> Outcome {
        let pending = try await deleteFromContacts(group)
        return Outcome(
            favoriteCleanupError: await cleanupFavorite(for: group),
            pendingFolderCleanup: pending)
    }

    func cleanupFavorite(for group: ContactGroup) async -> Error? {
        do {
            try await removeFromFavorites(group)
            return nil
        } catch {
            return error
        }
    }

    /// Retry the folder cleanup. Returns the token again when it is STILL owed.
    /// Never deletes anything: the group is already gone.
    func retryFolderCleanup(_ pending: PendingFolderCleanup) async -> PendingFolderCleanup? {
        do {
            try await finishFolderCleanup(pending)
            return nil
        } catch {
            return pending
        }
    }
}

/// The group row context menu — Email All Members, Rename, Move to…, Delete —
/// and the create/rename/delete flows behind it, shared by every surface that
/// shows a group: the Groups list, the Favorites list, and the Catalyst
/// sidebar's favorited-group rows. It also owns the FOLDER flows the Groups
/// list drives (new, rename, move, delete, and the folder row's menu), so a
/// folder command and a group command share one mutation guard and report
/// failure the same way — and so drag and drop and the "Move to…" menu move an
/// item through the very same call.
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
    private let deletionOperation: GroupDeletionOperation<PendingGroupPlacementCleanup>

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
            },
            finishFolderCleanup: { pending in
                try await repository.retryGroupPlacementCleanup(pending)
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
        var children: [UIMenuElement] = [email, rename]
        if let move = moveMenu(for: .group(group.localID)) { children.append(move) }
        children.append(delete)
        return UIMenu(title: group.displayName, children: children)
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
                    let outcome = try await self.deletionOperation.delete(group)
                    // The group IS deleted past this point. Anything still owed
                    // is reported as such, never as a failed delete.
                    if let cleanupError = outcome.favoriteCleanupError {
                        self.presentFavoriteCleanupError(
                            cleanupError, for: group, thenFolderCleanup: outcome.pendingFolderCleanup)
                    } else if let pending = outcome.pendingFolderCleanup {
                        self.presentFolderCleanupPending(pending)
                    }
                } catch {
                    await self.presentMutationError(action: "delete", error: error)
                }
            }
        })
        present(alert)
    }

    // MARK: - Create (the Groups list "＋" button)

    /// Prompt for a name and create a new group inside `parentFolderID` (nil =
    /// the top level). Only the Groups list drives this; it lives here so the
    /// create flow reuses the same prompt, mutation guard, and error copy as
    /// rename and delete. The prompt says where the group will go.
    func promptForNewGroup(inFolder parentFolderID: String? = nil) {
        let tree = repository.groupFolderTree
        present(GroupNamePrompt.makeAlert(
            title: "New Group",
            actionTitle: "Add",
            initialName: nil,
            message: GroupFolderDestination.promptMessage(parentFolderID: parentFolderID, in: tree)
        ) { [weak self] name in
            guard let self else { return }
            Task {
                guard self.beginMutation() else { return }
                defer { self.endMutation() }
                do {
                    _ = try await self.repository.createGroup(name: name, inFolder: parentFolderID)
                    if let parentFolderID { self.didPlaceItem?(parentFolderID) }
                } catch let failure as GroupPlacementFailedError {
                    // The group EXISTS; only filing it failed. Never create again.
                    self.presentPlacementFailure(failure.group, parentFolderID: parentFolderID)
                } catch {
                    await self.presentMutationError(action: "create", error: error)
                }
            }
        })
    }

    // MARK: - Folders

    /// Called after an item was created in, or moved into, a folder — so the
    /// list can open that folder and show where the item went.
    var didPlaceItem: ((_ parentFolderID: String) -> Void)?

    func promptForNewFolder(inFolder parentFolderID: String? = nil) {
        let tree = repository.groupFolderTree
        present(GroupNamePrompt.makeAlert(
            title: "New Folder",
            actionTitle: "Add",
            initialName: nil,
            message: GroupFolderDestination.promptMessage(parentFolderID: parentFolderID, in: tree),
            placeholder: "Folder Name"
        ) { [weak self] name in
            self?.runFolderCommand(action: "create folder") { repository in
                try await repository.createGroupFolder(name: name, inFolder: parentFolderID)
                if let parentFolderID { self?.didPlaceItem?(parentFolderID) }
            }
        })
    }

    func renameFolder(id folderID: String) {
        guard let folder = repository.groupFolderTree.folders[folderID] else { return }
        present(GroupNamePrompt.makeAlert(
            title: "Rename Folder",
            actionTitle: "Rename",
            initialName: folder.name,
            placeholder: "Folder Name"
        ) { [weak self] name in
            guard name != folder.name else { return }
            self?.runFolderCommand(action: "rename folder") { repository in
                try await repository.renameGroupFolder(id: folderID, to: name)
            }
        })
    }

    /// Deleting a folder removes only the folder. The prompt says where what is
    /// inside it will go, before anything happens.
    func confirmDeleteFolder(id folderID: String) {
        let tree = repository.groupFolderTree
        guard let folder = tree.folders[folderID] else { return }
        let alert = UIAlertController(
            title: "Delete “\(GroupFolderDestination.displayName(folder.name))”?",
            message: GroupFolderDestination.deletionMessage(forFolder: folderID, in: tree)
                + " Groups and contacts will not be deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.runFolderCommand(action: "delete folder") { repository in
                try await repository.deleteGroupFolder(id: folderID)
            }
        })
        present(alert)
    }

    /// Move a folder or a group into `parentFolderID` (nil = the top level).
    /// Shared by the "Move to…" menu and by drag and drop, so both go through
    /// the same validation and report failure the same way.
    func move(_ node: GroupFolderTree.NodeID, toFolder parentFolderID: String?) {
        runFolderCommand(action: "move") { [weak self] repository in
            switch node {
            case .folder(let id):
                try await repository.moveGroupFolder(id: id, toFolder: parentFolderID)
            case .group(let localID):
                guard let group = repository.group(localID: localID) else { return }
                try await repository.moveGroup(group, toFolder: parentFolderID)
            }
            if let parentFolderID { self?.didPlaceItem?(parentFolderID) }
        }
    }

    /// "Move to…" for a folder or a group: the top level, then every folder it
    /// may move into, nested as the list nests them. nil when there is nowhere
    /// to move it.
    func moveMenu(for node: GroupFolderTree.NodeID) -> UIMenu? {
        let tree = repository.groupFolderTree
        var children: [UIMenuElement] = []
        if GroupFolderMoveTargets.offersMoveToTopLevel(for: node, in: tree) {
            children.append(UIAction(
                title: "Top Level", image: UIImage(systemName: "arrow.up.to.line")
            ) { [weak self] _ in
                self?.move(node, toFolder: nil)
            })
        }
        children.append(contentsOf: moveElements(
            GroupFolderMoveTargets.targets(for: node, in: tree), moving: node))
        guard !children.isEmpty else { return nil }
        return UIMenu(title: "Move to…", image: UIImage(systemName: "folder"), children: children)
    }

    /// A folder with folders inside it is both a destination and a way to reach
    /// its children, so it becomes a submenu whose first item is the folder
    /// itself. Built over an explicit stack (deepest first) rather than by
    /// recursion, like every other walk of the tree.
    private func moveElements(
        _ targets: [GroupFolderMoveTarget], moving node: GroupFolderTree.NodeID
    ) -> [UIMenuElement] {
        func action(_ target: GroupFolderMoveTarget, title: String) -> UIAction {
            UIAction(
                title: title,
                image: UIImage(systemName: "folder"),
                attributes: target.isCurrentParent ? .disabled : [],
                state: target.isCurrentParent ? .on : .off
            ) { [weak self] _ in
                self?.move(node, toFolder: target.folderID)
            }
        }
        var built: [String: UIMenuElement] = [:]
        var stack: [(target: GroupFolderMoveTarget, expanded: Bool)] = targets.map { ($0, false) }
        while let (target, expanded) = stack.popLast() {
            if target.children.isEmpty {
                built[target.folderID] = action(target, title: target.name)
            } else if expanded {
                let inside = target.children.compactMap { built[$0.folderID] }
                built[target.folderID] = UIMenu(
                    title: target.name,
                    image: UIImage(systemName: "folder"),
                    children: [action(target, title: "“\(target.name)”")] + inside)
            } else {
                stack.append((target, true))
                stack.append(contentsOf: target.children.map { ($0, false) })
            }
        }
        return targets.compactMap { built[$0.folderID] }
    }

    /// The folder row context menu.
    func configuration(forFolder folderID: String) -> UIContextMenuConfiguration? {
        guard repository.groupFolderTree.folders[folderID] != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(forFolder: folderID)
        }
    }

    private func menu(forFolder folderID: String) -> UIMenu? {
        guard let folder = repository.groupFolderTree.folders[folderID] else { return nil }
        let newFolder = UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            self?.promptForNewFolder(inFolder: folderID)
        }
        let newGroup = UIAction(title: "New Group", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.promptForNewGroup(inFolder: folderID)
        }
        let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.renameFolder(id: folderID)
        }
        let delete = UIAction(
            title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in
            self?.confirmDeleteFolder(id: folderID)
        }
        var children: [UIMenuElement] = [
            UIMenu(title: "", options: .displayInline, children: [newFolder, newGroup]),
            rename,
        ]
        if let move = moveMenu(for: .folder(folderID)) { children.append(move) }
        children.append(delete)
        return UIMenu(title: GroupFolderDestination.displayName(folder.name), children: children)
    }

    /// Run one folder command under the same one-at-a-time guard as the group
    /// mutations, reporting a failure in plain language.
    private func runFolderCommand(
        action: String,
        _ command: @escaping @MainActor (ContactsRepository) async throws -> Void
    ) {
        Task { @MainActor in
            guard self.beginMutation() else { return }
            defer { self.endMutation() }
            do {
                try await command(self.repository)
            } catch {
                Self.log.error("couldn't \(action): \(error.localizedDescription)")
                let alert = UIAlertController(
                    title: "Couldn’t Save This Change",
                    message: GroupFolderErrorPresentation.message(for: error),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert)
            }
        }
    }

    /// The new group was created but could not be filed. It is at the top level
    /// and fully usable; Retry files THAT group, and never creates another.
    private func presentPlacementFailure(_ group: ContactGroup, parentFolderID: String?) {
        Self.log.error("created group but couldn't place it in its folder")
        let folderName = parentFolderID
            .flatMap { repository.groupFolderTree.folders[$0]?.name }
            .map(GroupFolderDestination.displayName)
        let destination = folderName.map { "“\($0)”" } ?? "its folder"
        let alert = UIAlertController(
            title: "Group Created",
            message: "“\(group.displayName)” was created, but it couldn’t be put in \(destination). It’s at the top level.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.repository.moveGroup(group, toFolder: parentFolderID)
                    if let parentFolderID { self.didPlaceItem?(parentFolderID) }
                } catch {
                    self.presentPlacementFailure(group, parentFolderID: parentFolderID)
                }
            }
        })
        present(alert)
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

    /// `pending` is folder cleanup the same deletion still owes. One alert at a
    /// time: it is raised once this one is settled, so neither is lost.
    private func presentFavoriteCleanupError(
        _ error: Error,
        for group: ContactGroup,
        thenFolderCleanup pending: PendingGroupPlacementCleanup? = nil
    ) {
        Self.log.error("couldn't remove deleted group from favorites: \(error.localizedDescription)")
        let alert = UIAlertController(
            title: "Group Deleted",
            message: "The group was deleted, but it couldn’t be removed from Favorites.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            if let pending { self?.presentFolderCleanupPending(pending) }
        })
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let retryError = await self.deletionOperation.cleanupFavorite(for: group) {
                    self.presentFavoriteCleanupError(retryError, for: group, thenFolderCleanup: pending)
                } else if let pending {
                    self.presentFolderCleanupPending(pending)
                }
            }
        })
        present(alert)
    }

    /// The group is deleted but is still filed in its folder. Nothing shows it
    /// there — the group is gone — but a later group with the same name could
    /// turn up in that folder, so offer to finish. Retrying deletes nothing.
    private func presentFolderCleanupPending(_ pending: PendingGroupPlacementCleanup) {
        Self.log.error("couldn't take deleted group out of its folder")
        let alert = UIAlertController(
            title: "Group Deleted",
            message: "The group was deleted, but it couldn’t be taken out of its folder.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let stillPending = await self.deletionOperation.retryFolderCleanup(pending) else {
                    return
                }
                self.presentFolderCleanupPending(stillPending)
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
