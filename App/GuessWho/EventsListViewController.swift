import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit Events list for the Catalyst 3-column shell. Single-section
/// diffable data source keyed on `Event.id` (UUID). Mirrors the
/// SwiftUI `EventsListView` behaviour: search bound to
/// `EventsRepository.searchText`, swipe-to-delete with a confirmation
/// alert, and a "+" toolbar that hosts the existing SwiftUI
/// `EventLinkSheet` via `UIHostingController`.
final class EventsListViewController: UIViewController {
    /// Selection callback so the SceneDelegate can mount a fresh
    /// `UIHostingController<EventDetailView>` in the secondary column.
    var didSelectEvent: (Event) -> Void = { _ in }

    private let repository: EventsRepository
    private let service: SyncService

    private enum CellID: String {
        case event
    }

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>!

    private var eventsByID: [UUID: Event] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var bannerDismissed: Bool = false
    private var sidecarBannerHost: UIHostingController<SidecarLocationBanner>?
    private var lastHeaderWidth: CGFloat = 0

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    init(repository: EventsRepository, service: SyncService) {
        self.repository = repository
        self.service = service
        super.init(nibName: nil, bundle: nil)
        title = "Events"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — EventsListViewController is code-only")
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
        configureSearch()
        configureEmptyState()
        configureDataSource()
        configureAddButton()
        observeRepositoryReloads()
        updateHeaderBanners()

        applySnapshot(animated: false)

        Task { await repository.reload() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnCompactNavigationReturn(in: tableView, animated: animated)
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(EventCell.self, forCellReuseIdentifier: CellID.event.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search events"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Events"
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
        dataSource = UITableViewDiffableDataSource<Int, UUID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, eventID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.event.rawValue, for: indexPath)
            guard let self, let event = self.eventsByID[eventID] else { return cell }
            (cell as? EventCell)?.configure(with: event)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func configureAddButton() {
        let addButton = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in
                self?.presentLinkSheet()
            }
        )
        navigationItem.rightBarButtonItem = addButton
    }

    private func presentLinkSheet() {
        let sheet = EventLinkSheet(mode: .create(onCreated: { [weak self] uuid in
            guard let self else { return }
            // Read from `repository.events` instead of `eventsByID`: the
            // notification observer enqueues on OperationQueue.main and
            // runs AFTER this continuation, so the VC's cache is still
            // stale. The repository's array is updated synchronously
            // inside reload() before the post.
            Task { @MainActor in
                await self.repository.reload()
                guard let uuid = UUID(uuidString: uuid),
                      let event = self.repository.events.first(where: { $0.id == uuid }) else { return }
                self.didSelectEvent(event)
            }
        }))
        .environment(service)
        let host = UIHostingController(rootView: sheet)
        present(host, animated: true)
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        // External Calendar.app edits and external contact changes already
        // drive a `repository.reload()` from `EventsRepository`'s own
        // observers (it owns `.EKEventStoreChanged` and subscribes to the
        // package's `.guessWhoContactsDidChange`) — that reload fires
        // `.eventsRepositoryDidReload`, which lands here. So we only need to
        // listen to the post-reload notification and re-apply the diffable
        // snapshot; duplicating the store-changed observers locally would just
        // double-reload the repo.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .eventsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySnapshot(animated: true)
                self?.updateHeaderBanners()
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        let events = repository.filtered

        var byID: [UUID: Event] = [:]
        for event in events {
            byID[event.id] = event
        }
        eventsByID = byID

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(events.map { $0.id }, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: animated)

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = dataSource.snapshot().numberOfItems == 0
        emptyLabel.isHidden = !isEmpty || repository.isLoading
        if isEmpty && repository.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        if isEmpty && !repository.searchText.isEmpty {
            emptyLabel.text = "No events match \"\(repository.searchText)\"."
        } else {
            emptyLabel.text = "No Events"
        }
    }

    // MARK: - Header banners

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Catalyst column resize changes tableView.bounds.width — the
        // banner was sized once at install time and won't reflow on
        // its own. Recompute the fitting size; only re-assign
        // tableHeaderView if the height actually changed (the assign
        // itself is what nudges UITableView to relayout — just setting
        // the frame is not enough).
        sizeHeaderBannerIfNeeded()
    }

    private func sizeHeaderBannerIfNeeded() {
        guard let header = tableView.tableHeaderView else { return }
        let targetWidth = tableView.bounds.width
        guard targetWidth > 0, abs(targetWidth - lastHeaderWidth) > 0.5 else { return }
        lastHeaderWidth = targetWidth
        let fitting = header.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        header.frame = CGRect(x: 0, y: 0, width: targetWidth, height: fitting.height)
        // Re-assignment forces the tableView to pick up the new
        // header size; mutating header.frame in place doesn't.
        tableView.tableHeaderView = header
    }

    private func updateHeaderBanners() {
        // Tear down the prior hosted SwiftUI banner (if any) so child-VC
        // lifecycle stays correct; the permission banner is plain UIKit
        // and just gets dropped with the stack.
        if let host = sidecarBannerHost {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            sidecarBannerHost = nil
        }

        let showSidecar = service.sidecarLocation.needsBanner
        let showPermission: Bool = {
            switch service.eventsAuthorization {
            case .notDetermined, .denied, .restricted: return !bannerDismissed
            case .authorized: return false
            }
        }()
        guard showSidecar || showPermission else {
            tableView.tableHeaderView = nil
            return
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if showSidecar {
            let host = UIHostingController(rootView: SidecarLocationBanner(location: service.sidecarLocation))
            host.view.backgroundColor = .clear
            addChild(host)
            stack.addArrangedSubview(host.view)
            host.didMove(toParent: self)
            sidecarBannerHost = host
        }

        if showPermission {
            let permission = PermissionBannerView { [weak self] in
                self?.bannerDismissed = true
                self?.updateHeaderBanners()
            }
            stack.addArrangedSubview(permission)
        }

        let container = UIView()
        // tableHeaderView is positioned by frame, not autolayout —
        // keep translatesAutoresizingMaskIntoConstraints true on the
        // container and use autoresizingMask to track column resizes.
        // Subviews still use autolayout against the container.
        container.autoresizingMask = [.flexibleWidth]
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        // Install with a provisional frame; sizeHeaderBannerIfNeeded
        // (called from viewDidLayoutSubviews) does the actual reflow
        // once tableView.bounds.width reflects the final column width.
        container.frame = CGRect(x: 0, y: 0, width: max(tableView.bounds.width, 1), height: 1)
        // Reset the cached width so the next sizing pass re-measures
        // against the (possibly newly-known) tableView width.
        lastHeaderWidth = 0
        tableView.tableHeaderView = container
        sizeHeaderBannerIfNeeded()
    }
}

// MARK: - UITableViewDelegate

extension EventsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let eventID = dataSource.itemIdentifier(for: indexPath),
              let event = eventsByID[eventID] else { return }
        didSelectEvent(event)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let eventID = dataSource.itemIdentifier(for: indexPath),
              let event = eventsByID[eventID] else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            self?.confirmDelete(event: event, completion: completion)
        }
        action.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    private func confirmDelete(event: Event, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Remove from GuessWho? (Won't delete from Calendar.)",
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.performDelete(event: event)
            completion(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }

    private func performDelete(event: Event) {
        do {
            try service.deleteEvent(uuid: event.id.uuidString)
        } catch {
            service.recordError("delete event failed: \(error.localizedDescription)")
        }
        Task { await repository.reload() }
    }
}

// MARK: - UISearchResultsUpdating

extension EventsListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard repository.searchText != text else { return }
        repository.searchText = text
        applySnapshot(animated: false)
    }
}

// MARK: - Row cell

/// Two-line event row: leading calendar icon, title label (falling
/// back to "(Untitled event)" when blank), caption start-date
/// subtitle.
private final class EventCell: UITableViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let dateLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — EventCell is code-only")
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
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1

        dateLabel.font = .preferredFont(forTextStyle: .caption1)
        dateLabel.textColor = .secondaryLabel
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, dateLabel])
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

    func configure(with event: Event) {
        iconView.image = UIImage(systemName: "calendar")
        titleLabel.text = event.title.isEmpty ? "(Untitled event)" : event.title
        dateLabel.text = event.startDate.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Permission banner view

private final class PermissionBannerView: UIView {
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — PermissionBannerView is code-only")
    }

    private func configureSubviews() {
        backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        layer.cornerRadius = 10

        let icon = UIImageView(image: UIImage(systemName: "calendar.badge.exclamationmark"))
        icon.tintColor = .systemOrange
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = "Calendar access disabled"
        let titleFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let boldDescriptor = titleFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? titleFont.fontDescriptor
        title.font = UIFont(descriptor: boldDescriptor, size: titleFont.pointSize)
        title.numberOfLines = 0

        let caption = UILabel()
        caption.text = "Enable Calendar access in Settings to see and link calendar events."
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [title, caption])
        textStack.axis = .vertical
        textStack.spacing = 4

        let dismissButton = UIButton(type: .system)
        dismissButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        dismissButton.tintColor = .secondaryLabel
        dismissButton.accessibilityLabel = "Dismiss"
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.addAction(UIAction { [weak self] _ in self?.onDismiss() }, for: .touchUpInside)

        let hStack = UIStackView(arrangedSubviews: [icon, textStack, dismissButton])
        hStack.axis = .horizontal
        hStack.alignment = .top
        hStack.spacing = 12
        hStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hStack)

        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            hStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
}
