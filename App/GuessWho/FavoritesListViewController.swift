import UIKit
import Contacts
import EventKit
import GuessWhoSync

/// UIKit Favorites list for the Catalyst 3-column shell. Single-section
/// diffable data source keyed on `Favorite.stableID`. Mirrors the
/// SwiftUI `FavoritesListView`: swipe-to-unfavorite, drag-to-reorder,
/// and an async contact-uuid map rebuilt on `.CNContactStoreDidChange`
/// and scene activation.
final class FavoritesListViewController: UIViewController {
    /// Selection callbacks — SceneDelegate routes each kind to the
    /// matching detail view (contact → ContactDetailView, event →
    /// EventDetailView).
    var didSelectContact: (Contact) -> Void = { _ in }
    var didSelectEvent: (Event) -> Void = { _ in }

    private let store: FavoritesListStore
    private let service: SyncService

    private enum CellID: String {
        case favorite
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, String>!

    private var favoritesByStableID: [String: Favorite] = [:]
    private var uuidToContact: [String: Contact] = [:]

    private let emptyLabel = UILabel()

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var sceneActiveObserver: NSObjectProtocol?
    private nonisolated(unsafe) var contactsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var eventsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var favoritesChangedObserver: NSObjectProtocol?

    init(store: FavoritesListStore, service: SyncService) {
        self.store = store
        self.service = service
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureEmptyState()
        configureDataSource()
        observeNotifications()

        // Initial paint may show "Unavailable" rows briefly until the
        // contact map populates — the async refresh below replaces them.
        store.reload()
        applySnapshot(animated: false)
        Task { @MainActor in
            await refreshContactMap()
            applySnapshot(animated: false)
        }
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(FavoriteCell.self, forCellReuseIdentifier: CellID.favorite.rawValue)
        view.addSubview(tableView)
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
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, String>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, stableID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.favorite.rawValue, for: indexPath)
            guard let self, let favorite = self.favoritesByStableID[stableID] else { return cell }
            (cell as? FavoriteCell)?.configure(
                with: favorite,
                contact: self.uuidToContact[favorite.id],
                event: favorite.kind == .event ? self.service.event(uuid: favorite.id) : nil
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
                Task { @MainActor in
                    await self.refreshContactMap()
                    self.applySnapshot(animated: true)
                }
            }
        }

        contactsChangedObserver = center.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshContactMap()
                    self.applySnapshot(animated: true)
                }
            }
        }

        eventsChangedObserver = center.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.reload()
                self?.applySnapshot(animated: true)
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
    }

    private func refreshContactMap() async {
        var map: [String: Contact] = [:]
        for contact in await service.fetchAll() {
            if let uuid = service.guessWhoUUID(in: contact) {
                map[uuid] = contact
            }
        }
        uuidToContact = map
    }

    private func applySnapshot(animated: Bool) {
        let items = store.items

        var byStableID: [String: Favorite] = [:]
        for favorite in items {
            byStableID[favorite.stableID] = favorite
        }
        favoritesByStableID = byStableID

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map { $0.stableID }, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animated)

        emptyLabel.isHidden = !items.isEmpty
    }
}

// MARK: - UITableViewDelegate

extension FavoritesListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let stableID = dataSource.itemIdentifier(for: indexPath),
              let favorite = favoritesByStableID[stableID] else { return }
        switch favorite.kind {
        case .contact:
            if let contact = uuidToContact[favorite.id] {
                didSelectContact(contact)
            }
        case .event:
            if let event = service.event(uuid: favorite.id) {
                didSelectEvent(event)
            }
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let stableID = dataSource.itemIdentifier(for: indexPath),
              let favorite = favoritesByStableID[stableID] else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Unfavorite") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            // store.toggle → store.reload → posts .favoritesDidChange,
            // which the observer turns into applySnapshot.
            self.store.toggle(kind: favorite.kind, id: favorite.id)
            completion(true)
        }
        action.image = UIImage(systemName: "star.slash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
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

        for item in coordinator.items {
            guard let source = item.sourceIndexPath else { continue }
            // store.move writes to disk and reloads `items`, so the
            // subsequent applySnapshot picks up the new order.
            store.move(from: IndexSet(integer: source.row), to: destination.row)
            coordinator.drop(item.dragItem, toRowAt: destination)
        }
        applySnapshot(animated: true)
    }
}

// MARK: - Row cell

/// Two-line favorite row. Cell presentation switches by `Favorite.kind`
/// and resolution state:
/// * .contact resolved → person.crop.circle.fill + display name.
/// * .contact unresolved → person.crop.circle.badge.questionmark +
///   "Unavailable" with a "Contact" caption.
/// * .event resolved → calendar + title + start-date caption.
/// * .event unresolved → calendar.badge.exclamationmark + "Unavailable"
///   with an "Event" caption.
private final class FavoriteCell: UITableViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — FavoriteCell is code-only")
    }

    private func configureSubviews() {
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
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

        let textStack = UIStackView(arrangedSubviews: [titleLabel, captionLabel])
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

    func configure(with favorite: Favorite, contact: Contact?, event: Event?) {
        switch favorite.kind {
        case .contact:
            if let contact {
                iconView.image = UIImage(systemName: "person.crop.circle.fill")
                titleLabel.text = contact.displayName
                captionLabel.text = nil
                captionLabel.isHidden = true
            } else {
                iconView.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Contact"
                captionLabel.isHidden = false
            }
        case .event:
            if let event {
                iconView.image = UIImage(systemName: "calendar")
                titleLabel.text = event.title.isEmpty ? "(Untitled event)" : event.title
                captionLabel.text = event.startDate.formatted(date: .abbreviated, time: .omitted)
                captionLabel.isHidden = false
            } else {
                iconView.image = UIImage(systemName: "calendar.badge.exclamationmark")
                titleLabel.text = "Unavailable"
                captionLabel.text = "Event"
                captionLabel.isHidden = false
            }
        }
    }
}
