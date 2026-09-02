import UIKit
import EventKit
import GuessWhoSync

/// UIKit Favorites list for the Catalyst 3-column shell. Single-section
/// diffable data source keyed on opaque `FavoriteListItem.ID`. Mirrors the
/// SwiftUI `FavoritesListView`: swipe-to-unfavorite, drag-to-reorder,
/// and package-vended favorite rows rebuilt on `.contactsRepositoryDidReload`
/// (the repository's cache-changed signal, posted after the launch reload,
/// incremental patches, and self-writes), `.guidesRepositoryDidReload` (the
/// guides + places cache behind the guide and place rows), and scene
/// activation.
final class FavoritesListViewController: UIViewController {
    /// Selection callbacks — SceneDelegate routes each kind to the
    /// matching detail view (contact → ContactDetailView, event →
    /// EventDetailView, guide → its places list, place →
    /// GuidePlaceDetailView).
    var didSelectContact: (Contact) -> Void = { _ in }
    var didSelectEvent: (Event) -> Void = { _ in }
    var didSelectGroup: (ContactGroup) -> Void = { _ in }
    var didSelectGuide: (MapsGuide) -> Void = { _ in }
    var didSelectPlace: (MapsPlace) -> Void = { _ in }
    /// A favorited department drills into its members list (org + department
    /// name), exactly like tapping the department row on the organization page.
    var didSelectDepartment: (DepartmentFavorite) -> Void = { _ in }

    private let store: FavoritesListStore
    private let service: SyncService
    /// The single app-owned in-memory contact cache. The favorites builder
    /// reads `repository.contacts` instead of re-enumerating the whole store.
    private let repository: ContactsRepository
    /// The app-owned guides + places cache. Backs the guide and place
    /// resolvers handed to `favoriteListItems`, so a starred guide or place
    /// renders its own name rather than "Unavailable".
    private let guidesRepository: GuidesRepository
    private let photoLoader: ContactPhotoLoader

    private enum CellID: String {
        case favorite
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, FavoriteListItem.ID>!

    private var favoriteItemsByID: [FavoriteListItem.ID: FavoriteListItem] = [:]
    private var prefetchTasks: [ContactID: Task<Void, Never>] = [:]

    private let emptyLabel = UILabel()

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var sceneActiveObserver: NSObjectProtocol?
    private nonisolated(unsafe) var contactsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var eventsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var favoritesChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var guidesChangedObserver: NSObjectProtocol?

    /// Coalesces the resolver's per-place repository reloads. Re-projecting
    /// Favorites resolves every event through a synchronous sidecar read, so
    /// doing that for each place resolved would put repeated file I/O on the
    /// main actor while large guides load.
    private var pendingGuidesSnapshot: Task<Void, Never>?
    private static let guidesSnapshotDebounce: Duration = .milliseconds(300)

    init(
        store: FavoritesListStore,
        service: SyncService,
        repository: ContactsRepository,
        guidesRepository: GuidesRepository,
        photoLoader: ContactPhotoLoader
    ) {
        self.store = store
        self.service = service
        self.repository = repository
        self.guidesRepository = guidesRepository
        self.photoLoader = photoLoader
        super.init(nibName: nil, bundle: nil)
        title = "Favorites"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — FavoritesListViewController is code-only")
    }

    deinit {
        let center = NotificationCenter.default
        if let sceneActiveObserver { center.removeObserver(sceneActiveObserver) }
        if let contactsChangedObserver { center.removeObserver(contactsChangedObserver) }
        if let eventsChangedObserver { center.removeObserver(eventsChangedObserver) }
        if let favoritesChangedObserver { center.removeObserver(favoritesChangedObserver) }
        if let guidesChangedObserver { center.removeObserver(guidesChangedObserver) }
        pendingGuidesSnapshot?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureEmptyState()
        configureDataSource()
        observeNotifications()

        // Rows are projected by the package from the persisted favorites list.
        // If the repository's launch reload hasn't landed yet, a contact
        // favorite shows "Unavailable" until the `.contactsRepositoryDidReload`
        // observer below re-applies (the reconfigure pass repaints it).
        store.reload()
        applySnapshot(animated: false)

        // Group favorites resolve against the repository's `groups` cache, which
        // only `loadGroups()` fills — and the Favorites list may be opened before
        // the Groups tab ever is. Kick a load so starred groups render their name
        // instead of "Unavailable"; the resulting `.contactsRepositoryDidReload`
        // re-applies the snapshot (observed below), repainting the rows.
        Task { await repository.loadGroups() }

        // Same story for guide and place favorites: the guides cache is filled
        // only by `GuidesRepository.reload()`, which the Guides and Places lists
        // own — and neither may have been opened yet. The resulting
        // `.guidesRepositoryDidReload` re-applies the snapshot (observed below).
        Task { await guidesRepository.reload() }
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
        tableView.prefetchDataSource = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(FavoriteCell.self, forCellReuseIdentifier: CellID.favorite.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Favorites"
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, FavoriteListItem.ID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.favorite.rawValue, for: indexPath)
            guard let self, let item = self.favoriteItemsByID[itemID] else { return cell }
            (cell as? FavoriteCell)?.configure(
                with: item,
                photoLoader: self.photoLoader,
                guidePlaceCount: item.guide.map { self.guidesRepository.placeCount(inGuide: $0.id) }
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeNotifications() {
        let center = NotificationCenter.default

        sceneActiveObserver = center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.reload()
                // Rows project their contact through the package; the apply's
                // reconfigure pass repaints any rows whose resolved content
                // changed.
                self.applySnapshot(animated: true)
            }
        }

        // The repository posts `.contactsRepositoryDidReload` after EVERY
        // cache change — the async launch reload (which populates an
        // otherwise-empty cache), incremental external patches, and our own
        // self-write refreshes/removes. The package's raw external-delta
        // signal (`.guessWhoContactsDidChange`) deliberately does NOT fire on
        // the launch reload, so observing it left contact favorites resolving
        // against an empty cache at cold launch — every contact favorite
        // rendered "Unavailable" until an external Contacts edit happened to
        // fire. Observing the repository's reload post fixes that: re-applying
        // here re-runs the cell provider (via the reconfigure pass) so each row
        // re-renders from the now-populated package projection. It also keeps
        // favorites in sync with incremental patches + self-writes the old
        // signal missed.
        contactsChangedObserver = center.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySnapshot(animated: true)
            }
        }

        eventsChangedObserver = center.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // store.reload posts .favoritesDidChange, which the
                // observer below turns into applySnapshot — no explicit
                // apply needed here.
                self?.store.reload()
            }
        }

        // Catches favorite toggles from ContactDetailView /
        // EventDetailView — the SwiftUI iPhone list re-renders via
        // @Observable, but UIKit needs an explicit nudge. The store
        // has already reloaded before posting, so just apply.
        favoritesChangedObserver = center.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySnapshot(animated: true)
            }
        }

        // The guides repository posts this after every fetch — the reload
        // kicked above, a sidecar change syncing in, an import, a delete. Guide
        // and place rows resolve against its caches, so re-applying here is
        // what turns their cold-launch "Unavailable" into a name. No
        // `store.reload()`: a guides change can't rewrite `Favorites.json`,
        // only the records the ids resolve to. Resolution explicitly reloads
        // after each place, so this feed can run at roughly the resolver's
        // 200 ms cadence. Collapse that burst before re-projecting every
        // favorite on the main actor.
        guidesChangedObserver = center.addObserver(
            forName: .guidesRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleGuidesSnapshot()
            }
        }
    }

    private func scheduleGuidesSnapshot() {
        pendingGuidesSnapshot?.cancel()
        pendingGuidesSnapshot = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.guidesSnapshotDebounce)
            } catch {
                return
            }
            self?.applySnapshot(animated: true)
        }
    }

    private func applySnapshot(animated: Bool) {
        let items = repository.favoriteListItems(
            from: store.items,
            event: { [service] uuid in service.event(uuid: uuid) },
            // `UUID(uuidString:)` is case-insensitive, so a favorite's
            // lowercased id resolves against the repository's canonical UUIDs.
            // A string that isn't a UUID at all (a hand-edited file) simply
            // yields nil, and the row falls back to "Unavailable".
            guide: { [guidesRepository] uuid in
                UUID(uuidString: uuid).flatMap { guidesRepository.guide(id: $0) }
            },
            place: { [guidesRepository] uuid in
                UUID(uuidString: uuid).flatMap { guidesRepository.place(id: $0) }
            }
        )

        var byID: [FavoriteListItem.ID: FavoriteListItem] = [:]
        for item in items {
            byID[item.id] = item
        }
        favoriteItemsByID = byID

        // A favorite row's identity is its opaque package-vended ID, but the
        // cell provider renders resolved content (display name, "Unavailable"
        // state) from the package projection at build time. When the item SET is
        // unchanged but that resolved content changed — the cold-launch case
        // where the repository cache flips empty→populated, plus any later
        // display-name edit — the diff is empty, so the data source never
        // re-invokes the cell provider for rows already on screen and the stale
        // "Unavailable" cell sticks. Explicitly reconfigure the items that
        // already exist so they re-run the provider and re-render against the
        // current projection. Newly inserted items are guard-excluded: they're
        // not yet in the data source's snapshot and the insert builds them fresh
        // anyway (reconfiguring an absent item would crash).
        let existingIDs = Set(dataSource.snapshot().itemIdentifiers)

        var snapshot = NSDiffableDataSourceSnapshot<Int, FavoriteListItem.ID>()
        snapshot.appendSections([0])
        let itemIDs = items.map(\.id)
        snapshot.appendItems(itemIDs, toSection: 0)
        let reconfigureIDs = itemIDs.filter { existingIDs.contains($0) }
        if !reconfigureIDs.isEmpty {
            snapshot.reconfigureItems(reconfigureIDs)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        emptyLabel.isHidden = !items.isEmpty
    }

    /// The row context menu, routed by kind through `FavoriteContextMenuRouter`.
    ///
    /// Favorites is a list whose rows are NOT all contacts: it mixes people,
    /// organizations, events, groups, guides, and places. The router hands a
    /// favorited person or organization the "Add to Group" menu (both are
    /// `Contact`s and both can hold group membership), a favorited group the
    /// Email All Members / Rename / Delete menu, and everything else no menu at
    /// all. The SAME router backs the Catalyst sidebar's favorite children, so a
    /// favorite reads identically in both surfaces — which is the whole reason it
    /// is factored out.
    ///
    /// A menu here always acts on exactly the row it was opened on: this list is
    /// single-selection (it never calls `ContactMultiSelectionSupport.configure`),
    /// so the "Add to Group" path never sweeps in an offscreen selection.
    private lazy var favoriteContextMenus = FavoriteContextMenuRouter(
        repository: repository,
        favoritesStore: store,
        host: self,
        itemForRow: { [weak self] indexPath in
            guard let self, let itemID = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            return self.favoriteItemsByID[itemID]
        }
    )
}

// MARK: - UITableViewDelegate

extension FavoritesListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let itemID = dataSource.itemIdentifier(for: indexPath),
              let item = favoriteItemsByID[itemID] else { return }
        switch item.kind {
        case .contact:
            if let contact = item.contact {
                didSelectContact(contact)
            }
        case .event:
            if let event = item.event {
                didSelectEvent(event)
            }
        case .group:
            if let group = item.group {
                didSelectGroup(group)
            }
        case .guide:
            if let guide = item.guide {
                didSelectGuide(guide)
            }
        case .place:
            if let place = item.place {
                didSelectPlace(place)
            }
        case .department:
            if let department = item.department {
                didSelectDepartment(department)
            }
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? FavoriteCell)?.cancelPhotoLoad()
    }

    /// Right-click / long-press menu, routed by the favorited row's kind — see
    /// `favoriteContextMenus`. Event, guide, and place rows return no
    /// configuration, so they keep the behavior they have today (no menu).
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        favoriteContextMenus.configuration(forRowAt: indexPath)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let itemID = dataSource.itemIdentifier(for: indexPath),
              favoriteItemsByID[itemID] != nil else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Unfavorite") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            // store.toggle → store.reload → posts .favoritesDidChange,
            // which the observer turns into applySnapshot.
            self.store.toggle(itemID)
            completion(true)
        }
        action.image = UIImage(systemName: "star.slash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }
}

extension FavoritesListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

// MARK: - GroupContextMenuEmailResponder

extension FavoritesListViewController: GroupContextMenuEmailResponder {
    // A favorited group's Catalyst Email command fires down the responder chain
    // (see `GroupContextMenu.emailElements`); forward it to the router that
    // built it. `individually` is what the Option alternate selects.
    func emailGroupMembers(_ sender: UICommand) {
        favoriteContextMenus.handleGroupEmailCommand(sender, individually: false)
    }

    func emailGroupMembersSeparately(_ sender: UICommand) {
        favoriteContextMenus.handleGroupEmailCommand(sender, individually: true)
    }
}

// MARK: - UITableViewDataSourcePrefetching

extension FavoritesListViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let itemID = dataSource.itemIdentifier(for: indexPath),
                  let contact = favoriteItemsByID[itemID]?.contact else { continue }
            let id = contact.contactID
            guard prefetchTasks[id] == nil,
                  photoLoader.cachedImage(for: id, kind: .thumbnail) == nil else { continue }
            prefetchTasks[id] = Task { [weak self, photoLoader] in
                _ = await photoLoader.image(for: id, kind: .thumbnail)
                await MainActor.run {
                    self?.prefetchTasks[id] = nil
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let itemID = dataSource.itemIdentifier(for: indexPath),
                  let contact = favoriteItemsByID[itemID]?.contact else { continue }
            let id = contact.contactID
            prefetchTasks[id]?.cancel()
            prefetchTasks[id] = nil
        }
    }
}

// MARK: - Drag & drop reorder

extension FavoritesListViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard dataSource.itemIdentifier(for: indexPath) != nil else { return [] }
        // Empty provider — the drop path uses item.sourceIndexPath, so
        // there's nothing to encode. A populated provider would leak
        // the internal stableID to external drop targets.
        return [UIDragItem(itemProvider: NSItemProvider())]
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        let destination = coordinator.destinationIndexPath
            ?? IndexPath(row: tableView.numberOfRows(inSection: 0), section: 0)

        // Collect every source row into one IndexSet so a single
        // store.move call handles the reorder atomically. A per-item
        // loop would feed each subsequent move the ORIGINAL row index
        // even though the prior move already shifted things — fine for
        // today's single-item drag sessions, broken the moment multi-
        // drag gets turned on.
        var sourceRows = IndexSet()
        for item in coordinator.items {
            guard let source = item.sourceIndexPath else { continue }
            sourceRows.insert(source.row)
        }
        guard !sourceRows.isEmpty else { return }

        // store.move writes to disk and reloads `items`, so the
        // subsequent applySnapshot picks up the new order.
        store.move(from: sourceRows, to: destination.row)
        for item in coordinator.items {
            coordinator.drop(item.dragItem, toRowAt: destination)
        }
        applySnapshot(animated: true)
    }
}

// MARK: - Row cell

/// Two-line favorite row. Cell presentation switches by `FavoriteListItem.kind`
/// and resolution state:
/// * .contact resolved → avatar + bold-family name, plus a
///   "jobTitle, organizationName" caption for people (matching the People
///   list's `ContactCell`); organizations render name-only like the
///   Organizations list's `OrganizationCell`.
/// * .contact unresolved → person.crop.circle.badge.questionmark +
///   "Unavailable" with a "Contact" caption.
/// * .event resolved → calendar + title + start-date caption.
/// * .event unresolved → calendar.badge.exclamationmark + "Unavailable"
///   with an "Event" caption.
/// * .group resolved → person.3.fill + group name.
/// * .group unresolved → person.3 + "Unavailable" with a "Group" caption.
/// * .guide resolved → map + guide name + "N places" caption.
/// * .guide unresolved → questionmark.circle + "Unavailable" with a "Guide"
///   caption (SF Symbols has no badged `map` variant to mirror the event row's
///   calendar.badge.exclamationmark).
/// * .place resolved → mappin.and.ellipse + place name + address caption.
/// * .place unresolved → mappin.slash + "Unavailable" with a "Place" caption.
private final class FavoriteCell: UITableViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let calendarSwatch = UIView()
    private let calendarLabel = UILabel()
    private let calendarRow = UIStackView()
    private var representedContactID: ContactID?
    private var photoTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — FavoriteCell is code-only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPhotoLoad()
        representedContactID = nil
        iconView.image = nil
        captionLabel.isHidden = false
        calendarLabel.text = nil
        calendarSwatch.backgroundColor = nil
        calendarRow.isHidden = true
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listPlainCell().updated(for: state)
        if state.isSelected || state.isHighlighted {
            background.backgroundColor = .tintColor
            background.cornerRadius = 8
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
        }
        backgroundConfiguration = background
    }

    private func configureSubviews() {
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 12
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1

        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.textColor = .secondaryLabel
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.numberOfLines = 1

        // Calendar line (swatch + name), shown only for resolved events that
        // carry a calendar name — matches the Events list so the same event
        // duplicated across calendars is disambiguated in both places.
        calendarSwatch.translatesAutoresizingMaskIntoConstraints = false
        calendarSwatch.layer.cornerRadius = 3
        calendarSwatch.layer.cornerCurve = .continuous
        calendarSwatch.setContentHuggingPriority(.required, for: .horizontal)
        calendarSwatch.setContentCompressionResistancePriority(.required, for: .horizontal)

        calendarLabel.font = .preferredFont(forTextStyle: .caption1)
        calendarLabel.textColor = .secondaryLabel
        calendarLabel.adjustsFontForContentSizeCategory = true
        calendarLabel.translatesAutoresizingMaskIntoConstraints = false
        calendarLabel.numberOfLines = 1

        calendarRow.axis = .horizontal
        calendarRow.alignment = .center
        calendarRow.spacing = 5
        calendarRow.translatesAutoresizingMaskIntoConstraints = false
        calendarRow.isHidden = true
        calendarRow.addArrangedSubview(calendarSwatch)
        calendarRow.addArrangedSubview(calendarLabel)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, captionLabel, calendarRow])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            calendarSwatch.widthAnchor.constraint(equalToConstant: 10),
            calendarSwatch.heightAnchor.constraint(equalToConstant: 10),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    /// - Parameter guidePlaceCount: how many places the row's guide holds, for
    ///   the "N places" caption the Guides list shows. Nil for every other kind
    ///   (and for a guide that hasn't resolved).
    func configure(
        with item: FavoriteListItem,
        photoLoader: ContactPhotoLoader,
        guidePlaceCount: Int? = nil
    ) {
        cancelPhotoLoad()
        representedContactID = nil
        // Default the calendar line off; only a resolved event turns it on.
        calendarLabel.text = nil
        calendarSwatch.backgroundColor = nil
        calendarRow.isHidden = true
        switch item.kind {
        case .contact:
            if let contact = item.contact {
                let id = contact.contactID
                representedContactID = id
                iconView.contentMode = .scaleAspectFill
                iconView.image = ContactAvatarImage.placeholder(for: contact, diameter: 24)
                if let cached = photoLoader.cachedImage(for: id, kind: .thumbnail) {
                    iconView.image = cached
                } else {
                    photoTask = Task { [weak self, photoLoader] in
                        guard let image = await photoLoader.image(for: id, kind: .thumbnail) else { return }
                        await MainActor.run {
                            guard self?.representedContactID == id else { return }
                            self?.iconView.image = image
                        }
                    }
                }
                titleLabel.attributedText = contact.nameAttributedString
                // Same "jobTitle, organizationName" caption the People list
                // shows. The helper returns "" for organizations (and people
                // with no job/org), so those rows stay name-only with the
                // caption hidden.
                let subtitle = Self.subtitle(for: contact)
                captionLabel.text = subtitle
                captionLabel.isHidden = subtitle.isEmpty
            } else {
                iconView.contentMode = .scaleAspectFit
                iconView.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Contact"
                captionLabel.isHidden = false
            }
        case .event:
            if let event = item.event {
                iconView.contentMode = .scaleAspectFit
                iconView.image = UIImage(systemName: "calendar")
                titleLabel.text = event.title.isEmpty ? "(Untitled event)" : event.title
                captionLabel.text = event.startDate.formatted(date: .abbreviated, time: .omitted)
                captionLabel.isHidden = false
                if let name = event.calendarName, !name.isEmpty {
                    calendarLabel.text = name
                    // Swatch shows only when we have a color; otherwise hide it
                    // and let the name alone identify the calendar.
                    let color = event.calendarColorHex.flatMap(UIColor.init(hexString:))
                    calendarSwatch.backgroundColor = color
                    calendarSwatch.isHidden = (color == nil)
                    calendarRow.isHidden = false
                }
            } else {
                iconView.contentMode = .scaleAspectFit
                iconView.image = UIImage(systemName: "calendar.badge.exclamationmark")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Event"
                captionLabel.isHidden = false
            }
        case .group:
            iconView.contentMode = .scaleAspectFit
            if let group = item.group {
                iconView.image = UIImage(systemName: "person.3.fill")
                let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                titleLabel.text = name.isEmpty ? "(Unnamed Group)" : name
                captionLabel.text = nil
                captionLabel.isHidden = true
            } else {
                iconView.image = UIImage(systemName: "person.3")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Group"
                captionLabel.isHidden = false
            }

        case .guide:
            iconView.contentMode = .scaleAspectFit
            if let guide = item.guide {
                // The Guides list row's icon, which is also the Guides
                // section's — one icon per kind.
                iconView.image = UIImage(systemName: SidebarTab.guides.systemImage)
                let name = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
                titleLabel.text = name.isEmpty ? "(Unnamed Guide)" : name
                if let count = guidePlaceCount {
                    captionLabel.text = count == 1 ? "1 place" : "\(count) places"
                    captionLabel.isHidden = false
                } else {
                    captionLabel.text = nil
                    captionLabel.isHidden = true
                }
            } else {
                iconView.image = UIImage(systemName: "questionmark.circle")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Guide"
                captionLabel.isHidden = false
            }

        case .place:
            iconView.contentMode = .scaleAspectFit
            if let place = item.place {
                iconView.image = UIImage(systemName: SidebarTab.places.systemImage)
                // Same title/caption split the Places lists use: the business
                // name leads with its address beneath, and an address-only
                // entry promotes the address to the title.
                let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let address = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty {
                    titleLabel.text = name
                    captionLabel.text = address
                    captionLabel.isHidden = address.isEmpty
                } else if !address.isEmpty {
                    titleLabel.text = address
                    captionLabel.text = nil
                    captionLabel.isHidden = true
                } else {
                    // Still waiting on its MapKit lookup, or resolved to
                    // nothing — same wording `PlaceCell` shows.
                    titleLabel.text = "(No details)"
                    captionLabel.text = nil
                    captionLabel.isHidden = true
                }
            } else {
                iconView.image = UIImage(systemName: "mappin.slash")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Place"
                captionLabel.isHidden = false
            }

        case .department:
            iconView.contentMode = .scaleAspectFit
            // The department row's icon on the organization page — one icon per
            // kind.
            iconView.image = UIImage(systemName: "person.2")
            if let department = item.department {
                titleLabel.text = department.department
                captionLabel.text = department.organization.displayName
                captionLabel.isHidden = department.organization.displayName.isEmpty
            } else {
                titleLabel.text = "Unavailable"
                captionLabel.text = "Department"
                captionLabel.isHidden = false
            }
        }
    }

    func cancelPhotoLoad() {
        photoTask?.cancel()
        photoTask = nil
    }

    /// "jobTitle, organizationName" caption for people; "" for organizations
    /// (guarded on `contactType`) and for people missing both fields. Mirrors
    /// `ContactCell.subtitle(for:)`.
    private static func subtitle(for contact: Contact) -> String {
        guard contact.contactType == .person else { return "" }
        let title = contact.jobTitle
        let org = contact.organizationName
        if !title.isEmpty, !org.isEmpty { return "\(title), \(org)" }
        if !title.isEmpty { return title }
        return org
    }
}
