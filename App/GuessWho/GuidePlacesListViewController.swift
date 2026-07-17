import UIKit
import GuessWhoSync

/// The places inside one imported guide, in the guide's shared order. Pushed
/// from the Guides list on both shells (like Groups → members). Rows fill in
/// as the MapKit resolution pass lands details; tapping a place opens it in
/// Apple Maps.
final class GuidePlacesListViewController: UIViewController {
    private var guide: MapsGuide
    private let repository: GuidesRepository
    private let service: SyncService

    private enum CellID: String {
        case place
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>!

    private var placesByID: [UUID: MapsPlace] = [:]

    /// Invoked when a place row is tapped. The scene delegate wires this to push
    /// a `GuidePlaceDetailView` onto the owning nav (with the shell-appropriate
    /// push handlers). When unset, tapping falls back to opening Apple Maps
    /// directly.
    var didSelectPlace: ((MapsPlace) -> Void)?

    private let emptyLabel = UILabel()

    /// The sort pull-down button. Its menu is rebuilt in the reload observer so
    /// the checkmark tracks the repository's live place order.
    private var sortButton: UIBarButtonItem!
    private var refreshButton: UIBarButtonItem!
    private var isRefreshing = false

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?
    private nonisolated(unsafe) var resolutionObserver: NSObjectProtocol?

    init(guide: MapsGuide, repository: GuidesRepository, service: SyncService) {
        self.guide = guide
        self.repository = repository
        self.service = service
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureEmptyState()
        configureDataSource()
        configureNavigationButtons()
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
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Places"
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
            (cell as? PlaceCell)?.configure(with: place, status: self.status(for: place))
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
        // The first item is the trailing (top-right) item; keep the sort menu
        // beside it so both existing and new actions remain available.
        navigationItem.rightBarButtonItems = [refreshButton, sortButton]
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
                // Rebuild the sort menu so the checkmark tracks the order that
                // produced this reload (menus are immutable snapshots).
                self.sortButton.menu = self.makePlaceSortMenu(repository: self.repository)
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

    /// Display state for a place row, driven by the resolver.
    enum PlaceRowStatus {
        /// Fully populated (an address entry, or a resolved place-ID entry).
        case resolved
        /// The resolver is looking this place up right now.
        case resolving
        /// Unresolved, and a pass is working through the queue toward it.
        case waiting
        /// Unresolved with no pass currently running.
        case idle
    }

    private func status(for place: MapsPlace) -> PlaceRowStatus {
        if !place.needsResolution { return .resolved }
        if GuidePlaceResolver.resolvingPlaceID == place.id { return .resolving }
        if GuidePlaceResolver.isResolving(guide: guide.id) { return .waiting }
        return .idle
    }

    private func applySnapshot(animated: Bool) {
        let places = repository.places(inGuide: guide.id)

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
        tableView.deselectRow(at: indexPath, animated: true)
        guard let placeID = dataSource.itemIdentifier(for: indexPath),
              let place = placesByID[placeID] else { return }
        if let didSelectPlace {
            didSelectPlace(place)
        } else {
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
    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        // Reordering only makes sense in the guide's own entry order — the
        // Name / Last Viewed orders are derived, so hand-placing a row there
        // has nothing to persist. Returning [] disables the drag lift.
        guard repository.placeSortOrder == .guideOrder,
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
        guard repository.placeSortOrder == .guideOrder else {
            return UITableViewDropProposal(operation: .cancel)
        }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard repository.placeSortOrder == .guideOrder else { return }
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
        applySnapshot(animated: true)
    }
}

// MARK: - Row cell

/// Place row: leading pin icon (or a spinner while this place is being looked
/// up), place name (with graceful fallbacks while details are still
/// resolving), and an address caption.
private final class PlaceCell: UITableViewCell {
    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let nameLabel = UILabel()
    private let addressLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — PlaceCell is code-only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        addressLabel.text = nil
        addressLabel.isHidden = false
        showSpinner(false)
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
        iconView.image = UIImage(systemName: "mappin.and.ellipse")
        iconView.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1

        addressLabel.font = .preferredFont(forTextStyle: .caption1)
        addressLabel.textColor = .secondaryLabel
        addressLabel.adjustsFontForContentSizeCategory = true
        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        addressLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [nameLabel, addressLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(spinner)
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            // The spinner shares the icon's slot so text stays aligned whether a
            // row shows the pin or is being looked up.
            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func showSpinner(_ show: Bool) {
        iconView.isHidden = show
        if show {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    func configure(with place: MapsPlace, status: GuidePlacesListViewController.PlaceRowStatus) {
        switch status {
        case .resolved:
            showSpinner(false)
            nameLabel.textColor = .label
            let trimmedName = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                nameLabel.text = trimmedName
                addressLabel.text = place.address
                addressLabel.isHidden = (place.address?.isEmpty ?? true)
            } else if let address = place.address, !address.isEmpty {
                // Address entry (or a resolution that carried no name): the
                // address IS the title.
                nameLabel.text = address
                addressLabel.isHidden = true
            } else {
                // Resolved but empty — rare (MapKit returned no name/address).
                nameLabel.text = "(No details)"
                nameLabel.textColor = .secondaryLabel
                addressLabel.isHidden = true
            }
        case .resolving:
            showSpinner(true)
            placeholder("Looking up location…")
        case .waiting:
            showSpinner(false)
            placeholder("Waiting to load…")
        case .idle:
            showSpinner(false)
            placeholder("Loading place details…")
        }
    }

    /// Secondary-tinted single-line placeholder shown while a place-ID entry is
    /// still unresolved.
    private func placeholder(_ text: String) {
        nameLabel.text = text
        nameLabel.textColor = .secondaryLabel
        addressLabel.text = nil
        addressLabel.isHidden = true
    }
}
