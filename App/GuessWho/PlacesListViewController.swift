import UIKit
import GuessWhoSync

/// Every place across every imported guide in one list — the unified Places
/// tab (a sidebar row on Catalyst, a tab on iPhone). Sibling of
/// `GuidePlacesListViewController`, which shows ONE guide's places: this list
/// spans guides, so it groups into per-guide sections in the default
/// "By Guide" order, adds a guide caption to rows in the flat orders, and
/// drops the drag-to-reorder and refresh affordances (entry order and the
/// source URL are per-guide concepts). Rows fill in as the MapKit resolution
/// pass lands details; tapping a place opens its detail via `didSelectPlace`.
final class PlacesListViewController: UIViewController {
    private let repository: GuidesRepository
    private let service: SyncService

    private enum CellID: String {
        case place
    }

    private var tableView: UITableView!
    private var dataSource: PlacesDataSource!
    private var searchController: UISearchController!

    /// The live search query, exactly as the search bar shows it. Per-view
    /// state rather than a shared `GuidesRepository` field — see
    /// `GuidePlacesListViewController.searchQuery` for why that is the safer
    /// half of the trade. Read it through `trimmedSearchQuery`, never raw.
    private var searchQuery = ""

    /// `searchQuery` without its surrounding whitespace — the form the matcher
    /// and the empty-state string use. Empty means "no search in force".
    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var placesByID: [UUID: MapsPlace] = [:]

    /// The Catalyst sidebar's outstanding "highlight this place" request,
    /// retained until the repository reload makes its row available.
    private let pendingSelection = PendingRowSelection<UUID>()

    /// Guide display names keyed by guide id, rebuilt per snapshot. Backs the
    /// flat sorts' per-row guide caption and the remove-confirmation copy.
    private var guideNamesByID: [UUID: String] = [:]

    /// Invoked when a place row is tapped. The scene delegate wires this to
    /// show a `GuidePlaceDetailView` (replacing the detail column on Catalyst,
    /// pushing on iPhone).
    var didSelectPlace: ((MapsPlace) -> Void)?

    private let emptyLabel = UILabel()

    /// Suppresses the empty-state label until the first explicit reload lands,
    /// so a slow cold start shows a blank list rather than flashing
    /// "No Places" at a user who has guides. Same shape as the Guides list.
    private var hasLoaded = false

    private var sortButton: UIBarButtonItem!
    private var filterButton: UIBarButtonItem!

    /// True while the sequential resolve-every-guide walk is running, so a
    /// re-appearance doesn't stack a second walk on top of it.
    private var isResolutionWalkActive = false

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?
    private nonisolated(unsafe) var resolutionObserver: NSObjectProtocol?

    init(repository: GuidesRepository, service: SyncService) {
        self.repository = repository
        self.service = service
        super.init(nibName: nil, bundle: nil)
        title = SidebarTab.places.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — PlacesListViewController is code-only")
    }

    deinit {
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
        }
        if let resolutionObserver {
            NotificationCenter.default.removeObserver(resolutionObserver)
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

        // Paint whatever the repository already cached, then kick a fresh
        // fetch; the reload's notification re-applies the snapshot. This tab
        // can be the first guide surface the user opens, so it must not rely
        // on the Guides list having loaded the repository.
        applySnapshot(animated: false)
        Task {
            await repository.reload()
            hasLoaded = true
            applySnapshot(animated: true)
            // Re-kick the retry walk now that guides are actually loaded: on a
            // cold start viewWillAppear fires before this reload lands, so its
            // walk can see zero guides and exit without retrying anything.
            kickResolutionRetries()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
        // Retry still-unresolved place IDs on each appearance (a prior pass
        // may have hit a network failure, or the app may have quit
        // mid-resolution). No-ops quickly when everything is resolved.
        kickResolutionRetries()
    }

    // MARK: - Programmatic selection

    /// Highlight `placeID` without opening it. Used by a Catalyst sidebar
    /// favorite child so navigation matches selecting the row normally.
    func select(placeID: UUID) {
        pendingSelection.request(placeID)
        applyPendingSelection()
    }

    private func applyPendingSelection() {
        guard isViewLoaded else { return }
        pendingSelection.applyIfPossible(in: tableView) { [self] placeID in
            dataSource.indexPath(for: placeID)
        }
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
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

    /// Installs the inline search bar — the same shape as the per-guide list
    /// and the People / Events lists. See
    /// `GuidePlacesListViewController.configureSearch` for why nothing is
    /// republished to the repository.
    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search places"
        searchController.installKeyboardDismissal(for: tableView)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        searchQuery = searchController.searchBar.text ?? ""
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Places\nShare an Apple Maps guide link to add one."
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
        dataSource = PlacesDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, placeID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.place.rawValue, for: indexPath)
            guard let self, let place = self.placesByID[placeID] else { return cell }
            // In "By Guide" the section header already names the guide; the
            // flat orders interleave guides, so each row carries the caption.
            let guideName = self.repository.allPlacesSortOrder.isFlat
                ? self.guideNamesByID[place.guideID]
                : nil
            (cell as? PlaceCell)?.configure(
                with: place,
                status: self.status(for: place),
                linkCount: self.repository.linkCount(for: place),
                guideName: guideName
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func configureNavigationButtons() {
        sortButton = makeAllPlacesSortBarButtonItem(repository: repository)
        filterButton = makeLinkFilterBarButtonItem(
            current: repository.placeFilter,
            allTitle: "All Places"
        ) { [weak repository] filter in
            repository?.placeFilter = filter
        }
        // Right bar items render right-to-left (index 0 is rightmost): the
        // sort glyph trailing with the filter glyph on the left, so
        // left-to-right the user reads filter, sort — the same relative order
        // as every other list (which put their add/refresh button after sort).
        navigationItem.rightBarButtonItems = [sortButton, filterButton]
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
                self.applySnapshot(animated: true)
                // Rebuild the menus so the checkmarks track the state that
                // produced this reload (menus are immutable snapshots).
                self.sortButton.menu = self.makeAllPlacesSortMenu(repository: self.repository)
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
    }

    /// Reconfigure the still-unresolved rows so their status (looking-up /
    /// waiting) tracks the resolver's current place. Cheap: touches only the
    /// pending rows, and no-ops when everything is resolved.
    private func refreshResolutionStatus() {
        var snapshot = dataSource.snapshot()
        let unresolved = snapshot.itemIdentifiers.filter { placesByID[$0]?.needsResolution == true }
        guard !unresolved.isEmpty else { return }
        snapshot.reconfigureItems(unresolved)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func status(for place: MapsPlace) -> PlaceRowStatus {
        if !place.needsResolution { return .resolved }
        if GuidePlaceResolver.resolvingPlaceID == place.id { return .resolving }
        if GuidePlaceResolver.isResolving(guide: place.guideID) { return .waiting }
        return .idle
    }

    /// The repository's sections — already Linked-filtered and ordered by
    /// `allPlacesSortOrder` — narrowed to the live search query, with sections
    /// the query empties dropped so no bare header survives its rows.
    ///
    /// Works on either snapshot shape without caring which: `.byGuide` hands
    /// over one section per guide and the flat orders one big section, and
    /// filtering rows inside a section disturbs neither the section order nor
    /// the row order within it.
    ///
    /// The guide name is passed alongside each place, so typing a guide's name
    /// keeps that guide's places — which is what the rows themselves promise on
    /// this tab: the flat sorts caption every row with its guide, and `.byGuide`
    /// heads every section with it. Requires `guideNamesByID` to be current,
    /// hence the rebuild before the call.
    private func searchedSections() -> [UnifiedPlaceSection] {
        let sections = repository.unifiedPlaceSections()
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let kept = section.places.filter {
                $0.matchesPlaceSearch(query, guideName: guideNamesByID[$0.guideID])
            }
            guard !kept.isEmpty else { return nil }
            return UnifiedPlaceSection(guideID: section.guideID, title: section.title, places: kept)
        }
    }

    private func applySnapshot(animated: Bool) {
        // Names first: the search matcher reads them (see `searchedSections`),
        // as does the flat sorts' per-row caption and the remove confirmation.
        var names: [UUID: String] = [:]
        for guide in repository.guides {
            names[guide.id] = guide.name
        }
        guideNamesByID = names

        let sections = searchedSections()

        var byID: [UUID: MapsPlace] = [:]
        for section in sections {
            for place in section.places {
                byID[place.id] = place
            }
        }
        placesByID = byID

        var snapshot = NSDiffableDataSourceSnapshot<PlacesSection, UUID>()
        for section in sections {
            let sectionID = PlacesSection(guideID: section.guideID, title: section.title)
            snapshot.appendSections([sectionID])
            snapshot.appendItems(section.places.map(\.id), toSection: sectionID)
        }
        // Resolution mutates a row's content without changing its item id —
        // reconfigure survivors so names/addresses repaint as they land.
        let surviving = snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil }
        if !surviving.isEmpty {
            snapshot.reconfigureItems(surviving)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        applyPendingSelection()

        // Name the query when one is in force: the stock copy invites the user
        // to share a guide link, which is the wrong advice for someone whose
        // places are simply filtered out by what they typed.
        let query = trimmedSearchQuery
        if byID.isEmpty && !query.isEmpty {
            emptyLabel.text = "No places match “\(query)”."
        } else if repository.placeFilter == .linked {
            emptyLabel.text = "No Linked Places"
        } else {
            emptyLabel.text = "No Places\nShare an Apple Maps guide link to add one."
        }
        emptyLabel.isHidden = !byID.isEmpty || !hasLoaded || repository.isLoading
    }

    // MARK: - Resolution retry walk

    /// Retry unresolved place IDs across EVERY guide, one guide at a time.
    /// Awaiting each pass keeps MapKit traffic at the resolver's designed
    /// serial pace — kicking all guides concurrently would multiply the
    /// request rate — and the resolver's per-guide in-flight guard coalesces
    /// with any pass a guide's own places screen already started.
    private func kickResolutionRetries() {
        guard !isResolutionWalkActive else { return }
        isResolutionWalkActive = true
        Task { [weak self, repository, service] in
            for guide in repository.guides {
                let hasPending = repository.placesByGuide[guide.id]?
                    .contains(where: \.needsResolution) ?? false
                guard hasPending else { continue }
                await GuidePlaceResolver.resolvePlaces(
                    inGuide: guide.id, service: service, repository: repository
                )
            }
            self?.isResolutionWalkActive = false
        }
    }
}

// MARK: - UITableViewDelegate

extension PlacesListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // No immediate deselect: on an expanded split view the highlighted row
        // is the pointer to the open detail pane (the People/Events pattern);
        // the viewWillAppear helper clears it for the collapsed/push cases.
        guard let placeID = dataSource.itemIdentifier(for: indexPath),
              let place = placesByID[placeID] else { return }
        pendingSelection.cancel()
        didSelectPlace?(place)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingSelection.cancel()
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
        // Same removal semantics as the per-guide list — a row here IS one
        // guide's membership record — but name the guide, since this list
        // spans all of them.
        let guideName = guideNamesByID[place.guideID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let alert = UIAlertController(
            title: guideName.isEmpty
                ? "Remove this place from its guide?"
                : "Remove this place from “\(guideName)”?",
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
        }
        Task { await repository.reload() }
    }
}

extension PlacesListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

// MARK: - UISearchResultsUpdating

extension PlacesListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard searchQuery != text else { return }
        searchQuery = text
        // Nothing observes `searchQuery`, so re-snapshot here. Unanimated: the
        // list re-filters on every keystroke, and a fade per character reads as
        // flicker (the People and Events lists do the same).
        applySnapshot(animated: false)
    }
}

// MARK: - Search matching

extension MapsPlace {
    /// Case-, diacritic-, and width-insensitive substring match over the text a
    /// place row actually shows: the place's name, its address, and — where
    /// rows span guides — the owning guide's caption.
    ///
    /// Shared by BOTH place surfaces, the way `PlaceCell` is:
    /// `GuidePlacesListViewController` passes no `guideName` (that screen IS
    /// one guide, so the arm would match every row or none), the unified tab
    /// always does. It lives here rather than in the package because
    /// `MapsPlace` search has no package caller; the package's
    /// `Contact.matches(searchQuery:)` is the model for the shape.
    ///
    /// `localizedStandardContains` is what makes "cafe" find "Café" and "SoHo"
    /// find "soho" — a wider net than the People and Events lists cast with
    /// `lowercased().contains`, and the one Apple's own search fields use.
    ///
    /// Unresolved rows match on whatever they already carry: an address entry
    /// has its address from import, while a place-ID entry has neither name nor
    /// address until the resolver fills them in, so it stays unmatchable until
    /// then. It reappears on the reload that resolution posts.
    ///
    /// `query` is expected pre-trimmed; a blank one matches everything, so a
    /// bar holding only spaces filters nothing.
    func matchesPlaceSearch(_ query: String, guideName: String? = nil) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if let address, address.localizedStandardContains(query) { return true }
        if let guideName, guideName.localizedStandardContains(query) { return true }
        return false
    }
}

// MARK: - Data source

/// Diffable section identity for the unified Places list. Identity includes
/// the guide UUID — two guides may share a display name ("Import as New"
/// deliberately keeps both), so the title alone can't be the identifier the
/// way the person lists use their header strings. A guide rename changes the
/// pair, recreating the section so its header repaints.
private struct PlacesSection: Hashable {
    /// nil for the flat single section and the orphan bucket (which never
    /// coexist — see `GuidesRepository.unifiedPlaceSections()`).
    let guideID: UUID?
    let title: String?
}

/// Subclasses the diffable data source to expose the section-title hook —
/// same rationale as the person lists' `SectionedDataSource`.
private final class PlacesDataSource: UITableViewDiffableDataSource<PlacesSection, UUID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        // Bounds-checked so `numberOfSections` briefly disagreeing with the
        // snapshot during an animated apply can't crash the title call.
        let ids = snapshot().sectionIdentifiers
        return ids.indices.contains(section) ? ids[section].title : nil
    }
}
