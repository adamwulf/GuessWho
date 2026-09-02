import UIKit
import EventKit
import GuessWhoSync

/// What a sidebar row means to the scene: a section (the parent rows, which
/// behave exactly as they always have) or one favorited record shown as an
/// indented child under the section it belongs to.
enum SidebarSelection {
    case section(SidebarTab)
    /// An inferred organization parent has no favorite payload of its own, so
    /// route it by the same opaque contact identity the Organizations list uses.
    case organization(ContactID)
    /// The resolved favorite plus the section it hangs under, so the scene can
    /// mount that section's list and select the record's row in it.
    case favorite(FavoriteListItem, in: SidebarTab)
}

/// UIKit primary-column (sidebar) for the Catalyst 3-column shell.
///
/// An outline: every `SidebarTab` is a parent row, and each favorited record
/// hangs under the section it belongs to (a favorited person under People, an
/// organization under Organizations, an event under Events, a group under
/// Groups, a guide under Guides, a place under Places). Only the Favorites
/// section itself never has children.
///
/// The parent row stays a normal selectable row: a single click on "People"
/// shows the People list, and a DOUBLE click opens or closes that section's
/// favorites. There is no disclosure chevron — a closed section instead carries
/// a trailing badge counting the favorites it is hiding (e.g. "2 ★"). A section
/// with no favorites has no badge and nothing to open.
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
    /// The app-owned guides + places cache, backing the guide and place
    /// resolvers handed to `favoriteListItems` — see the Favorites list, which
    /// uses the same two.
    private let guidesRepository: GuidesRepository
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
        /// A non-favorited organization inferred from department favorites.
        case organization(ContactID)
    }

    private typealias FavoriteHierarchy = SidebarFavoriteHierarchy<
        SidebarTab,
        FavoriteListItem.ID,
        ContactID
    >

    private var collectionView: UICollectionView!

    /// The double-click-to-open recognizer, kept so the gesture delegate can
    /// answer for THAT recognizer specifically rather than for anything that
    /// happens to be routed here later.
    private weak var expansionToggle: UITapGestureRecognizer?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    /// The visible roots and nested department rows projected from global
    /// favorites order. Rebuilt on every apply and shared by snapshot building,
    /// badges, selection, and drag reorder.
    private var favoriteHierarchy = FavoriteHierarchy(entries: [])
    private var favoriteItemsByID: [FavoriteListItem.ID: FavoriteListItem] = [:]
    private var favoriteSections: [FavoriteListItem.ID: SidebarTab] = [:]
    private var organizationsByID: [ContactID: Contact] = [:]

    /// Sections the user has open. A section the user has never closed starts
    /// expanded, so a freshly starred record is visible where it landed; an
    /// explicit collapse is remembered here and re-applied after every rebuild,
    /// so a favorite toggled elsewhere never re-opens a section the user closed.
    ///
    /// Seeded from `SidebarExpansionSetting`, which persists the closed sections
    /// across launches. `didSet` writes every change straight back, so there is
    /// no separate "save" call to forget — see the note there on why the STORED
    /// form is the closed set rather than this one.
    private var expandedSections: Set<SidebarTab> = SidebarExpansionSetting.expanded {
        didSet {
            guard expandedSections != oldValue else { return }
            SidebarExpansionSetting.save(expanded: expandedSections)
        }
    }

    /// In-flight thumbnail loads, keyed by contact so a rebuild can't stack
    /// duplicate fetches for the same row. The completion repaints through
    /// `reconfigureVisibleRows`, which re-reads each visible cell's CURRENT
    /// item identifier from the data source before it paints that cell. If the
    /// cell the load started against was reused before the photo landed, it
    /// therefore renders the row that now occupies it, not the row that asked.
    private var photoTasks: [ContactID: Task<Void, Never>] = [:]

    /// See `ContactsListViewController.reloadObserver` for the
    /// `nonisolated(unsafe)` rationale.
    private nonisolated(unsafe) var favoritesChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var contactsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var eventsChangedObserver: NSObjectProtocol?
    private nonisolated(unsafe) var guidesChangedObserver: NSObjectProtocol?

    /// The right-click menu for a favorite CHILD row, routed by kind through the
    /// same `FavoriteContextMenuRouter` the Favorites list uses: a favorited
    /// person/organization gets "Add to Group", a favorited group gets Email All
    /// Members / Rename / Delete, and events/guides/places get none. Parent
    /// (section) rows have no menu. Lazy so it can capture `self` for the host and
    /// the row resolver.
    private lazy var favoriteContextMenus = FavoriteContextMenuRouter(
        repository: repository,
        favoritesStore: store,
        host: self,
        itemForRow: { [weak self] indexPath in
            guard let self,
                  let item = self.dataSource.itemIdentifier(for: indexPath),
                  case .favorite(let id) = item else { return nil }
            return self.favoriteItemsByID[id]
        },
        contactForRow: { [weak self] indexPath in
            guard let self,
                  let item = self.dataSource.itemIdentifier(for: indexPath),
                  case .organization(let id) = item else { return nil }
            return self.organizationsByID[id] ?? self.repository.contact(id: id)
        }
    )

    init(
        store: FavoritesListStore,
        service: SyncService,
        repository: ContactsRepository,
        guidesRepository: GuidesRepository,
        photoLoader: ContactPhotoLoader
    ) {
        self.store = store
        self.service = service
        self.repository = repository
        self.guidesRepository = guidesRepository
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
        if let guidesChangedObserver { center.removeObserver(guidesChangedObserver) }
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

        // Same story for guides and places, whose cache only
        // `GuidesRepository.reload()` fills — and the sidebar is on screen
        // before either of those sections is. Its `.guidesRepositoryDidReload`
        // rebuilds the children through the observer registered above.
        Task { await guidesRepository.reload() }
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

        // Double-click a section row to open or close it. This recognizer only
        // OBSERVES the click — the collection view keeps its own handling of it,
        // so one click still selects the row and shows that section's list, and
        // a double click does both. All three settings are needed for that:
        // `cancelsTouchesInView = false` stops a recognized double click from
        // swallowing the clicks the collection view was already given,
        // `delaysTouchesEnded = false` lets the first click land immediately
        // instead of waiting to see whether a second one follows, and the
        // delegate lets us and the collection view's own recognizers run
        // together rather than one blocking the other.
        let toggle = UITapGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        toggle.numberOfTapsRequired = 2
        toggle.cancelsTouchesInView = false
        toggle.delaysTouchesEnded = false
        toggle.delegate = self
        collectionView.addGestureRecognizer(toggle)
        expansionToggle = toggle

        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let sectionRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SidebarTab> {
            [weak self] cell, _, tab in
            self?.configure(cell, for: .section(tab))
        }

        let favoriteRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, FavoriteListItem.ID> {
            [weak self] cell, _, id in
            self?.configure(cell, for: .favorite(id))
        }

        let organizationRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ContactID> {
            [weak self] cell, _, id in
            self?.configure(cell, for: .organization(id))
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
            case .organization(let id):
                return collectionView.dequeueConfiguredReusableCell(
                    using: organizationRegistration,
                    for: indexPath,
                    item: id
                )
            }
        }
    }

    /// Paint `cell` for `item`. The one place a sidebar row's appearance is
    /// defined, shared by the cell registrations (on dequeue) and by
    /// `reconfigureVisibleRows` (on a repaint), so the two can never drift.
    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        switch item {
        case .section(let tab):
            var content = cell.defaultContentConfiguration()
            content.text = tab.title
            content.image = UIImage(systemName: tab.systemImage)
            cell.contentConfiguration = content
            // A closed section says how many favorites it is hiding; an open one
            // is already showing them, so it says nothing. A section with no
            // favorites has nothing to count and nothing to open.
            let count = favoriteHierarchy.favoriteCount(in: tab)
            let isClosed = !expandedSections.contains(tab)
            cell.accessories = (count > 0 && isClosed) ? [favoritesCountAccessory(count: count)] : []

            // A double click is a mouse-only affordance, so it can't be the ONLY
            // way to open a section — the outline chevron this replaced was a
            // real control that assistive technology could reach. A custom
            // action is the documented way to put the toggle back in front of
            // VoiceOver.
            //
            // NOT yet verified, and it covers this whole block — the action
            // below, the value below that, and the badge's own label:
            //
            // * Everything here is set on the CELL. `UICollectionViewCell` is an
            //   accessibility CONTAINER by default rather than an element (unlike
            //   `UITableViewCell`), and how a list cell aggregates its content
            //   view is undocumented — neither `UIListContentConfiguration.h` nor
            //   `UICollectionViewListCell.h` mentions accessibility at all. So
            //   whether what is spoken comes from these properties or from the
            //   content view inside is untested. One VoiceOver pass settles the
            //   lot; they stand or fall together.
            // * Whether Catalyst's Full Keyboard Access surfaces UIKit custom
            //   actions is unconfirmed.
            // * A sighted keyboard user running neither VoiceOver nor FKA still
            //   has no way to open a section — the chevron was clickable, none
            //   of this is.
            cell.accessibilityCustomActions = count > 0
                ? [expansionAction(for: tab, isClosed: isClosed)]
                : nil

            // The open/closed state, spoken. VoiceOver reads an element's value
            // on focus and does NOT read an action's name there (actions live
            // behind the Actions rotor), so without this the only cue is the
            // badge — "2 favorites" when closed, nothing at all when open. That
            // reads as an absence, not as a state. A section with nothing to
            // open has no state to report.
            //
            // Subject to the caveat above: that VoiceOver is right about the
            // general rule doesn't prove a value set HERE, on the cell, is the
            // one spoken.
            cell.accessibilityValue = count > 0 ? (isClosed ? "Collapsed" : "Expanded") : nil
        case .favorite(let id):
            guard let favorite = favoriteItemsByID[id] else { return }
            cell.contentConfiguration = contentConfiguration(for: favorite, in: cell)
            cell.accessories = []
            // Cleared for the same reason as `accessories`: a child has no
            // section to open, so it has neither an action nor a state to
            // report. Nothing can carry one over today — the two cell
            // registrations have separate reuse pools — but leaving the resets
            // asymmetric is a trap if they are ever merged.
            cell.accessibilityCustomActions = nil
            cell.accessibilityValue = nil
        case .organization(let id):
            let organization = organizationsByID[id] ?? repository.contact(id: id)
            cell.contentConfiguration = contactContentConfiguration(for: organization, in: cell)
            cell.accessories = []
            cell.accessibilityCustomActions = nil
            cell.accessibilityValue = nil
        }
    }

    /// The trailing badge on a closed section: the number of favorites hiding
    /// under it, beside a star. Built as a custom view rather than
    /// `.label(text:)` so the star is the same SF Symbol the rest of the app
    /// uses for a favorite, at the label's own text size.
    private func favoritesCountAccessory(count: Int) -> UICellAccessory {
        let label = UILabel()
        label.text = "\(count)"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        // Read as "2 favorites", not a bare "2" — the star carries that meaning
        // visually and says nothing out loud.
        label.accessibilityLabel = count == 1 ? "1 favorite" : "\(count) favorites"

        let star = UIImageView(
            image: UIImage(
                systemName: "star.fill",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1)
            )
        )
        star.tintColor = .secondaryLabel
        star.isAccessibilityElement = false

        let badge = UIStackView(arrangedSubviews: [label, star])
        badge.axis = .horizontal
        badge.alignment = .center
        badge.spacing = 2

        return .customView(configuration: .init(customView: badge, placement: .trailing()))
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
            applyContact(item.contact, to: &content)

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

        case .guide:
            guard let guide = item.guide else {
                content.text = Self.unavailableTitle
                // SF Symbols has no badged `map`, so an unresolved guide gets
                // the neutral glyph rather than one from a different family.
                content.image = UIImage(systemName: "questionmark.circle")
                return content
            }
            let guideName = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
            content.text = guideName.isEmpty ? "(Unnamed Guide)" : guideName
            content.image = UIImage(systemName: SidebarTab.guides.systemImage)

        case .place:
            guard let place = item.place else {
                content.text = Self.unavailableTitle
                content.image = UIImage(systemName: "mappin.slash")
                return content
            }
            content.text = Self.placeTitle(place)
            content.image = UIImage(systemName: SidebarTab.places.systemImage)

        case .department:
            // The department row's icon on the organization page — one icon per
            // kind, never branched on where the data comes from.
            content.image = UIImage(systemName: "person.2")
            guard let department = item.department else {
                content.text = Self.unavailableTitle
                return content
            }
            content.text = department.department
        }
        return content
    }

    /// The shared organization/person row appearance. Structural organization
    /// parents deliberately use this exact path so an inferred row is visually
    /// indistinguishable from a favorited organization row.
    private func contactContentConfiguration(
        for contact: Contact?,
        in cell: UICollectionViewListCell
    ) -> UIListContentConfiguration {
        var content = cell.defaultContentConfiguration()
        content.imageProperties.maximumSize = CGSize(
            width: Self.childIconSize,
            height: Self.childIconSize
        )
        applyContact(contact, to: &content)
        return content
    }

    private func applyContact(
        _ contact: Contact?,
        to content: inout UIListContentConfiguration
    ) {
        guard let contact else {
            content.text = Self.unavailableTitle
            content.image = UIImage(systemName: "person.crop.circle.badge.questionmark")
            return
        }
        // The nickname form every other contact row shows, but as plain text:
        // `nameAttributedString` carries the nickname AND pins the body font,
        // which would fight the sidebar's own row typography.
        content.text = contact.displayNameWithNickname
        content.imageProperties.cornerRadius = Self.childIconSize / 2
        let id = contact.contactID
        if let cached = photoLoader.cachedImage(for: id, kind: .thumbnail) {
            content.image = cached
        } else {
            content.image = ContactAvatarImage.placeholder(for: contact, diameter: Self.childIconSize)
            loadPhotoIfNeeded(for: id)
        }
    }

    /// One line for a place child: its name, or its address when the entry
    /// carries no business name, or a neutral placeholder while a place-ID
    /// entry is still waiting on its MapKit lookup. The sidebar shows a single
    /// line per row, so unlike the Favorites list there is no address caption
    /// underneath.
    private static func placeTitle(_ place: MapsPlace) -> String {
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let address = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !address.isEmpty { return address }
        return "(No details)"
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
            // photo keeps its initials placeholder, and repainting anyway would
            // re-enter `configure(_:for:)`, find nothing cached, ask again, and
            // spin forever. (The loader negative-caches "no photo", so the
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
        // with an immediate reload-or-patch and posts at least once per answer
        // (`ContactsRepository.contactsDidChange`, which has no debounce of its
        // own — only the sidecar signal gets one; a full reload that carries
        // pending creation-timestamp repairs posts again), and that inbound
        // signal bursts during contact sync. So this arrives in bursts too.
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

        // And the same for guides and places: a guide renamed on another
        // device, a place whose MapKit lookup just landed, or the reload kicked
        // from `viewDidLoad` all arrive here. Like the events feed this does NOT
        // reload the favorites store — a guides change can't rewrite
        // `Favorites.json`, only the records the ids resolve to. Shares the
        // debounce because the repository's own reloads are already bursty.
        guidesChangedObserver = center.addObserver(
            forName: .guidesRepositoryDidReload,
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

        // ONE section snapshot holds the whole outline: section rows at the
        // root, ordinary favorites below them, and department favorites one
        // level deeper beneath their organization.
        var snapshot = NSDiffableDataSourceSectionSnapshot<Item>()
        for tab in sidebarTabs {
            let parent = Item.section(tab)
            snapshot.append([parent])
            let roots = favoriteHierarchy.roots(in: tab)
            guard !roots.isEmpty else { continue }
            snapshot.append(roots.map(item(for:)), to: parent)

            for root in roots {
                let rootItem = item(for: root)
                let children = favoriteHierarchy.children(of: root).map(item(for:))
                guard !children.isEmpty else { continue }
                snapshot.append(children, to: rootItem)
                // Organization rows are not user-controlled outline sections:
                // they always start expanded and every rebuild reasserts that.
                snapshot.expand([rootItem])
            }
            if expandedSections.contains(tab) {
                snapshot.expand([parent])
            }
        }
        // Every row here renders from state the diff can't see, so an apply
        // alone is not enough to repaint them:
        //
        // * a child's identity is its opaque favorite id, so a row whose
        //   RESOLVED content changed (the cold-launch empty→populated cache, a
        //   renamed group, an edited display name) produces an empty diff; and
        // * a PARENT's identity never changes at all, yet its badge is built
        //   from `favoriteHierarchy` inside `configure(_:for:)`. Starring a
        //   record in a closed section would otherwise leave the old count on
        //   screen, and unstarring the last one would leave a badge over a
        //   section that no longer hides anything. A parent that stays on screen
        //   is never re-dequeued, so nothing else would fix it.
        //
        // So repaint every row on screen; anything offscreen builds fresh when
        // it is dequeued.
        //
        // From the completion rather than the next line, so the repaint reads
        // `indexPathsForVisibleItems` after the apply completes rather than
        // during the animation, where how visible index paths pair with cells is
        // not documented. The completion is the form Apple documents for "after
        // the apply", and it runs on the main queue.
        dataSource.apply(snapshot, to: .tabs, animatingDifferences: animated) { [weak self] in
            self?.reconfigureVisibleRows()
        }
    }

    /// Carry the user's expand/collapse choices across a rebuild. Only sections
    /// that currently SHOW children have a state worth remembering — a section
    /// whose last favorite was just removed can't be opened at all, and treating
    /// its (always false) expansion as a user choice would leave it collapsed
    /// when its next favorite arrives.
    ///
    /// MUST run BEFORE `rebuildFavoriteChildren`, so that `favoriteHierarchy`
    /// still describes what is on screen — the same thing the snapshot it reads
    /// describes. Run it after, and it would ask `isExpanded` about parents that
    /// have no children in the CURRENT snapshot and get false for each one,
    /// dropping them from `expandedSections`. At cold launch that is EVERY
    /// section, because the map goes empty→populated in one step. And it is no
    /// longer merely a display glitch: `expandedSections` is persisted on write,
    /// so it would save "everything closed" and every later launch would honour
    /// it.
    private func rememberExpansionState() {
        guard dataSource != nil else { return }
        let current = dataSource.snapshot(for: .tabs)
        for tab in sidebarTabs where favoriteHierarchy.favoriteCount(in: tab) > 0 {
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
        // Same resolvers the Favorites list passes — see
        // `FavoritesListViewController.applySnapshot` for the id-parsing notes.
        let items = repository.favoriteListItems(
            from: store.items,
            event: { [service] uuid in service.event(uuid: uuid) },
            guide: { [guidesRepository] uuid in
                UUID(uuidString: uuid).flatMap { guidesRepository.guide(id: $0) }
            },
            place: { [guidesRepository] uuid in
                UUID(uuidString: uuid).flatMap { guidesRepository.place(id: $0) }
            }
        )

        var byID: [FavoriteListItem.ID: FavoriteListItem] = [:]
        var sections: [FavoriteListItem.ID: SidebarTab] = [:]
        var organizations: [ContactID: Contact] = [:]
        var entries: [FavoriteHierarchy.Entry] = []
        for item in items {
            let tab = Self.section(for: item)
            byID[item.id] = item
            sections[item.id] = tab
            let role: FavoriteHierarchy.Role
            switch item.kind {
            case .contact:
                if let contact = item.contact, contact.contactType == .organization {
                    let id = contact.contactID
                    organizations[id] = contact
                    role = .organization(id)
                } else {
                    role = .regular
                }
            case .department:
                if let department = item.department {
                    let organization = department.organization
                    let id = organization.contactID
                    organizations[id] = organization
                    role = .department(id)
                } else {
                    role = .department(nil)
                }
            case .event, .group, .guide, .place:
                role = .regular
            }
            entries.append(.init(id: item.id, section: tab, role: role))
        }
        favoriteHierarchy = FavoriteHierarchy(entries: entries)
        favoriteItemsByID = byID
        favoriteSections = sections
        organizationsByID = organizations
    }

    private func item(for row: FavoriteHierarchy.Row) -> Item {
        switch row {
        case .favorite(let id):
            return .favorite(id)
        case .organization(let id):
            return .organization(id)
        }
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
        case .guide:
            return .guides
        case .place:
            return .places
        case .department:
            return .organizations
        }
    }

    /// Repaint the rows on screen, keeping the existing cells. Safe for a
    /// parent: a section's open/closed state lives in the section snapshot, not
    /// in anything painted here, so rebuilding a parent's accessories can't
    /// close an open section.
    ///
    /// This re-applies `configure(_:for:)` to each visible cell rather than
    /// asking the collection view to reconfigure them. `UICollectionView`
    /// raises `NSInternalInconsistencyException` ("must be updated via the
    /// UICollectionViewDiffableDataSource APIs") for `reconfigureItems(at:)`
    /// and every other direct mutation while a diffable data source is its
    /// `dataSource` — on Catalyst that fires during the first layout and the
    /// half-finished update segfaults the process a moment later. The snapshot
    /// API is not an option either: an outline is driven by
    /// `NSDiffableDataSourceSectionSnapshot`, which has no `reconfigureItems`
    /// (only the flat `NSDiffableDataSourceSnapshot` does, and that one can't
    /// express the hierarchy). Writing the configuration straight onto the cell
    /// mutates neither, so it is safe from both sides.
    private func reconfigureVisibleRows() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                  let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
            else { continue }
            configure(cell, for: item)
        }
    }

    // MARK: - Expand / collapse

    /// Open or close the section row under a double click. A click that lands
    /// on a favorite, on empty space, or on a section with no favorites has
    /// nothing to toggle.
    @objc
    private func handleDoubleClick(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let item = dataSource.itemIdentifier(for: indexPath),
              case .section(let tab) = item
        else { return }
        toggleExpansion(of: tab)
    }

    /// The VoiceOver / Full Keyboard Access equivalent of double-clicking the
    /// row. Named for what it will DO, which is the convention for a custom
    /// action, and in the user's own words — favorites, not internal vocabulary.
    private func expansionAction(for tab: SidebarTab, isClosed: Bool) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(
            name: isClosed ? "Show Favorites" : "Hide Favorites"
        ) { [weak self] _ in
            self?.toggleExpansion(of: tab)
            return true
        }
    }

    /// Flip `tab` between open and closed.
    ///
    /// This edits the live section snapshot directly instead of going through
    /// `applySnapshot`, which would undo the toggle: `applySnapshot` starts by
    /// calling `rememberExpansionState`, and that reads the state back off the
    /// snapshot we have not written yet — so it would overwrite the new value
    /// with the old one before applying.
    private func toggleExpansion(of tab: SidebarTab) {
        guard favoriteHierarchy.favoriteCount(in: tab) > 0 else { return }
        let parent = Item.section(tab)
        var snapshot = dataSource.snapshot(for: .tabs)
        guard snapshot.contains(parent) else { return }

        if snapshot.isExpanded(parent) {
            snapshot.collapse([parent])
            expandedSections.remove(tab)
        } else {
            snapshot.expand([parent])
            expandedSections.insert(tab)
        }
        // The parent's own badge appears or disappears with the toggle, and its
        // identity did not change, so the apply alone will not repaint it. From
        // the completion for the same reason as in `applySnapshot`.
        dataSource.apply(snapshot, to: .tabs, animatingDifferences: true) { [weak self] in
            guard let self else { return }
            self.reconfigureVisibleRows()

            // Rows just appeared or disappeared, so VoiceOver's picture of this
            // screen is stale. This SPEAKS nothing — `.layoutChanged` refreshes
            // the element map and optionally moves focus; it is not an
            // announcement. Naming the section's own cell pins focus to the row
            // the user acted on instead of leaving the landing spot unspecified
            // after the removed rows.
            //
            // What they hear on that focus is the row's label and VALUE. NOT the
            // action's name — Apple surfaces custom actions through the Actions
            // rotor, behind a deliberate user cue — which is why the open/closed
            // state is carried by `accessibilityValue` in `configure(_:for:)`.
            let toggled = self.dataSource.indexPath(for: .section(tab))
                .flatMap { self.collectionView.cellForItem(at: $0) }
            UIAccessibility.post(notification: .layoutChanged, argument: toggled)
        }
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

extension SidebarViewController: UIGestureRecognizerDelegate {
    /// Let the double-click recognizer run alongside the collection view's own
    /// selection and drag recognizers instead of excluding them.
    ///
    /// Belt-and-braces, not the actual cure: what broke single clicks was touch
    /// DELIVERY, not recognizer arbitration. A tap recognizer withholds
    /// `touchesEnded` from the view while it is still deciding, and cancels it
    /// outright once it recognizes — which `delaysTouchesEnded = false` and
    /// `cancelsTouchesInView = false` are what actually fix. This only removes
    /// the remaining mutual exclusion.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Answer only for our own recognizer. `true` here is documented to
        // GUARANTEE simultaneous recognition, so it overrides UIKit's own
        // exclusivity rules — worth granting narrowly rather than to whatever
        // else might be pointed at this delegate later.
        gestureRecognizer === expansionToggle
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
        case .organization(let id):
            didSelect(.organization(id))
        }
    }

    /// Right-click a favorite child to get the same menu that record has in its
    /// own list — the router returns nil for a parent (section) row and for kinds
    /// with no menu, so those are unaffected. Opening the menu never changes the
    /// sidebar selection.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        favoriteContextMenus.configuration(forRowAt: indexPath)
    }
}

// MARK: - GroupContextMenuEmailResponder

extension SidebarViewController: GroupContextMenuEmailResponder {
    // A favorited group's Catalyst Email command fires down the responder chain
    // (see `GroupContextMenu.emailElements`); forward it to the router that built
    // it. `individually` is what the Option alternate selects.
    func emailGroupMembers(_ sender: UICommand) {
        favoriteContextMenus.handleGroupEmailCommand(sender, individually: false)
    }

    func emailGroupMembersSeparately(_ sender: UICommand) {
        favoriteContextMenus.handleGroupEmailCommand(sender, individually: true)
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
              case .favorite(let id) = item,
              isDraggableFavorite(id) else { return [] }
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
              let context = reorderContext(for: id),
              context.range.contains(resolvedDestination(destinationIndexPath).item)
        else {
            // Outside the row's own sibling list (or a drag from another app):
            // refuse it rather than move a person under Events or a department
            // beneath a different organization.
            return UICollectionViewDropProposal(operation: .cancel)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        let destinationIndexPath = resolvedDestination(coordinator.destinationIndexPath)
        guard let id = draggedFavorite(in: coordinator.session),
              let context = reorderContext(for: id),
              context.range.contains(destinationIndexPath.item)
        else { return }

        // Translate the flat visible-row insertion point into this hierarchy
        // level. Nested department rows make root sibling indices noncontiguous:
        // any destination inside a root's subtree counts as after that root.
        // UIKit reports a pre-removal index, so a downward move lands one slot
        // earlier once the source block is out (the pure index math is unit
        // tested on `SidebarFavoriteHierarchy`).
        let rows = FavoriteHierarchy.rowsAfterMoving(
            context.rows,
            from: context.source,
            rowStarts: context.rowStarts,
            toVisibleIndex: destinationIndexPath.item)

        // A root row is a block: a favorited organization contributes its own
        // favorite id plus its departments, while a structural organization
        // contributes only its departments. Flattening the reordered blocks
        // lets the unchanged package primitive refill precisely those global
        // slots. A department-level reorder has one id per block and therefore
        // rewrites only that organization's department slots.
        let order = favoriteHierarchy.flattenedFavoriteIDs(in: rows)

        // Rewrite only this sibling scope's slots in the global array, then repaint.
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

    /// Structural organizations are never favorites and already vend no drag
    /// item. An unresolved department also has no same-organization sibling
    /// scope, so it stays visible/removable but does not begin a misleading drag.
    private func isDraggableFavorite(_ id: FavoriteListItem.ID) -> Bool {
        guard let item = favoriteItemsByID[id] else { return false }
        guard item.kind == .department else { return true }
        guard case .row = favoriteHierarchy.parent(of: id) else { return false }
        return true
    }

    /// UIKit reports no destination when the pointer is in the empty space below
    /// the last row. Read that as the end of the list, so a child of the LAST
    /// section can be dropped there instead of meeting a "no drop" cursor (the
    /// same end-of-list fallback `FavoritesListViewController` uses). Every
    /// other sibling scope still refuses it — its `reorderContext` range
    /// doesn't reach.
    private func resolvedDestination(_ destinationIndexPath: IndexPath?) -> IndexPath {
        destinationIndexPath
            ?? IndexPath(item: collectionView.numberOfItems(inSection: 0), section: 0)
    }

    private typealias ReorderContext = (
        rows: [FavoriteHierarchy.Row],
        source: Int,
        rowStarts: [Int],
        range: ClosedRange<Int>
    )

    /// The direct sibling list containing `id`, plus its visible insertion
    /// range. Root rows may have department descendants between their visible
    /// indices, so the range ends after the last sibling's whole subtree rather
    /// than one row after the last sibling itself.
    private func reorderContext(for id: FavoriteListItem.ID) -> ReorderContext? {
        guard isDraggableFavorite(id),
              let parent = favoriteHierarchy.parent(of: id)
        else { return nil }

        let rows: [FavoriteHierarchy.Row]
        switch parent {
        case .section(let tab):
            rows = favoriteHierarchy.roots(in: tab)
        case .row(let row):
            rows = favoriteHierarchy.children(of: row)
        }

        let sourceRow = FavoriteHierarchy.Row.favorite(id)
        guard let source = rows.firstIndex(of: sourceRow) else { return nil }
        let rowStarts = rows.compactMap {
            dataSource.indexPath(for: item(for: $0))?.item
        }
        guard rowStarts.count == rows.count,
              let first = rowStarts.first,
              let lastRow = rows.last,
              let last = lastVisibleIndex(includingDescendantsOf: lastRow)
        else { return nil }
        return (rows, source, rowStarts, first...(last + 1))
    }

    private func lastVisibleIndex(
        includingDescendantsOf row: FavoriteHierarchy.Row
    ) -> Int? {
        var indices = [dataSource.indexPath(for: item(for: row))?.item].compactMap { $0 }
        indices.append(contentsOf: favoriteHierarchy.children(of: row).compactMap {
            dataSource.indexPath(for: item(for: $0))?.item
        })
        return indices.max()
    }
}
