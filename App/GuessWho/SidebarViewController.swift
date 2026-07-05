import UIKit

/// UIKit primary-column (sidebar) for the Catalyst 3-column shell.
/// Backed by a diffable data source so future dynamic content
/// (favorites, tag filters, …) can drop in without rewriting the
/// reload path, though it currently shows only the static `SidebarTab` rows.
final class SidebarViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can wire
    /// the sidebar to whichever content view controller is mounted in
    /// the supplementary column without us holding a hard reference to
    /// the split or the content VC.
    var didSelectTab: (SidebarTab) -> Void = { _ in }

    /// The tab to select on first load. Defaults to the first sidebar row; state
    /// restoration sets it to the section that was showing when the app quit so
    /// the sidebar comes up already pointed there (no default → restored flash).
    var initialTab: SidebarTab?

    private enum Section: Int, CaseIterable {
        case tabs
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, SidebarTab>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GuessWho"
        view.backgroundColor = .systemBackground

        configureCollectionView()
        configureDataSource()
        applyInitialSnapshot()
        selectInitialTab()
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        config.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarTab> { cell, _, tab in
            var content = cell.defaultContentConfiguration()
            content.text = tab.title
            content.image = UIImage(systemName: tab.systemImage)
            cell.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource<Section, SidebarTab>(
            collectionView: collectionView
        ) { collectionView, indexPath, tab in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: tab
            )
        }
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, SidebarTab>()
        snapshot.appendSections([.tabs])
        snapshot.appendItems(sidebarTabs, toSection: .tabs)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Settings has no sidebar row on any platform: every user reaches
    /// the Debug Mode toggle through the system Settings app via the
    /// bundled `Settings.bundle` (Catalyst auto-renders it into the
    /// ⌘, preferences window; iOS/iPadOS show it in Settings.app).
    private var sidebarTabs: [SidebarTab] {
        SidebarTab.allCases
    }

    private func selectInitialTab() {
        // Restored section if set (and still a valid row), else the first tab.
        let target = initialTab.flatMap { sidebarTabs.contains($0) ? $0 : nil } ?? sidebarTabs.first
        guard
            let tab = target,
            let indexPath = dataSource.indexPath(for: tab)
        else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        didSelectTab(tab)
    }
}

extension SidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tab = dataSource.itemIdentifier(for: indexPath) else { return }
        didSelectTab(tab)
    }
}
