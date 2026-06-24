import UIKit
import GuessWhoSync

/// UIKit People list. Used by both the Catalyst 3-column shell (as
/// the supplementary column for `.people`) and the iPhone tab shell
/// (rooted in the People nav stack). Backed by a
/// `UITableViewDiffableDataSource` keyed on (section-letter, localID)
/// so a repository reload only re-applies a snapshot rather than
/// invalidating the entire view. A–Z sectioning, search bound to
/// `ContactsRepository.peopleSearch`, per-row layout matching
/// `ContactRow` (icon + name + caption subtitle).
final class ContactsListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can mount
    /// a fresh `UIHostingController<ContactDetailView>` in the secondary
    /// column without us holding a strong reference to the split.
    var didSelectContact: (Contact) -> Void = { _ in }

    private let repository: ContactsRepository

    private enum CellID: String {
        case contact
    }

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: SectionedDataSource!

    /// Local cache so `tableView(_:cellForRowAt:)` and selection
    /// resolve a `localID` back to a `Contact` without re-running the
    /// repository's sort/filter pipeline on every row.
    private var contactsByLocalID: [String: Contact] = [:]
    private var sectionLetters: [String] = []

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

    init(repository: ContactsRepository) {
        self.repository = repository
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

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
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
        ) { [weak self] tableView, indexPath, localID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.contact.rawValue, for: indexPath)
            guard let self, let contact = self.contactsByLocalID[localID] else { return cell }
            (cell as? ContactCell)?.configure(with: contact)
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
                self?.applySnapshot(animated: true)
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        let sections = repository.peopleSections

        // Rebuild the localID → Contact lookup before the cell provider
        // can ask for it. Doing this before .apply keeps any
        // mid-snapshot dequeue from seeing stale data.
        let previousByID = contactsByLocalID
        var byID: [String: Contact] = [:]
        for (_, contacts) in sections {
            for contact in contacts {
                byID[contact.localID] = contact
            }
        }
        contactsByLocalID = byID
        sectionLetters = sections.map { $0.0 }

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections(sectionLetters)
        for (letter, contacts) in sections {
            snapshot.appendItems(contacts.map { $0.localID }, toSection: letter)
        }

        // The snapshot keys rows on `localID`, so the diff treats a row
        // with an unchanged localID as identical even when the contact's
        // displayed fields (name, jobTitle, organizationName) changed —
        // it would keep the stale cell until recycling. Explicitly
        // reconfigure rows whose Contact value differs from the previous
        // snapshot so an in-place edit repaints immediately. Contact is
        // Equatable (via Hashable), so the comparison is a cheap value
        // check. Brand-new and removed rows are handled by `apply` itself
        // and must be excluded here — reconfiguring an item not present in
        // the new snapshot would trap.
        let changedIDs = byID.compactMap { localID, contact -> String? in
            guard let previous = previousByID[localID] else { return nil }
            return previous == contact ? nil : localID
        }
        if !changedIDs.isEmpty {
            snapshot.reconfigureItems(changedIDs)
        }

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
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let contact = contactsByLocalID[localID] else { return }
        didSelectContact(contact)
    }
}

/// Subclasses the diffable data source to expose the section title
/// hook. The optional `titleForHeaderInSection` lives on
/// `UITableViewDataSource`, but the diffable data source's default
/// implementation doesn't forward to its closure — overriding here
/// is the documented way to add A–Z section headers + the right-side
/// index scrubber.
private final class SectionedDataSource: UITableViewDiffableDataSource<String, String> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        // The snapshot's section identifier IS the letter, so the
        // header text is just the section identifier itself.
        snapshot().sectionIdentifiers[safe: section]
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
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

/// Two-line contact row mirroring the SwiftUI `ContactRow`: leading
/// circle/building icon, name with bold family name, caption-sized
/// subtitle showing "jobTitle, organizationName" (non-breaking space
/// when empty so every row stays the same height).
private final class ContactCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — ContactCell is code-only")
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

    func configure(with contact: Contact) {
        let symbol = contact.contactType == .organization
            ? "building.2.crop.circle.fill"
            : "person.crop.circle.fill"
        iconView.image = UIImage(systemName: symbol)
        nameLabel.attributedText = Self.nameAttributedString(for: contact)
        // Non-breaking space keeps the row's two-line height stable
        // when the contact has no jobTitle/organizationName — matches
        // the SwiftUI ContactRow's subtitleLine placeholder.
        subtitleLabel.text = Self.subtitle(for: contact).isEmpty ? "\u{00A0}" : Self.subtitle(for: contact)
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
