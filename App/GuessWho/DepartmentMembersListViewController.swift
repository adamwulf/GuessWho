import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit list of the people in one department of one organization. Pushed when a
/// department row is tapped in an organization's `ContactDetailView` — on iPhone
/// onto the active tab's nav stack, on Catalyst onto the secondary column's nav.
/// Renders EXACTLY like `ContactsListViewController` / `GroupMembersListViewController`:
/// A–Z sectioning by the global sort order, the same two-line `ContactCell`, and
/// lazy photo loading + prefetch via `ContactPhotoLoader`.
///
/// The member set is DERIVED from the in-memory contacts cache — every person
/// associated with `organization` (their Contacts "company" names it) whose
/// "department" matches — so there is no one-shot async fetch. It recomputes on
/// every `.contactsRepositoryDidReload`, keeping the list live as contacts,
/// their org, or their department change, and honoring a global sort flip like
/// the other lists. Mirrors `contactsAssociated(with:inDepartment:)`.
final class DepartmentMembersListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can mount/push a
    /// `ContactDetailView` (push on iPhone, replace-secondary on Catalyst)
    /// without us holding a reference to the nav stack or the split.
    var didSelectContact: (Contact) -> Void = { _ in }
    var didSelectContacts: ([Contact]) -> Void = { _ in }

    /// The organization whose department this list shows. Captured at init as a
    /// fallback; each recompute re-resolves the freshest record from the
    /// repository by `ContactID` so a renamed org still resolves its people.
    private let organizationID: ContactID
    private let fallbackOrganization: Contact
    /// The department this list shows. Mutable: a successful rename rewrites it
    /// (and the nav title) so the reload observer and subsequent recomputes
    /// resolve members by the NEW name.
    private var department: String
    private let repository: ContactsRepository
    private let photoLoader: ContactPhotoLoader
    private let favoritesStore: FavoritesListStore

    private enum CellID: String {
        case contact
    }

    private var tableView: UITableView!
    private var dataSource: SectionedDataSource!

    private var sectionLetters: [String] = []

    /// The current members keyed by `ContactID` — the SOLE source the cell
    /// provider resolves a member `Contact` from. Rebuilt on every recompute.
    private var membersByID: [ContactID: Contact] = [:]

    private let emptyLabel = UILabel()

    /// Opaque observer token for `.contactsRepositoryDidReload` so a global sort
    /// change re-sorts, and a data change recomputes, this list. See
    /// `ContactsListViewController.reloadObserver` for the `nonisolated(unsafe)`
    /// rationale (written once on main, read only from `deinit`).
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    /// Observes `.favoritesDidChange` so a star toggled in a detail view
    /// repaints the matching row here. Same `nonisolated(unsafe)` rationale as
    /// `reloadObserver`.
    private nonisolated(unsafe) var favoritesObserver: NSObjectProtocol?

    private var prefetchTasks: [ContactID: Task<Void, Never>] = [:]

    init(
        organizationID: ContactID,
        organization: Contact,
        department: String,
        repository: ContactsRepository,
        photoLoader: ContactPhotoLoader,
        favoritesStore: FavoritesListStore
    ) {
        self.organizationID = organizationID
        self.fallbackOrganization = organization
        self.department = department
        self.repository = repository
        self.photoLoader = photoLoader
        self.favoritesStore = favoritesStore
        super.init(nibName: nil, bundle: nil)
        title = DepartmentMembersListViewController.title(for: department)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — DepartmentMembersListViewController is code-only")
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
        configureNavigationItems()
        configureEmptyState()
        configureDataSource()
        observeRepositoryReloads()

        recomputeMembers()
        applySnapshot(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        deselectSelectedTableRowOnNavigationReturn(in: tableView, animated: animated)
    }

    // MARK: - Members

    /// The freshest organization record for this list, falling back to the one
    /// captured at init if the repository no longer resolves the id (rare:
    /// deleted while open). The org's display name is what associates people, so
    /// re-resolving keeps the member set correct across a rename.
    private var currentOrganization: Contact {
        repository.contact(id: organizationID) ?? fallbackOrganization
    }

    /// Rebuild `membersByID` from the repository. A member appears once per
    /// effective identity (`ContactID`), exactly like the People list.
    private func recomputeMembers() {
        let members = repository.contactsAssociated(with: currentOrganization, inDepartment: department)
        var byID: [ContactID: Contact] = [:]
        for member in members {
            byID[member.contactID] = member
        }
        membersByID = byID
    }

    // MARK: - Nav bar items

    /// Install the nav bar's right items: "Edit" (rename this department,
    /// rightmost) and the global sort pull-down. The sort item is held in
    /// `sortBarButtonItem` because `navigationItem.rightBarButtonItem` now
    /// resolves to the first of the array — mirrors
    /// `OrganizationsListViewController.configureNavigationItems`.
    private func configureNavigationItems() {
        let editItem = UIBarButtonItem(
            title: "Edit",
            primaryAction: UIAction { [weak self] _ in self?.presentRename() }
        )
        editItem.accessibilityLabel = "Rename Department"
        let sortItem = makeSortBarButtonItem(repository: repository)
        sortBarButtonItem = sortItem
        navigationItem.rightBarButtonItems = [editItem, sortItem]
    }

    private var sortBarButtonItem: UIBarButtonItem?

    private func selectedIDs() -> [ContactID] {
        ContactMultiSelectionSupport.selectedIDs(
            in: tableView,
            itemIdentifier: { [weak self] in self?.dataSource.itemIdentifier(for: $0) }
        )
    }

    private func selectedContacts() -> [Contact] {
        selectedIDs().compactMap { membersByID[$0] }
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
    /// order. Called from the reload observer.
    private func refreshSortMenu() {
        sortBarButtonItem?.menu = makeSortMenu(repository: repository)
    }

    // MARK: - Rename

    /// Present the one-field rename form as a sheet, seeded with the current
    /// department name. Save routes through `performRename`; Cancel just
    /// dismisses.
    private func presentRename() {
        let sheet = DepartmentRenameView(
            originalName: department,
            onSave: { [weak self] newName in
                self?.dismiss(animated: true)
                self?.performRename(to: newName)
            },
            onCancel: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let host = UIHostingController(rootView: sheet)
        present(host, animated: true)
    }

    /// Rewrite the department across the organization's matching contacts, then
    /// re-key this list onto the new name. `DepartmentRenameView` already trimmed
    /// and non-empty-checked `newName`; a no-op change (same as the current name)
    /// short-circuits without a write. On success the reload posted by the
    /// repository refreshes every open list; here we also update our own
    /// `department`/title and re-snapshot immediately so the list doesn't flash
    /// empty against the stale name. Failures surface in a plain-copy alert.
    private func performRename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != department else { return }
        Task { @MainActor in
            do {
                try await repository.renameDepartment(
                    from: department, to: trimmed, in: currentOrganization
                )
                department = trimmed
                title = Self.title(for: trimmed)
                recomputeMembers()
                applySnapshot(animated: true)
            } catch {
                presentRenameError(error)
            }
        }
    }

    private func presentRenameError(_ error: Error) {
        let alert = UIAlertController(
            title: "Couldn't Rename Department",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Observe `.contactsRepositoryDidReload` so both a GLOBAL sort change and a
    /// contact-data change re-derive + re-sort this department list. Same
    /// `OperationQueue.main` + `MainActor.assumeIsolated` pattern as the other
    /// lists (the diffable apply is main-thread-only).
    @MainActor
    private func observeRepositoryReloads() {
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSortMenu()
                self?.recomputeMembers()
                self?.applySnapshot(animated: true)
            }
        }

        // Favorite status isn't part of `Contact`, so a star toggle never
        // changes the snapshot — reconfigure the current rows explicitly when
        // the favorites list changes (see ContactsListViewController).
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
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Contacts"
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
        dataSource = SectionedDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.contact.rawValue, for: indexPath)
            guard let self, let contact = self.membersByID[id] else { return cell }
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

    private func applySnapshot(animated: Bool) {
        // Sort + section the members by the CURRENT global sort order via the
        // package, so this list honors the same picker as the People /
        // Organizations lists (name A–Z or a relative-time bucket order).
        let sections = repository.sectionedIDs(forMembers: Array(membersByID.values))
        sectionLetters = sections.map { $0.0 }
        // Hide the A–Z scrubber for time orders (bucket-name sections) — see
        // ContactsListViewController.applySnapshot.
        dataSource.showsSectionIndex = !repository.sortOrder.isTimeOrder

        var snapshot = NSDiffableDataSourceSnapshot<String, ContactID>()
        snapshot.appendSections(sectionLetters)
        // De-dupe by effective identity across the whole snapshot — equal
        // ContactIDs trap in appendItems. `membersByID` is keyed on ContactID so
        // duplicates are already collapsed, but the per-section arrays are rebuilt
        // from the map's values, so guard defensively as the contact lists do.
        var seen = Set<ContactID>()
        for (letter, ids) in sections {
            let unique = ids.filter { seen.insert($0).inserted }
            snapshot.appendItems(unique, toSection: letter)
        }

        dataSource.apply(snapshot, animatingDifferences: animated)

        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !sectionLetters.isEmpty
    }
}

// MARK: - UITableViewDelegate

extension DepartmentMembersListViewController: UITableViewDelegate {
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

extension DepartmentMembersListViewController: UITableViewDataSourcePrefetching {
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

extension DepartmentMembersListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

private extension DepartmentMembersListViewController {
    /// The department's user-facing name, used as the navigation title.
    static func title(for department: String) -> String {
        let name = department.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Department" : name
    }
}

/// Diffable data source subclass that forwards A–Z section headers and the index
/// scrubber. Same rationale as `ContactsListViewController.SectionedDataSource`.
private final class SectionedDataSource: UITableViewDiffableDataSource<String, ContactID> {
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

// MARK: - Row cell

/// Two-line member row mirroring `ContactsListViewController`'s `ContactCell`:
/// leading circle icon, name with bold family name, caption-sized subtitle
/// ("jobTitle, organizationName"). A pragmatic mirror — each list VC in this
/// shell owns its own private cell, and matching that convention keeps the
/// department row pixel-identical to People (including the trailing star on
/// favorited members).
private final class ContactCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let starView = UIImageView()
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

        // Trailing favorite star. The image stays installed and only `isHidden`
        // toggles, so the star's intrinsic size keeps the layout deterministic
        // and every row reserves the same text width (see ContactsListViewController).
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
        contentView.addSubview(starView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            starView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            starView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: starView.leadingAnchor, constant: -8),
            textStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
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
        // Non-breaking space keeps the row's two-line height stable when the
        // contact has no jobTitle/organizationName — matches the People row.
        subtitleLabel.text = Self.subtitle(for: contact).isEmpty ? "\u{00A0}" : Self.subtitle(for: contact)
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
