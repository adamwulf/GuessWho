import UIKit
import GuessWhoSync

/// UIKit People list. Used by both the Catalyst 3-column shell (as the
/// supplementary column for `.people`) and the iPhone tab shell (rooted in the
/// People nav stack). Backed by a `UITableViewDiffableDataSource` keyed on
/// (section-letter, ContactID) so a repository reload only re-applies a snapshot
/// rather than invalidating the whole view. A–Z sectioning, search bound to
/// `ContactsRepository.peopleSearch`, per-row layout of a leading avatar plus a
/// name and caption subtitle.
final class ContactsListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can mount a fresh
    /// `UIHostingController<ContactDetailView>` in the secondary column without
    /// this VC holding a strong reference to the split.
    var didSelectContact: (Contact) -> Void = { _ in }

    /// Multi-selection callback. The scene renders these contacts with the
    /// same detail views arranged as a Mail-style stack.
    var didSelectContacts: ([Contact]) -> Void = { _ in }

    /// Nav-bar "+" callback. The SceneDelegate owns what "add" means (create a
    /// blank record, then open its detail already editing) — this VC only
    /// vends the tap, same pattern as `didSelectContact`.
    var didRequestAddContact: () -> Void = {}

    private let repository: ContactsRepository
    private let photoLoader: ContactPhotoLoader
    private let favoritesStore: FavoritesListStore

    private enum CellID: String {
        case contact
    }

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: SectionedDataSource!

    private var sectionLetters: [String] = []

    /// The `Contact` each `ContactID` row last rendered. `ContactID` is
    /// identity-only (`==`/`hash` key on effective identity alone), so the
    /// diffable apply keeps a same-identity row in place but does NOT repaint its
    /// contents on an in-place edit — Apple's `apply(_:)` reconfigures by
    /// `Hashable` identity only, never by re-checking `==`. `applySnapshot`
    /// compares this map's `Contact` against the freshly fetched one and calls
    /// `snapshot.reconfigureItems(_:)` for the differences. Keyed by `ContactID`
    /// so it survives reloads; rebuilt to the current rows each apply.
    private var renderedContacts: [ContactID: Contact] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// Opaque token from the closure-based `addObserver` so `deinit` can remove
    /// this specific observer (not "all observers for self", which the
    /// selector-based form requires). `nonisolated(unsafe)` because it's written
    /// once (setup on main) and read only from `deinit` (nonisolated under Swift
    /// 6) — no concurrent access to guard against.
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
        title = "People"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — ContactsListViewController is code-only")
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

        // First paint from whatever the AppDelegate's initial reload produced —
        // it kicks `repository.reload()` from didFinishLaunching, so by the time
        // the user picks People the array is usually populated. Re-applying here
        // also covers "navigated away and back" where the cached snapshot still
        // matches.
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
        tableView.estimatedRowHeight = 56
        tableView.sectionIndexBackgroundColor = .clear
        tableView.register(ContactCell.self, forCellReuseIdentifier: CellID.contact.rawValue)
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
        searchController.searchBar.placeholder = "Search people"
        searchController.installKeyboardDismissal(for: tableView)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    /// Install the nav bar's right items: "+" (add contact, rightmost) and the
    /// global sort pull-down. The sort menu is rebuilt from
    /// `repository.sortOrder` on every call (see `makeSortBarButtonItem` in
    /// `SortOrderSetting`), so this covers the initial checkmark;
    /// `refreshSortMenu()` refreshes it from the reload observer so a change
    /// made in another list moves the checkmark here too. The sort item is
    /// held in `sortBarButtonItem` because `navigationItem.rightBarButtonItem`
    /// now resolves to the "+".
    private func configureNavigationItems() {
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.didRequestAddContact() }
        )
        addItem.accessibilityLabel = "Add Contact"
        let sortItem = makeSortBarButtonItem(repository: repository)
        sortBarButtonItem = sortItem
        let filterItem = makeLinkFilterBarButtonItem(
            current: repository.peopleFilter,
            allTitle: "All People"
        ) { [weak repository] filter in
            repository?.peopleFilter = filter
        }
        filterBarButtonItem = filterItem
        navigationItem.rightBarButtonItems = [addItem, filterItem, sortItem]
    }

    private var sortBarButtonItem: UIBarButtonItem?
    private var filterBarButtonItem: UIBarButtonItem?

    private func selectedContacts() -> [Contact] {
        ContactMultiSelectionSupport.selectedContacts(
            in: tableView,
            repository: repository,
            itemIdentifier: { [weak self] in self?.dataSource.itemIdentifier(for: $0) }
        )
    }

    private func notifySelectionChanged(_ contacts: [Contact]? = nil) {
        let contacts = contacts ?? selectedContacts()
        if contacts.count == 1, let contact = contacts.first {
            didSelectContact(contact)
        } else if contacts.count > 1 {
            didSelectContacts(contacts)
        }
    }

    /// Rebuild the sort button's menu so its checkmark tracks the live global
    /// order. Called from the reload observer because a sort change posts
    /// `.contactsRepositoryDidReload`, and the menu is otherwise cached at the
    /// order it was built with.
    private func refreshSortMenu() {
        sortBarButtonItem?.menu = makeSortMenu(repository: repository)
    }

    private func refreshFilterMenu() {
        filterBarButtonItem?.menu = makeLinkFilterMenu(
            current: repository.peopleFilter,
            allTitle: "All People"
        ) { [weak repository] filter in
            repository?.peopleFilter = filter
        }
    }

    private func configureEmptyState() {
        emptyLabel.text = "No People"
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
        // Capture self weakly in the cell provider so a deinit mid-reload can't
        // leak a strong reference cycle.
        dataSource = SectionedDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.contact.rawValue, for: indexPath)
            guard let self, let contact = self.repository.contact(id: id) else { return cell }
            (cell as? ContactCell)?.configure(
                with: contact,
                photoLoader: self.photoLoader,
                isFavorite: self.favoritesStore.isFavorite(contact.contactID),
                linkCount: self.repository.linkCount(for: contact)
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        // Repository fires `.contactsRepositoryDidReload` after its async fetch
        // lands. A notification is simpler than `withObservationTracking` for
        // this one-shot refresh — UIKit only needs to know "the array changed",
        // not which property.
        //
        // Pinned to OperationQueue.main so a future off-main post (Task.detached,
        // a background queue, …) still applies the diffable snapshot from the
        // main thread — `UITableViewDiffableDataSource.apply` is main-thread-only
        // and would crash otherwise. Today the repository is @MainActor so posts
        // come from main; the pin is defensive.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // OperationQueue.main delivers on the main thread, but Swift can't
            // statically prove the closure is @MainActor — assert it so the
            // diffable apply runs in the right isolation context.
            MainActor.assumeIsolated {
                // Move the sort button's checkmark first: a global sort change
                // posts this same notification, so the menu must re-read the
                // live order too, not just the snapshot.
                self?.refreshSortMenu()
                self?.refreshFilterMenu()
                self?.applySnapshot(animated: true)
            }
        }

        // Favorite status isn't part of `Contact`, so applySnapshot's
        // rendered-contact diff can't detect a star toggle — reconfigure the
        // current rows explicitly when the favorites list changes (posted by
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
    /// favorite stars repaint. Reconfigure only touches on-screen cells, so
    /// this is cheap even for a large list.
    private func reconfigureAllRows() {
        var snapshot = dataSource.snapshot()
        guard snapshot.numberOfItems > 0 else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshot(animated: Bool) {
        let sections = repository.peopleSectionIDs
        sectionLetters = sections.map { $0.0 }
        // Time orders section into relative-time buckets ("Today", "This Week",
        // …) where an A–Z scrubber is meaningless, so hide it; name orders keep
        // the index. The data source reads this flag from
        // `sectionIndexTitles(for:)`; set it before apply so the index appears/
        // disappears in the same pass as the new sections.
        dataSource.showsSectionIndex = !repository.sortOrder.isTimeOrder

        var snapshot = NSDiffableDataSourceSnapshot<String, ContactID>()
        snapshot.appendSections(sectionLetters)
        // De-dupe by effective identity across the WHOLE snapshot: two ContactIDs
        // sharing an effectiveID are EQUAL (identity-only) and `appendItems` traps
        // on a duplicate. Duplicates arise only in the transient pre-reconcile
        // window where two contacts momentarily carry the same guessWhoID (until
        // reconciliation collapses them). First occurrence wins which token is
        // KEPT, but the cell renders whatever `repository.contact(id:)` resolves
        // (the index's last-writer for that effectiveID) — the VC doesn't pick.
        var seen = Set<ContactID>()
        for (letter, contactIDs) in sections {
            let unique = contactIDs.filter { seen.insert($0).inserted }
            snapshot.appendItems(unique, toSection: letter)
        }

        // ContactID is identity-only, so the diffable apply keeps a same-identity
        // row in place but will NOT repaint its contents on an in-place edit
        // (Apple's apply(_:) reconfigures by Hashable identity only, never by
        // re-checking ==). Detect content changes explicitly: for each row in
        // BOTH the last render and the new snapshot, compare the last-rendered
        // Contact against the fresh one (Contact is Equatable) and reconfigure
        // the ones that differ. Only reconfigure IDs present in the new snapshot
        // — brand-new/removed rows are apply's inserts/deletes, and including
        // them here traps.
        let currentIDs = Set(snapshot.itemIdentifiers)
        let changed = currentIDs.filter { id in
            guard let previous = renderedContacts[id] else { return false }
            return previous != repository.contact(id: id)
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(Array(changed))
        }

        // Rebuild the render map to exactly this snapshot's rows so a removed
        // row's stale Contact can't linger and a re-added row compares fresh next
        // time.
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
        if isEmpty && !repository.peopleSearch.isEmpty {
            emptyLabel.text = "No people match \"\(repository.peopleSearch)\"."
        } else if repository.peopleFilter == .linked {
            emptyLabel.text = "No Linked People"
        } else {
            emptyLabel.text = "No People"
        }
    }
}

// MARK: - UITableViewDelegate

extension ContactsListViewController: UITableViewDelegate {
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
        (cell as? ContactCell)?.cancelPhotoLoad()
    }
}

// MARK: - UITableViewDataSourcePrefetching

extension ContactsListViewController: UITableViewDataSourcePrefetching {
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

extension ContactsListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

/// Subclasses the diffable data source to expose the section-title hook.
/// `titleForHeaderInSection` lives on `UITableViewDataSource`, but the diffable
/// data source's default implementation doesn't forward it — overriding here is
/// the documented way to add A–Z section headers + the right-side index
/// scrubber.
private final class SectionedDataSource: UITableViewDiffableDataSource<String, ContactID> {
    /// Whether the right-side A–Z scrubber is shown. The VC sets this to
    /// `!repository.sortOrder.isTimeOrder` before each apply: NAME orders have
    /// A–Z letter sections and a useful index; TIME orders have bucket-name
    /// sections ("Today", "This Week", …) where an alphabetical index is
    /// meaningless, so it's hidden.
    var showsSectionIndex = true

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        tableView.isEditing
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        // The snapshot's section identifier IS the letter — use it directly.
        snapshot().sectionIdentifiers[safe: section]
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        // Suppress the scrubber for time orders — bucket-name sections don't
        // form an alphabetical index.
        guard showsSectionIndex else { return nil }
        let titles = snapshot().sectionIdentifiers
        return titles.isEmpty ? nil : titles
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        // sectionIndexTitles matches sectionIdentifiers 1:1, so the index IS the
        // section number.
        index
    }
}

private extension Array {
    /// Safe-indexed lookup so `tableView.numberOfSections` briefly disagreeing
    /// with the snapshot during an animated apply can't crash the section-title
    /// call.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - UISearchResultsUpdating

extension ContactsListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard repository.peopleSearch != text else { return }
        repository.peopleSearch = text
        // peopleSearch only re-filters the computed property; nothing republishes
        // on its own, so apply a fresh snapshot here.
        applySnapshot(animated: false)
    }
}

// MARK: - Row cell

/// Two-line contact row: leading avatar thumbnail (initials-circle fallback from
/// `ContactAvatarImage`), name with bold family name, caption-sized subtitle
/// showing "jobTitle, organizationName" (a non-breaking space when empty keeps
/// every row the same height), and a trailing star on favorited contacts.
private final class ContactCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let linkCountLabel = UILabel()
    private let starView = UIImageView()
    // Spacing between the text stack and the link-count label. A hidden
    // (empty, zero-width) label still holds its -8 spacer, which would stack
    // with the label's own -8 trailing spacer and steal ~8pt from the text on
    // every linkless row; collapsing this to 0 when hidden makes such rows
    // reclaim the full width up to the star exactly as before this feature.
    private var textToLinkCountSpacing: NSLayoutConstraint?
    private var representedID: ContactID?
    private var photoTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — ContactCell is code-only")
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

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.numberOfLines = 1

        // Trailing "N links" caption, shown only when the contact has at least
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
        // deterministic (an image-less UIImageView has no intrinsic size) and
        // every row reserves the same text width whether or not it's starred.
        starView.image = UIImage(systemName: "star.fill")
        starView.contentMode = .scaleAspectFit
        starView.tintColor = .systemYellow
        starView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        starView.isHidden = true
        starView.setContentHuggingPriority(.required, for: .horizontal)
        starView.setContentCompressionResistancePriority(.required, for: .horizontal)
        starView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
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
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            starView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            starView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            linkCountLabel.trailingAnchor.constraint(equalTo: starView.leadingAnchor, constant: -8),
            linkCountLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textToLinkCount,
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
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
        nameLabel.attributedText = Self.nameAttributedString(for: contact)
        // Non-breaking space when there's no jobTitle/organizationName — an empty
        // string would collapse the second line and shrink the row.
        subtitleLabel.text = Self.subtitle(for: contact).isEmpty ? "\u{00A0}" : Self.subtitle(for: contact)
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

    private static func subtitle(for contact: Contact) -> String {
        guard contact.contactType == .person else { return "" }
        let title = contact.jobTitle
        let org = contact.organizationName
        if !title.isEmpty, !org.isEmpty { return "\(title), \(org)" }
        if !title.isEmpty { return title }
        return org
    }
}
