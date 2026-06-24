import UIKit
import GuessWhoSync

/// UIKit Organizations list for the Catalyst 3-column shell. Mirrors
/// `ContactsListViewController` but reads `organizationsSections` /
/// `organizationsSearch` and renders a single-line row (organizations
/// have no subtitle).
final class OrganizationsListViewController: UIViewController {
    var didSelectContact: (Contact) -> Void = { _ in }

    private let repository: ContactsRepository

    private enum CellID: String {
        case organization
    }

    private var tableView: UITableView!
    private var searchController: UISearchController!
    private var dataSource: SectionedDataSource!

    private var contactsByLocalID: [String: Contact] = [:]
    private var sectionLetters: [String] = []

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    init(repository: ContactsRepository) {
        self.repository = repository
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureTableView()
        configureSearch()
        configureEmptyState()
        configureDataSource()
        observeRepositoryReloads()

        applySnapshot(animated: false)
    }

    // MARK: - Table view

    private func configureTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.sectionIndexBackgroundColor = .clear
        tableView.register(OrganizationCell.self, forCellReuseIdentifier: CellID.organization.rawValue)
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
        searchController.searchBar.placeholder = "Search organizations"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
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
        ) { [weak self] tableView, indexPath, localID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.organization.rawValue, for: indexPath)
            guard let self, let contact = self.contactsByLocalID[localID] else { return cell }
            (cell as? OrganizationCell)?.configure(with: contact)
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
                self?.applySnapshot(animated: true)
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        let sections = repository.organizationsSections

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

        // See ContactsListViewController.applySnapshot — rows keyed on
        // localID don't repaint on an in-place content change, so
        // reconfigure the rows whose Contact value differs. New/removed
        // rows are handled by `apply` and must be excluded (reconfiguring
        // an item absent from the new snapshot traps).
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
        guard let localID = dataSource.itemIdentifier(for: indexPath),
              let contact = contactsByLocalID[localID] else { return }
        didSelectContact(contact)
    }
}

/// Diffable data source subclass that forwards A–Z section headers
/// and the index scrubber. Same rationale as
/// `ContactsListViewController.SectionedDataSource`.
private final class SectionedDataSource: UITableViewDiffableDataSource<String, String> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let ids = snapshot().sectionIdentifiers
        return ids.indices.contains(section) ? ids[section] : nil
    }

    override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
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

/// Single-line organization row: leading building icon + bold family
/// name (which is the organization's name in the data model). No
/// subtitle — matches the SwiftUI `ContactRow` for `.organization`.
private final class OrganizationCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — OrganizationCell is code-only")
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
        iconView.image = UIImage(systemName: "building.2.crop.circle.fill")
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1

        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    func configure(with contact: Contact) {
        nameLabel.attributedText = Self.nameAttributedString(for: contact)
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
