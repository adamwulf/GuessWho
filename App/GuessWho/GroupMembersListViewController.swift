import UIKit
import GuessWhoSync

/// UIKit list of the members of one Contacts.app group. Pushed when a row is
/// tapped in `GroupsListViewController` — on iPhone onto the Groups tab's nav
/// stack, on Catalyst onto the supplementary column's nav. Renders members
/// EXACTLY like `ContactsListViewController`: A–Z sectioning, the same two-line
/// `ContactCell` (icon + bold-family-name + caption subtitle), and lazy photo
/// loading + prefetch via `ContactPhotoLoader`.
///
/// A group's members are a FLAT mix of people and organizations — the user
/// asked for "all the people/orgs in the group" with no person/org split — so
/// this VC sections the single fetched member array A–Z rather than reading the
/// repository's separate `people`/`organizations` projections.
///
/// Members are resolved from this VC's OWN `[ContactID: Contact]` map (built
/// from the one-shot `members(ofGroup:)` fetch), not from `repository.contact(id:)`.
/// That guarantees every fetched member renders its name even in the (rare) case
/// it isn't present in the main contacts cache, and keeps the member set tied to
/// this group rather than the global address book.
final class GroupMembersListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can mount/push a
    /// `ContactDetailView` (push on iPhone, replace-secondary on Catalyst)
    /// without us holding a reference to the nav stack or the split.
    var didSelectContact: (Contact) -> Void = { _ in }

    private let group: ContactGroup
    private let repository: ContactsRepository
    private let photoLoader: ContactPhotoLoader

    private enum CellID: String {
        case contact
    }

    private var tableView: UITableView!
    private var dataSource: SectionedDataSource!

    private var sectionLetters: [String] = []

    /// The members this VC fetched for `group`, keyed by `ContactID` — the SOLE
    /// source the cell provider resolves a member `Contact` from (see the type
    /// doc). Filled once by `loadMembers()`.
    private var membersByID: [ContactID: Contact] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var hasLoaded = false

    private var prefetchTasks: [ContactID: Task<Void, Never>] = [:]

    /// Opaque observer token for `.contactsRepositoryDidReload` so a global
    /// sort change re-sorts this member list too. See
    /// `ContactsListViewController.reloadObserver` for the `nonisolated(unsafe)`
    /// rationale (written once on main, read only from `deinit`).
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    init(group: ContactGroup, repository: ContactsRepository, photoLoader: ContactPhotoLoader) {
        self.group = group
        self.repository = repository
        self.photoLoader = photoLoader
        super.init(nibName: nil, bundle: nil)
        title = GroupMembersListViewController.title(for: group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GroupMembersListViewController is code-only")
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
        configureSortMenu()
        configureEmptyState()
        configureDataSource()
        observeRepositoryReloads()

        applySnapshot(animated: false)
        Task { await loadMembers() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
    }

    // MARK: - Members fetch

    private func loadMembers() async {
        let members = await repository.members(ofGroup: group.localID)
        // Key each fetched member by its opaque `ContactID` (effective identity),
        // exactly like the People list keys its rows. A member appears once per
        // identity — last-writer-wins on the (transient pre-reconcile) duplicate
        // window, matching the contact lists' de-dup behavior.
        var byID: [ContactID: Contact] = [:]
        for member in members {
            byID[member.contactID] = member
        }
        membersByID = byID
        hasLoaded = true
        applySnapshot(animated: true)
    }

    // MARK: - Sort menu

    /// Install the global sort pull-down as the nav bar's right item. Shared
    /// with the People / Organizations lists via `makeSortBarButtonItem` so the
    /// member list offers the same orders + checkmark.
    private func configureSortMenu() {
        navigationItem.rightBarButtonItem = makeSortBarButtonItem(repository: repository)
    }

    /// Rebuild the sort button's menu so its checkmark tracks the live global
    /// order. Called from the reload observer.
    private func refreshSortMenu() {
        navigationItem.rightBarButtonItem?.menu = makeSortMenu(repository: repository)
    }

    /// Observe `.contactsRepositoryDidReload` so a GLOBAL sort change (posted by
    /// the repository's `sortOrder` `didSet`) re-sorts THIS member list too.
    /// The member set itself is fetched once in `loadMembers()` and doesn't
    /// change here — re-applying the snapshot only re-sorts/re-sections the
    /// already-loaded members by the new order. Same `OperationQueue.main` +
    /// `MainActor.assumeIsolated` pattern as the contact lists (the diffable
    /// apply is main-thread-only).
    @MainActor
    private func observeRepositoryReloads() {
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSortMenu()
                self?.applySnapshot(animated: true)
            }
        }
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

    private func configureEmptyState() {
        emptyLabel.text = "No Members"
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
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.contact.rawValue, for: indexPath)
            guard let self, let contact = self.membersByID[id] else { return cell }
            (cell as? ContactCell)?.configure(with: contact, photoLoader: self.photoLoader)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    // MARK: - Snapshot wiring

    private func applySnapshot(animated: Bool) {
        // Sort + section this group's members by the CURRENT global sort order
        // via the package, so the member list honors the same picker as the
        // People / Organizations lists (name A–Z or a relative-time bucket
        // order).
        let sections = repository.sectionedIDs(forMembers: Array(membersByID.values))
        sectionLetters = sections.map { $0.0 }
        // Hide the A–Z scrubber for time orders (bucket-name sections) — see
        // ContactsListViewController.applySnapshot.
        dataSource.showsSectionIndex = !repository.sortOrder.isTimeOrder

        var snapshot = NSDiffableDataSourceSnapshot<String, ContactID>()
        snapshot.appendSections(sectionLetters)
        // De-dupe by effective identity across the whole snapshot — equal
        // ContactIDs trap in appendItems. Building `membersByID` keyed on
        // ContactID already collapses duplicates, but the per-section arrays are
        // rebuilt from the map's values, so guard defensively as the contact
        // lists do.
        var seen = Set<ContactID>()
        for (letter, ids) in sections {
            let unique = ids.filter { seen.insert($0).inserted }
            snapshot.appendItems(unique, toSection: letter)
        }

        dataSource.apply(snapshot, animatingDifferences: animated)

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = sectionLetters.isEmpty
        // Show the spinner only while the first fetch is in flight; once it lands
        // (`hasLoaded`), an empty member set surfaces the "No Members" label. The
        // label text is fixed (set in configureEmptyState) and has no search-empty
        // variant, so it never needs re-assigning here.
        emptyLabel.isHidden = !isEmpty || !hasLoaded
        if isEmpty && !hasLoaded {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }
}

// MARK: - UITableViewDelegate

extension GroupMembersListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let contact = membersByID[id] else { return }
        didSelectContact(contact)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? ContactCell)?.cancelPhotoLoad()
    }
}

// MARK: - UITableViewDataSourcePrefetching

extension GroupMembersListViewController: UITableViewDataSourcePrefetching {
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

extension GroupMembersListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

private extension GroupMembersListViewController {
    /// The group's user-facing name, used as the navigation title.
    static func title(for group: ContactGroup) -> String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Group" : name
    }
}

/// Diffable data source subclass that forwards A–Z section headers and the
/// index scrubber. Same rationale as `ContactsListViewController.SectionedDataSource`.
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

// MARK: - Row cell

/// Two-line member row mirroring `ContactsListViewController`'s `ContactCell`:
/// leading circle/building icon, name with bold family name, caption-sized
/// subtitle ("jobTitle, organizationName" for people; empty for organizations,
/// padded with a non-breaking space so every row keeps the same height). A
/// pragmatic mirror — each list VC in this shell owns its own private cell, and
/// matching that convention keeps the member row pixel-identical to People.
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
        // Non-breaking space keeps the row's two-line height stable when the
        // contact has no jobTitle/organizationName — matches the People row.
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
