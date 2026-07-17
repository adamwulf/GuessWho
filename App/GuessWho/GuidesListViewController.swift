import UIKit
import GuessWhoSync
import GuessWhoLogging

/// UIKit Guides list. Used by both the Catalyst 3-column shell (as the
/// supplementary column for `.guides`) and the iPhone tab shell (rooted in
/// the Guides nav stack). Lists imported Apple Maps guides newest-first;
/// selecting a guide surfaces its places via `didSelectGuide` (a push, like
/// the Groups → members drill-in).
///
/// The "+" button imports a new guide from a pasted Apple Maps share link
/// (`maps.apple/ug/…`). There is no picker over anything external — a guide
/// only ever enters the app through a share link the user provides.
final class GuidesListViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can push the
    /// places list without us holding the nav stack or the split.
    var didSelectGuide: (MapsGuide) -> Void = { _ in }

    private let repository: GuidesRepository
    private let service: SyncService

    private static let log = GuessWhoLog.logger("app.guides.list")

    private enum CellID: String {
        case guide
    }

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, UUID>!

    private var guidesByID: [UUID: MapsGuide] = [:]

    private let emptyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// The "+" add button — always present.
    private var addButton: UIBarButtonItem!
    /// The sort pull-down button — always present. Its menu is rebuilt in the
    /// reload observer so the checkmark tracks the repository's live order.
    private var sortButton: UIBarButtonItem!

    /// Flips true once the first reload completes, so the empty state can
    /// show a spinner until then. Mirrors `GroupsListViewController.hasGroupsLoaded`.
    private var hasLoaded = false

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var reloadObserver: NSObjectProtocol?

    init(repository: GuidesRepository, service: SyncService) {
        self.repository = repository
        self.service = service
        super.init(nibName: nil, bundle: nil)
        title = "Guides"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GuidesListViewController is code-only")
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
        configureEmptyState()
        configureDataSource()
        configureAddButton()
        observeRepositoryReloads()

        // Paint whatever the repository already cached, then kick a fresh
        // fetch; the reload's notification re-applies the snapshot.
        applySnapshot(animated: false)
        Task {
            await repository.reload()
            hasLoaded = true
            applySnapshot(animated: true)
        }
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
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.register(GuideCell.self, forCellReuseIdentifier: CellID.guide.rawValue)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func configureEmptyState() {
        emptyLabel.text = "No Guides\nShare an Apple Maps guide link to add one."
        emptyLabel.numberOfLines = 0
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
        ) { [weak self] tableView, indexPath, guideID in
            let cell = tableView.dequeueReusableCell(withIdentifier: CellID.guide.rawValue, for: indexPath)
            guard let self, let guide = self.guidesByID[guideID] else { return cell }
            (cell as? GuideCell)?.configure(
                with: guide,
                placeCount: self.repository.placeCount(inGuide: guide.id)
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func configureAddButton() {
        addButton = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in
                self?.presentAddGuideAlert()
            }
        )
        sortButton = makeGuideSortBarButtonItem(repository: repository)
        // Right bar items render right-to-left: "+" rightmost (as before),
        // sort next to it — the same relative placement the events / person
        // lists give their sort button.
        navigationItem.rightBarButtonItems = [addButton, sortButton]
    }

    // MARK: - Add flow (paste a share link)

    /// "+" flow: a small alert with a text field for the Apple Maps guide
    /// link. Pre-fills from the pasteboard when it already holds a guide
    /// link, so share-copy-open-tap-paste collapses to share-copy-open-tap.
    private func presentAddGuideAlert() {
        let alert = UIAlertController(
            title: "Add Guide",
            message: "Paste an Apple Maps guide link (maps.apple/ug/…).",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "https://maps.apple/ug/…"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let pasted = UIPasteboard.general.string,
               let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)),
               MapsGuideURL.isGuideShareURL(url) {
                field.text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            let raw = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.importGuide(fromLink: raw)
        })
        present(alert, animated: true)
    }

    private func importGuide(fromLink raw: String) {
        guard let url = URL(string: raw), MapsGuideURL.isGuideShareURL(url) else {
            presentImportFailure(message: "That doesn't look like an Apple Maps guide link. Copy the guide's share link (maps.apple/ug/…) and try again.")
            return
        }
        activityIndicator.startAnimating()
        Task { @MainActor in
            // The collision flow may present its own alert (and then store
            // asynchronously), so stop the spinner once the fetch/decide step
            // has run — the store branches manage their own completion.
            await GuideImporter.importGuideResolvingNameCollision(
                from: url,
                service: service,
                repository: repository,
                presenter: self,
                onImported: { [weak self] guideID in
                    guard let self else { return }
                    self.updateEmptyState()
                    // Open the guide (new or updated) so the user lands on it.
                    if let guide = self.repository.guides.first(where: { $0.id == guideID }) {
                        self.didSelectGuide(guide)
                    }
                },
                onFailure: { [weak self] error in
                    guard let self else { return }
                    self.updateEmptyState()
                    Self.log.error("import failed: \(error.localizedDescription)")
                    self.presentImportFailure(
                        message: "The guide couldn't be loaded. Check the link and your internet connection, then try again."
                    )
                }
            )
            // The interactive branch may still be waiting on the user's alert
            // choice; either way the fetch/decide step is done, so drop the
            // spinner now. onImported/onFailure repaint the empty state again.
            self.updateEmptyState()
        }
    }

    private func presentImportFailure(message: String) {
        let alert = UIAlertController(
            title: "Couldn't Add Guide",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeRepositoryReloads() {
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .guidesRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applySnapshot(animated: true)
                // Rebuild the sort menu so the checkmark tracks the order that
                // produced this reload (menus are immutable snapshots).
                self.sortButton.menu = self.makeGuideSortMenu(repository: self.repository)
            }
        }
    }

    private func applySnapshot(animated: Bool) {
        let guides = repository.guides

        var byID: [UUID: MapsGuide] = [:]
        for guide in guides {
            byID[guide.id] = guide
        }
        guidesByID = byID

        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(guides.map(\.id), toSection: 0)
        // A guide's row also renders its (mutable) place count, and the
        // diffable apply won't re-run the provider for an unchanged item id —
        // reconfigure survivors so counts repaint after resolution/deletes.
        let surviving = guides.map(\.id).filter { dataSource.snapshot().indexOfItem($0) != nil }
        if !surviving.isEmpty {
            snapshot.reconfigureItems(surviving)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = repository.guides.isEmpty
        emptyLabel.isHidden = !isEmpty || !hasLoaded || repository.isLoading
        if isEmpty && (!hasLoaded || repository.isLoading) {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }
}

// MARK: - UITableViewDelegate

extension GuidesListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let guideID = dataSource.itemIdentifier(for: indexPath),
              let guide = guidesByID[guideID] else { return }
        didSelectGuide(guide)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let guideID = dataSource.itemIdentifier(for: indexPath),
              let guide = guidesByID[guideID] else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completion in
            self?.confirmDelete(guide: guide, completion: completion)
        }
        action.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    private func confirmDelete(guide: MapsGuide, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Remove \"\(GuideCell.displayName(for: guide))\" and its places?",
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.performDelete(guide: guide)
            completion(true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }

    private func performDelete(guide: MapsGuide) {
        do {
            try service.deleteGuide(uuid: guide.id.uuidString)
        } catch {
            service.recordError("delete guide failed: \(error.localizedDescription)")
        }
        Task { await repository.reload() }
    }
}

extension GuidesListViewController: ScrollsToTop {
    func scrollToTop(animated: Bool) {
        tableView.scrollToTopRespectingAdjustedInset(animated: animated)
    }
}

// MARK: - Row cell

/// Guide row: leading map icon, guide name, and a "N places" caption.
private final class GuideCell: UITableViewCell {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — GuideCell is code-only")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        countLabel.text = nil
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
        accessoryType = .disclosureIndicator

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        // Keep the row icon in lockstep with the Guides tab/sidebar icon.
        iconView.image = UIImage(systemName: SidebarTab.guides.systemImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1

        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabel
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [nameLabel, countLabel])
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

    func configure(with guide: MapsGuide, placeCount: Int) {
        nameLabel.text = Self.displayName(for: guide)
        countLabel.text = placeCount == 1 ? "1 place" : "\(placeCount) places"
    }

    static func displayName(for guide: MapsGuide) -> String {
        let name = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "(Unnamed Guide)" : name
    }
}
