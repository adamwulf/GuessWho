import UIKit
import GuessWhoSync

/// UIKit Groups list. Used by both the Catalyst 3-column shell (as the
/// supplementary column for `.groups`) and the iPhone tab shell (rooted in
/// the Groups nav stack). Lists Contacts.app groups alphabetically by name;
/// selecting a group surfaces its members via `didSelectGroup`.
///
/// Unlike `ContactsListViewController` / `OrganizationsListViewController`,
/// groups need no A–Z sectioning or photo prefetch — a group is just a name —
/// so this is a plain single-section `UITableViewDiffableDataSource` keyed on
/// the group's `localID` (Contacts' `CNGroup.identifier`, the correct group
/// key; groups are not GuessWho-ID'd). The repository's `loadGroups()` fills
/// the cache and posts `.contactsRepositoryDidReload`, the same notification
/// the contact lists observe, so this list refreshes through one shared path.
final class GroupsListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can push (iPhone)
    /// or push-onto-supplementary (Catalyst) a `GroupMembersListViewController`
    /// without us holding a reference to the nav stack or the split.
    var didSelectGroup: (ContactGroup) -> Void = { _ in }

    private let repository: ContactsRepository
    private let favoritesStore: FavoritesListStore

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

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

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

        // Paint whatever the repository already cached, then kick a fresh fetch.
        // Groups are not loaded by the AppDelegate's contact reload, so this VC
        // owns triggering `loadGroups()`. The resulting `.contactsRepositoryDidReload`
        // re-applies the snapshot when the fetch lands; we additionally flip
        // `hasGroupsLoaded` in the continuation so the empty state can show the
        // spinner until the first fetch settles (repository is @MainActor, so the
        // continuation already resumes on main).
        applySnapshot(animated: false)
        Task {
            await repository.loadGroups()
            hasGroupsLoaded = true
            applySnapshot(animated: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
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
        emptyLabel.text = "No Groups"
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
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
                isFavorite: self.favoritesStore.isFavorite(kind: .group, id: group.localID)
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

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = repository.groups.isEmpty
        // Show the spinner only while the first fetch is in flight; once it lands
        // (`hasGroupsLoaded`), an empty group set surfaces the "No Groups" label.
        // The label text is fixed (set in configureEmptyState) — there is no
        // search-empty variant here, so it never needs re-assigning.
        emptyLabel.isHidden = !isEmpty || !hasGroupsLoaded
        if isEmpty && !hasGroupsLoaded {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }
}

// MARK: - UITableViewDelegate

extension GroupsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let group = groupsByLocalID[localID] else { return }
        didSelectGroup(group)
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
        let isFavorited = favoritesStore.isFavorite(kind: .group, id: group.localID)
        let action = UIContextualAction(
            style: .normal,
            title: isFavorited ? "Unfavorite" : "Favorite"
        ) { [weak self] _, _, completion in
            self?.favoritesStore.toggle(kind: .group, id: group.localID)
            completion(true)
        }
        action.image = UIImage(systemName: isFavorited ? "star.slash" : "star")
        action.backgroundColor = .systemYellow
        return UISwipeActionsConfiguration(actions: [action])
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
    /// for an (effectively never) empty name. Static so the list VC can compute
    /// the same string when comparing renders to detect a rename.
    static func displayName(for group: ContactGroup?) -> String {
        let name = group?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "(Unnamed Group)" : name
    }
}
