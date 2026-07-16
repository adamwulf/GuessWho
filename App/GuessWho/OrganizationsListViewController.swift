import UIKit
import GuessWhoSync

/// UIKit Organizations list for the Catalyst 3-column shell. Mirrors
/// `ContactsListViewController` but reads `organizationsSections` /
/// `organizationsSearch` and renders a single-line row (organizations
/// have no subtitle).
final class OrganizationsListViewController: UIViewController {
    var didSelectContact: (Contact) -> Void = { _ in }
    var didSelectContacts: ([Contact]) -> Void = { _ in }

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

    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search organizations"
        searchController.installKeyboardDismissal(for: tableView)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
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
        let selectionItem = ContactMultiSelectionSupport.selectionButton { [weak self] in
            self?.toggleSelectionMode()
        }
        selectionBarButtonItem = selectionItem
        navigationItem.rightBarButtonItems = [addItem, sortItem] + [selectionItem].compactMap { $0 }
    }

    private var sortBarButtonItem: UIBarButtonItem?
    private var selectionBarButtonItem: UIBarButtonItem?

    private func toggleSelectionMode() {
        if tableView.isEditing {
            tableView.setEditing(false, animated: true)
            ContactMultiSelectionSupport.updateSelectionButton(selectionBarButtonItem, isEditing: false)
            notifySelectionChanged()
        } else {
            tableView.setEditing(true, animated: true)
            ContactMultiSelectionSupport.updateSelectionButton(selectionBarButtonItem, isEditing: true)
        }
    }

    private func notifySelectionChanged() {
        let contacts = ContactMultiSelectionSupport.selectedContacts(
            in: tableView,
            repository: repository,
            itemIdentifier: { [weak self] in self?.dataSource.itemIdentifier(for: $0) }
        )
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
        ) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.organization.rawValue, for: indexPath)
            guard let self, let contact = self.repository.contact(id: id) else { return cell }
            (cell as? OrganizationCell)?.configure(
                with: contact,
                photoLoader: self.photoLoader,
                isFavorite: self.favoritesStore.isFavorite(contact.contactID)
            )
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
        let sections = repository.organizationsSectionIDs
        sectionLetters = sections.map { $0.0 }
        // Hide the A–Z scrubber for time orders, whose section identifiers are
        // relative-time bucket names rather than index letters (see
        // ContactsListViewController.applySnapshot).
        dataSource.showsSectionIndex = !repository.sortOrder.isTimeOrder

        var snapshot = NSDiffableDataSourceSnapshot<String, ContactID>()
        snapshot.appendSections(sectionLetters)
        // De-dupe by effective identity across the whole snapshot (see
        // ContactsListViewController.applySnapshot): equal ContactIDs trap in
        // appendItems; the transient pre-reconcile duplicate-guessWhoID window
        // is the only source, and reconciliation collapses it. First wins.
        var seen = Set<ContactID>()
        for (letter, contactIDs) in sections {
            let unique = contactIDs.filter { seen.insert($0).inserted }
            snapshot.appendItems(unique, toSection: letter)
        }

        // See ContactsListViewController.applySnapshot — ContactID is
        // identity-only, so apply() keeps a same-identity row in place but does
        // NOT repaint its contents on an in-place edit. Drive reconfigure
        // explicitly: reconfigure rows present in BOTH the last render and the
        // new snapshot whose fetched Contact differs from the one we last
        // rendered (exclude inserts/removes — apply handles those, and
        // reconfiguring an absent item traps).
        let currentIDs = Set(snapshot.itemIdentifiers)
        let changed = currentIDs.filter { id in
            guard let previous = renderedContacts[id] else { return false }
            return previous != repository.contact(id: id)
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(Array(changed))
        }

        var rendered: [ContactID: Contact] = [:]
        for id in currentIDs {
            rendered[id] = repository.contact(id: id)
        }
        renderedContacts = rendered

        dataSource.apply(snapshot, animatingDifferences: animated)

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
        } else {
            emptyLabel.text = "No Organizations"
        }
    }
}

// MARK: - UITableViewDelegate

extension OrganizationsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        #if !targetEnvironment(macCatalyst)
        guard !tableView.isEditing else { return }
        #endif
        notifySelectionChanged()
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        #if targetEnvironment(macCatalyst)
        notifySelectionChanged()
        #endif
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? OrganizationCell)?.cancelPhotoLoad()
    }
}

// MARK: - UITableViewDataSourcePrefetching

extension OrganizationsListViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath),
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
            guard let id = dataSource.itemIdentifier(for: indexPath) else { continue }
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
private final class SectionedDataSource: UITableViewDiffableDataSource<String, ContactID> {
    /// Whether the right-side A–Z scrubber is shown. The VC sets this to
    /// `!repository.sortOrder.isTimeOrder` before each apply — see
    /// `ContactsListViewController.SectionedDataSource.showsSectionIndex`.
    var showsSectionIndex = true

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
    private let starView = UIImageView()
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
        contentView.addSubview(starView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            starView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            starView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: starView.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    func configure(with contact: Contact, photoLoader: ContactPhotoLoader, isFavorite: Bool) {
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
        nameLabel.attributedText = Self.nameAttributedString(for: contact)
        starView.isHidden = !isFavorite
    }

    func cancelPhotoLoad() {
        photoTask?.cancel()
        photoTask = nil
    }

    private static func nameAttributedString(for contact: Contact) -> NSAttributedString {
        let given = contact.givenName.trimmingCharacters(in: .whitespaces)
        let family = contact.familyName.trimmingCharacters(in: .whitespaces)
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let boldDescriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold) ?? bodyFont.fontDescriptor
        let boldFont = UIFont(descriptor: boldDescriptor, size: bodyFont.pointSize)

        let attributed = NSMutableAttributedString()
        if !given.isEmpty, !family.isEmpty {
            attributed.append(NSAttributedString(
                string: given + " ",
                attributes: [.font: bodyFont]
            ))
            attributed.append(NSAttributedString(
                string: family,
                attributes: [.font: boldFont]
            ))
            return attributed
        }
        if !family.isEmpty {
            return NSAttributedString(string: family, attributes: [.font: boldFont])
        }
        if !given.isEmpty {
            return NSAttributedString(string: given, attributes: [.font: bodyFont])
        }
        return NSAttributedString(string: contact.displayName, attributes: [.font: bodyFont])
    }
}
