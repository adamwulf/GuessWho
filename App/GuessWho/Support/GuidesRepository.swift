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

/// One section of the unified Places tab. The `.byGuide` order produces one
/// section per guide (plus, rarely, a trailing untitled bucket for places
/// whose guide sidecar hasn't synced yet); the flat orders produce a single
/// untitled section.
struct UnifiedPlaceSection {
    /// The owning guide, or nil for the flat single section and the orphan
    /// bucket. Doubles as the diffable section identity (nil is free for the
    /// no-guide cases because grouped and flat sections never coexist).
    let guideID: UUID?
    /// Section header text (the guide's name); nil when the section shouldn't
    /// render a header.
    let title: String?
    let places: [MapsPlace]
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
            notificationCenter.post(name: .guidesRepositoryDidReload, object: self)
        }
    }

    /// Canonical place UUID strings participating in at least one live link.
    /// Reloaded with the rest of the sidecar-backed guide projection.
    private var linkedPlaceIDs: Set<String> = []

    /// Per-place link COUNT keyed by lowercased place UUID string. Powers the
    /// "N links" list badge; reloaded in the same pass as `linkedPlaceIDs`. A
    /// place with no entry has zero links and shows no badge.
    private var linkCountsByID: [String: Int] = [:]

    /// The live sort order every guides list reads. Persistence is the app's
    /// job (`GuideSortOrderSetting` writes UserDefaults and sets this);
    /// setting it re-sorts in place and posts `.guidesRepositoryDidReload`
    /// so visible lists re-snapshot — same shape as
    /// `EventsRepository.sortOrder`. No-op (and no post) when unchanged.
    var sortOrder: GuideSortOrder = .recentlyAdded {
        didSet {
            guard sortOrder != oldValue else { return }
            guides = sortOrder.sorted(guides) { [weak self] in self?.placeCount(inGuide: $0) ?? 0 }
            notificationCenter.post(name: .guidesRepositoryDidReload, object: self)
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
            notificationCenter.post(name: .guidesRepositoryDidReload, object: self)
        }
    }

    /// The live sort order the unified Places tab reads. Persistence is
    /// `AllPlacesSortOrderSetting`'s job — same shape as `placeSortOrder`,
    /// but deliberately a SEPARATE property: re-sorting the cross-guide tab
    /// must not silently reorder every guide's own places screen. No stored
    /// copy to re-sort here — `unifiedPlaceSections()` computes on demand —
    /// so the setter only posts the reload.
    var allPlacesSortOrder: AllPlacesSortOrder = .byGuide {
        didSet {
            guard allPlacesSortOrder != oldValue else { return }
            notificationCenter.post(name: .guidesRepositoryDidReload, object: self)
        }
    }

    /// The center this repository observes `.guessWhoSidecarsDidChange` on AND
    /// posts `.guidesRepositoryDidReload` to. Defaults to `.default` so
    /// production wiring is unchanged (the live watcher posts there, and the
    /// list controllers observe there). It is INJECTABLE solely for test
    /// isolation — a fresh `NotificationCenter()` per test repository confines
    /// both its observers and its posts to that test, exactly as
    /// `ContactsRepository` and `EventsRepository` do for the same reason.
    private let notificationCenter: NotificationCenter

    init(service: SyncService, notificationCenter: NotificationCenter = .default) {
        self.service = service
        self.notificationCenter = notificationCenter
        super.init()
        // Refresh when sidecar files change on disk — a guide arriving from
        // another device, or a `notYetDownloaded` file materializing. Local
        // writes (import, resolution, delete) drive explicit `reload()` calls
        // from their call sites, so this observer only needs to cover the
        // external path. Same selector + debounce shape as `EventsRepository`.
        notificationCenter.addObserver(
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
        let changeSet = note.guessWhoSidecarChangeSet
        Task { @MainActor [weak self] in
            self?.scheduleDebouncedReload(changeSet)
        }
    }

    private var pendingReload: Task<Void, Never>?
    private var pendingChangeSet: SidecarChangeSet?
    private static let reloadDebounce: Duration = .milliseconds(300)

    /// Monotonic refresh token. Bumped whenever a NEWER authoritative refresh
    /// intent begins — a sidecar-change notification (`scheduleDebouncedReload`)
    /// or a direct `reload()` (import, delete, list mount, sort change) — and
    /// captured by the task that will read. Every async read path re-checks the
    /// token still holds the current value before it mutates published state or
    /// posts `.guidesRepositoryDidReload`, so an older read that resumes after a
    /// newer one cannot publish its stale projection (newest-request-wins, the
    /// same shape as `ContactsRepository.groupLoadRequestGeneration` and
    /// `EventsRepository`). A delta that must fall back to a full reload passes
    /// its token so the fallback does not supersede itself.
    private var refreshGeneration = 0

    /// True once a full `reload()` has published a complete projection. A delta
    /// `refresh` may only PATCH a complete base — before the first full load
    /// lands (e.g. a sidecar change racing the launch reload) it upgrades itself
    /// to a full reload under the same token rather than stranding a partial
    /// guides/places projection.
    private var hasLoadedOnce = false

    /// Bump the generation and return the new token. Every fresh authoritative
    /// refresh intent calls this exactly once.
    private func nextRefreshToken() -> Int {
        refreshGeneration &+= 1
        return refreshGeneration
    }

    /// Test seam (nil in production, no behavior change): a barrier awaited once
    /// inside `reload(token:)` AFTER its reads complete and BEFORE it publishes,
    /// so a test can hold a stale read in flight while it drives a newer refresh
    /// and prove the older read cannot overwrite the newer one.
    var readBarrierForTesting: (@MainActor () async -> Void)?

    /// `internal` (not `private`) so a test can establish a pending debounce
    /// synchronously — the notification path hops through a `Task`, which makes
    /// "a scoped change is already pending" impossible to set up deterministically
    /// otherwise. Production callers are unchanged.
    func scheduleDebouncedReload(_ changeSet: SidecarChangeSet) {
        if pendingReload == nil {
            pendingChangeSet = changeSet
        } else {
            pendingChangeSet = (pendingChangeSet ?? .fullRefresh).merging(changeSet)
        }
        // A newer change supersedes any in-flight read: bump the generation now
        // and capture the token for the single task that survives the debounce.
        let token = nextRefreshToken()
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.reloadDebounce)
            } catch {
                return   // superseded by a newer notification
            }
            guard let self else { return }
            // Guard BEFORE consuming: a direct reload() or a newer schedule can
            // supersede this task after its sleep returned (cooperative
            // cancellation does not unwind a task already past `Task.sleep`). If
            // so, do NOT consume the merged set — the newer intent owns it now.
            guard token == self.refreshGeneration else { return }
            // Only this (current, newest) task consumes the merged change set.
            let coalescedChangeSet = self.pendingChangeSet ?? .fullRefresh
            self.pendingChangeSet = nil
            self.pendingReload = nil
            await self.refresh(for: coalescedChangeSet, token: token)
        }
    }

    /// Refresh only the guide/place envelopes named by a watcher delta. Link
    /// deletions still require the existing full-link scans because the
    /// notification cannot name their former endpoints. Unknown scope or a
    /// failed single-key read falls back to the established full reload.
    private func refresh(for changeSet: SidecarChangeSet, token: Int) async {
        guard let changedKeys = changeSet.changedKeys else {
            // Fallback full reload reuses this token so it does not supersede the
            // very refresh intent that delegated to it.
            await reload(token: token)
            return
        }

        let guideIDs = Set(changedKeys.lazy.filter { $0.kind == .guide }.map(\.id))
        let placeIDs = Set(changedKeys.lazy.filter { $0.kind == .place }.map(\.id))
        let linksChanged = changedKeys.contains { $0.kind == .link }
        guard !guideIDs.isEmpty || !placeIDs.isEmpty || linksChanged else { return }

        // A delta can only patch a COMPLETE base. If no full load has landed yet
        // (e.g. a sidecar change raced the launch reload), upgrade to a full
        // reload under the same token instead of stranding a partial projection.
        guard hasLoadedOnce else {
            await reload(token: token)
            return
        }

        let changedGuides: [String: MapsGuide]
        if guideIDs.isEmpty {
            changedGuides = [:]
        } else {
            guard let fetched = await service.sidecarGuides(uuids: guideIDs) else {
                await reload(token: token)
                return
            }
            changedGuides = fetched
        }

        let changedPlaces: [String: MapsPlace]
        if placeIDs.isEmpty {
            changedPlaces = [:]
        } else {
            guard let fetched = await service.sidecarPlaces(uuids: placeIDs) else {
                await reload(token: token)
                return
            }
            changedPlaces = fetched
        }

        let refreshedLinkedPlaceIDs: Set<String>?
        let refreshedLinkCounts: [String: Int]?
        if linksChanged {
            refreshedLinkedPlaceIDs = await service.linkedEndpointIDs(ofKind: .place)
            refreshedLinkCounts = await service.linkCountsByEndpointID(ofKind: .place)
        } else {
            refreshedLinkedPlaceIDs = nil
            refreshedLinkCounts = nil
        }

        // A newer refresh/reload superseded us while our reads were in flight.
        // Never let an older delta overwrite that newer request's projection.
        guard token == refreshGeneration else { return }

        if !guideIDs.isEmpty {
            guides.removeAll { guideIDs.contains($0.id.uuidString.lowercased()) }
            guides.append(contentsOf: changedGuides.values)
        }

        if !placeIDs.isEmpty {
            for guideID in Array(placesByGuide.keys) {
                placesByGuide[guideID]?.removeAll {
                    placeIDs.contains($0.id.uuidString.lowercased())
                }
            }
            for place in changedPlaces.values {
                placesByGuide[place.guideID, default: []].append(place)
            }
            for guideID in Array(placesByGuide.keys) {
                placesByGuide[guideID] = placeSortOrder.sorted(placesByGuide[guideID] ?? [])
            }
        }

        if let refreshedLinkedPlaceIDs {
            linkedPlaceIDs = refreshedLinkedPlaceIDs
        }
        if let refreshedLinkCounts {
            linkCountsByID = refreshedLinkCounts
        }
        guides = sortOrder.sorted(guides) { [weak self] in self?.placeCount(inGuide: $0) ?? 0 }
        notificationCenter.post(name: .guidesRepositoryDidReload, object: self)
    }

    /// Full reload as a fresh authoritative refresh intent — the entry point
    /// every direct caller (import, delete, list mount, sort change) uses. It
    /// mints a new generation token so any older in-flight read is superseded.
    func reload() async {
        // A full read subsumes any pending scoped delta, so cancel and clear it.
        // The token bump below then supersedes any debounce task already past
        // its sleep (its pre-consume guard sees the newer generation). Only this
        // DIRECT entry clears pending work — the token-scoped fallback below must
        // not, or it could wipe a newer schedule it does not own.
        pendingReload?.cancel()
        pendingReload = nil
        pendingChangeSet = nil
        await reload(token: nextRefreshToken())
    }

    /// Token-scoped full reload. `token` is either freshly minted (a direct
    /// `reload()`) or handed down from a delta `refresh` that fell back here — in
    /// which case it deliberately reuses that token so the fallback does not
    /// supersede the refresh intent it belongs to.
    private func reload(token: Int) async {
        // A fallback reload may already be superseded before it even starts;
        // guard before touching `isLoading` or issuing a read.
        guard token == refreshGeneration else { return }
        isLoading = true
        let fetchedGuides = await service.allGuides()
        let fetchedPlaces = await service.allPlaces()
        let fetchedLinkedPlaceIDs = await service.linkedEndpointIDs(ofKind: .place)
        let fetchedLinkCounts = await service.linkCountsByEndpointID(ofKind: .place)

        if let readBarrierForTesting { await readBarrierForTesting() }

        // A newer refresh/reload superseded us while these reads were in flight;
        // discard our now-stale snapshot before touching any published state.
        guard token == refreshGeneration else { return }

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
        linkCountsByID = fetchedLinkCounts

        guides = sortOrder.sorted(fetchedGuides) { [weak self] in self?.placeCount(inGuide: $0) ?? 0 }
        hasLoadedOnce = true

        // Flip BEFORE posting so synchronous observers see the post-load
        // state — same ordering rationale as ContactsRepository.reload().
        isLoading = false
        notificationCenter.post(name: .guidesRepositoryDidReload, object: self)
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

    /// The unified Places tab's content: every live place across every guide,
    /// filtered by `placeFilter` and arranged by `allPlacesSortOrder`. For
    /// `.byGuide`, one section per guide holding places (section order follows
    /// `guides`, i.e. the user's guides-list order; guides left empty by the
    /// filter are skipped), plus a trailing untitled bucket for places whose
    /// guide sidecar hasn't arrived yet (a sync race — dropping their rows
    /// would make them look deleted). The flat orders return one untitled
    /// section. Within-section order for `.byGuide` is the guide's canonical
    /// entry order, NOT the per-guide lists' `placeSortOrder` — the two
    /// surfaces sort independently.
    func unifiedPlaceSections() -> [UnifiedPlaceSection] {
        func filtered(_ places: [MapsPlace]) -> [MapsPlace] {
            switch placeFilter {
            case .all:
                return places
            case .linked:
                return places.filter { linkedPlaceIDs.contains($0.id.uuidString.lowercased()) }
            }
        }

        if allPlacesSortOrder.isFlat {
            let all = filtered(placesByGuide.values.flatMap { $0 })
            return [UnifiedPlaceSection(
                guideID: nil,
                title: nil,
                places: allPlacesSortOrder.sorted(all)
            )]
        }

        var sections: [UnifiedPlaceSection] = []
        var remaining = placesByGuide
        for guide in guides {
            guard let places = remaining.removeValue(forKey: guide.id) else { continue }
            let kept = filtered(places)
            guard !kept.isEmpty else { continue }
            let name = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(UnifiedPlaceSection(
                guideID: guide.id,
                title: name.isEmpty ? "Guide" : name,
                places: AllPlacesSortOrder.byGuide.sorted(kept)
            ))
        }
        let orphans = filtered(remaining.values.flatMap { $0 })
        if !orphans.isEmpty {
            sections.append(UnifiedPlaceSection(
                guideID: nil,
                title: nil,
                places: AllPlacesSortOrder.nameAscending.sorted(orphans)
            ))
        }
        return sections
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

    /// Number of live links touching `place` (any far-endpoint kind), for the
    /// "N links" list badge. Zero for a place with no links; callers hide the
    /// badge on zero. Keyed the same way as `linkedPlaceIDs` so the badge and
    /// the Linked filter agree.
    func linkCount(for place: MapsPlace) -> Int {
        linkCountsByID[place.id.uuidString.lowercased()] ?? 0
    }

    // MARK: - Identity lookups
    //
    // Both DELIBERATELY ignore `placeFilter`: they answer "does this record
    // exist" for callers holding only an id — the favorites projection, which
    // must render a starred guide or place by name whatever relationship
    // filter the Places tab happens to be showing. `places(inGuide:)` and
    // `unifiedPlaceSections()` stay filtered; they answer "what should this
    // list show", which is a different question.

    /// The guide with `id`, or nil when no such guide is cached.
    func guide(id: UUID) -> MapsGuide? {
        guides.first { $0.id == id }
    }

    /// The place with `id` in any guide, or nil when no such place is cached.
    func place(id: UUID) -> MapsPlace? {
        for places in placesByGuide.values {
            if let match = places.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}
