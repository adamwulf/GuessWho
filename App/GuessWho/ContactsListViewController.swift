import UIKit
import GuessWhoSync

/// UIKit People list. Used by both the Catalyst 3-column shell (as
/// the supplementary column for `.people`) and the iPhone tab shell
/// (rooted in the People nav stack). Backed by a
/// `UITableViewDiffableDataSource` keyed on (section-letter, ContactID)
/// so a repository reload only re-applies a snapshot rather than
/// invalidating the entire view. A–Z sectioning, search bound to
/// `ContactsRepository.peopleSearch`, per-row layout of a leading
/// avatar plus a name and caption subtitle.
final class ContactsListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can mount
    /// a fresh `UIHostingController<ContactDetailView>` in the secondary
    /// column without us holding a strong reference to the split.
    var didSelectContact: (Contact) -> Void = { _ in }

    private let repository: ContactsRepository
    private let photoLoader: ContactPhotoLoader

    private enum CellID: String {
        case contact
    }

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: SectionedDataSource!

    private var sectionLetters: [String] = []

    /// The `Contact` each `ContactID` row last rendered. `ContactID` is an
    /// identity-only token (its `==`/`hash` key on effective identity alone), so
    /// the diffable apply keeps a same-identity row in place but does NOT repaint
    /// its contents on an in-place edit — Apple's `apply(_:)` reconfigures items
    /// by `Hashable` identity only, never by re-checking `==`. We detect content
    /// changes ourselves by comparing this map's `Contact` against the freshly
    /// fetched one and call `snapshot.reconfigureItems(_:)` explicitly. Keyed by
    /// `ContactID` so it survives reloads; rebuilt to the current rows each apply.
    private var renderedContacts: [ContactID: Contact] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// Opaque token returned by the closure-based `addObserver` so
    /// `deinit` can remove the specific observer (not "all observers
    /// for self", which the selector-based form requires).
    /// `nonisolated(unsafe)` because the property is only written once
    /// (during setup on main) and only read from `deinit` (which is
    /// nonisolated under Swift 6) — there is no concurrent access to
    /// guard against.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    private var prefetchTasks: [ContactID: Task<Void, Never>] = [:]

    init(repository: ContactsRepository, photoLoader: ContactPhotoLoader) {
        self.repository = repository
        self.photoLoader = photoLoader
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureSearch()
        configureSortMenu()
        configureEmptyState()
        configureDataSource()
        observeRepositoryReloads()

        // First paint from whatever the AppDelegate's initial reload
        // already produced — Phase 3's AppDelegate kicks
        // `repository.reload()` from didFinishLaunching, so by the time
        // the user picks People in the sidebar the array is usually
        // populated. Re-applying here also covers the "navigated away
        // and back" case where the cached snapshot still matches.
        applySnapshot(animated: false)
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
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureSearch() {
        searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search people"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    /// Install the global sort pull-down as the nav bar's right item. The menu
    /// is rebuilt from `repository.sortOrder` on every call (see
    /// `makeSortBarButtonItem` in `SortOrderSetting`), so installing here covers
    /// the initial checkmark; `refreshSortMenu()` re-installs it in the reload
    /// observer so a change made from another list moves the checkmark here too.
    private func configureSortMenu() {
        navigationItem.rightBarButtonItem = makeSortBarButtonItem(repository: repository)
    }

    /// Rebuild the sort button's menu so its checkmark tracks the live global
    /// order. Called from the reload observer because the sort change posts
    /// `.contactsRepositoryDidReload` and the menu is otherwise cached at the
    /// order it was built with.
    private func refreshSortMenu() {
        navigationItem.rightBarButtonItem?.menu = makeSortMenu(repository: repository)
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
        // Capture self weakly inside the cell provider so a deinit
        // mid-reload can't leak a strong reference cycle.
        dataSource = SectionedDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.contact.rawValue, for: indexPath)
            guard let self, let contact = self.repository.contact(id: id) else { return cell }
            (cell as? ContactCell)?.configure(with: contact, photoLoader: self.photoLoader)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        // Repository fires `.contactsRepositoryDidReload` after its
        // async fetch lands. The notification path is intentionally
        // simpler than `withObservationTracking` for this one-shot
        // refresh — UIKit only needs to know "the array changed",
        // not which specific property.
        //
        // Pinned to OperationQueue.main so a future post from an off-
        // main context (Task.detached, a background queue, …) still
        // applies the diffable snapshot from the main thread —
        // UITableViewDiffableDataSource.apply is main-thread-only and
        // would crash otherwise. Today the repository is @MainActor so
        // posts always come from main; the queue pin is defensive.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // OperationQueue.main delivers on the main thread but Swift
            // can't statically prove the closure is @MainActor — hop
            // explicitly so the diffable apply runs in the right
            // isolation context.
            MainActor.assumeIsolated {
                // Move the sort button's checkmark first: a global sort change
                // posts this same notification, so the menu must re-read the
                // live order even though only the snapshot strictly "changed".
                self?.refreshSortMenu()
                self?.applySnapshot(animated: true)
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        let sections = repository.peopleSectionIDs
        sectionLetters = sections.map { $0.0 }
        // Time orders section into relative-time buckets ("Today", "This
        // Week", …), where an A–Z scrubber is meaningless — hide it. Name
        // orders keep the A–Z index. The data source reads this flag from
        // `sectionIndexTitles(for:)`; set it before apply so the index appears/
        // disappears in the same pass as the new sections.
        dataSource.showsSectionIndex = !repository.sortOrder.isTimeOrder

        var snapshot = NSDiffableDataSourceSnapshot<String, ContactID>()
        snapshot.appendSections(sectionLetters)
        // De-dupe by effective identity across the WHOLE snapshot. Two ContactIDs
        // sharing an effectiveID are now EQUAL (identity-only), and appendItems
        // traps on a duplicate item. Duplicates only occur in the transient
        // pre-reconcile window where two contacts momentarily carry the same
        // guessWhoID; reconciliation collapses them. First occurrence wins for
        // which token is KEPT, but the cell renders whatever
        // `repository.contact(id:)` resolves (the index's last-writer for that
        // effectiveID) — the VC doesn't pick which duplicate contact shows.
        var seen = Set<ContactID>()
        for (letter, contactIDs) in sections {
            let unique = contactIDs.filter { seen.insert($0).inserted }
            snapshot.appendItems(unique, toSection: letter)
        }

        // ContactID is identity-only, so the diffable apply keeps a same-identity
        // row in place but will NOT repaint its contents on an in-place edit
        // (Apple's apply(_:) reconfigures by Hashable identity only, never by
        // re-checking ==). Detect content changes explicitly: for each row
        // present in BOTH the last render and the new snapshot, compare the
        // Contact we last rendered against the freshly fetched one (Contact is
        // Equatable) and reconfigure the ones that differ. Brand-new/removed rows
        // are inserts/deletes handled by apply and must be excluded — only
        // reconfigure IDs present in the new snapshot, else apply traps.
        let currentIDs = Set(snapshot.itemIdentifiers)
        let changed = currentIDs.filter { id in
            guard let previous = renderedContacts[id] else { return false }
            return previous != repository.contact(id: id)
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(Array(changed))
        }

        // Rebuild the render map to exactly the rows in this snapshot so a
        // removed row's stale Contact can't linger and a re-added row compares
        // fresh next time.
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
        } else {
            emptyLabel.text = "No People"
        }
    }
}

// MARK: - UITableViewDelegate

extension ContactsListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let contact = repository.contact(id: id) else { return }
        didSelectContact(contact)
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

/// Subclasses the diffable data source to expose the section title
/// hook. The optional `titleForHeaderInSection` lives on
/// `UITableViewDataSource`, but the diffable data source's default
/// implementation doesn't forward to its closure — overriding here
/// is the documented way to add A–Z section headers + the right-side
/// index scrubber.
private final class SectionedDataSource: UITableViewDiffableDataSource<String, ContactID> {
    /// Whether the right-side A–Z scrubber is shown. The VC sets this to
    /// `!repository.sortOrder.isTimeOrder` before each apply: for NAME orders
    /// the section identifiers are A–Z letters and the index is a useful
    /// scrubber; for TIME orders they are bucket names ("Today", "This Week",
    /// …) where an alphabetical index is meaningless, so it is hidden.
    var showsSectionIndex = true

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        // The snapshot's section identifier IS the letter, so the
        // header text is just the section identifier itself.
        snapshot().sectionIdentifiers[safe: section]
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        // Suppress the scrubber entirely for time orders — the bucket-name
        // section identifiers don't form an alphabetical index.
        guard showsSectionIndex else { return nil }
        let titles = snapshot().sectionIdentifiers
        return titles.isEmpty ? nil : titles
    }

    override func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        // sectionIndexTitles matches the snapshot's sectionIdentifiers
        // order 1:1, so the index is the section number.
        index
    }
}

private extension Array {
    /// Safe-indexed lookup so `tableView.numberOfSections` can briefly
    /// disagree with the snapshot during an animated apply without
    /// crashing the section-title call.
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
        // peopleSearch only re-filters the computed property; nothing
        // re-publishes on its own, so apply a fresh snapshot here.
        applySnapshot(animated: false)
    }
}

// MARK: - Row cell

/// Two-line contact row: leading avatar thumbnail (initials-circle
/// fallback from `ContactAvatarImage`), name with bold family name,
/// caption-sized subtitle showing "jobTitle, organizationName"
/// (non-breaking space when empty so every row stays the same height).
private final class ContactCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
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

        let textStack = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    func configure(with contact: Contact, photoLoader: ContactPhotoLoader) {
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
        // Non-breaking space keeps the row's two-line height stable
        // when the contact has no jobTitle/organizationName — an empty
        // string would collapse the second line and shrink the row.
        subtitleLabel.text = Self.subtitle(for: contact).isEmpty ? "\u{00A0}" : Self.subtitle(for: contact)
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
