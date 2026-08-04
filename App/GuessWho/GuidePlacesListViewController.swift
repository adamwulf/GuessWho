import UIKit
import GuessWhoSync

/// The places inside one imported guide, in the guide's shared order. Pushed
/// from the Guides list on both shells (like Groups → members). Rows fill in
/// as the MapKit resolution pass lands details; tapping a place opens its
/// detail via `didSelectPlace`.
final class GuidePlacesListViewController: UIViewController {
    private var guide: MapsGuide
    private let repository: GuidesRepository
    private let service: SyncService
    private let favoritesStore: FavoritesListStore

    private enum CellID: String {
        case place
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>!
    private var searchController: UISearchController!

    /// The live search query, exactly as the search bar shows it.
    ///
    /// Unlike the People / Events / Organizations lists — whose queries live on
    /// their shared repository and so can outlive the list that typed them (see
    /// `ContactsListViewController.configureSearch`) — this one is per-view
    /// state, because `GuidesRepository` is out of this list's reach to extend.
    /// That makes the bar and the filter agree by construction: a fresh list
    /// gets a fresh, empty bar AND a fresh, empty query, and the two die
    /// together. Read it through `trimmedSearchQuery`, never raw.
    private var searchQuery = ""

    /// `searchQuery` without its surrounding whitespace — the form every
    /// matcher, empty-state string, and drag guard uses. Empty means "no
    /// search in force", so a bar holding only spaces filters nothing.
    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placesByID: [UUID: MapsPlace] = [:]

    /// Invoked when a place row is tapped. The scene delegate wires this to show
    /// a `GuidePlaceDetailView` the way the owning shell expects: PUSHED onto the
    /// owning nav in the iPhone tab stack (and for a Catalyst in-detail
    /// drill-down), or REPLACING the secondary column when this list is in the
    /// Catalyst supplementary column. When unset, tapping falls back to opening
    /// Apple Maps directly.
    var didSelectPlace: ((MapsPlace) -> Void)?

    private let emptyLabel = UILabel()

    /// The sort pull-down button. Its menu is rebuilt in the reload observer so
    /// the checkmark tracks the repository's live place order.
    private var sortButton: UIBarButtonItem!
    private var refreshButton: UIBarButtonItem!
    private var isRefreshing = false
    private var filterButton: UIBarButtonItem!

    /// Set true when a reload / resolution notification arrives during an active
    /// drag, so we can defer the `dataSource.apply` until the drag ends. Applying
    /// a diffable snapshot mid-drag re-materializes the lifted source row in the
    /// list (the lift preview is a separate snapshot view), leaving a duplicate
    /// with no gap. The background resolution pass reloads the repository after
    /// every place, so without this gate a drag over an unresolved guide is
    /// almost always interrupted. Flushed by `flushDeferredSnapshotIfNeeded()`
    /// when the drag ends (`performDropWith` / `dragSessionDidEnd`).
    private var needsSnapshotAfterDrag = false

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?
    private nonisolated(unsafe) var resolutionObserver: NSObjectProtocol?
    private nonisolated(unsafe) var favoritesObserver: NSObjectProtocol?

    init(
        guide: MapsGuide,
        repository: GuidesRepository,
        service: SyncService,
        favoritesStore: FavoritesListStore
    ) {
        self.guide = guide
        self.repository = repository
        self.service = service
        self.favoritesStore = favoritesStore
        super.init(nibName: nil, bundle: nil)
        let name = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
        title = name.isEmpty ? "Guide" : name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GuidePlacesListViewController is code-only")
    }

    deinit {
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
        }
        if let resolutionObserver {
            NotificationCenter.default.removeObserver(resolutionObserver)
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
        configureNavigationButtons()
        configureSearch()
        observeRepositoryReloads()

        applySnapshot(animated: false)

        // Stamp lastViewed ONCE per open (opening a guide's places is the
        // guide equivalent of opening a detail view). Fire-and-forget: the
        // package no-ops when no sidecar exists, and the resulting sidecar
        // change drives the guides list's debounced reload so a "Last Viewed"
        // sort re-orders. Mirrors EventDetailView's on-open stamp.
        service.stampGuideViewed(uuid: guide.id.uuidString)

        // Retry any still-unresolved place IDs each time the guide opens (a
        // prior pass may have hit a network failure, or the app may have quit
        // mid-resolution). No-op when everything is already resolved, or when
        // the import path's pass is still running (the resolver's per-guide
        // in-flight guard coalesces the two). The resolver reloads the
        // repository after each place, so rows fill in live.
        Task { [repository, service, guideID = guide.id] in
            await GuidePlaceResolver.resolvePlaces(
                inGuide: guideID, service: service, repository: repository
            )
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
        // Press-and-hold to reorder, like the Favorites list. Dragging is only
        // offered while sorted by "Guide Order" (see the drag delegate) — the
        // other orders are derived, so hand-reordering them is meaningless.
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(PlaceCell.self, forCellReuseIdentifier: CellID.place.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            // Keyboard guide, not safe area: rows stay above the search
            // keyboard instead of hiding under it. With no keyboard the guide
            // rests at the safe-area bottom, so this is the same constraint
            // the rest of the time. (The People / Events lists pin the same
            // way — see `UISearchController.installKeyboardDismissal`.)
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    /// Installs the inline search bar, the same shape the People and Events
    /// lists use: no dimming (rows stay live under the bar), always visible
    /// rather than hiding on scroll, and both keyboard escape hatches.
    ///
    /// No republish-to-the-repository step here, unlike those lists: the query
    /// is this view controller's own (see `searchQuery`), so there is no shared
    /// field a stale query could linger in.
    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search places"
        searchController.installKeyboardDismissal(for: tableView)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        // Mirror the bar rather than assigning "", so the invariant reads as
        // "the filter is whatever the user can see in the bar" — still correct
        // if state restoration ever seeds the bar with text.
        searchQuery = searchController.searchBar.text ?? ""
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Places"
        // Multi-line, like the unified Places tab's label: the no-matches copy
        // quotes the user's query back, which a one-line label would truncate.
        emptyLabel.numberOfLines = 0
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
        dataSource = UITableViewDiffableDataSource<Int, UUID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, placeID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.place.rawValue, for: indexPath)
            guard let self, let place = self.placesByID[placeID] else { return cell }
            (cell as? PlaceCell)?.configure(
                with: place,
                status: self.status(for: place),
                isFavorite: self.favoritesStore.isFavorite(kind: .place, id: place.id.uuidString),
                linkCount: self.repository.linkCount(for: place)
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func configureNavigationButtons() {
        sortButton = makePlaceSortBarButtonItem(repository: repository)
        refreshButton = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refreshGuide)
        )
        refreshButton.accessibilityLabel = "Refresh Guide"
        refreshButton.isEnabled = guide.sourceURL != nil
        filterButton = makeLinkFilterBarButtonItem(
            current: repository.placeFilter,
            allTitle: "All Places"
        ) { [weak repository] filter in
            repository?.placeFilter = filter
        }
        // The first item is the trailing (top-right) item. Preserve Refresh in
        // that position, with the sort glyph beside it and the filter glyph on
        // the left. Left-to-right the user reads: filter, sort, refresh.
        navigationItem.rightBarButtonItems = [refreshButton, sortButton, filterButton]
    }

    @objc
    private func refreshGuide() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshButton.isEnabled = false

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await GuideImporter.refreshGuide(
                    self.guide,
                    service: self.service,
                    repository: self.repository
                )
                self.guide.name = snapshot.name
                let name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
                self.title = name.isEmpty ? "Guide" : name
            } catch is CancellationError {
                // A cancelled navigation task needs no user-facing error.
            } catch {
                self.service.recordError("refresh guide failed: \(error.localizedDescription)")
                self.presentRefreshError(error)
            }
            self.isRefreshing = false
            self.refreshButton.isEnabled = self.guide.sourceURL != nil
        }
    }

    private func presentRefreshError(_ error: Error) {
        guard viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(
            title: "Couldn’t Refresh Guide",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func refreshFilterMenu() {
        filterButton.menu = makeLinkFilterMenu(
            current: repository.placeFilter,
            allTitle: "All Places"
        ) { [weak repository] filter in
            repository?.placeFilter = filter
        }
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        // The repository reloads after imports, deletes, resolution passes,
        // and external sidecar changes — all funnel through this one post.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .guidesRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A diffable apply mid-drag re-materializes the lifted row (see
                // `needsSnapshotAfterDrag`); defer it until the drag settles.
                guard !self.isDragActive else {
                    self.needsSnapshotAfterDrag = true
                    return
                }
                self.applySnapshot(animated: true)
                // Rebuild the sort menu so the checkmark tracks the order that
                // produced this reload (menus are immutable snapshots).
                self.sortButton.menu = self.makePlaceSortMenu(repository: self.repository)
                self.refreshFilterMenu()
            }
        }
        // The resolver moves its "looking up now" marker between rows without a
        // data reload; repaint the unresolved rows so the spinner follows it.
        resolutionObserver = NotificationCenter.default.addObserver(
            forName: .guideResolutionActivePlaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshResolutionStatus()
            }
        }
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFavoriteStatus()
            }
        }
    }

    /// Favorite state is not part of `MapsPlace`, so a toggle from detail does
    /// not change item identity. Reconfigure rows, while honoring the same
    /// mid-drag gate as resolver-driven snapshots.
    private func refreshFavoriteStatus() {
        guard !isDragActive else {
            needsSnapshotAfterDrag = true
            return
        }
        var snapshot = dataSource.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Reconfigure the still-unresolved rows so their status (looking-up /
    /// waiting) tracks the resolver's current place. Cheap: touches only the
    /// pending rows, and no-ops when everything is resolved.
    private func refreshResolutionStatus() {
        // Same mid-drag guard as the reload observer: reconfiguring rows is a
        // `dataSource.apply`, which would re-materialize the lifted row.
        guard !isDragActive else {
            needsSnapshotAfterDrag = true
            return
        }
        var snapshot = dataSource.snapshot()
        let unresolved = snapshot.itemIdentifiers.filter { placesByID[$0]?.needsResolution == true }
        guard !unresolved.isEmpty else { return }
        snapshot.reconfigureItems(unresolved)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// True while a drag (or its drop animation) is in flight, so a snapshot
    /// apply would disrupt the lift. Covers both the source table's drag and an
    /// incoming drop.
    private var isDragActive: Bool {
        tableView.hasActiveDrag || tableView.hasActiveDrop
    }

    /// Apply any snapshot deferred during a drag. Called when the drag ends —
    /// whether it completed in a drop or was cancelled — so the list catches up
    /// on resolution progress that landed while the user was dragging.
    private func flushDeferredSnapshotIfNeeded() {
        guard needsSnapshotAfterDrag else { return }
        needsSnapshotAfterDrag = false
        applySnapshot(animated: true)
        sortButton.menu = makePlaceSortMenu(repository: repository)
    }

    private func status(for place: MapsPlace) -> PlaceRowStatus {
        if !place.needsResolution { return .resolved }
        if GuidePlaceResolver.resolvingPlaceID == place.id { return .resolving }
        if GuidePlaceResolver.isResolving(guide: guide.id) { return .waiting }
        return .idle
    }

    /// The guide's places after the repository's Linked filter and sort (both
    /// applied by `places(inGuide:)`) and then this list's search query.
    /// Filtering last preserves whichever order the repository handed back, so
    /// search composes with every sort instead of replacing it.
    ///
    /// No guide name is passed to the matcher: every row on this screen belongs
    /// to the SAME guide, so a guide-name arm would match all rows or none —
    /// the unified Places tab is where that arm earns its keep.
    private func searchedPlaces() -> [MapsPlace] {
        let places = repository.places(inGuide: guide.id)
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return places }
        return places.filter { $0.matchesPlaceSearch(query) }
    }

    private func applySnapshot(animated: Bool) {
        let places = searchedPlaces()

        var byID: [UUID: MapsPlace] = [:]
        for place in places {
            byID[place.id] = place
        }
        placesByID = byID

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(places.map(\.id), toSection: 0)
        // Resolution mutates a row's content without changing its item id —
        // reconfigure survivors so names/addresses repaint as they land.
        let surviving = places.map(\.id).filter { dataSource.snapshot().indexOfItem($0) != nil }
        if !surviving.isEmpty {
            snapshot.reconfigureItems(surviving)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        // Name the query when one is in force: "No Places" under an active
        // search would read as an empty guide rather than an empty result.
        let query = trimmedSearchQuery
        if places.isEmpty && !query.isEmpty {
            emptyLabel.text = "No places match “\(query)”."
        } else if repository.placeFilter == .linked {
            emptyLabel.text = "No Linked Places"
        } else {
            emptyLabel.text = "No Places"
        }
        emptyLabel.isHidden = !places.isEmpty
    }

    // MARK: - Open in Maps

    /// Open the place in Apple Maps. Resolved (or place-ID) entries open via
    /// the durable place ID; address entries fall back to coordinate + query.
    private func openInMaps(_ place: MapsPlace) {
        var components = URLComponents(string: "https://maps.apple.com/place")!
        if let placeID = place.mapsPlaceID {
            components.queryItems = [URLQueryItem(name: "place-id", value: placeID)]
        } else {
            components.path = "/"
            var items: [URLQueryItem] = []
            if let latitude = place.latitude, let longitude = place.longitude {
                items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
            }
            let query = place.name.isEmpty ? (place.address ?? "") : place.name
            if !query.isEmpty {
                items.append(URLQueryItem(name: "q", value: query))
            }
            guard !items.isEmpty else { return }
            components.queryItems = items
        }
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - UITableViewDelegate

extension GuidePlacesListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // No immediate deselect: on an expanded split view the highlighted row
        // is the pointer to the place open in the detail pane (the People /
        // Events pattern, shared with `PlacesListViewController`); the
        // viewWillAppear helper clears it for the collapsed/push cases.
        guard let placeID = dataSource.itemIdentifier(for: indexPath),
              let place = placesByID[placeID] else { return }
        if let didSelectPlace {
            didSelectPlace(place)
        } else {
            // Handing off to Apple Maps opens nothing in-app, so no later
            // navigation return will clear the highlight — drop it here.
            tableView.deselectRow(at: indexPath, animated: true)
            openInMaps(place)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let placeID = dataSource.itemIdentifier(for: indexPath),
              let place = placesByID[placeID] else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            self?.confirmDelete(place: place, completion: completion)
        }
        action.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    private func confirmDelete(place: MapsPlace, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Remove this place from the guide?",
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.performDelete(place: place)
            completion(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }

    private func performDelete(place: MapsPlace) {
        do {
            try service.deletePlace(uuid: place.id.uuidString)
        } catch {
            service.recordError("delete place failed: \(error.localizedDescription)")
            Task { await repository.reload() }
            return
        }
        if favoritesStore.isFavorite(kind: .place, id: place.id.uuidString) {
            do {
                try favoritesStore.remove(kind: .place, id: place.id.uuidString)
            } catch {
                service.recordError("unfavorite deleted place failed: \(error.localizedDescription)")
            }
        }
        Task { await repository.reload() }
    }
}

extension GuidePlacesListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

// MARK: - Drag & drop reorder

extension GuidePlacesListViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    /// Whether a hand-reorder can be persisted right now. All three conditions
    /// are about the same hazard: the rows on screen must BE the guide's
    /// canonical order, because `movePlaces(inGuide:from:to:)` renumbers every
    /// place from the moved row positions.
    ///
    /// - `.guideOrder` — the other orders are derived, so a drop in them has
    ///   nothing to persist.
    /// - `.all` — the Linked filter hides rows, so dropping between two
    ///   survivors would renumber past the hidden ones.
    /// - no search — likewise, and more so: a query can hide any subset, so a
    ///   filtered drop would rewrite the whole guide's order from a handful of
    ///   visible rows.
    private var canReorder: Bool {
        repository.placeSortOrder == .guideOrder
            && repository.placeFilter == .all
            && trimmedSearchQuery.isEmpty
    }

    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        // Reordering only makes sense in the guide's own entry order — the
        // Name / Last Viewed orders are derived, so hand-placing a row there
        // has nothing to persist. Returning [] disables the drag lift.
        guard canReorder,
              dataSource.itemIdentifier(for: indexPath) != nil else { return [] }
        // Empty provider — the drop path uses item.sourceIndexPath, so there's
        // nothing to encode (mirrors FavoritesListViewController).
        return [UIDragItem(itemProvider: NSItemProvider())]
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard canReorder else {
            return UITableViewDropProposal(operation: .cancel)
        }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        // Re-checked here, not just at lift time: a query typed (or a sort or
        // filter changed) mid-drag must not land a reorder computed from the
        // rows the drag started with.
        guard canReorder else { return }
        let destination = coordinator.destinationIndexPath
            ?? IndexPath(row: tableView.numberOfRows(inSection: 0), section: 0)

        // Collect every source row into one IndexSet so a single move handles
        // the reorder atomically (same rationale as FavoritesListViewController).
        var sourceRows = IndexSet()
        for item in coordinator.items {
            guard let source = item.sourceIndexPath else { continue }
            sourceRows.insert(source.row)
        }
        guard !sourceRows.isEmpty else { return }

        // Persists the new order and updates the in-memory copy, so the
        // applySnapshot below paints the final order immediately (the debounced
        // sidecar reload later reconciles to the same order).
        repository.movePlaces(inGuide: guide.id, from: sourceRows, to: destination.row)
        for item in coordinator.items {
            coordinator.drop(item.dragItem, toRowAt: destination)
        }
        // This apply already reflects the newest repository state, so any reload
        // deferred during the drag is now redundant — clear the pending flag.
        needsSnapshotAfterDrag = false
        applySnapshot(animated: true)
    }

    /// Fires when the drag ends for ANY reason — a completed drop, a cancel, or
    /// a lift-and-release in place. `performDropWith` handles the reorder case;
    /// this catches the no-drop cases so a reload/resolution update that arrived
    /// mid-drag still gets applied instead of being stranded.
    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        flushDeferredSnapshotIfNeeded()
    }
}

// MARK: - UISearchResultsUpdating

extension GuidePlacesListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard searchQuery != text else { return }
        searchQuery = text
        // The search controller can update while a lifted row is active (for
        // example, hardware-keyboard input during a pointer drag). Defer this
        // snapshot through the same gate as resolution/favorite updates.
        guard !isDragActive else {
            needsSnapshotAfterDrag = true
            return
        }
        // Nothing observes `searchQuery`, so re-snapshot here. Unanimated: the
        // list re-filters on every keystroke, and a fade per character reads as
        // flicker (the People and Events lists do the same).
        applySnapshot(animated: false)
    }
}

// The row cell lives in `PlaceCell.swift`, shared with the unified Places
// tab (`PlacesListViewController`). The row matcher
// (`MapsPlace.matchesPlaceSearch`) is likewise shared, and lives in
// `PlacesListViewController.swift` — the surface that needs its guide-name arm.
