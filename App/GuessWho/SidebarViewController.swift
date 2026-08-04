import UIKit
import EventKit
import GuessWhoSync

/// What a sidebar row means to the scene: a section (the parent rows, which
/// behave exactly as they always have) or one favorited record shown as an
/// indented child under the section it belongs to.
enum SidebarSelection {
    case section(SidebarTab)
    /// The resolved favorite plus the section it hangs under, so the scene can
    /// mount that section's list and select the record's row in it.
    case favorite(FavoriteListItem, in: SidebarTab)
}

/// UIKit primary-column (sidebar) for the Catalyst 3-column shell.
///
/// An outline: every `SidebarTab` is a parent row, and each favorited record
/// hangs under the section it belongs to (a favorited person under People, an
/// organization under Organizations, an event under Events, a group under
/// Groups). Guides and Places never have children — favorites only exist for
/// contacts, events, and groups.
///
/// The parent row stays a normal selectable row: the disclosure chevron uses
/// the `.cell` style, so only the chevron expands/collapses and a click on
/// "People" still shows the People list. Sections without favorites show no
/// chevron at all.
final class SidebarViewController: UIViewController {
    /// Closure-based selection callback so the SceneDelegate can wire
    /// the sidebar to whichever content view controller is mounted in
    /// the supplementary column without us holding a hard reference to
    /// the split or the content VC.
    var didSelect: (SidebarSelection) -> Void = { _ in }

    /// The tab to select on first load. Defaults to the first sidebar row; state
    /// restoration sets it to the section that was showing when the app quit so
    /// the sidebar comes up already pointed there (no default → restored flash).
    var initialTab: SidebarTab?

    private let store: FavoritesListStore
    private let service: SyncService
    private let repository: ContactsRepository
    private let photoLoader: ContactPhotoLoader

    private enum Section: Int, CaseIterable {
        case tabs
    }

    /// Diffable identity for a sidebar row. A favorite is keyed on its opaque
    /// package-vended id (never on the resolved record), so a row survives the
    /// contact cache going empty→populated at cold launch — only its rendered
    /// content changes, which `reconfigureVisibleRows` repaints.
    private enum Item: Hashable {
        case section(SidebarTab)
        case favorite(FavoriteListItem.ID)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// The favorites hanging under each section, in the global favorites order.
    /// Rebuilt on every apply; also the source of truth for "does this section
    /// get a chevron" and for the drag-reorder's sibling list.
    private var favoriteChildren: [SidebarTab: [FavoriteListItem]] = [:]
    private var favoriteItemsByID: [FavoriteListItem.ID: FavoriteListItem] = [:]
    private var favoriteSections: [FavoriteListItem.ID: SidebarTab] = [:]

    /// Sections the user has open. Every section starts expanded so a freshly
    /// starred record is visible where it landed; an explicit collapse is
    /// remembered here and re-applied after every rebuild, so a favorite
    /// toggled elsewhere never re-opens a section the user closed.
    private var expandedSections: Set<SidebarTab> = Set(SidebarTab.allCases)

    /// In-flight thumbnail loads, keyed by contact so a rebuild can't stack
    /// duplicate fetches for the same row. The completion repaints through
    /// `reconfigureVisibleRows` rather than touching a cell directly, which is
    /// what makes it safe against reuse.
    private var photoTasks: [ContactID: Task<Void, Never>] = [:]

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var favoritesChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var contactsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var eventsChangedObserver: NSObjectProtocol?

    init(
        store: FavoritesListStore,
        service: SyncService,
        repository: ContactsRepository,
        photoLoader: ContactPhotoLoader
    ) {
        self.store = store
        self.service = service
        self.repository = repository
        self.photoLoader = photoLoader
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported — SidebarViewController is code-only")
    }

    deinit {
        let center = NotificationCenter.default
        if let favoritesChangedObserver { center.removeObserver(favoritesChangedObserver) }
        if let contactsChangedObserver { center.removeObserver(contactsChangedObserver) }
        if let eventsChangedObserver { center.removeObserver(eventsChangedObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "GuessWho"
        view.backgroundColor = .systemBackground

        configureCollectionView()
        configureDataSource()
        observeNotifications()
        // Build from whatever the favorites store has cached. DELIBERATELY does
        // not call `store.reload()`: the sidebar is built during scene connect,
        // and that read is a coordinated file read the store itself defers off
        // the launch path. Its deferred first read posts `.favoritesDidChange`,
        // which the observer above turns into a rebuild — children simply
        // appear a beat after the sections do.
        applySnapshot(animated: false)
        selectInitialTab()

        // Group favorites resolve against the repository's `groups` cache, which
        // only `loadGroups()` fills — and the sidebar is on screen long before
        // the Groups section ever is. Kick a load so a starred group renders its
        // name instead of "Unavailable"; the resulting `.contactsRepositoryDidReload`
        // rebuilds the children through the observer registered above.
        Task { await repository.loadGroups() }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
        config.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        // Drag-to-reorder favorites within their section. The drag delegate
        // vends nothing for a parent row (section reordering is not a feature)
        // and the drop delegate refuses a landing spot outside the row's own
        // section.
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let sectionRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarTab> {
            [weak self] cell, _, tab in
            var content = cell.defaultContentConfiguration()
            content.text = tab.title
            content.image = UIImage(systemName: tab.systemImage)
            cell.contentConfiguration = content
            // Chevron only when the section actually holds favorites, and the
            // `.cell` style so ONLY the chevron toggles — the default
            // (`.automatic`) resolves to `.header` at the root level, which
            // would swallow the click and stop "People" from showing the People
            // list.
            let hasChildren = !(self?.favoriteChildren[tab]?.isEmpty ?? true)
            cell.accessories = hasChildren ? [.outlineDisclosure(options: .init(style: .cell))] : []
        }

        let favoriteRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, FavoriteListItem.ID> {
            [weak self] cell, _, id in
            guard let self, let item = self.favoriteItemsByID[id] else { return }
            cell.contentConfiguration = self.contentConfiguration(for: item, in: cell)
            cell.accessories = []
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .section(let tab):
                return collectionView.dequeueConfiguredReusableCell(
                    using: sectionRegistration,
                    for: indexPath,
                    item: tab
                )
            case .favorite(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: favoriteRegistration,
                    for: indexPath,
                    item: id
                )
            }
        }
    }

    /// Row content for one favorite child. Mirrors `FavoritesListViewController`'s
    /// cell: one icon per kind (never branched on where the record's data comes
    /// from), a photo for people and organizations, and the same "Unavailable"
    /// wording for a record that hasn't resolved yet.
    private func contentConfiguration(
        for item: FavoriteListItem,
        in cell: UICollectionViewListCell
    ) -> UIListContentConfiguration {
        var content = cell.defaultContentConfiguration()
        // Sized to sit under the parent row's symbol without out-growing it.
        content.imageProperties.maximumSize = CGSize(width: Self.childIconSize, height: Self.childIconSize)

        switch item.kind {
        case .contact:
            guard let contact = item.contact else {
                content.text = Self.unavailableTitle
                content.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
                return content
            }
            // The nickname form every other contact row shows, but as plain
            // text: `nameAttributedString` carries the nickname AND pins the
            // body font, which would fight the sidebar's own row typography.
            content.text = contact.displayNameWithNickname
            content.imageProperties.cornerRadius = Self.childIconSize / 2
            let id = contact.contactID
            if let cached = photoLoader.cachedImage(for: id, kind: .thumbnail) {
                content.image = cached
            } else {
                content.image = ContactAvatarImage.placeholder(for: contact, diameter: Self.childIconSize)
                loadPhotoIfNeeded(for: id)
            }

        case .event:
            guard let event = item.event else {
                content.text = Self.unavailableTitle
                content.image = UIImage(systemName: "calendar.badge.exclamationmark")
                return content
            }
            content.text = event.title.isEmpty ? "(Untitled event)" : event.title
            // The Events list row's icon, which is also the Events section's —
            // one icon per kind.
            content.image = UIImage(systemName: SidebarTab.events.systemImage)

        case .group:
            guard let group = item.group else {
                content.text = Self.unavailableTitle
                content.image = UIImage(systemName: "person.3")
                return content
            }
            content.text = group.displayName
            content.image = UIImage(systemName: SidebarTab.groups.systemImage)
        }
        return content
    }

    /// Diameter of a child row's leading image, in points.
    private static let childIconSize: CGFloat = 20

    /// Shown for a favorite whose record can't be resolved (yet) — the same
    /// wording the Favorites list uses, so the two surfaces read alike.
    private static let unavailableTitle = "Unavailable"

    /// Fetch a thumbnail that isn't cached yet, then repaint the rows on screen.
    /// Going through the cache + a reconfigure (rather than handing the image to
    /// a cell) means a recycled cell can never show someone else's photo.
    private func loadPhotoIfNeeded(for id: ContactID) {
        guard photoTasks[id] == nil else { return }
        photoTasks[id] = Task { [weak self, photoLoader] in
            let image = await photoLoader.image(for: id, kind: .thumbnail)
            guard let self else { return }
            self.photoTasks[id] = nil
            // Repaint ONLY when there's something new to show. A contact with no
            // photo keeps its initials placeholder, and reconfiguring anyway
            // would re-enter the cell provider, find nothing cached, ask again,
            // and spin forever. (The loader negative-caches "no photo", so the
            // repeat asks that a later repaint does trigger are cache hits, not
            // Contacts fetches.)
            guard image != nil else { return }
            self.reconfigureVisibleRows()
        }
    }

    // MARK: - Snapshot wiring

    @MainActor
    private func observeNotifications() {
        let center = NotificationCenter.default

        // A star toggled in ContactDetailView / EventDetailView (or a swipe in
        // any list) reaches the sidebar here — the store has already reloaded
        // before it posts, so a rebuild is all that's needed. This is also how
        // the store's own deferred first read fills the children at launch.
        favoritesChangedObserver = center.addObserver(
            forName: .favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySnapshot(animated: true)
            }
        }

        // The favorites SET is unchanged here, but the records behind it resolve
        // against the repository's caches: at cold launch every contact and
        // group child renders "Unavailable" until the first reload lands. The
        // repository posts this after its launch reload, after incremental
        // external patches, and after its own writes — the same signal the
        // Favorites list leans on for exactly this reason.
        //
        // DEBOUNCED: the repository answers each `.guessWhoContactsDidChange`
        // with an immediate reload-or-patch and posts once per answer
        // (`ContactsRepository.contactsDidChange`, which has no debounce of its
        // own — only the sidecar signal gets one), and that inbound signal
        // bursts during contact sync. So this arrives in bursts too.
        contactsChangedObserver = center.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDebouncedRebuild()
            }
        }

        // Same story for events: an event renamed in Calendar.app would leave a
        // stale title on a child here, so watch the store the Favorites list
        // watches. This rebuild deliberately does NOT reload the favorites store
        // first (the Favorites list does): a Calendar edit can't change
        // `Favorites.json`, only the records the ids resolve to, so re-resolving
        // is the whole job and a coordinated file read would be pure overhead.
        //
        // Debounced for the same reason: `.EKEventStoreChanged` fires in bursts
        // during background calendar sync.
        eventsChangedObserver = center.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDebouncedRebuild()
            }
        }
    }

    /// The pending debounced rebuild, if any. Replaced (and the prior one
    /// cancelled) on every notification that feeds it, so a burst collapses into
    /// one rebuild on the trailing edge — the same shape as
    /// `EventsRepository`'s reload debounce and `ContactsRepository`'s sidecar
    /// refresh, which is the house pattern for this (there is no shared helper
    /// to reuse).
    ///
    /// It exists because a rebuild re-resolves EVERY favorited event through
    /// `service.event(uuid:)` — one sidecar file read each, on the main actor,
    /// which is the shape that has hung this app before.
    ///
    /// Both external-change feeds share it; only `.favoritesDidChange` stays
    /// immediate, because that is one post per user action and a lag before a
    /// just-starred child appeared would be felt. Direct `applySnapshot` calls
    /// stay immediate too.
    private var pendingRebuild: Task<Void, Never>?
    private static let rebuildDebounce: Duration = .milliseconds(300)

    private func scheduleDebouncedRebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.rebuildDebounce)
            } catch {
                return   // superseded by a newer notification
            }
            self?.applySnapshot(animated: true)
        }
    }

    /// Settings has no sidebar row on any platform: every user reaches
    /// the Debug Mode toggle through the system Settings app via the
    /// bundled `Settings.bundle` (Catalyst auto-renders it into the
    /// ⌘, preferences window; iOS/iPadOS show it in Settings.app).
    private var sidebarTabs: [SidebarTab] {
        SidebarTab.allCases
    }

    private func applySnapshot(animated: Bool) {
        rememberExpansionState()
        rebuildFavoriteChildren()

        // ONE section snapshot holds the whole outline: the parent rows at the
        // root and each section's favorites beneath their own parent.
        var snapshot = NSDiffableDataSourceSectionSnapshot<Item>()
        for tab in sidebarTabs {
            let parent = Item.section(tab)
            snapshot.append([parent])
            let children = (favoriteChildren[tab] ?? []).map { Item.favorite($0.id) }
            guard !children.isEmpty else { continue }
            snapshot.append(children, to: parent)
            if expandedSections.contains(tab) {
                snapshot.expand([parent])
            }
        }
        dataSource.apply(snapshot, to: .tabs, animatingDifferences: animated)

        // Every row here renders from state the diff can't see, so an apply
        // alone is not enough to repaint them:
        //
        // * a child's identity is its opaque favorite id, so a row whose
        //   RESOLVED content changed (the cold-launch empty→populated cache, a
        //   renamed group, an edited display name) produces an empty diff; and
        // * a PARENT's identity never changes at all, yet its chevron is built
        //   from `favoriteChildren[tab]` inside the cell registration. Starring
        //   the first record in an empty section would otherwise leave a child
        //   with no chevron to collapse it, and unstarring the last one would
        //   leave a chevron over a leaf. `expand(_:)` can't help — it rotates an
        //   existing disclosure accessory, it can't add or remove one. With
        //   seven rows and no scrolling, nothing ever re-dequeues to fix it.
        //
        // So re-run the cell provider for every row on screen; anything
        // offscreen builds fresh when it is dequeued.
        reconfigureVisibleRows()
    }

    /// Carry the user's expand/collapse choices across a rebuild. Only sections
    /// that currently SHOW children have a state worth remembering — a section
    /// whose last favorite was just removed has no chevron, and treating its
    /// (always false) expansion as a user choice would leave it collapsed when
    /// its next favorite arrives.
    private func rememberExpansionState() {
        guard dataSource != nil else { return }
        let current = dataSource.snapshot(for: .tabs)
        for (tab, children) in favoriteChildren where !children.isEmpty {
            let parent = Item.section(tab)
            guard current.contains(parent) else { continue }
            if current.isExpanded(parent) {
                expandedSections.insert(tab)
            } else {
                expandedSections.remove(tab)
            }
        }
    }

    /// Project the persisted favorites into per-section children. The package
    /// owns the resolution (`favoriteListItems`), so there is exactly one
    /// resolver for the Favorites list and the sidebar alike.
    private func rebuildFavoriteChildren() {
        let items = repository.favoriteListItems(from: store.items) { [service] uuid in
            service.event(uuid: uuid)
        }

        var children: [SidebarTab: [FavoriteListItem]] = [:]
        var byID: [FavoriteListItem.ID: FavoriteListItem] = [:]
        var sections: [FavoriteListItem.ID: SidebarTab] = [:]
        for item in items {
            let tab = Self.section(for: item)
            byID[item.id] = item
            sections[item.id] = tab
            children[tab, default: []].append(item)
        }
        favoriteChildren = children
        favoriteItemsByID = byID
        favoriteSections = sections
    }

    /// Which section a favorite hangs under. A contact splits by `contactType`
    /// exactly like the People / Organizations lists do; one that hasn't
    /// resolved yet has no type to read, so it waits under People (the section
    /// that shows people-shaped records) until the cache fills in.
    private static func section(for item: FavoriteListItem) -> SidebarTab {
        switch item.kind {
        case .contact:
            return item.contact?.contactType == .organization ? .organizations : .people
        case .event:
            return .events
        case .group:
            return .groups
        }
    }

    /// Re-run the cell provider for the rows on screen, keeping the existing
    /// cells. Safe for a parent: the chevron's open/closed rotation comes from
    /// the cell's configuration state, not from how the accessory was built, so
    /// rebuilding the accessory can't collapse an expanded section.
    ///
    /// The collection-view API rather than the snapshot's: an outline is driven
    /// by `NSDiffableDataSourceSectionSnapshot`, which has no `reconfigureItems`
    /// (only the flat `NSDiffableDataSourceSnapshot` does, and that one can't
    /// express the hierarchy).
    private func reconfigureVisibleRows() {
        let paths = collectionView.indexPathsForVisibleItems.filter { indexPath in
            dataSource.itemIdentifier(for: indexPath) != nil
        }
        guard !paths.isEmpty else { return }
        collectionView.reconfigureItems(at: paths)
    }

    // MARK: - Selection

    /// Programmatically select `tab`: highlight its row and fire
    /// `didSelect`, mirroring a user tap. Used when a deep link (e.g. an
    /// imported Apple Maps guide) needs to land the UI on a section.
    func select(_ tab: SidebarTab) {
        guard let indexPath = dataSource.indexPath(for: .section(tab)) else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        didSelect(.section(tab))
    }

    private func selectInitialTab() {
        // Restored section if set (and still a valid row), else the first tab.
        let target = initialTab.flatMap { sidebarTabs.contains($0) ? $0 : nil } ?? sidebarTabs.first
        guard let tab = target else { return }
        select(tab)
    }
}

extension SidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .section(let tab):
            didSelect(.section(tab))
        case .favorite(let id):
            guard let favorite = favoriteItemsByID[id], let tab = favoriteSections[id] else { return }
            didSelect(.favorite(favorite, in: tab))
        }
    }
}

// MARK: - Drag & drop reorder
//
// A favorite can be dragged among its siblings and nowhere else: parent rows
// are not draggable, and a landing spot outside the dragged row's own section
// is refused. Persistence rewrites ONLY that section's slots in the single
// global favorites array (`FavoritesOrder`), so the other kinds — and the
// Favorites list's view of them — keep their positions.

extension SidebarViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .favorite(let id) = item else { return [] }
        // Empty provider — nothing about a favorite should be exportable to an
        // outside drop target (see `FavoritesListViewController`). The id rides
        // along as `localObject`, which never leaves the process and tells the
        // drop path which section the drag started in.
        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = id
        return [dragItem]
    }
}

extension SidebarViewController: UICollectionViewDropDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard let id = draggedFavorite(in: session),
              let tab = favoriteSections[id],
              let range = insertionRange(for: tab),
              range.contains(resolvedDestination(destinationIndexPath).item)
        else {
            // Outside the row's own section (or a drag from another app):
            // refuse it rather than move a person under Events.
            return UICollectionViewDropProposal(operation: .cancel)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        let destinationIndexPath = resolvedDestination(coordinator.destinationIndexPath)
        guard let id = draggedFavorite(in: coordinator.session),
              let tab = favoriteSections[id],
              let siblings = favoriteChildren[tab],
              let source = siblings.firstIndex(where: { $0.id == id }),
              let range = insertionRange(for: tab),
              range.contains(destinationIndexPath.item)
        else { return }

        // Translate the visible-row insertion point into a position among this
        // section's own children. UIKit reports a PRE-removal index (the dragged
        // row is still in place), so a downward move lands one slot earlier once
        // it is pulled out.
        let destination = destinationIndexPath.item - range.lowerBound
        var order = siblings.map(\.id)
        let moved = order.remove(at: source)
        order.insert(moved, at: destination > source ? destination - 1 : destination)

        // Rewrite only this section's slots in the global array, then repaint.
        // `setOrder` reloads the store and posts `.favoritesDidChange`; the
        // explicit apply here doesn't wait for that round trip, so the row is
        // already in its new place when the drop animation finishes.
        store.setOrder(FavoritesOrder.reordered(store.items, sectionOrder: order))
        applySnapshot(animated: true)

        guard let landing = dataSource.indexPath(for: .favorite(id)) else { return }
        for item in coordinator.items {
            coordinator.drop(item.dragItem, toItemAt: landing)
        }
    }

    /// The favorite this session is dragging, or nil for a drag that didn't
    /// start on one of our rows (another app, or a parent row that vended no
    /// drag items).
    private func draggedFavorite(in session: UIDropSession) -> FavoriteListItem.ID? {
        session.items.lazy.compactMap { $0.localObject as? FavoriteListItem.ID }.first
    }

    /// UIKit reports no destination when the pointer is in the empty space below
    /// the last row. Read that as the end of the list, so a child of the LAST
    /// section can be dropped there instead of meeting a "no drop" cursor (the
    /// same end-of-list fallback `FavoritesListViewController` uses). Every
    /// other section still refuses it — `insertionRange` doesn't reach.
    private func resolvedDestination(_ destinationIndexPath: IndexPath?) -> IndexPath {
        destinationIndexPath
            ?? IndexPath(item: collectionView.numberOfItems(inSection: 0), section: 0)
    }

    /// Visible-row indices a child of `tab` may be dropped at: from its first
    /// child's row through one past its last. The upper bound is the row the
    /// next section header currently occupies — UIKit reports the same index
    /// for "after the last child" and "before the next header", and since the
    /// drag can only have started inside this section, it reads as the
    /// section's own last slot. Nil when the section shows no children (a
    /// collapsed section can't be a drag source in the first place).
    private func insertionRange(for tab: SidebarTab) -> ClosedRange<Int>? {
        let rows = (favoriteChildren[tab] ?? []).compactMap {
            dataSource.indexPath(for: .favorite($0.id))?.item
        }
        guard let first = rows.min(), let last = rows.max() else { return nil }
        return first...(last + 1)
    }
}
