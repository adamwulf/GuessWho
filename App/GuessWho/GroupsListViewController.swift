import UIKit
import GuessWhoSync
import GuessWhoLogging

// The group create/rename/delete/email flows and their error copy live in
// `GroupContextMenu` (backed by `GroupPresentation.swift`'s `GroupNamePrompt`,
// `GroupMutationErrorPresentation`, and `GroupDeletionOperation`) so the Groups
// list, the Favorites list, and the sidebar share one implementation.

/// UIKit Groups list. Used by both the Catalyst 3-column shell (as the
/// supplementary column for `.groups`) and the iPhone tab shell (rooted in
/// the Groups nav stack). Lists Contacts.app groups alphabetically by name;
/// selecting a group surfaces its members via `didSelectGroup`.
///
/// Unlike `ContactsListViewController` / `OrganizationsListViewController`,
/// groups need no A–Z sectioning or photo prefetch — a group is just a name —
/// so this is a plain single-section `UITableViewDiffableDataSource` keyed on
/// the group's transient `localID` for the lifetime of the Contacts snapshot.
/// Durable favorite identity is separate and stays behind the repository's
/// `GroupIdentity` resolver. The repository's `loadGroups()` fills the cache
/// and posts `.contactsRepositoryDidReload`, the same notification the contact
/// lists observe, so this list refreshes through one shared path.
final class GroupsListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can push (iPhone)
    /// or push-onto-supplementary (Catalyst) a `GroupMembersListViewController`
    /// without us holding a reference to the nav stack or the split.
    var didSelectGroup: (ContactGroup) -> Void = { _ in }

    private let repository: ContactsRepository
    private let favoritesStore: FavoritesListStore
    private static let log = GuessWhoLog.logger("app.groups.list")

    /// The shared group context menu + create/rename/delete/email coordinator.
    /// Lazy so it can capture `self` for its presenter and mutation callbacks —
    /// the same pattern as `AddToGroupMenu` on the contact lists. Its alerts go
    /// through this VC's queue-until-visible `presentAlertWhenReady`, and it
    /// disables the "＋" button and table while a mutation is in flight.
    private lazy var groupContextMenu = GroupContextMenu(
        repository: repository,
        favoritesStore: favoritesStore,
        host: self,
        presentAlert: { [weak self] alert in self?.presentAlertWhenReady(alert) },
        willBeginMutation: { [weak self] in self?.setGroupMutationUI(enabled: false) },
        didEndMutation: { [weak self] in self?.setGroupMutationUI(enabled: true) }
    )

    private enum CellID: String {
        case group
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, String>!

    /// The `ContactGroup` each `localID` row last rendered, so the cell provider
    /// can resolve a row's name from a stable map (the diffable item is the bare
    /// `localID`). Rebuilt to the current groups on every snapshot apply.
    private var groupsByLocalID: [String: ContactGroup] = [:]

    /// The display name each `localID` row last rendered. The diffable item is
    /// the bare `localID`, so a rename (same id, new name) keeps the row in place
    /// and the cell provider is NOT re-run — we detect the change by comparing
    /// this map against the freshly cached name and `reconfigureItems(_:)` the
    /// rows that differ. Mirrors `ContactsListViewController.renderedContacts`.
    private var renderedNames: [String: String] = [:]

    /// The sidebar's outstanding "select this row" request, if any. See
    /// `PendingRowSelection`.
    private let pendingSelection = PendingRowSelection<String>()

    private let emptyStateStack = UIStackView()
    private let emptyLabel = UILabel()
    private let emptyDetailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var pendingAlert: UIAlertController?

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

    init(repository: ContactsRepository, favoritesStore: FavoritesListStore) {
        self.repository = repository
        self.favoritesStore = favoritesStore
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
        configureDataSource()
        observeRepositoryReloads()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addGroup)
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingAlertIfPossible()
    }

    // MARK: - Programmatic selection

    /// Highlight the row for `localID` and scroll it into view without
    /// republishing the member list — the Catalyst sidebar's favorite children
    /// entry point. See `ContactsListViewController.select(contactID:)` for the
    /// full contract; groups make the "before the first reload" case the normal
    /// one, since this list owns its own `loadGroups()` fetch.
    func select(groupLocalID localID: String) {
        pendingSelection.request(localID)
        applyPendingSelection()
    }

    /// See `ContactsListViewController.applyPendingSelection`.
    private func applyPendingSelection() {
        guard isViewLoaded else { return }
        pendingSelection.applyIfPossible(in: tableView) { [self] localID in
            dataSource.indexPath(for: localID)
        }
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.register(GroupCell.self, forCellReuseIdentifier: CellID.group.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

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
        dataSource = UITableViewDiffableDataSource<Int, String>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, localID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.group.rawValue, for: indexPath)
            guard let self, let group = self.groupsByLocalID[localID] else { return cell }
            (cell as? GroupCell)?.configure(
                with: group,
                isFavorite: self.repository.isGroupFavorite(group)
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        // Repository posts `.contactsRepositoryDidReload` after `loadGroups()`
        // lands (and after contact reloads — harmless extra applies here). Same
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

        // Favorite status isn't part of `ContactGroup`, so a star toggled
        // elsewhere never changes the snapshot — reconfigure the visible rows so
        // their trailing stars repaint (see ContactsListViewController).
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconfigureAllRows()
            }
        }
    }

    /// Re-run the cell provider for every current row so favorite stars repaint.
    /// Reconfigure only touches on-screen cells.
    private func reconfigureAllRows() {
        var snapshot = dataSource.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshot(animated: Bool) {
        let groups = repository.groups

        // Rebuild the localID → group map so the cell provider resolves names
        // from a stable lookup, and so a removed group's stale name can't linger.
        var byLocalID: [String: ContactGroup] = [:]
        for group in groups {
            byLocalID[group.localID] = group
        }
        groupsByLocalID = byLocalID

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        // De-dupe by localID defensively — Contacts issues a unique identifier
        // per group, but appendItems traps on a duplicate, so guard regardless.
        var seen = Set<String>()
        let ids = groups.map(\.localID).filter { seen.insert($0).inserted }
        snapshot.appendItems(ids, toSection: 0)

        // A group row renders only its name; reconfigure rows whose name changed
        // between renders (a rename) so the cell repaints — the diffable apply
        // keeps a same-localID row in place but won't re-run the cell provider
        // for it otherwise. Only reconfigure rows present in the new snapshot
        // (inserts/removes are handled by apply; reconfiguring an absent item
        // traps). Mirrors ContactsListViewController.applySnapshot.
        let currentIDs = Set(ids)
        let changed = currentIDs.filter { id in
            guard let previous = renderedNames[id] else { return false }
            return previous != GroupCell.displayName(for: byLocalID[id])
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(Array(changed))
        }

        // Rebuild the render map to exactly the rows in this snapshot.
        var rendered: [String: String] = [:]
        for id in currentIDs {
            rendered[id] = GroupCell.displayName(for: byLocalID[id])
        }
        renderedNames = rendered

        dataSource.apply(snapshot, animatingDifferences: animated)

        // A pending sidebar selection waits here for its row to exist — the
        // usual case for groups, whose first rows arrive with `loadGroups()`.
        applyPendingSelection()

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = repository.groups.isEmpty
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

    // MARK: - Group mutations

    @objc private func addGroup() {
        groupContextMenu.promptForNewGroup()
    }

    /// Disable (or re-enable) the "＋" button and the table while a group
    /// create/rename/delete is in flight. Driven by `GroupContextMenu`'s
    /// mutation callbacks, which also enforce the one-at-a-time guard.
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
}

// MARK: - UITableViewDelegate

extension GroupsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let group = groupsByLocalID[localID] else { return }
        // The user picked a row, so retire an unfulfilled sidebar request rather
        // than let a later reload move the selection out from under them.
        pendingSelection.cancel()
        didSelectGroup(group)
    }

    /// See `ContactsListViewController.scrollViewWillBeginDragging(_:)`.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingSelection.cancel()
    }

    /// Trailing swipe to favorite / unfavorite the group, mirroring the
    /// Favorites list's swipe-to-unfavorite. The favorites store posts
    /// `.favoritesDidChange`, which the observer above turns into a row repaint.
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let group = groupsByLocalID[localID] else { return nil }
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

        let deleteAction = UIContextualAction(
            style: .destructive,
            title: "Delete"
        ) { [weak self] _, _, completion in
            self?.groupContextMenu.confirmDelete(group)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")

        return UISwipeActionsConfiguration(actions: [deleteAction, favoriteAction])
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let group = groupsByLocalID[localID] else { return nil }
        let renameAction = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
            self?.groupContextMenu.rename(group)
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
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let group = groupsByLocalID[localID] else { return nil }
        return groupContextMenu.configuration(for: group)
    }
}

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

// MARK: - Row cell

/// Single-line group row: leading group icon + the group's name. A group has no
/// subtitle and no photo, so this is deliberately lighter than `ContactCell`.
/// Member count is intentionally omitted — surfacing it would require fetching
/// every group's members up front, which the read-only Groups list avoids.
private final class GroupCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let starView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GroupCell is code-only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        starView.isHidden = true
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listPlainCell().updated(for: state)
        if state.isSelected || state.isHighlighted {
            background.backgroundColor = .tintColor
            background.cornerRadius = 8
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 20)
        }
        backgroundConfiguration = background
    }

    private func configureSubviews() {
        accessoryType = .disclosureIndicator

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        // Keep the row icon in lockstep with the Groups tab/sidebar icon.
        iconView.image = UIImage(systemName: SidebarTab.groups.systemImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1

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

        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(starView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: starView.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            starView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            starView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func configure(with group: ContactGroup, isFavorite: Bool) {
        nameLabel.text = Self.displayName(for: group)
        starView.isHidden = !isFavorite
    }

    /// The user-facing name for a group, falling back to a neutral placeholder
    /// for an (effectively never) empty name or a row whose group is gone.
    /// Static so the list VC can compute the same string when comparing renders
    /// to detect a rename; the non-optional case is `ContactGroup.displayName`,
    /// shared with the "Add to Group" menu.
    static func displayName(for group: ContactGroup?) -> String {
        group?.displayName ?? "(Unnamed Group)"
    }
}
