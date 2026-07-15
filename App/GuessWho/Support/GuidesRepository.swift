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

    /// The live sort order every guides list reads. Persistence is the app's
    /// job (`GuideSortOrderSetting` writes UserDefaults and sets this);
    /// setting it re-sorts in place and posts `.guidesRepositoryDidReload`
    /// so visible lists re-snapshot — same shape as
    /// `EventsRepository.sortOrder`. No-op (and no post) when unchanged.
    var sortOrder: GuideSortOrder = .recentlyAdded {
        didSet {
            guard sortOrder != oldValue else { return }
            guides = sortOrder.sorted(guides)
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

        guides = sortOrder.sorted(fetchedGuides)

        var byGuide: [UUID: [MapsPlace]] = [:]
        for place in fetchedPlaces {
            byGuide[place.guideID, default: []].append(place)
        }
        for guideID in byGuide.keys {
            byGuide[guideID] = placeSortOrder.sorted(byGuide[guideID] ?? [])
        }
        placesByGuide = byGuide

        // Flip BEFORE posting so synchronous observers see the post-load
        // state — same ordering rationale as ContactsRepository.reload().
        isLoading = false
        NotificationCenter.default.post(name: .guidesRepositoryDidReload, object: self)
    }

    func places(inGuide guideID: UUID) -> [MapsPlace] {
        placesByGuide[guideID] ?? []
    }

    func placeCount(inGuide guideID: UUID) -> Int {
        placesByGuide[guideID]?.count ?? 0
    }
}
