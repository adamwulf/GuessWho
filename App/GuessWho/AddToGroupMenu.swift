import UIKit
import GuessWhoSync
import GuessWhoLogging

/// Resolves WHICH rows a table's context menu acts on.
///
/// The rule, in one sentence: a menu opened on a row that is part of the current
/// selection acts on the WHOLE selection; a menu opened anywhere else acts on
/// that row alone. Opening a menu never changes the selection — on Catalyst
/// selecting a row replaces the detail pane, and a right-click must not throw
/// away what the user was reading.
///
/// Generic over the element and its identity so the rule is unit-testable
/// without a table view or a `ContactID` (which has no app-visible initializer;
/// see `docs/contact-identity.md`).
enum ContactContextMenuTargets {
    /// - Parameters:
    ///   - hitRow: The row the menu was opened on, or nil when the data source
    ///     can't resolve it (a stale index path mid-apply) — which yields no
    ///     targets, and therefore no menu.
    ///   - selection: The live selection, in the order the caller wants it
    ///     acted on (the contact lists hand over selection-recency order).
    ///   - id: Identity for the membership test. Contacts compare on
    ///     `ContactID`, never on the whole record.
    static func targets<Element, ID: Hashable>(
        hitRow: Element?,
        selection: [Element],
        id: (Element) -> ID
    ) -> [Element] {
        guard let hitRow else { return [] }
        let hitID = id(hitRow)
        guard selection.contains(where: { id($0) == hitID }) else { return [hitRow] }
        return selection
    }
}

/// Alert copy for an "Add to Group" batch that didn't fully land.
///
/// A value type rather than inline alert construction so the THREE-WAY outcome
/// of `ContactsRepository.addContacts(_:toGroup:)` — everything landed, some
/// landed, nothing was attempted — is expressible and testable without a running
/// app. The distinction matters to the user: "some of your contacts are in the
/// group now" and "no contact moved" call for different next steps.
struct AddToGroupAlertCopy: Equatable {
    let title: String
    let message: String

    /// The batch RAN and some of it landed. Names what actually made it in and
    /// which contacts didn't, because a bare "something went wrong" would leave
    /// the user re-adding contacts that are already there.
    static func partialFailure(_ error: GroupMembershipPartialFailureError) -> AddToGroupAlertCopy {
        let groupName = error.group.displayName
        let total = error.applied.count + error.failures.count
        let failedNames = names(of: error.failures.map(\.contact))

        // One contact has no partial state to describe — say what stopped it.
        if total == 1 {
            let reason = error.failures.first?.error.localizedDescription ?? ""
            return AddToGroupAlertCopy(
                title: "Couldn’t Add to “\(groupName)”",
                message: reason.isEmpty
                    ? "\(failedNames) wasn’t added to “\(groupName).”"
                    : reason
            )
        }

        let landed = error.applied.isEmpty
            ? "None of these \(total) contacts were added to “\(groupName).”"
            : "\(error.applied.count) of \(total) contacts were added to “\(groupName).”"
        return AddToGroupAlertCopy(
            title: "Couldn’t Add Every Contact",
            message: "\(landed)\n\nNot added: \(failedNames)."
        )
    }

    /// The write failed BEFORE anything was attempted (the repository's
    /// pre-flight). Says so outright: nothing moved, so retrying is safe and
    /// nothing needs undoing.
    static func nothingAttempted(
        contactCount: Int,
        groupName: String,
        reason: String
    ) -> AddToGroupAlertCopy {
        let scope = contactCount == 1
            ? "This contact wasn’t added."
            : "None of these \(contactCount) contacts were added."
        return AddToGroupAlertCopy(
            title: "Couldn’t Add to “\(groupName)”",
            message: "\(reason)\n\n\(scope)"
        )
    }

    /// The new group itself couldn't be created, so there was nothing to add to.
    static func groupCreationFailed(reason: String) -> AddToGroupAlertCopy {
        AddToGroupAlertCopy(title: "Couldn’t Create Group", message: reason)
    }

    /// Names a small set of contacts for an alert body, capping the list so a
    /// 200-contact selection can't produce an unreadable wall of text.
    private static func names(of contacts: [Contact], limit: Int = 5) -> String {
        let shown = contacts.prefix(limit).map(\.displayName)
        let overflow = contacts.count - shown.count
        let parts = overflow > 0 ? shown + ["\(overflow) more"] : Array(shown)
        return parts.formatted(.list(type: .and))
    }
}

/// The "Add to Group" row context menu, shared by every contact list.
///
/// One instance per list controller. The controller supplies only the two things
/// that differ between lists — how a row resolves to a `Contact`, and what the
/// current selection is — and gets the menu, the group submenu, the New Group
/// prompt, and all of the error handling from here. Factored out for the same
/// reason as `ContactMultiSelectionSupport`: four copies of this would be four
/// chances to drift.
///
/// Nothing here mentions the sidecar. "Add to Group" writes a real Contacts.app
/// group membership — the same groups the Groups tab lists — and the copy speaks
/// only of contacts and groups.
@MainActor
final class AddToGroupMenu {
    private let repository: ContactsRepository
    /// The controller that presents the alerts. Weak: the menu is owned BY that
    /// controller.
    private weak var host: UIViewController?
    private let contactAt: (IndexPath) -> Contact?
    private let selection: () -> [Contact]

    private static let log = GuessWhoLog.logger("app.contacts.addtogroup")

    init(
        repository: ContactsRepository,
        host: UIViewController,
        contactAt: @escaping (IndexPath) -> Contact?,
        selection: @escaping () -> [Contact]
    ) {
        self.repository = repository
        self.host = host
        self.contactAt = contactAt
        self.selection = selection
    }

    // MARK: - Menu construction

    /// The configuration to return from
    /// `tableView(_:contextMenuConfigurationForRowAt:point:)`. Nil when the row
    /// resolves to no contact, so UIKit shows no menu rather than an empty one.
    func configuration(forRowAt indexPath: IndexPath) -> UIContextMenuConfiguration? {
        let contacts = targets(forRowAt: indexPath)
        guard !contacts.isEmpty else { return nil }
        // No `previewProvider`: UIKit previews the row itself, which is the only
        // indication of the menu's target on iPhone/iPad. (Catalyst shows a
        // plain AppKit menu with no row highlight at all — hence the scope title
        // below, which names the contact or counts them.)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: contacts)
        }
    }

    /// The contacts a menu opened on `indexPath` acts on. Exposed (rather than
    /// private) so a list controller can build a menu of its own on the same
    /// targets without re-deriving the selection rule.
    func targets(forRowAt indexPath: IndexPath) -> [Contact] {
        ContactContextMenuTargets.targets(
            hitRow: contactAt(indexPath),
            selection: selection(),
            id: \.contactID
        )
    }

    private func menu(for contacts: [Contact]) -> UIMenu {
        UIMenu(title: Self.scopeTitle(for: contacts), children: [addToGroupMenu(for: contacts)])
    }

    /// The submenu: every existing group (alphabetical), then New Group.
    ///
    /// The groups arrive through `UIDeferredMenuElement.uncached` because
    /// `repository.groups` is only filled by `loadGroups()`, which the Groups tab
    /// drives — a user who has never opened that tab has an EMPTY cache, which is
    /// not the same as having no groups. The deferred element lets UIKit show its
    /// own loading placeholder while the fetch runs instead of blocking the main
    /// thread or rendering a submenu that lies. `uncached` (not the caching
    /// variant) so a group added in Contacts.app since the last menu shows up.
    private func addToGroupMenu(for contacts: [Contact]) -> UIMenu {
        let groups = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion([])
                    return
                }
                completion(await self.groupElements(for: contacts))
            }
        }
        let newGroup = UIAction(
            title: "New Group…",
            image: UIImage(systemName: "plus")
        ) { [weak self] _ in
            self?.promptForNewGroup(adding: contacts)
        }
        return UIMenu(
            title: Self.addToGroupTitle(for: contacts),
            // The same glyph the Groups tab and the contact card's Groups
            // section use, so a group reads the same everywhere.
            image: UIImage(systemName: SidebarTab.groups.systemImage),
            children: [
                groups,
                // Inline section so New Group sits below a separator, and so it
                // renders immediately while the groups above are still loading.
                UIMenu(title: "", options: .displayInline, children: [newGroup]),
            ]
        )
    }

    private func groupElements(for contacts: [Contact]) async -> [UIMenuElement] {
        let groups = await loadedGroups()
        guard !groups.isEmpty else {
            return [Self.placeholder(
                title: repository.groupsError == nil ? "No Groups Yet" : "Couldn’t Load Groups"
            )]
        }
        return groups.map { group in
            UIAction(title: group.displayName) { [weak self] _ in
                self?.add(contacts, to: group)
            }
        }
    }

    /// The groups to list, fetching them first when the cache is cold. Sorted
    /// here rather than trusting the cache's order, since "alphabetical" is the
    /// menu's own contract.
    ///
    /// An empty cache re-fetches on every open. That is deliberate: an empty
    /// cache means either "never loaded" or "genuinely no groups," and the only
    /// way to tell them apart is to ask Contacts.
    private func loadedGroups() async -> [ContactGroup] {
        if repository.groups.isEmpty {
            await repository.loadGroups()
        }
        return repository.groups.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// A non-actionable row (UIKit has no dedicated "empty menu" element).
    private static func placeholder(title: String) -> UIMenuElement {
        let action = UIAction(title: title) { _ in }
        action.attributes = .disabled
        return action
    }

    // MARK: - Titles

    /// The menu header, stating what the menu acts on. Multi-selection counts
    /// the contacts; a single contact names them, which reads as plainly and
    /// carries more information than "1 Contact."
    static func scopeTitle(for contacts: [Contact]) -> String {
        if contacts.count == 1, let contact = contacts.first {
            return contact.displayName
        }
        return "\(contacts.count) Contacts"
    }

    /// The submenu's own title. It repeats the count for a multi-selection
    /// because a menu HEADER is not guaranteed to be visible everywhere the menu
    /// is (Mac Catalyst bridges these to AppKit menus), and the scope of a
    /// destructive-feeling bulk action must never be a guess.
    static func addToGroupTitle(for contacts: [Contact]) -> String {
        contacts.count == 1 ? "Add to Group" : "Add \(contacts.count) Contacts to Group"
    }

    // MARK: - Writes

    private func add(_ contacts: [Contact], to group: ContactGroup) {
        Task { await performAdd(contacts, to: group) }
    }

    /// Honors the repository's three-way contract: returning normally means
    /// every contact is in the group (contacts already there are a silent no-op
    /// success, the normal case for a multi-select add, so there is nothing to
    /// report); `GroupMembershipPartialFailureError` means the batch ran and
    /// some landed; anything else means the pre-flight failed and NOTHING was
    /// attempted.
    private func performAdd(_ contacts: [Contact], to group: ContactGroup) async {
        do {
            try await repository.addContacts(contacts, toGroup: group)
        } catch let partial as GroupMembershipPartialFailureError {
            Self.log.error(
                "add to group partially failed: \(partial.failures.count) of \(contacts.count) contacts"
            )
            present(.partialFailure(partial))
        } catch {
            Self.log.error("couldn't add contacts to group: \(error.localizedDescription)")
            let presentation = GroupMutationErrorPresentation.make(
                error: error,
                authorization: await repository.contactsAuthorizationStatus()
            )
            if presentation.shouldRefreshGroups {
                await repository.loadGroups()
            }
            present(.nothingAttempted(
                contactCount: contacts.count,
                groupName: group.displayName,
                reason: presentation.message
            ))
        }
    }

    // MARK: - New group

    private func promptForNewGroup(adding contacts: [Contact]) {
        // Same prompt the Groups tab uses, so the name is validated the same way
        // (trimmed; the confirm button stays disabled while it's blank).
        present(GroupNamePrompt.makeAlert(
            title: "New Group",
            actionTitle: "Add",
            initialName: nil
        ) { [weak self] name in
            self?.createGroup(named: name, adding: contacts)
        })
    }

    private func createGroup(named name: String, adding contacts: [Contact]) {
        Task {
            let group: ContactGroup
            do {
                group = try await repository.createGroup(name: name)
            } catch {
                Self.log.error("couldn't create group: \(error.localizedDescription)")
                let presentation = GroupMutationErrorPresentation.make(
                    error: error,
                    authorization: await repository.contactsAuthorizationStatus()
                )
                if presentation.shouldRefreshGroups {
                    await repository.loadGroups()
                }
                present(.groupCreationFailed(reason: presentation.message))
                return
            }
            await performAdd(contacts, to: group)
        }
    }

    // MARK: - Alerts

    private func present(_ copy: AddToGroupAlertCopy) {
        let alert = UIAlertController(
            title: copy.title,
            message: copy.message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    /// Present from the host list controller, dismissing anything already up
    /// first — a context-menu action can fire while UIKit is still tearing the
    /// menu (or a previous alert) down. Mirrors
    /// `GroupsListViewController.presentAlertWhenReady`, minus its queue-until-
    /// visible step: this menu can only be opened from a visible list.
    private func present(_ alert: UIAlertController) {
        guard let host, host.isViewLoaded, host.view.window != nil else {
            Self.log.error("no visible host for the Add to Group alert: \(alert.title ?? "")")
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
