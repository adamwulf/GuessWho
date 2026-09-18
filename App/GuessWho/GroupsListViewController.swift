import UIKit
import GuessWhoSync
import GuessWhoLogging

// The group and folder create/rename/move/delete/email flows and their error
// copy live in `GroupContextMenu` (backed by `GroupPresentation.swift` and
// `GroupFolderPresentation.swift`) so the Groups list, the Favorites list, and
// the sidebar share one implementation.

/// UIKit Groups list. Used by both the Catalyst 3-column shell (as the
/// supplementary column for `.groups`) and the iPhone tab shell (rooted in
/// the Groups nav stack).
///
/// The list is a TREE: folders organize groups, a folder can hold folders and
/// groups, and a group is always a leaf. Folders and groups are mixed and sorted
/// by name at every level, exactly as the flat list always sorted groups.
/// Selecting a group surfaces its members via `didSelectGroup`; selecting a
/// folder surfaces the members of every group beneath it via `didSelectFolder`.
///
/// It shows `repository.groupFolderTree`, an immutable snapshot, flattened by
/// `visibleRows(collapsed:)`. Which folders are closed is this device's own
/// business (`GroupFolderExpansionStore`); it changes only which rows appear,
/// never what a folder contains. Rows are keyed by a TYPED id — a folder's
/// durable id or a group's `localID` — so the two id spaces cannot collide.
/// Every rule that does not need a table view (where a drop may land, what a
/// row says to VoiceOver, how deep an indent is drawn, single- versus
/// double-click) lives in `GroupFolderPresentation.swift`, where it is tested.
///
/// The repository's `loadGroups()` fills the cache and posts
/// `.contactsRepositoryDidReload`, the same notification the contact lists
/// observe, so this list refreshes through one shared path.
final class GroupsListViewController: UIViewController {
    typealias Item = GroupFolderTree.NodeID

    /// Closure-based selection callbacks so the SceneDelegate can push (iPhone)
    /// or push-onto-supplementary (Catalyst) a `GroupMembersListViewController`
    /// without us holding a reference to the nav stack or the split.
    var didSelectGroup: (ContactGroup) -> Void = { _ in }
    var didSelectFolder: (_ folderID: String) -> Void = { _ in }

    private let repository: ContactsRepository
    private let favoritesStore: FavoritesListStore
    private let expansion: GroupFolderExpansionStore
    private let clickArbiter = GroupFolderClickArbiter()
    private static let log = GuessWhoLog.logger("app.groups.list")

    /// The shared group context menu + create/rename/delete/email coordinator.
    /// Lazy so it can capture `self` for its presenter and mutation callbacks —
    /// the same pattern as `AddToGroupMenu` on the contact lists. Its alerts go
    /// through this VC's queue-until-visible `presentAlertWhenReady`, and it
    /// disables the "＋" button and table while a mutation is in flight.
    private lazy var groupContextMenu: GroupContextMenu = {
        let menu = GroupContextMenu(
            repository: repository,
            favoritesStore: favoritesStore,
            host: self,
            presentAlert: { [weak self] alert in self?.presentAlertWhenReady(alert) },
            willBeginMutation: { [weak self] in self?.setGroupMutationUI(enabled: false) },
            didEndMutation: { [weak self] in self?.setGroupMutationUI(enabled: true) }
        )
        // Show where an item went: open the folder it was created in or moved to.
        menu.didPlaceItem = { [weak self] folderID in self?.reveal(folderID: folderID) }
        return menu
    }()

    private enum CellID: String {
        case node
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, Item>!

    /// Everything a row draws from. The diffable item is the bare typed id, so
    /// a change that keeps the id — a rename, a new depth, a changed count, a
    /// star, a folder opening — keeps the row in place WITHOUT re-running the
    /// cell provider. Comparing this whole state between applies is what finds
    /// those rows to `reconfigureItems(_:)`; comparing names alone would miss
    /// most of them.
    private struct RenderState: Equatable {
        let row: GroupFolderTree.Row
        let isFavorite: Bool
        let indentLevels: Int
    }
    private var renderedStates: [Item: RenderState] = [:]
    private var rows: [GroupFolderTree.Row] = []
    /// Width the indent cap was last computed for; a change re-renders rows.
    private var renderedWidth: CGFloat = 0

    /// The sidebar's outstanding "select this row" request, if any. See
    /// `PendingRowSelection`.
    private let pendingSelection = PendingRowSelection<Item>()

    private let emptyStateStack = UIStackView()
    private let emptyLabel = UILabel()
    private let emptyDetailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let topLevelDropTarget = TopLevelDropTargetView()
    private var pendingAlert: UIAlertController?

    /// Marks a drag as having started in THIS list. Anything else — a contact
    /// dragged from another list, a file from another app — is not ours to move.
    private let dragContext = NSObject()

    /// Flips true once the first `loadGroups()` completes. Drives the
    /// spinner-vs-empty-label choice in `updateEmptyState()` — a LOCAL flag
    /// rather than `repository.isLoading` because `loadGroups()` deliberately
    /// does not touch `isLoading` (sharing it with the contacts reload would
    /// risk cross-talk between the two independent loads). Mirrors
    /// `GroupMembersListViewController.hasLoaded`.
    private var hasGroupsLoaded = false

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale (written once on main, read only from the
    /// nonisolated `deinit`).
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    /// Observes `.favoritesDidChange` so a group starred/unstarred from the
    /// member list, the contact detail Groups section, or the Favorites list
    /// repaints its row's trailing star here. Same `nonisolated(unsafe)`
    /// rationale as `reloadObserver`.
    private nonisolated(unsafe) var favoritesObserver: NSObjectProtocol?

    init(
        repository: ContactsRepository,
        favoritesStore: FavoritesListStore,
        expansion: GroupFolderExpansionStore = GroupFolderExpansionStore()
    ) {
        self.repository = repository
        self.favoritesStore = favoritesStore
        self.expansion = expansion
        super.init(nibName: nil, bundle: nil)
        title = "Groups"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GroupsListViewController is code-only")
    }

    deinit {
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
        }
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureEmptyState()
        configureTopLevelDropTarget()
        configureDataSource()
        observeRepositoryReloads()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: nil,
            menu: UIMenu(children: [
                // Built when the menu opens, so the destination reflects the
                // row selected at THAT moment.
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.addMenuElements() ?? [])
                }
            ])
        )

        // Paint whatever the repository already cached, then kick a fresh fetch.
        // Groups are not loaded by the AppDelegate's contact reload, so this VC
        // owns triggering `loadGroups()`. The resulting `.contactsRepositoryDidReload`
        // re-applies the snapshot when the fetch lands; we additionally flip
        // `hasGroupsLoaded` in the continuation so the empty state can show the
        // spinner until the first fetch settles (repository is @MainActor, so the
        // continuation already resumes on main).
        applySnapshot(animated: false)
        loadGroups(animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The drawn indent is capped by the width, so a column resize or a
        // rotation can change it without the tree changing at all.
        if tableView.bounds.width != renderedWidth {
            applySnapshot(animated: false)
        }
        applyPendingSelection()
    }

    // Keep selection when returning from members. Besides restoring context,
    // the selected row determines where the + menu creates a folder or group.

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingAlertIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clickArbiter.cancel()
    }

    // MARK: - Programmatic selection

    /// Highlight the row for `localID` and scroll it into view without
    /// republishing the member list — the Catalyst sidebar's favorite children
    /// entry point. See `ContactsListViewController.select(contactID:)` for the
    /// full contract; groups make the "before the first reload" case the normal
    /// one, since this list owns its own `loadGroups()` fetch.
    ///
    /// A group inside closed folders has no row to select, so its ancestors are
    /// opened first. They are re-opened on every apply while the request is
    /// outstanding, because the tree (and so the ancestors) may not have loaded
    /// when the request is made.
    func select(groupLocalID localID: String) {
        pendingSelection.request(.group(localID))
        applySnapshot(animated: false)
        applyPendingSelection()
    }

    /// See `ContactsListViewController.applyPendingSelection`.
    private func applyPendingSelection() {
        guard isViewLoaded else { return }
        pendingSelection.applyIfPossible(in: tableView) { [self] item in
            dataSource.indexPath(for: item)
        }
    }

    /// Open `folderID` and every folder above it, so something just placed
    /// inside is on screen.
    private func reveal(folderID: String) {
        let tree = repository.groupFolderTree
        expansion.expand([folderID] + tree.ancestorFolderIDs(of: .folder(folderID)))
        applySnapshot(animated: true)
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.register(GroupTreeCell.self, forCellReuseIdentifier: CellID.node.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        #if targetEnvironment(macCatalyst)
        // Double-click a folder to open or close it — the sidebar's convention.
        // Same touch-delivery settings as the sidebar's recognizer (see
        // `SidebarViewController`): without them a tap recognizer withholds and
        // then cancels the touches the table's own selection needs.
        let toggle = UITapGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        toggle.numberOfTapsRequired = 2
        toggle.cancelsTouchesInView = false
        toggle.delaysTouchesEnded = false
        toggle.delegate = self
        tableView.addGestureRecognizer(toggle)
        expansionToggle = toggle
        #endif
    }

    private var expansionToggle: UITapGestureRecognizer?

    private func configureEmptyState() {
        emptyStateStack.axis = .vertical
        emptyStateStack.alignment = .center
        emptyStateStack.spacing = 10
        emptyStateStack.isHidden = true
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateStack)

        emptyLabel.font = .preferredFont(forTextStyle: .headline)
        emptyLabel.textColor = .label
        emptyLabel.textAlignment = .center
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyStateStack.addArrangedSubview(emptyLabel)

        emptyDetailLabel.font = .preferredFont(forTextStyle: .body)
        emptyDetailLabel.textColor = .secondaryLabel
        emptyDetailLabel.textAlignment = .center
        emptyDetailLabel.numberOfLines = 0
        emptyDetailLabel.adjustsFontForContentSizeCategory = true
        emptyStateStack.addArrangedSubview(emptyDetailLabel)

        activityIndicator.hidesWhenStopped = true
        emptyStateStack.addArrangedSubview(activityIndicator)

        var retryConfiguration = UIButton.Configuration.borderedProminent()
        retryConfiguration.title = "Retry"
        retryButton.configuration = retryConfiguration
        retryButton.addTarget(self, action: #selector(retryLoadGroups), for: .touchUpInside)
        emptyStateStack.addArrangedSubview(retryButton)

        NSLayoutConstraint.activate([
            emptyStateStack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            emptyDetailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, Item>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.node.rawValue, for: indexPath)
            guard let self, let state = self.renderedStates[item], let cell = cell as? GroupTreeCell else {
                return cell
            }
            cell.configure(
                row: state.row,
                isFavorite: state.isFavorite,
                indentLevels: state.indentLevels,
                tree: self.repository.groupFolderTree,
                onToggle: { [weak self] in
                    guard case .folder(let folderID) = item else { return }
                    self?.toggleExpansion(of: folderID)
                })
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        // Repository posts `.contactsRepositoryDidReload` after `loadGroups()`
        // lands, after every folder command, and after a hierarchy change syncs
        // in (and after contact reloads — harmless extra applies here). Same
        // main-queue pin + assumeIsolated hop as the contact lists so a future
        // off-main post still applies the diffable snapshot on the main thread.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySnapshot(animated: true)
            }
        }

        // Favorite status isn't part of the tree, so a star toggled elsewhere
        // never changes the snapshot's items — re-apply so the render-state
        // comparison finds the rows whose star moved.
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySnapshot(animated: false)
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        guard isViewLoaded else { return }
        let tree = repository.groupFolderTree

        // An outstanding "select this group" request needs the group's folders
        // open, or there is no row to select.
        if case .group(let localID)? = pendingSelection.requested, tree.groups[localID] != nil {
            expansion.expand(tree.ancestorFolderIDs(of: .group(localID)))
        }
        // Forget closed folders that no longer exist — but only on the strength
        // of a complete, loaded tree. The empty tree before the first load, or
        // one missing a folder whose file has not downloaded, proves nothing.
        if hasGroupsLoaded, tree.isComplete, repository.groupsError == nil {
            expansion.prune(keeping: Set(tree.folders.keys))
        }

        rows = tree.visibleRows(collapsed: expansion.collapsed)
        let width = tableView.bounds.width
        renderedWidth = width

        var states: [Item: RenderState] = [:]
        for row in rows {
            var isFavorite = false
            if case .group(let localID) = row.id, let group = repository.group(localID: localID) {
                isFavorite = repository.isGroupFavorite(group)
            }
            states[row.id] = RenderState(
                row: row,
                isFavorite: isFavorite,
                indentLevels: GroupFolderRowLayout.drawnIndentLevels(depth: row.depth, availableWidth: width))
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        // The tree shows each folder and each group once, so ids are unique;
        // appendItems traps on a duplicate, so guard regardless.
        var seen = Set<Item>()
        let items = rows.map(\.id).filter { seen.insert($0).inserted }
        snapshot.appendItems(items, toSection: 0)

        // Reconfigure rows that stayed but whose render state moved. Only rows
        // present in BOTH snapshots: inserts/removes are handled by apply, and
        // reconfiguring an absent item traps.
        let changed = items.filter { item in
            guard let previous = renderedStates[item] else { return false }
            return previous != states[item]
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(changed)
        }
        renderedStates = states

        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.applyPendingSelection()
        }

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = rows.isEmpty
        emptyStateStack.isHidden = !isEmpty
        guard isEmpty else {
            activityIndicator.stopAnimating()
            return
        }

        if !hasGroupsLoaded {
            emptyLabel.text = "Loading Groups"
            emptyDetailLabel.isHidden = true
            retryButton.isHidden = true
            activityIndicator.startAnimating()
        } else if repository.groupsError != nil {
            activityIndicator.stopAnimating()
            emptyLabel.text = "Couldn’t Load Groups"
            emptyDetailLabel.text = "Check Contacts access in Settings, then try again."
            emptyDetailLabel.isHidden = false
            retryButton.isHidden = false
        } else {
            activityIndicator.stopAnimating()
            emptyLabel.text = "No Groups"
            emptyDetailLabel.isHidden = true
            retryButton.isHidden = true
        }
    }

    private func loadGroups(animated: Bool) {
        hasGroupsLoaded = false
        updateEmptyState()
        Task {
            await repository.loadGroups()
            hasGroupsLoaded = true
            applySnapshot(animated: animated)
        }
    }

    @objc private func retryLoadGroups() {
        loadGroups(animated: true)
    }

    // MARK: - Expand / collapse

    /// Open or close a folder. Changes only which rows are shown. Never
    /// navigates: a folder's members open from the ROW, not from its disclosure
    /// control.
    private func toggleExpansion(of folderID: String) {
        guard !repository.groupFolderTree.children(of: folderID).isEmpty else { return }
        expansion.setCollapsed(!expansion.isCollapsed(folderID), folderID: folderID)
        applySnapshot(animated: true)

        // Rows just appeared or disappeared, so VoiceOver's picture of the
        // screen is stale. `.layoutChanged` refreshes it and keeps focus on the
        // folder the user acted on; the new state is read from the row's
        // `accessibilityValue`.
        let cell = dataSource.indexPath(for: .folder(folderID)).flatMap { tableView.cellForRow(at: $0) }
        UIAccessibility.post(notification: .layoutChanged, argument: cell)
    }

    private func setExpanded(_ expanded: Bool, folderID: String) {
        guard expansion.isCollapsed(folderID) == expanded else { return }
        toggleExpansion(of: folderID)
    }

    #if targetEnvironment(macCatalyst)
    @objc private func handleDoubleClick(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              case .folder(let folderID)? = dataSource.itemIdentifier(for: indexPath)
        else { return }
        // A double click ON the disclosure control is two toggles already, by
        // the control itself; toggling again here would undo one of them.
        if let cell = tableView.cellForRow(at: indexPath) as? GroupTreeCell,
           cell.disclosureContains(recognizer.location(in: cell)) {
            return
        }
        clickArbiter.doubleClick { toggleExpansion(of: folderID) }
    }
    #endif

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let expand = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(expandSelectedFolder))
        expand.discoverabilityTitle = "Expand Folder"
        let collapse = UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(collapseSelectedFolder))
        collapse.discoverabilityTitle = "Collapse Folder"
        // Without priority the system's own arrow-key handling (focus movement)
        // takes these before the responder chain sees them.
        expand.wantsPriorityOverSystemBehavior = true
        collapse.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [expand, collapse]
    }

    private var selectedFolderID: String? {
        guard let indexPath = tableView.indexPathForSelectedRow,
              case .folder(let folderID)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return folderID
    }

    @objc private func expandSelectedFolder() {
        if let folderID = selectedFolderID { setExpanded(true, folderID: folderID) }
    }

    @objc private func collapseSelectedFolder() {
        if let folderID = selectedFolderID { setExpanded(false, folderID: folderID) }
    }

    // MARK: - Group and folder mutations

    /// New Folder / New Group. The default destination is the selected folder,
    /// the selected group's folder, or the top level — and each prompt says
    /// which, so the user confirms it rather than discovering it.
    var creationParentFolderID: String? {
        let selection = tableView.indexPathForSelectedRow.flatMap { dataSource.itemIdentifier(for: $0) }
        return GroupFolderDestination.defaultParent(
            forSelection: selection, in: repository.groupFolderTree)
    }

    private func addMenuElements() -> [UIMenuElement] {
        let parent = creationParentFolderID
        return [
            UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                self?.groupContextMenu.promptForNewFolder(inFolder: parent)
            },
            UIAction(title: "New Group", image: UIImage(systemName: SidebarTab.groups.systemImage)) { [weak self] _ in
                self?.groupContextMenu.promptForNewGroup(inFolder: parent)
            },
        ]
    }

    /// Disable (or re-enable) the "＋" button and the table while a group or
    /// folder mutation is in flight. Driven by `GroupContextMenu`'s mutation
    /// callbacks, which also enforce the one-at-a-time guard.
    private func setGroupMutationUI(enabled: Bool) {
        navigationItem.rightBarButtonItem?.isEnabled = enabled
        tableView.isUserInteractionEnabled = enabled
    }

    /// Alerts can complete their action before UIKit finishes dismissing them.
    /// Dismiss any current alert first, then present the queued result only
    /// while this controller is visible.
    private func presentAlertWhenReady(_ alert: UIAlertController) {
        guard isViewLoaded, view.window != nil else {
            pendingAlert = alert
            return
        }
        if let presented = presentedViewController {
            presented.dismiss(animated: true) { [weak self] in
                self?.presentAlertWhenReady(alert)
            }
            return
        }
        pendingAlert = nil
        present(alert, animated: true)
    }

    private func presentPendingAlertIfPossible() {
        guard let alert = pendingAlert else { return }
        presentAlertWhenReady(alert)
    }

    private func group(at indexPath: IndexPath) -> ContactGroup? {
        guard case .group(let localID)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return repository.group(localID: localID)
    }
}

// MARK: - UITableViewDelegate

extension GroupsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        // The user picked a row, so retire an unfulfilled sidebar request rather
        // than let a later reload move the selection out from under them.
        pendingSelection.cancel()
        switch item {
        case .group(let localID):
            guard let group = repository.group(localID: localID) else { return }
            didSelectGroup(group)
        case .folder(let folderID):
            #if targetEnvironment(macCatalyst)
            // Held for the double-click interval: opening a folder pushes the
            // member list over this tree, so a double click has to be ruled out
            // FIRST. See `GroupFolderClickArbiter`.
            clickArbiter.singleClick { [weak self] in
                guard let self, self.repository.groupFolderTree.folders[folderID] != nil else { return }
                self.didSelectFolder(folderID)
            }
            #else
            didSelectFolder(folderID)
            #endif
        }
    }

    /// See `ContactsListViewController.scrollViewWillBeginDragging(_:)`.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingSelection.cancel()
    }

    /// Trailing swipe: favorite / unfavorite a group (mirroring the Favorites
    /// list's swipe-to-unfavorite) and Delete. A folder cannot be favorited, so
    /// it offers Delete alone. The favorites store posts `.favoritesDidChange`,
    /// which the observer above turns into a row repaint.
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            switch item {
            case .folder(let folderID):
                self?.groupContextMenu.confirmDeleteFolder(id: folderID)
            case .group(let localID):
                if let group = self?.repository.group(localID: localID) {
                    self?.groupContextMenu.confirmDelete(group)
                }
            }
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")

        guard let group = group(at: indexPath) else {
            return UISwipeActionsConfiguration(actions: [deleteAction])
        }
        let isFavorited = repository.isGroupFavorite(group)
        let favoriteAction = UIContextualAction(
            style: .normal,
            title: isFavorited ? "Unfavorite" : "Favorite"
        ) { [weak self] _, _, completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                do {
                    _ = try await self.repository.setGroupFavorite(!isFavorited, for: group)
                    self.favoritesStore.reload()
                    completion(true)
                } catch {
                    completion(false)
                }
            }
        }
        favoriteAction.image = UIImage(systemName: isFavorited ? "star.slash" : "star")
        favoriteAction.backgroundColor = .systemYellow
        return UISwipeActionsConfiguration(actions: [deleteAction, favoriteAction])
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let renameAction = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
            switch item {
            case .folder(let folderID):
                self?.groupContextMenu.renameFolder(id: folderID)
            case .group(let localID):
                if let group = self?.repository.group(localID: localID) {
                    self?.groupContextMenu.rename(group)
                }
            }
            completion(true)
        }
        renameAction.image = UIImage(systemName: "pencil")
        renameAction.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [renameAction])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .folder(let folderID):
            return groupContextMenu.configuration(forFolder: folderID)
        case .group(let localID):
            return repository.group(localID: localID).flatMap { groupContextMenu.configuration(for: $0) }
        case nil:
            return nil
        }
    }
}

// MARK: - Drag and drop

/// Local, single-item moves only: drag a folder or a group onto a folder to move
/// it inside, or to a top-level gap / the Top Level bar to move it out. WHERE a
/// drop may land is `GroupFolderDropPolicy`'s decision, recomputed against the
/// latest tree at drop time; the move itself goes through the same command as
/// the "Move to…" menu, so it is validated and reported identically. Siblings
/// stay alphabetical — a drop never sets an order.
extension GroupsListViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    func tableView(
        _ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return [] }
        // The IDENTITY rides along, never the row index: the tree can change
        // between the drag starting and the drop landing.
        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = item
        session.localContext = dragContext
        return [dragItem]
    }

    /// One item per drag: adding a second is refused.
    func tableView(
        _ tableView: UITableView, itemsForAddingTo session: UIDragSession,
        at indexPath: IndexPath, point: CGPoint
    ) -> [UIDragItem] {
        []
    }

    func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) {
        clickArbiter.cancel()
        guard let item = draggedItem(in: session.items, context: session.localContext) else { return }
        // Offer the bar only when there is somewhere "up" to go.
        topLevelDropTarget.isHidden = repository.groupFolderTree.parentFolderID(of: item) == nil
    }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        topLevelDropTarget.isHidden = true
        topLevelDropTarget.isHighlighted = false
    }

    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        draggedItem(in: session) != nil
    }

    func tableView(
        _ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard let item = draggedItem(in: session) else {
            return UITableViewDropProposal(operation: .forbidden)
        }
        switch dropProposal(for: item, at: session.location(in: tableView)) {
        case .moveInto:
            return UITableViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
        case .moveToTopLevel:
            return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        case .forbidden:
            return UITableViewDropProposal(operation: .forbidden)
        }
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let item = draggedItem(in: coordinator.session) else { return }
        // Decided again NOW, against the tree as it is at the drop.
        switch dropProposal(for: item, at: coordinator.session.location(in: tableView)) {
        case .moveInto(let folderID):
            groupContextMenu.move(item, toFolder: folderID)
        case .moveToTopLevel:
            groupContextMenu.move(item, toFolder: nil)
        case .forbidden:
            break
        }
    }

    private func dropProposal(for item: Item, at location: CGPoint) -> GroupFolderDropProposal {
        var target: Item?
        var fraction: CGFloat = 0.5
        if let indexPath = tableView.indexPathForRow(at: location) {
            target = dataSource.itemIdentifier(for: indexPath)
            let rect = tableView.rectForRow(at: indexPath)
            if rect.height > 0 { fraction = (location.y - rect.minY) / rect.height }
        }
        return GroupFolderDropPolicy.proposal(
            dragged: item, target: target, verticalFraction: fraction,
            rows: rows, in: repository.groupFolderTree)
    }

    /// The one tree item of a drag that began in this list, or nil for anything
    /// else: a drag from another list or app, or a drag of several items.
    private func draggedItem(in session: UIDropSession) -> Item? {
        draggedItem(in: session.items, context: session.localDragSession?.localContext)
    }

    private func draggedItem(in items: [UIDragItem], context: Any?) -> Item? {
        guard (context as AnyObject?) === dragContext,
              items.count == 1,
              let item = items[0].localObject as? Item,
              renderedStates[item] != nil
        else { return nil }
        return item
    }

    private func configureTopLevelDropTarget() {
        topLevelDropTarget.isHidden = true
        topLevelDropTarget.translatesAutoresizingMaskIntoConstraints = false
        topLevelDropTarget.addInteraction(UIDropInteraction(delegate: self))
        view.addSubview(topLevelDropTarget)
        NSLayoutConstraint.activate([
            topLevelDropTarget.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            topLevelDropTarget.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            topLevelDropTarget.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
}

/// The dedicated "Move to Top Level" bar, shown only while an item that is
/// inside a folder is being dragged.
extension GroupsListViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        draggedItem(in: session) != nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let item = draggedItem(in: session),
              repository.groupFolderTree.parentFolderID(of: item) != nil else {
            return UIDropProposal(operation: .forbidden)
        }
        return UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        topLevelDropTarget.isHighlighted = true
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        topLevelDropTarget.isHighlighted = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let item = draggedItem(in: session),
              repository.groupFolderTree.parentFolderID(of: item) != nil else { return }
        groupContextMenu.move(item, toFolder: nil)
    }
}

#if targetEnvironment(macCatalyst)
extension GroupsListViewController: UIGestureRecognizerDelegate {
    /// Let the double-click recognizer run alongside the table's own selection
    /// and drag recognizers — narrowly, for our recognizer only. See the same
    /// method on `SidebarViewController`.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === expansionToggle
    }
}
#endif

// MARK: - GroupContextMenuEmailResponder

extension GroupsListViewController: GroupContextMenuEmailResponder {
    // The Catalyst group Email command fires down the responder chain (see
    // `GroupContextMenu.emailElements`); forward it to the coordinator that
    // built it. `individually` is what the Option alternate selects.
    func emailGroupMembers(_ sender: UICommand) {
        groupContextMenu.handleEmailCommand(sender, individually: false)
    }

    func emailGroupMembersSeparately(_ sender: UICommand) {
        groupContextMenu.handleEmailCommand(sender, individually: true)
    }
}

extension GroupsListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

// MARK: - Top Level drop target

private final class TopLevelDropTargetView: UIView {
    private let label = UILabel()

    var isHighlighted = false {
        didSet { backgroundColor = isHighlighted ? .tintColor.withAlphaComponent(0.25) : .secondarySystemBackground }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        label.text = "Move to Top Level"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Move to Top Level"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — TopLevelDropTargetView is code-only")
    }
}

// MARK: - Row cell

/// One row of the tree: indent, a disclosure control for a folder that has
/// something inside, a folder or group icon, the name, a count badge on a CLOSED
/// folder, and a favorite star on a group. A group has no subtitle and no photo,
/// so this is deliberately lighter than `ContactCell`. Member counts are
/// intentionally omitted — surfacing them would require fetching every group's
/// members up front. The badge counts a folder's immediate ITEMS (folders plus
/// groups), and only while the folder is closed, when they are not on screen.
private final class GroupTreeCell: UITableViewCell {
    private let disclosureButton = UIButton(type: .system)
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private let starView = UIImageView()
    private var indentConstraint: NSLayoutConstraint!
    private var onToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GroupTreeCell is code-only")
    }

    /// Everything a row sets is cleared, so a reused cell cannot show another
    /// row's indent, badge, star, or assistive description.
    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        countLabel.text = nil
        countLabel.isHidden = true
        starView.isHidden = true
        disclosureButton.isHidden = true
        indentConstraint.constant = 0
        onToggle = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityCustomActions = nil
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listPlainCell().updated(for: state)
        let isEmphasized = state.isSelected || state.isHighlighted
        if isEmphasized {
            background.backgroundColor = .tintColor
            background.cornerRadius = 8
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
        }
        backgroundConfiguration = background

        // Preserve normal label colors while keeping text readable on the selection.
        for label in [nameLabel, countLabel] {
            label.highlightedTextColor = .white
            label.isHighlighted = isEmphasized
        }
        disclosureButton.tintColor = isEmphasized ? .white : .secondaryLabel
    }

    private func configureSubviews() {
        accessoryType = .disclosureIndicator

        var disclosure = UIButton.Configuration.plain()
        disclosure.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
        disclosure.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        disclosureButton.configuration = disclosure
        disclosureButton.tintColor = .secondaryLabel
        disclosureButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        // The row is the accessibility element; expand/collapse is offered as a
        // custom action on it rather than as a second, unlabeled control.
        disclosureButton.isAccessibilityElement = false
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.font = .preferredFont(forTextStyle: .footnote)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .secondaryLabel
        countLabel.isHidden = true
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        // Trailing favorite star. The image stays installed and only `isHidden`
        // toggles, so its intrinsic size keeps the layout deterministic — same
        // pattern as ContactsListViewController's ContactCell.
        starView.image = UIImage(systemName: "star.fill")
        starView.contentMode = .scaleAspectFit
        starView.tintColor = .systemYellow
        starView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        starView.isHidden = true
        starView.setContentHuggingPriority(.required, for: .horizontal)
        starView.setContentCompressionResistancePriority(.required, for: .horizontal)
        starView.translatesAutoresizingMaskIntoConstraints = false

        let trailing = UIStackView(arrangedSubviews: [countLabel, starView])
        trailing.axis = .horizontal
        trailing.spacing = 6
        trailing.alignment = .center
        trailing.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(disclosureButton)
        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(trailing)

        // Leading/trailing anchors throughout, so the indent and the order of
        // the pieces mirror in a right-to-left layout.
        indentConstraint = disclosureButton.leadingAnchor.constraint(
            equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            indentConstraint,
            disclosureButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // The control keeps its width when hidden, so a group's icon lines
            // up with the icons of the folders beside it.
            disclosureButton.widthAnchor.constraint(equalToConstant: 24),
            iconView.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            trailing.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func configure(
        row: GroupFolderTree.Row,
        isFavorite: Bool,
        indentLevels: Int,
        tree: GroupFolderTree,
        onToggle: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        indentConstraint.constant = CGFloat(indentLevels) * GroupFolderRowLayout.indentStep

        nameLabel.text = row.name.isEmpty
            ? (row.isFolder ? "(Unnamed Folder)" : "(Unnamed Group)")
            : row.name
        // Distinct icons: a folder, and the Groups tab/sidebar icon for a group.
        iconView.image = UIImage(systemName: row.isFolder ? "folder" : SidebarTab.groups.systemImage)
        starView.isHidden = !isFavorite

        // An empty folder has nothing to open, so it gets no control and no
        // count. The count shows only while the folder is closed.
        let canToggle = row.isFolder && row.childCount > 0
        disclosureButton.isHidden = !canToggle
        let chevron = UIImage(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
        disclosureButton.configuration?.image = row.isExpanded
            ? chevron
            : chevron?.imageFlippedForRightToLeftLayoutDirection()
        countLabel.isHidden = !canToggle || row.isExpanded
        countLabel.text = canToggle && !row.isExpanded ? "\(row.childCount)" : nil

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = GroupFolderRowLayout.accessibilityLabel(for: row, isFavorite: isFavorite, in: tree)
        accessibilityValue = GroupFolderRowLayout.accessibilityValue(for: row)
        accessibilityCustomActions = canToggle
            ? [UIAccessibilityCustomAction(name: row.isExpanded ? "Collapse" : "Expand") { [weak self] _ in
                self?.onToggle?()
                return true
            }]
            : nil
    }

    /// Whether `point` (in this cell's coordinates) is on the disclosure control.
    func disclosureContains(_ point: CGPoint) -> Bool {
        guard !disclosureButton.isHidden else { return false }
        return disclosureButton.convert(disclosureButton.bounds, to: self)
            .insetBy(dx: -6, dy: -6).contains(point)
    }
}
