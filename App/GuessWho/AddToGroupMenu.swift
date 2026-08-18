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

    /// The batch RAN and some of it landed. Reports the RESULTING STATE and
    /// names the contacts that aren't in it, because a bare "something went
    /// wrong" would leave the user re-adding contacts that are already there.
    ///
    /// "…are in “Family”" rather than "…were added to “Family”" is deliberate
    /// and load-bearing: `applied` means "ended in the requested state," which
    /// INCLUDES contacts that were already members and needed no write. Phrasing
    /// it as an action would claim credit for adds that never happened — a
    /// selection of one already-member plus one new member plus one failure
    /// would read "2 of 3 contacts were added" when exactly one was. The
    /// end-state wording is true either way.
    ///
    /// - Parameter authorization: Contacts authorization, for turning a single
    ///   contact's store error into product copy (see `GroupMutationErrorPresentation`).
    static func partialFailure(
        _ error: GroupMembershipPartialFailureError,
        authorization: StoreAuthorizationStatus
    ) -> AddToGroupAlertCopy {
        let groupName = error.group.displayName
        let total = error.applied.count + error.failures.count
        let failedNames = names(of: error.failures.map(\.contact))

        // One contact has no partial state to describe — say what stopped it.
        if total == 1 {
            return AddToGroupAlertCopy(
                title: "Couldn’t Add to “\(groupName)”",
                message: error.failures.first.map {
                    reason(for: $0.error, authorization: authorization)
                } ?? "\(failedNames) isn’t in “\(groupName).”"
            )
        }

        let state = error.applied.isEmpty
            ? "None of these \(total) contacts are in “\(groupName).”"
            : "\(error.applied.count) of \(total) contacts are in “\(groupName).”"
        return AddToGroupAlertCopy(
            title: "Couldn’t Add Every Contact",
            message: "\(state)\n\nNot added: \(failedNames)."
        )
    }

    /// Plain-language reason for ONE contact's failure.
    ///
    /// A store error's `localizedDescription` can be raw framework text
    /// (`CNErrorDomain` codes read like diagnostics), so everything that isn't
    /// package-authored user copy routes through the same mapper the Groups tab
    /// uses. `ContactNotSavedError` is the exception: the package writes that one
    /// as product copy on purpose ("This contact hasn't been saved yet."), and it
    /// says something the generic mapper can't.
    private static func reason(
        for error: any Error,
        authorization: StoreAuthorizationStatus
    ) -> String {
        if let notSaved = error as? ContactNotSavedError {
            return notSaved.localizedDescription
        }
        return GroupMutationErrorPresentation.make(
            error: error,
            authorization: authorization
        ).message
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

    private static func names(of contacts: [Contact], limit: Int = 5) -> String {
        ContactNameList.joined(contacts, limit: limit)
    }
}

/// Names a set of contacts for a menu title or an alert body, capping the list
/// so a 200-contact selection can't produce an unreadable wall of text. One
/// helper for both surfaces so a menu and the alert it can produce never
/// enumerate the same selection two different ways.
enum ContactNameList {
    static func joined(_ contacts: [Contact], limit: Int) -> String {
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

    /// For hosts that already have the target contact(s) in hand and only need
    /// `configuration(for:)` — e.g. the sidebar's favorited-contact rows, routed
    /// through `FavoriteContextMenuRouter`. The row-based resolvers are unused on
    /// this path, so they no-op.
    convenience init(repository: ContactsRepository, host: UIViewController) {
        self.init(repository: repository, host: host, contactAt: { _ in nil }, selection: { [] })
    }

    // MARK: - Menu construction

    /// The configuration to return from
    /// `tableView(_:contextMenuConfigurationForRowAt:point:)`. Nil when the row
    /// resolves to no contact, so UIKit shows no menu rather than an empty one.
    func configuration(forRowAt indexPath: IndexPath) -> UIContextMenuConfiguration? {
        configuration(for: targets(forRowAt: indexPath))
    }

    /// The configuration for an explicit set of target contacts. Nil for an empty
    /// set, so UIKit shows no menu rather than an empty one — which is also what
    /// gates a non-contact row (a favorited event/group/place resolves to no
    /// contact, so the router hands over `[]`).
    func configuration(for contacts: [Contact]) -> UIContextMenuConfiguration? {
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
    /// The groups arrive through `UIDeferredMenuElement.uncached` because they
    /// have to be READ before they can be listed: `repository.groups` is only
    /// filled by `loadGroups()`, which the Groups tab drives, so a user who has
    /// never opened that tab has an EMPTY cache — which is not the same as
    /// having no groups — and a cache that IS warm can still be stale against
    /// Contacts.app. The deferred element lets UIKit show its own loading
    /// placeholder while the fetch runs instead of blocking the main thread or
    /// rendering a submenu that lies. `uncached` (not the caching variant) is
    /// what makes the provider run on every display; `loadedGroups()` re-reads
    /// Contacts each time, and together those are what keep the list honest.
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

    /// The groups to list, re-read from Contacts on every open. Sorted here
    /// rather than trusting the cache's order, since "alphabetical" is the
    /// menu's own contract.
    ///
    /// EVERY open, not just a cold cache: `repository.groups` is a cache of
    /// whatever the Groups tab last loaded, and groups are created, renamed, and
    /// deleted in Contacts.app behind our back. Trusting a warm cache would
    /// offer a deleted group forever (choosing it fails, refreshes, and makes
    /// the user reopen the menu) and would never show a group added since. The
    /// deferred element already pays for the async load and shows UIKit's own
    /// placeholder while it runs, so freshness costs nothing the menu wasn't
    /// already spending — this is the whole reason the submenu is deferred.
    ///
    /// One fetch per menu display, and no coalescing machinery: the repository's
    /// load/mutation generation counters already make the newest read win, so
    /// two opens in quick succession settle correctly on their own.
    private func loadedGroups() async -> [ContactGroup] {
        await repository.loadGroups()
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

    /// How many targets get NAMED in the menu titles before they are merely
    /// counted.
    ///
    /// Three is where a name list stops being scannable at menu width: "Alice,
    /// Bob, and Carol" reads at a glance, while a fourth name (or a truncated
    /// "…and 4 more") is noisier than the number — and past a handful the number
    /// is exactly what a user checks a bulk action against. Naming matters
    /// because the selection can extend OFFSCREEN: right-clicking Bob with Alice
    /// selected and scrolled out of view must still say Alice is coming along.
    private static let namedTargetLimit = 3

    /// The menu header, stating who the menu acts on: the names while there are
    /// few enough to read, the count beyond that.
    static func scopeTitle(for contacts: [Contact]) -> String {
        guard contacts.count > namedTargetLimit else {
            return ContactNameList.joined(contacts, limit: namedTargetLimit)
        }
        return "\(contacts.count) Contacts"
    }

    /// The submenu's own title. It restates the scope for anything beyond the
    /// clicked row because a menu HEADER is not guaranteed to be visible
    /// everywhere the menu is (Mac Catalyst bridges these to AppKit menus), and
    /// the reach of a bulk action must never be a guess.
    static func addToGroupTitle(for contacts: [Contact]) -> String {
        if contacts.count == 1 {
            // One target: the header already names them, and the row that was
            // clicked is the row that is acted on.
            return "Add to Group"
        }
        guard contacts.count > namedTargetLimit else {
            return "Add \(ContactNameList.joined(contacts, limit: namedTargetLimit)) to Group"
        }
        return "Add \(contacts.count) Contacts to Group"
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
            present(.partialFailure(
                partial,
                authorization: await repository.contactsAuthorizationStatus()
            ))
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
