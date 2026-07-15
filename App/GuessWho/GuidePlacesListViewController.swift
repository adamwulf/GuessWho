import UIKit
import GuessWhoSync

/// The places inside one imported guide, in the guide's shared order. Pushed
/// from the Guides list on both shells (like Groups → members). Rows fill in
/// as the MapKit resolution pass lands details; tapping a place opens it in
/// Apple Maps.
final class GuidePlacesListViewController: UIViewController {
    private let guide: MapsGuide
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

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureEmptyState()
        configureDataSource()
        observeRepositoryReloads()

        applySnapshot(animated: false)

        // Retry any still-unresolved place IDs each time the guide opens (a
        // prior pass may have hit a network failure, or the app may have quit
        // mid-resolution). No-op when everything is already resolved.
        Task { [repository, service, guideID = guide.id] in
            await GuidePlaceResolver.resolvePlaces(inGuide: guideID, service: service)
            await repository.reload()
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
            (cell as? PlaceCell)?.configure(with: place)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
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
                self?.applySnapshot(animated: true)
            }
        }
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

// MARK: - Row cell

/// Place row: leading pin icon, place name (with graceful fallbacks while
/// details are still resolving), and an address caption.
private final class PlaceCell: UITableViewCell {
    private let iconView = UIImageView()
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
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    func configure(with place: MapsPlace) {
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
            // Place-ID entry still waiting on its MapKit lookup.
            nameLabel.text = "Loading place details…"
            addressLabel.isHidden = true
        }
    }
}
