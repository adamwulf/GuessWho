import Foundation
import GuessWhoSync

extension Notification.Name {
    /// Posted by `GuidesRepository.reload()` after a fetch completes.
    /// Parallels `.eventsRepositoryDidReload`; the guides and places list
    /// controllers subscribe to re-apply their diffable snapshots.
    static let guidesRepositoryDidReload = Notification.Name("GuidesRepositoryDidReload")

    /// Posted by `GuidePlaceResolver` when the place it is currently looking up
    /// changes (including pass start/end). The places list observes it to move
    /// its per-row "looking up now" spinner without a full data reload.
    static let guideResolutionActivePlaceDidChange = Notification.Name("GuideResolutionActivePlaceDidChange")
}

@MainActor
@Observable
final class GuidesRepository: NSObject {
    private let service: SyncService

    /// Live guides, ordered by `sortOrder`.
    private(set) var guides: [MapsGuide] = []

    /// Every live place, keyed by its guide — one sidecar walk backs both the
    /// guides list's place counts and each guide's places screen.
    private(set) var placesByGuide: [UUID: [MapsPlace]] = [:]

    private(set) var isLoading: Bool = false

    /// Relationship filter for every guide's Places page. It changes only
    /// the candidate rows returned by `places(inGuide:)`; `placeSortOrder`
    /// continues to order that filtered set.
    var placeFilter: LinkFilter = .all {
        didSet {
            guard placeFilter != oldValue else { return }
            NotificationCenter.default.post(name: .guidesRepositoryDidReload, object: self)
        }
    }

    /// Canonical place UUID strings participating in at least one live link.
    /// Reloaded with the rest of the sidecar-backed guide projection.
    private var linkedPlaceIDs: Set<String> = []

    /// The live sort order every guides list reads. Persistence is the app's
    /// job (`GuideSortOrderSetting` writes UserDefaults and sets this);
    /// setting it re-sorts in place and posts `.guidesRepositoryDidReload`
    /// so visible lists re-snapshot — same shape as
    /// `EventsRepository.sortOrder`. No-op (and no post) when unchanged.
    var sortOrder: GuideSortOrder = .recentlyAdded {
        didSet {
            guard sortOrder != oldValue else { return }
            guides = sortOrder.sorted(guides) { [weak self] in self?.placeCount(inGuide: $0) ?? 0 }
            NotificationCenter.default.post(name: .guidesRepositoryDidReload, object: self)
        }
    }

    /// The live sort order every guide's places list reads (global across all
    /// guides). Persistence is `PlaceSortOrderSetting`'s job; setting it
    /// re-sorts each guide's places in place and posts
    /// `.guidesRepositoryDidReload` so the open places list re-snapshots. The
    /// package's canonical `places(inGuide:)` stays in guide-entry order (the
    /// resolver relies on it); only this display copy is reordered.
    var placeSortOrder: PlaceSortOrder = .guideOrder {
        didSet {
            guard placeSortOrder != oldValue else { return }
            for guideID in placesByGuide.keys {
                placesByGuide[guideID] = placeSortOrder.sorted(placesByGuide[guideID] ?? [])
            }
            NotificationCenter.default.post(name: .guidesRepositoryDidReload, object: self)
        }
    }

    init(service: SyncService) {
        self.service = service
        super.init()
        // Refresh when sidecar files change on disk — a guide arriving from
        // another device, or a `notYetDownloaded` file materializing. Local
        // writes (import, resolution, delete) drive explicit `reload()` calls
        // from their call sites, so this observer only needs to cover the
        // external path. Same selector + debounce shape as `EventsRepository`.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: .guessWhoSidecarsDidChange,
            object: nil
        )
    }

    /// See `EventsRepository.storeDidChange` — the selector API delivers on
    /// the posting thread; hop to the main actor and debounce the burst.
    @objc
    private nonisolated func storeDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            self?.scheduleDebouncedReload()
        }
    }

    private var pendingReload: Task<Void, Never>?
    private static let reloadDebounce: Duration = .milliseconds(300)

    private func scheduleDebouncedReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.reloadDebounce)
            } catch {
                return   // superseded by a newer notification
            }
            await self?.reload()
        }
    }

    func reload() async {
        isLoading = true
        let fetchedGuides = await service.allGuides()
        let fetchedPlaces = await service.allPlaces()
        let fetchedLinkedPlaceIDs = await service.linkedEndpointIDs(ofKind: .place)

        // Build the per-guide place map BEFORE sorting the guides: the
        // `.placeCount` order sorts guides by how many places each has, so the
        // counts (which `placeCount(inGuide:)` reads from `placesByGuide`) must
        // be in place first.
        var byGuide: [UUID: [MapsPlace]] = [:]
        for place in fetchedPlaces {
            byGuide[place.guideID, default: []].append(place)
        }
        for guideID in byGuide.keys {
            byGuide[guideID] = placeSortOrder.sorted(byGuide[guideID] ?? [])
        }
        placesByGuide = byGuide
        linkedPlaceIDs = fetchedLinkedPlaceIDs

        guides = sortOrder.sorted(fetchedGuides) { [weak self] in self?.placeCount(inGuide: $0) ?? 0 }

        // Flip BEFORE posting so synchronous observers see the post-load
        // state — same ordering rationale as ContactsRepository.reload().
        isLoading = false
        NotificationCenter.default.post(name: .guidesRepositoryDidReload, object: self)
    }

    func places(inGuide guideID: UUID) -> [MapsPlace] {
        let places = placesByGuide[guideID] ?? []
        switch placeFilter {
        case .all:
            return places
        case .linked:
            return places.filter { linkedPlaceIDs.contains($0.id.uuidString.lowercased()) }
        }
    }

    /// Apply a drag-reorder of `guideID`'s places (source rows → destination
    /// row, `Array.move(fromOffsets:toOffset:)` semantics), persist the new
    /// entry order, and update the in-memory copy so the list repaints
    /// immediately without waiting for the debounced sidecar reload. Only used
    /// while the places list is in `.guideOrder` (the order this rewrites).
    /// Mirrors `FavoritesListStore.move(from:to:)`.
    func movePlaces(inGuide guideID: UUID, from source: IndexSet, to destination: Int) {
        guard var places = placesByGuide[guideID] else { return }
        places.move(fromOffsets: source, toOffset: destination)
        // Renumber sortOrder so the in-memory copy matches the cells we're
        // about to persist (and stays consistent if a reload races in).
        for index in places.indices {
            places[index].sortOrder = index
        }
        placesByGuide[guideID] = places
        service.reorderPlaces(inGuide: guideID, orderedIDs: places.map(\.id))
    }

    func placeCount(inGuide guideID: UUID) -> Int {
        placesByGuide[guideID]?.count ?? 0
    }
}
