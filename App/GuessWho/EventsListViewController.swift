import UIKit
import SwiftUI
import GuessWhoSync
import GuessWhoLogging

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
    private let favoritesStore: FavoritesListStore

    private enum CellID: String {
        case event
        case pager
    }

    /// Snapshot sections. The two pager sections exist only in chronological
    /// sort while not searching — the same visibility rule as the link
    /// sheet's "Load older events" / "Show more" rows.
    private enum Section: Int {
        case olderPager
        case events
        case laterPager
    }

    /// Sentinel item identifiers for the two paging rows. Fixed UUIDs so the
    /// diffable snapshot keeps a stable identity for them across applies
    /// (their month labels change via reconfigure); a collision with a real
    /// event UUID is impossible in practice.
    private static let loadOlderItemID = UUID(uuidString: "D3AD0B5D-0A6E-4F1B-9C7A-1A2B3C4D5E6F")!
    private static let loadLaterItemID = UUID(uuidString: "F6E5D4C3-B2A1-4F9E-8D7C-6B5A4B3C2D1E")!

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: UITableViewDiffableDataSource<Section, UUID>!

    private var eventsByID: [UUID: Event] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var bannerDismissed: Bool = false
    private var sidecarBannerHost: UIHostingController<SidecarLocationBanner>?
    private var lastHeaderWidth: CGFloat = 0

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    /// Observes `.favoritesDidChange` so a star toggled in a detail view
    /// repaints the matching row here. Same `nonisolated(unsafe)` rationale as
    /// `reloadObserver`.
    private nonisolated(unsafe) var favoritesObserver: NSObjectProtocol?

    /// Observes `UserDefaults.didChangeNotification` so the debug-mode-only
    /// Export Logs button appears/disappears live when the toggle flips while
    /// the app is open (same `nonisolated(unsafe)` rationale as `reloadObserver`).
    private nonisolated(unsafe) var debugModeObserver: NSObjectProtocol?

    /// The "+" add button — always present.
    private var addButton: UIBarButtonItem!
    /// The sort pull-down button — always present. Its menu is rebuilt in the
    /// reload observer so the checkmark tracks the repository's live order.
    private var sortButton: UIBarButtonItem!
    /// The filter pull-down button — always present and independent of sort.
    /// Its menu is rebuilt after repository changes so the selected candidate
    /// set keeps an accurate checkmark.
    private var filterButton: UIBarButtonItem!
    /// Debug-mode-only "Export Logs" button. Built once; included in the navbar
    /// only while debug mode is enabled.
    private var exportLogsButton: UIBarButtonItem!

    init(repository: EventsRepository, service: SyncService, favoritesStore: FavoritesListStore) {
        self.repository = repository
        self.service = service
        self.favoritesStore = favoritesStore
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
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
        if let debugModeObserver {
            NotificationCenter.default.removeObserver(debugModeObserver)
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
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
        // Re-evaluate the debug-mode Export Logs button each appearance (the
        // toggle lives in the system Settings app and may have changed while we
        // were backgrounded; the UserDefaults observer covers in-app flips).
        updateNavigationButtons()
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(EventCell.self, forCellReuseIdentifier: CellID.event.rawValue)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: CellID.pager.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            // Keyboard guide, not safe area: rows stay above the search
            // keyboard instead of hiding under it. With no keyboard the guide
            // rests at the safe-area bottom, so this is the same constraint
            // the rest of the time.
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search events"
        searchController.installKeyboardDismissal(for: tableView)
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
        dataSource = UITableViewDiffableDataSource<Section, UUID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            if itemID == Self.loadOlderItemID || itemID == Self.loadLaterItemID {
                let cell = tableView.dequeueReusableCell(withIdentifier: CellID.pager.rawValue, for: indexPath)
                self?.configurePagerCell(cell, older: itemID == Self.loadOlderItemID)
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.event.rawValue, for: indexPath)
            guard let self, let event = self.eventsByID[itemID] else { return cell }
            (cell as? EventCell)?.configure(
                with: event,
                isFavorite: self.favoritesStore.isFavorite(kind: .event, id: event.id.uuidString),
                linkCount: self.repository.linkCount(for: event)
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    /// Style a paging row like the link sheet's Label rows: tinted text +
    /// chevron pointing the direction the window will grow, naming the month
    /// the tap reveals.
    private func configurePagerCell(_ cell: UITableViewCell, older: Bool) {
        var content = UIListContentConfiguration.cell()
        content.text = older
            ? "Load older events (\(pagerMonthTitle(older: true)))"
            : "Load later events (\(pagerMonthTitle(older: false)))"
        content.textProperties.color = .tintColor
        content.image = UIImage(systemName: older ? "chevron.up" : "chevron.down")
        content.imageProperties.tintColor = .tintColor
        cell.contentConfiguration = content
    }

    /// "May 2026"-style title of the month the next paging tap will reveal —
    /// same template as `EventLinkSheet.previousMonthTitle`.
    private func pagerMonthTitle(older: Bool) -> String {
        let cal = Calendar.current
        let anchor = older ? repository.windowStart : repository.windowEnd
        let revealed = cal.date(byAdding: .month, value: older ? -1 : 1, to: anchor) ?? anchor
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: revealed)
    }

    /// The paging rows show in chronological order only (the other orders
    /// aren't date-anchored, so "older/later" has no meaning there) and hide
    /// while searching, mirroring the link sheet.
    private var showsPagingRows: Bool {
        repository.sortOrder == .chronological
            && repository.filter != .linked
            && repository.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configureAddButton() {
        addButton = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in
                self?.presentLinkSheet()
            }
        )

        sortButton = makeEventSortBarButtonItem(repository: repository)
        filterButton = UIBarButtonItem(
            title: nil,
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            primaryAction: nil,
            menu: makeEventFilterMenu(repository: repository)
        )
        filterButton.accessibilityLabel = "Filter Events"

        // Debug-mode-only Export Logs button. This is a sanctioned debug-only
        // surface (like the contact-row reconcile checkmark): the label stays
        // plain ("Export Logs"). Gated below so it never shows without the
        // debug toggle.
        exportLogsButton = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in
                self?.exportLogs()
            }
        )
        exportLogsButton.title = "Export Logs"
        exportLogsButton.accessibilityLabel = "Export Logs"

        // Use the PLURAL `rightBarButtonItems` so adding Export Logs doesn't
        // clobber the "+" button. Observe `UserDefaults` so the button
        // appears/disappears live when debug mode flips while the app is open;
        // `viewWillAppear` also re-evaluates.
        debugModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateNavigationButtons()
            }
        }
        updateNavigationButtons()
    }

    /// Re-evaluate which right-bar buttons to show. The "+", Filter, and sort
    /// buttons are always present; Export Logs is appended only while debug
    /// mode is enabled.
    private func updateNavigationButtons() {
        let debugEnabled = UserDefaults.standard.bool(forKey: AppSettings.Key.debugModeEnabled)
        // Right bar items render right-to-left: the first array element is the
        // rightmost. Keep "+" rightmost (as before), then the Filter glyph,
        // then the sort glyph. Export Logs remains leftmost when debug mode is
        // enabled.
        navigationItem.rightBarButtonItems = debugEnabled
            ? [addButton, filterButton, sortButton, exportLogsButton]
            : [addButton, filterButton, sortButton]
    }

    /// Build the Events-tab filter menu. The chosen filter changes only the
    /// candidate set; `EventsRepository` then applies its existing sort order,
    /// so the two controls compose instead of replacing one another.
    private func makeEventFilterMenu(repository: EventsRepository) -> UIMenu {
        let actions = EventListFilter.allCases.map { filter in
            UIAction(
                title: filter.title,
                state: filter == repository.filter ? .on : .off
            ) { [weak repository] _ in
                repository?.filter = filter
            }
        }
        return UIMenu(title: "Filter Events", children: actions)
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

    // MARK: - Export Logs (debug mode only)

    /// Zip the shared `Logs/` directory off the main thread, then present a save
    /// dialog (Catalyst) / share sheet (iOS) on the main thread. Debug-mode-only
    /// action; failures surface in a plain-copy alert.
    private func exportLogs() {
        let appGroupID = AppGroup.id
        // Zip creation touches the filesystem (coordination + copy) — keep it
        // off the main thread; present back on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let zipURL = try LogExporter.exportLogs(appGroupID: appGroupID)
                DispatchQueue.main.async {
                    self?.presentExport(zipURL: zipURL)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.presentExportFailure(error)
                }
            }
        }
    }

    private func presentExport(zipURL: URL) {
        #if targetEnvironment(macCatalyst)
        // On Catalyst this surfaces the macOS save/export panel — the cleanest
        // cross-Catalyst path (no AppKit bridging).
        let picker = UIDocumentPickerViewController(forExporting: [zipURL])
        present(picker, animated: true)
        #else
        let activity = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
        // Anchor the popover to the bar button so it doesn't crash on iPad.
        activity.popoverPresentationController?.barButtonItem = exportLogsButton
        present(activity, animated: true)
        #endif
    }

    /// Plain-copy failure alert (debug-only surface, so no internal vocabulary).
    private func presentExportFailure(_ error: Error) {
        let alert = UIAlertController(
            title: "Couldn't export logs",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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
                // Rebuild the sort menu so the checkmark tracks the order
                // that produced this reload (menus are immutable snapshots).
                guard let self else { return }
                self.sortButton.menu = self.makeEventSortMenu(repository: self.repository)
                self.filterButton.menu = self.makeEventFilterMenu(repository: self.repository)
            }
        }

        // Favorite status isn't part of `Event`, and the snapshot's UUID items
        // don't change on a star toggle — reconfigure the current rows
        // explicitly when the favorites list changes (posted by
        // `FavoritesListStore.reload()` after every toggle).
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

    /// Re-run the cell provider for every row in the current snapshot so the
    /// favorite stars repaint. Reconfigure only touches on-screen cells.
    private func reconfigureAllRows() {
        var snapshot = dataSource.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshot(animated: Bool) {
        let events = repository.filtered

        var byID: [UUID: Event] = [:]
        for event in events {
            byID[event.id] = event
        }
        eventsByID = byID

        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        if showsPagingRows {
            snapshot.appendSections([.olderPager, .events, .laterPager])
            snapshot.appendItems([Self.loadOlderItemID], toSection: .olderPager)
            snapshot.appendItems(events.map { $0.id }, toSection: .events)
            snapshot.appendItems([Self.loadLaterItemID], toSection: .laterPager)
            // The pager identifiers are stable but their month labels move
            // with the window — reconfigure the ones surviving from the
            // previous snapshot so a post-paging apply re-runs the provider.
            let surviving = [Self.loadOlderItemID, Self.loadLaterItemID].filter {
                dataSource.snapshot().indexOfItem($0) != nil
            }
            snapshot.reconfigureItems(surviving)
        } else {
            snapshot.appendSections([.events])
            snapshot.appendItems(events.map { $0.id }, toSection: .events)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        updateEmptyState()
    }

    private func updateEmptyState() {
        // Count EVENTS, not snapshot items — the paging rows are always
        // present in chronological mode and must not defeat the empty label.
        let isEmpty = eventsByID.isEmpty
        emptyLabel.isHidden = !isEmpty || repository.isLoading
        if isEmpty && repository.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        if isEmpty && !repository.searchText.isEmpty {
            emptyLabel.text = "No events match \"\(repository.searchText)\"."
        } else {
            switch repository.filter {
            case .showAll:
                emptyLabel.text = "No Events"
            case .linked:
                emptyLabel.text = "No Linked Events"
            case .hasAttendees:
                emptyLabel.text = "No Events with Attendees"
            }
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
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return }
        if itemID == Self.loadOlderItemID || itemID == Self.loadLaterItemID {
            tableView.deselectRow(at: indexPath, animated: true)
            let older = (itemID == Self.loadOlderItemID)
            // The reload posts `.eventsRepositoryDidReload`, which re-applies
            // the snapshot (revealed events + refreshed pager labels).
            Task { [repository] in
                if older {
                    await repository.loadOlderMonth()
                } else {
                    await repository.loadLaterMonth()
                }
            }
            return
        }
        guard let event = eventsByID[itemID] else { return }
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

extension EventsListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
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

/// Event row: leading calendar icon, title label (falling back to
/// "(Untitled event)" when blank), caption start-date subtitle, and — for
/// events sourced from a calendar — a third line with a color swatch and
/// the calendar's name. The calendar line lets the user tell apart the same
/// event duplicated across several calendars (a common pattern when one copy
/// is shared per audience). Manual events omit the third line and stay
/// two-line; the row self-sizes so its height follows the content. A trailing
/// star marks favorited events.
private final class EventCell: UITableViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let dateLabel = UILabel()
    private let linkCountLabel = UILabel()
    private let starView = UIImageView()
    private let calendarSwatch = UIView()
    private let calendarLabel = UILabel()
    private let calendarRow = UIStackView()
    // Spacing between the text stack and the link-count label; collapsed to 0
    // when the label is hidden so a linkless row reclaims the full width up to
    // the star (see ContactsListViewController's ContactCell for rationale).
    private var textToLinkCountSpacing: NSLayoutConstraint?

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

        // Color swatch matching the source calendar's color. A small rounded
        // square, vertically centered against the calendar name's cap height.
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
        calendarRow.addArrangedSubview(calendarSwatch)
        calendarRow.addArrangedSubview(calendarLabel)

        // Trailing "N links" caption, shown only when the event has at least
        // one link (hidden otherwise, so a linkless row looks unchanged).
        linkCountLabel.font = .preferredFont(forTextStyle: .caption1)
        linkCountLabel.textColor = .secondaryLabel
        linkCountLabel.adjustsFontForContentSizeCategory = true
        linkCountLabel.numberOfLines = 1
        linkCountLabel.isHidden = true
        linkCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        linkCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        linkCountLabel.translatesAutoresizingMaskIntoConstraints = false

        // Trailing favorite star. The image stays installed and only
        // `isHidden` toggles, so the star's intrinsic size keeps the layout
        // deterministic and every row reserves the same text width (see
        // ContactsListViewController's ContactCell).
        starView.image = UIImage(systemName: "star.fill")
        starView.contentMode = .scaleAspectFit
        starView.tintColor = .systemYellow
        starView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        starView.isHidden = true
        starView.setContentHuggingPriority(.required, for: .horizontal)
        starView.setContentCompressionResistancePriority(.required, for: .horizontal)
        starView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, dateLabel, calendarRow])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(textStack)
        contentView.addSubview(linkCountLabel)
        contentView.addSubview(starView)

        let textToLinkCount = textStack.trailingAnchor.constraint(equalTo: linkCountLabel.leadingAnchor, constant: 0)
        textToLinkCountSpacing = textToLinkCount

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            calendarSwatch.widthAnchor.constraint(equalToConstant: 10),
            calendarSwatch.heightAnchor.constraint(equalToConstant: 10),
            starView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            starView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            linkCountLabel.trailingAnchor.constraint(equalTo: starView.leadingAnchor, constant: -8),
            linkCountLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textToLinkCount,
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    func configure(with event: Event, isFavorite: Bool, linkCount: Int) {
        iconView.image = UIImage(systemName: "calendar")
        titleLabel.text = event.title.isEmpty ? "(Untitled event)" : event.title
        dateLabel.text = event.startDate.formatted(date: .abbreviated, time: .omitted)
        starView.isHidden = !isFavorite

        // Reset every configure so a recycled cell never shows a stale count.
        // The spacing constraint flips with visibility so a hidden label
        // collapses flush and the text reclaims the full width (see property).
        if linkCount > 0 {
            linkCountLabel.text = linkCount == 1 ? "1 link" : "\(linkCount) links"
            linkCountLabel.isHidden = false
            textToLinkCountSpacing?.constant = -8
        } else {
            linkCountLabel.text = nil
            linkCountLabel.isHidden = true
            textToLinkCountSpacing?.constant = 0
        }

        // Third line appears only for calendar-sourced events that carry a
        // calendar name; manual events stay two-line. Both branches fully
        // reset the row's mutable state so nothing leaks across reused cells.
        if let name = event.calendarName, !name.isEmpty {
            calendarLabel.text = name
            // Swatch shows only when we have a color; otherwise hide it and
            // let the name alone identify the calendar.
            let color = event.calendarColorHex.flatMap(UIColor.init(hexString:))
            calendarSwatch.backgroundColor = color
            calendarSwatch.isHidden = (color == nil)
            calendarRow.isHidden = false
        } else {
            calendarLabel.text = nil
            calendarSwatch.backgroundColor = nil
            calendarRow.isHidden = true
        }
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
