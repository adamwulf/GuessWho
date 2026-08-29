import UIKit
import GuessWhoSync

/// UIKit Organizations list for the Catalyst 3-column shell. Mirrors
/// `ContactsListViewController` but reads `organizationsSections` /
/// `organizationsSearch` and renders a single-line row (organizations
/// have no subtitle).
final class OrganizationsListViewController: UIViewController {
    var didSelectContact: (Contact) -> Void = { _ in }
    var didSelectContacts: ([Contact]) -> Void = { _ in }

    /// Tapping a phantom-organization row (a company named on people's cards
    /// with no record of its own). The SceneDelegate presents a read-only
    /// `PhantomOrganizationDetailView`. See `PhantomOrganization`.
    var didSelectPhantomOrganization: (PhantomOrganization) -> Void = { _ in }

    /// Nav-bar "+" callback. The SceneDelegate owns what "add" means (create a
    /// blank organization record and show it in edit mode) — see
    /// `ContactsListViewController.didRequestAddContact` for the same pattern.
    var didRequestAddOrganization: () -> Void = {}

    private let repository: ContactsRepository
    private let photoLoader: ContactPhotoLoader
    private let favoritesStore: FavoritesListStore

    private enum CellID: String {
        case organization
    }

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: SectionedDataSource!

    private var sectionLetters: [String] = []

    /// See `ContactsListViewController.renderedContacts`. `ContactID` is
    /// identity-only, so the diffable apply does not repaint a same-identity
    /// row's contents on an in-place edit; we drive `reconfigureItems(_:)`
    /// ourselves by comparing the `Contact` each row last rendered against the
    /// freshly fetched one.
    private var renderedContacts: [ContactID: Contact] = [:]

    /// The phantom organizations shown in the current snapshot, keyed by their
    /// normalized `key`. Rebuilt on every `applySnapshot` so the `.phantom` cell
    /// provider and the row-tap handler resolve a row's content/identity without
    /// recomputing the phantom set per cell.
    private var phantomsByKey: [String: PhantomOrganization] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    /// Observes `.favoritesDidChange` so a star toggled in a detail view
    /// repaints the matching row here. Same `nonisolated(unsafe)` rationale as
    /// `reloadObserver`.
    private nonisolated(unsafe) var favoritesObserver: NSObjectProtocol?

    private var prefetchTasks: [ContactID: Task<Void, Never>] = [:]

    /// Selection ORDER only — see `ContactsListViewController.selectionRecency`.
    private let selectionRecency = ContactMultiSelectionSupport.RecencyTracker()

    /// See `ContactsListViewController.pendingSelection`.
    private let pendingSelection = PendingRowSelection<ContactID>()

    init(
        repository: ContactsRepository,
        photoLoader: ContactPhotoLoader,
        favoritesStore: FavoritesListStore
    ) {
        self.repository = repository
        self.photoLoader = photoLoader
        self.favoritesStore = favoritesStore
        super.init(nibName: nil, bundle: nil)
        title = "Organizations"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — OrganizationsListViewController is code-only")
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
        configureSearch()
        configureNavigationItems()
        configureEmptyState()
        configureDataSource()
        observeRepositoryReloads()

        applySnapshot(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
    }

    // MARK: - Programmatic selection

    /// Highlight `id`'s row and scroll it into view without republishing the
    /// detail — the Catalyst sidebar's favorite children entry point. See
    /// `ContactsListViewController.select(contactID:)` for the full contract,
    /// including why it is safe to call before the first snapshot lands.
    func select(contactID id: ContactID) {
        pendingSelection.request(id)
        applyPendingSelection()
    }

    /// See `ContactsListViewController.applyPendingSelection`.
    private func applyPendingSelection() {
        guard isViewLoaded else { return }
        let selected = pendingSelection.applyIfPossible(in: tableView) { [self] id in
            dataSource.indexPath(for: .record(id))
        }
        selectionRecency.recordSelection(of: selected)
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        ContactMultiSelectionSupport.configure(tableView)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.sectionIndexBackgroundColor = .clear
        tableView.register(OrganizationCell.self, forCellReuseIdentifier: CellID.organization.rawValue)
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

    /// Installs the search bar and republishes its text to the shared
    /// repository. See `ContactsListViewController.configureSearch` for why the
    /// republish is here and not in a teardown hook — identical reasoning,
    /// `organizationsSearch` instead of `peopleSearch`.
    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search organizations"
        searchController.installKeyboardDismissal(for: tableView)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        repository.organizationsSearch = searchController.searchBar.text ?? ""
    }

    /// Install the nav bar's right items: "+" (add organization, rightmost)
    /// and the global sort pull-down. See
    /// `ContactsListViewController.configureNavigationItems` — identical
    /// wiring; the menu is shared via `makeSortBarButtonItem` so all three
    /// person lists present the same orders + checkmark rule. The sort item is
    /// held in `sortBarButtonItem` because `navigationItem.rightBarButtonItem`
    /// now resolves to the "+".
    private func configureNavigationItems() {
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.didRequestAddOrganization() }
        )
        addItem.accessibilityLabel = "Add Organization"
        let sortItem = makeSortBarButtonItem(repository: repository)
        sortBarButtonItem = sortItem
        let filterItem = makeLinkFilterBarButtonItem(
            current: repository.organizationsFilter,
            allTitle: "All Orgs"
        ) { [weak repository] filter in
            repository?.organizationsFilter = filter
        }
        filterBarButtonItem = filterItem
        // Right bar items render right-to-left (index 0 is rightmost): "+" stays
        // rightmost, then the sort glyph beside it, then the filter glyph on the
        // left. Left-to-right the user reads: filter, sort, +.
        navigationItem.rightBarButtonItems = [addItem, sortItem, filterItem]
    }

    private var sortBarButtonItem: UIBarButtonItem?
    private var filterBarButtonItem: UIBarButtonItem?

    private func selectedContacts() -> [Contact] {
        ContactMultiSelectionSupport.selectedContacts(
            in: tableView,
            repository: repository,
            recency: selectionRecency,
            // Only real records are contacts — a `.phantom` row has no ContactID,
            // so it never joins a multi-selection or an "Add to Group" action.
            itemIdentifier: { [weak self] indexPath in self?.recordID(at: indexPath) }
        )
    }

    /// The `ContactID` for the row at `indexPath` when it is a real record, or
    /// nil for a `.phantom` row (or an unresolved index). The single place the VC
    /// narrows an `OrganizationRow` to a contact identity for the ContactID-keyed
    /// multi-select / pending-selection / group machinery.
    private func recordID(at indexPath: IndexPath) -> ContactID? {
        if case .record(let id)? = dataSource.itemIdentifier(for: indexPath) { return id }
        return nil
    }

    /// The row context menu ("Add to Group") — see
    /// `ContactsListViewController.addToGroupMenu`.
    private lazy var addToGroupMenu = AddToGroupMenu(
        repository: repository,
        host: self,
        contactAt: { [weak self] indexPath in
            guard let self, let id = self.recordID(at: indexPath) else { return nil }
            return self.repository.contact(id: id)
        },
        selection: { [weak self] in self?.selectedContacts() ?? [] }
    )

    private func notifySelectionChanged(_ contacts: [Contact]? = nil) {
        let contacts = contacts ?? selectedContacts()
        if contacts.count == 1, let contact = contacts.first {
            didSelectContact(contact)
        } else if contacts.count > 1 {
            didSelectContacts(contacts)
        }
    }

    /// Rebuild the sort button's menu so its checkmark tracks the live global
    /// order. Called from the reload observer (a global sort change posts
    /// `.contactsRepositoryDidReload`).
    private func refreshSortMenu() {
        sortBarButtonItem?.menu = makeSortMenu(repository: repository)
    }

    private func refreshFilterMenu() {
        filterBarButtonItem?.menu = makeLinkFilterMenu(
            current: repository.organizationsFilter,
            allTitle: "All Orgs"
        ) { [weak repository] filter in
            repository?.organizationsFilter = filter
        }
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Organizations"
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
        dataSource = SectionedDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, row in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.organization.rawValue, for: indexPath)
            guard let self, let orgCell = cell as? OrganizationCell else { return cell }
            switch row {
            case .record(let id):
                guard let contact = self.repository.contact(id: id) else { return cell }
                orgCell.configure(
                    with: contact,
                    photoLoader: self.photoLoader,
                    isFavorite: self.favoritesStore.isFavorite(contact.contactID),
                    linkCount: self.repository.linkCount(for: contact)
                )
            case .phantom(let key):
                if let phantom = self.phantomsByKey[key] {
                    orgCell.configurePhantom(phantom)
                }
            }
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Move the sort button's checkmark first (see
                // ContactsListViewController) — the global sort change posts
                // this same notification.
                self?.refreshSortMenu()
                self?.refreshFilterMenu()
                self?.applySnapshot(animated: true)
            }
        }

        // Favorite status isn't part of `Contact`, so the rendered-contact diff
        // can't detect a star toggle — reconfigure the current rows explicitly
        // when the favorites list changes (see ContactsListViewController).
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
        let sections = repository.organizationRowSectionIDs
        sectionLetters = sections.map { $0.0 }
        // Cache the phantom set for this snapshot so the cell provider and the
        // row-tap handler resolve `.phantom` rows without recomputing it per row.
        // This recomputes `phantomOrganizations` a second time (the merged-rows
        // accessor above computes it internally); both are O(cache) and run only
        // per reload — not per cell — so the second pass is deliberately kept for
        // a single-purpose accessor rather than folding both into a tuple return.
        phantomsByKey = Dictionary(
            repository.phantomOrganizations.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Hide the A–Z scrubber for time orders, whose section identifiers are
        // relative-time bucket names rather than index letters (see
        // ContactsListViewController.applySnapshot).
        dataSource.showsSectionIndex = !repository.sortOrder.isTimeOrder

        var snapshot = NSDiffableDataSourceSnapshot<String, OrganizationRow>()
        snapshot.appendSections(sectionLetters)
        // De-dupe across the whole snapshot (see ContactsListViewController):
        // equal identifiers trap in appendItems. For `.record` rows the only
        // source is the transient pre-reconcile duplicate-guessWhoID window,
        // which reconciliation collapses; `.phantom` keys are already distinct.
        // First wins.
        var seen = Set<OrganizationRow>()
        for (letter, rows) in sections {
            let unique = rows.filter { seen.insert($0).inserted }
            snapshot.appendItems(unique, toSection: letter)
        }

        // See ContactsListViewController.applySnapshot — ContactID is
        // identity-only, so apply() keeps a same-identity row in place but does
        // NOT repaint its contents on an in-place edit. Drive reconfigure
        // explicitly for `.record` rows present in BOTH the last render and the
        // new snapshot whose fetched Contact differs (exclude inserts/removes —
        // apply handles those, and reconfiguring an absent item traps). Phantom
        // rows carry no editable content beyond their name, which IS their
        // identity, so they never need an explicit reconfigure.
        let currentRows = Set(snapshot.itemIdentifiers)
        var changed: [OrganizationRow] = []
        for case .record(let id) in currentRows {
            guard let previous = renderedContacts[id] else { continue }
            if previous != repository.contact(id: id) { changed.append(.record(id)) }
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(changed)
        }

        var rendered: [ContactID: Contact] = [:]
        for case .record(let id) in currentRows {
            rendered[id] = repository.contact(id: id)
        }
        renderedContacts = rendered

        dataSource.apply(snapshot, animatingDifferences: animated)

        // A pending sidebar selection waits here for its row to exist.
        applyPendingSelection()

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = sectionLetters.isEmpty
        emptyLabel.isHidden = !isEmpty || repository.isLoading
        if isEmpty && repository.isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        if isEmpty && !repository.organizationsSearch.isEmpty {
            emptyLabel.text = "No organizations match \"\(repository.organizationsSearch)\"."
        } else if repository.organizationsFilter == .linked {
            emptyLabel.text = "No Linked Organizations"
        } else {
            emptyLabel.text = "No Organizations"
        }
    }
}

// MARK: - UITableViewDelegate

extension OrganizationsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = dataSource.itemIdentifier(for: indexPath)
        // Before the editing-mode early return — see
        // `ContactsListViewController.tableView(_:didSelectRowAt:)`. Only a real
        // record participates in multi-select ordering; a `.phantom` records nil.
        selectionRecency.recordSelection(of: recordID(at: indexPath))
        // See `ContactsListViewController.tableView(_:didSelectRowAt:)` — a user
        // pick retires an unfulfilled sidebar request.
        pendingSelection.cancel()

        // A phantom row is a navigation, not a selection: it opens the read-only
        // phantom page and clears its own highlight (on Catalyst it would
        // otherwise stay in the multi-selection). Handled before the iPhone
        // editing early-return so a phantom tap always navigates.
        if case .phantom(let key)? = row {
            tableView.deselectRow(at: indexPath, animated: false)
            if let phantom = phantomsByKey[key] { didSelectPhantomOrganization(phantom) }
            return
        }

        #if !targetEnvironment(macCatalyst)
        guard !tableView.isEditing else { return }
        #endif
        notifySelectionChanged()
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        selectionRecency.recordDeselection(of: recordID(at: indexPath))
        #if targetEnvironment(macCatalyst)
        notifySelectionChanged()
        #endif
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? OrganizationCell)?.cancelPhotoLoad()
    }

    /// See `ContactsListViewController.scrollViewWillBeginDragging(_:)`.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingSelection.cancel()
    }

    /// Right-click / long-press menu. Leaves the selection untouched — see
    /// `ContactsListViewController`.
    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        addToGroupMenu.configuration(forRowAt: indexPath)
    }
}

// MARK: - UITableViewDataSourcePrefetching

extension OrganizationsListViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            // Phantom rows carry no photo — only real records prefetch.
            guard let id = recordID(at: indexPath),
                  prefetchTasks[id] == nil,
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
            guard let id = recordID(at: indexPath) else { continue }
            prefetchTasks[id]?.cancel()
            prefetchTasks[id] = nil
        }
    }
}

extension OrganizationsListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

/// Diffable data source subclass that forwards A–Z section headers
/// and the index scrubber. Same rationale as
/// `ContactsListViewController.SectionedDataSource`.
private final class SectionedDataSource: UITableViewDiffableDataSource<String, OrganizationRow> {
    /// Whether the right-side A–Z scrubber is shown. The VC sets this to
    /// `!repository.sortOrder.isTimeOrder` before each apply — see
    /// `ContactsListViewController.SectionedDataSource.showsSectionIndex`.
    var showsSectionIndex = true

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        tableView.isEditing
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let ids = snapshot().sectionIdentifiers
        return ids.indices.contains(section) ? ids[section] : nil
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        guard showsSectionIndex else { return nil }
        let titles = snapshot().sectionIdentifiers
        return titles.isEmpty ? nil : titles
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        index
    }
}

// MARK: - UISearchResultsUpdating

extension OrganizationsListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard repository.organizationsSearch != text else { return }
        repository.organizationsSearch = text
        applySnapshot(animated: false)
    }
}

// MARK: - Row cell

/// Single-line organization row: leading avatar thumbnail (initials-
/// circle fallback from `ContactAvatarImage`) + bold family name (which
/// is the organization's name in the data model). No subtitle; a trailing
/// star marks favorited organizations.
private final class OrganizationCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let linkCountLabel = UILabel()
    private let starView = UIImageView()
    // Spacing between the name and the link-count label; collapsed to 0 when
    // the label is hidden so a linkless row reclaims the full width up to the
    // star (see ContactsListViewController's ContactCell for the rationale).
    private var textToLinkCountSpacing: NSLayoutConstraint?
    private var representedID: ContactID?
    private var photoTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — OrganizationCell is code-only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPhotoLoad()
        representedID = nil
        iconView.image = nil
        linkCountLabel.text = nil
        linkCountLabel.isHidden = true
        textToLinkCountSpacing?.constant = 0
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
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 14
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1

        // Trailing "N links" caption, shown only when the organization has at
        // least one link (hidden otherwise, so a linkless row looks unchanged).
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

        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(linkCountLabel)
        contentView.addSubview(starView)

        let textToLinkCount = nameLabel.trailingAnchor.constraint(equalTo: linkCountLabel.leadingAnchor, constant: 0)
        textToLinkCountSpacing = textToLinkCount

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            starView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            starView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            linkCountLabel.trailingAnchor.constraint(equalTo: starView.leadingAnchor, constant: -8),
            linkCountLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textToLinkCount,
            nameLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    func configure(with contact: Contact, photoLoader: ContactPhotoLoader, isFavorite: Bool, linkCount: Int) {
        cancelPhotoLoad()
        let id = contact.contactID
        representedID = id
        iconView.contentMode = .scaleAspectFill
        iconView.image = ContactAvatarImage.placeholder(for: contact, diameter: 28)
        if let cached = photoLoader.cachedImage(for: id, kind: .thumbnail) {
            iconView.image = cached
        } else {
            photoTask = Task { [weak self, photoLoader] in
                guard let image = await photoLoader.image(for: id, kind: .thumbnail) else { return }
                await MainActor.run {
                    guard self?.representedID == id else { return }
                    self?.iconView.image = image
                }
            }
        }
        nameLabel.attributedText = contact.nameAttributedString
        // Reset every configure so a recycled cell never shows a stale count.
        // The spacing constraint flips with visibility so a hidden label
        // collapses flush and the name reclaims the full width (see property).
        if linkCount > 0 {
            linkCountLabel.text = linkCount == 1 ? "1 link" : "\(linkCount) links"
            linkCountLabel.isHidden = false
            textToLinkCountSpacing?.constant = -8
        } else {
            linkCountLabel.text = nil
            linkCountLabel.isHidden = true
            textToLinkCountSpacing?.constant = 0
        }
        starView.isHidden = !isFavorite
    }

    /// Configure the cell for a phantom organization — a company named on
    /// people's cards with no record of its own. It renders like a plain
    /// organization row (initials monogram + name), deliberately WITHOUT a photo,
    /// favorite star, or link count: a phantom has no record to carry those, and
    /// hiding the seam means it should read as just another organization.
    func configurePhantom(_ phantom: PhantomOrganization) {
        cancelPhotoLoad()
        // No represented photo id — a phantom never loads or caches a thumbnail.
        representedID = nil
        // Synthesize a name-only organization so the monogram initials + color
        // match how a real organization row draws its placeholder.
        let synthetic = Contact(contactType: .organization, organizationName: phantom.displayName)
        iconView.contentMode = .scaleAspectFill
        iconView.image = ContactAvatarImage.placeholder(for: synthetic, diameter: 28)
        nameLabel.attributedText = synthetic.nameAttributedString
        linkCountLabel.text = nil
        linkCountLabel.isHidden = true
        textToLinkCountSpacing?.constant = 0
        starView.isHidden = true
    }

    func cancelPhotoLoad() {
        photoTask?.cancel()
        photoTask = nil
    }
}
