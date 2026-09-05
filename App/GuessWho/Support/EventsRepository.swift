import Foundation
import EventKit
import GuessWhoSync
import Logging

extension Notification.Name {
    /// Posted by `EventsRepository.reload()` after a fetch completes.
    /// Parallels `.contactsRepositoryDidReload`; UIKit list controllers
    /// subscribe to re-apply a diffable snapshot.
    static let eventsRepositoryDidReload = Notification.Name("EventsRepositoryDidReload")
}

/// Candidate set shown by the Events tab. Filtering is independent of
/// `EventSortOrder`: the repository fetches/selects the matching events, then
/// applies whichever sort order the user currently has selected.
enum EventListFilter: CaseIterable, Sendable {
    case showAll
    case linked
    case hasAttendees
    case physicalLocation

    var title: String {
        switch self {
        case .showAll: "All Events"
        case .linked: "Linked"
        case .hasAttendees: "Has Attendees"
        case .physicalLocation: "Physical Location"
        }
    }
}

enum EventsRepositoryReloadOutcome: Equatable, Sendable {
    /// This invocation owns the authoritative list publication. A zero count is
    /// a valid successful result, distinct from `.failed`.
    case published(itemCount: Int)
    /// The backing event read failed and the repository published its settled
    /// empty fallback.
    case failed(message: String)
    /// A newer refresh intent replaced this invocation before publication.
    case superseded
}

@MainActor
@Observable
final class EventsRepository: NSObject {
    private static let reloadLog = Logger(label: "app.events-reload")

    private let service: SyncService

    private(set) var events: [Event] = []
    private(set) var isLoading: Bool = false

    #if DEBUG && targetEnvironment(macCatalyst)
    private var benchmarkLastReloadSucceeded: Bool?

    /// Outcome of the winning window read, including one that superseded the
    /// app-launch caller. A cleared or still-loading projection is not ready.
    var benchmarkLoadSucceeded: Bool? {
        guard hasLoadedOnce, !isLoading else { return nil }
        return benchmarkLastReloadSucceeded
    }
    #endif

    /// Per-event link COUNT keyed by lowercased event UUID string. Powers the
    /// "N links" list badge; refreshed in `reload()` (the single funnel for
    /// every reload path). An event with no entry has zero links and shows no
    /// badge. Purely derived read-model state.
    private var linkCountsByID: [String: Int] = [:]

    var searchText: String = ""

    /// The active Events-tab filter. A change clears the prior filter's
    /// candidate set immediately, then reloads the correct backing pool:
    /// Linked walks every relationship in the database, while Show All and
    /// Has Attendees use the existing date-windowed Calendar query.
    var filter: EventListFilter = .showAll {
        didSet {
            guard filter != oldValue else { return }
            isLoading = true
            events = []
            // The cleared list is no longer a complete projection for the new
            // filter, so a delta that races the reload below must rebuild rather
            // than patch this empty base. `reload()` re-arms it on completion.
            hasLoadedOnce = false
            notificationCenter.post(name: .eventsRepositoryDidReload, object: self)
            Task { [weak self] in
                await self?.reload(trigger: "filter-change")
            }
        }
    }

    /// The live sort order every events list reads. Persistence is the app's
    /// job (`EventSortOrderSetting` writes UserDefaults and sets this);
    /// setting it re-sorts in place and posts `.eventsRepositoryDidReload`
    /// so visible lists re-snapshot — same shape as
    /// `ContactsRepository.sortOrder`. No-op (and no post) when unchanged.
    var sortOrder: EventSortOrder = .chronological {
        didSet {
            guard sortOrder != oldValue else { return }
            events = sortOrder.sorted(events)
            notificationCenter.post(name: .eventsRepositoryDidReload, object: self)
        }
    }

    /// Absolute bounds of the loaded window. `reload()` always fetches
    /// exactly this range, so the debounced external-change reloads keep a
    /// user-extended window instead of snapping back to the default. Seeded
    /// at launch with the list's original −30d/+90d window; the paging
    /// methods below are the only writers.
    private(set) var windowStart: Date
    private(set) var windowEnd: Date

    /// The center this repository observes external-change notifications on AND
    /// posts `.eventsRepositoryDidReload` to. Defaults to `.default` so
    /// production wiring is unchanged (the live watchers post there, and the
    /// list controllers observe there). It is INJECTABLE solely for test
    /// isolation: many repositories — and the real app's own live watcher —
    /// share `.default`, so a fresh `NotificationCenter()` per test repository
    /// confines both its observers and its posts to that test, exactly as
    /// `ContactsRepository` does for the same reason.
    private let notificationCenter: NotificationCenter

    init(service: SyncService, notificationCenter: NotificationCenter = .default) {
        self.service = service
        self.notificationCenter = notificationCenter
        let now = Date()
        self.windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        self.windowEnd = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        super.init()
        // Refresh on any external store change that can affect the events list:
        // a Calendar.app edit (`.EKEventStoreChanged`), a contact edit that can
        // alter attendee rendering (`.guessWhoContactsDidChange`), or sidecar
        // files changing on disk (`.guessWhoSidecarsDidChange` —
        // an event sidecar arriving from another device, or a
        // `notYetDownloaded` one materializing). Both funnel through the
        // same debounced reload, which is READ-ONLY over sidecars — so a
        // sidecar post can never re-trigger itself.
        // The repo owns its own refresh path; the AppDelegate registers no
        // observers. Selector-based registrations are held weakly and auto-
        // cleaned on release (this repo lives for the whole process), so there
        // is no `deinit` or token bookkeeping.
        notificationCenter.addObserver(self, selector: #selector(storeDidChange(_:)), name: .EKEventStoreChanged, object: nil)
        notificationCenter.addObserver(self, selector: #selector(storeDidChange(_:)), name: .guessWhoContactsDidChange, object: nil)
        notificationCenter.addObserver(self, selector: #selector(storeDidChange(_:)), name: .guessWhoSidecarsDidChange, object: nil)
    }

    /// Reloads the events list. `nonisolated` because the selector API delivers
    /// on the posting thread; hops to the main actor to do the work.
    ///
    /// Debounced: `.EKEventStoreChanged` fires in bursts during background
    /// calendar sync, and each reload walks every event sidecar plus an
    /// EventKit window query. The trailing debounce collapses a burst into one
    /// reload after the last notification. Direct `reload()` calls stay
    /// immediate.
    @objc
    private nonisolated func storeDidChange(_ note: Notification) {
        let changeSet = note.name == .guessWhoSidecarsDidChange
            ? note.guessWhoSidecarChangeSet
            : .fullRefresh
        let trigger = note.name.rawValue
        Task { @MainActor [weak self] in
            self?.scheduleDebouncedReload(changeSet, trigger: trigger)
        }
    }

    /// The pending debounced reload, if any. Replaced (and the prior one
    /// cancelled) on every notification, so only the trailing edge fires.
    private var pendingReload: Task<Void, Never>?
    private var pendingChangeSet: SidecarChangeSet?
    private var pendingReloadTriggers: Set<String> = []
    /// Scoped keys currently being read. A newer scoped schedule must inherit
    /// them: invalidating the running token means its result will be discarded,
    /// so the successor is now responsible for both sets of keys.
    private var inFlightChangeSet: (token: Int, value: SidecarChangeSet)?
    private static let reloadDebounce: Duration = .milliseconds(300)

    /// The sidecar kinds whose scoped changes can move the events list. A
    /// watcher delivery is global and routinely names kinds this list does not
    /// project (a guide/place/contact edit): a scoped change naming NONE of
    /// these is irrelevant and must not mint a generation or cancel a
    /// pending/parked reload it cannot affect. A coarse kind-directory delivery
    /// has nil keys but known `changedKinds`; only globally unknown kinds are
    /// always relevant.
    private static let handledKinds: Set<SidecarKind> = [.event, .link]

    /// Monotonic refresh token. Bumped whenever a NEWER authoritative refresh
    /// intent begins — a sidecar-change notification (`scheduleDebouncedReload`)
    /// or a direct `reload()`/paging/filter change — and captured by the task
    /// that will read. Every async read path re-checks the token still holds the
    /// current value before it mutates published state or posts
    /// `.eventsRepositoryDidReload`, so an older read that resumes after a newer
    /// one cannot publish its stale projection (newest-request-wins, the same
    /// shape as `ContactsRepository.groupLoadRequestGeneration`). A delta that
    /// must fall back to a full reload passes its token so the fallback does not
    /// supersede itself.
    private var refreshGeneration = 0

    /// True once a full `reload()` has published a complete window projection.
    /// A delta `refresh` may only PATCH a complete base — before the first full
    /// load lands (e.g. a sidecar change racing the launch reload) it upgrades
    /// itself to a full reload under the same token rather than stranding a
    /// partial list.
    private var hasLoadedOnce = false

    /// Bump the generation and return the new token. Every fresh authoritative
    /// refresh intent calls this exactly once.
    private func nextRefreshToken() -> Int {
        refreshGeneration &+= 1
        return refreshGeneration
    }

    /// Test seam (nil in production, no behavior change): a barrier awaited once
    /// inside `reload(token:)` AFTER its read completes and BEFORE it publishes,
    /// so a test can hold a stale read in flight while it drives a newer refresh
    /// and prove the older read cannot overwrite the newer one.
    var readBarrierForTesting: (@MainActor () async -> Void)?

    /// Test seam (nil in production, no behavior change): a barrier awaited once
    /// inside the scoped `refresh(for:token:)` path AFTER the first envelope read
    /// (`sidecarEvents`) and BEFORE the mid-read supersession guard, so a test can
    /// park a scoped delta there, drive a newer refresh to bump the token, and
    /// prove the parked delta STOPS before the extra link-count scan. Deliberately
    /// NOT referenced by `reload(token:)`, so a superseding full reload never
    /// trips it.
    var refreshReadPauseForTesting: (@MainActor () async -> Void)?

    /// Test seam (nil in production, no behavior change): invoked synchronously
    /// in the scoped `refresh(for:token:)` path IMMEDIATELY before the link-count
    /// scan — i.e. only once the mid-read guard has let execution through. A test
    /// asserts it is NEVER called after the delta was superseded, proving the scan
    /// was skipped rather than paid for and then discarded. Not referenced by
    /// `reload(token:)`.
    var refreshWillScanLinksForTesting: (@MainActor () -> Void)?

    /// `internal` (not `private`) so a test can establish a pending debounce
    /// synchronously — the notification path hops through a `Task`, which makes
    /// "a scoped change is already pending" impossible to set up deterministically
    /// otherwise. Production callers are unchanged.
    func scheduleDebouncedReload(_ changeSet: SidecarChangeSet, trigger: String = "direct-schedule") {
        let keySummary = changeSet.changedKeys.map {
            "exact/\($0.count)"
        } ?? (changeSet.requiresFullRefresh ? "nil/full-scope" : "nil/coarse-scope")
        let kindSummary = changeSet.changedKinds.map {
            $0.map(\.rawValue).sorted().joined(separator: ",")
        } ?? "nil/full-scope"
        // Drop a scoped change that names no kind this list projects BEFORE any
        // merge, generation bump, or cancellation — an irrelevant delivery must
        // not supersede a pending/parked reload it cannot affect.
        if let kinds = changeSet.changedKinds,
           kinds.isDisjoint(with: Self.handledKinds) {
            Self.reloadLog.info(
                "events sidecar delivery dropped",
                metadata: [
                    "trigger": .string(trigger),
                    "changedKinds": .string(kindSummary),
                    "changedKeys": .string(keySummary),
                ]
            )
            return
        }
        Self.reloadLog.info(
            "events sidecar delivery accepted",
            metadata: [
                "trigger": .string(trigger),
                "changedKinds": .string(kindSummary),
                "changedKeys": .string(keySummary),
            ]
        )
        if pendingReload == nil {
            pendingChangeSet = inFlightChangeSet?.value.merging(changeSet) ?? changeSet
        } else {
            pendingChangeSet = (pendingChangeSet ?? .fullRefresh).merging(changeSet)
        }
        pendingReloadTriggers.insert(trigger)
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
            let coalescedTriggers = self.pendingReloadTriggers.sorted().joined(separator: ",")
            self.pendingChangeSet = nil
            self.pendingReloadTriggers = []
            self.pendingReload = nil
            self.inFlightChangeSet = (token, coalescedChangeSet)
            await self.refresh(
                for: coalescedChangeSet,
                token: token,
                trigger: "notifications:\(coalescedTriggers)"
            )
            if self.inFlightChangeSet?.token == token {
                self.inFlightChangeSet = nil
            }
        }
    }

    /// Apply a sidecar watcher delta where the repository can do so without a
    /// corpus walk. Unknown scope and linked-filter membership changes retain
    /// the existing full reload. Link changes in the ordinary date-window
    /// filters refresh only link counts.
    private func refresh(for changeSet: SidecarChangeSet, token: Int, trigger: String) async {
        guard let changedKeys = changeSet.changedKeys else {
            // Fallback full reload reuses this token so it does not supersede the
            // very refresh intent that delegated to it.
            await reload(token: token, trigger: trigger)
            return
        }

        let eventIDs = Set(changedKeys.lazy.filter { $0.kind == .event }.map(\.id))
        let linksChanged = changedKeys.contains { $0.kind == .link }
        guard !eventIDs.isEmpty || linksChanged else {
            // Unreachable while `scheduleDebouncedReload` drops irrelevant scoped
            // changes, but stay safe if one ever slips through: settle any loading
            // state an aborted older reload left set, rather than strand it.
            if token == refreshGeneration { isLoading = false }
            return
        }

        // A delta can only patch a COMPLETE base. If no full load has landed yet
        // (e.g. a sidecar change raced the launch reload), upgrade to a full
        // reload under the same token instead of stranding a partial list.
        guard hasLoadedOnce else {
            await reload(token: token, trigger: trigger)
            return
        }

        if filter == .linked {
            await reload(token: token, trigger: trigger)
            return
        }

        let requestedFilter = filter
        let requestedStart = windowStart
        let requestedEnd = windowEnd
        var projectedEvents: [String: Event] = [:]
        if !eventIDs.isEmpty {
            guard let fetched = await service.sidecarEvents(
                uuids: eventIDs, from: requestedStart, to: requestedEnd
            ) else {
                await reload(token: token, trigger: trigger)
                return
            }
            projectedEvents = fetched
        }

        if let refreshReadPauseForTesting { await refreshReadPauseForTesting() }

        let refreshedLinkCounts: [String: Int]?
        if linksChanged {
            // The event read above awaited; a newer refresh/reload (or a filter/
            // window change, which starts its own reload) may have superseded us
            // in the meantime. Stop BEFORE the extra link-count scan rather than
            // pay for a projection the publish guard below would only discard.
            guard token == refreshGeneration,
                  requestedFilter == filter,
                  requestedStart == windowStart,
                  requestedEnd == windowEnd
            else { return }
            refreshWillScanLinksForTesting?()
            refreshedLinkCounts = await service.linkCountsByEndpointID(ofKind: .event)
        } else {
            refreshedLinkCounts = nil
        }

        if let readBarrierForTesting { await readBarrierForTesting() }

        // A newer refresh/reload (or filter/window change, which starts its own
        // full reload) superseded us while our reads were in flight. Never let an
        // older delta overwrite that newer request's projection.
        guard token == refreshGeneration,
              requestedFilter == filter,
              requestedStart == windowStart,
              requestedEnd == windowEnd
        else { return }

        for id in eventIDs {
            let previous = events.first { $0.id.uuidString.lowercased() == id }
            events.removeAll { $0.id.uuidString.lowercased() == id }

            if let projected = projectedEvents[id] {
                if let eventKitID = projected.eventKitID {
                    events.removeAll { $0.eventKitID == eventKitID }
                }
                if projected.startDate >= windowStart && projected.startDate <= windowEnd {
                    events.append(projected)
                }
            } else if let eventKitID = previous?.eventKitID,
                      var live = service.eventKitEvent(eventKitID: eventKitID),
                      live.startDate >= windowStart,
                      live.startDate <= windowEnd
            {
                // Removing a linked sidecar exposes the underlying EventKit
                // record as the same ephemeral row a full window read emits.
                live.id = Event.stableID(forEventKitID: eventKitID)
                events.removeAll { $0.eventKitID == eventKitID }
                events.append(live)
            }
        }

        events = sortOrder.sorted(events)
        if let refreshedLinkCounts {
            linkCountsByID = refreshedLinkCounts
        }
        // This delta is the current authoritative projection, so the load is
        // settled. Flip BEFORE posting (as `reload()` does) so observers see it
        // false: an older reload that this delta superseded set `isLoading` true
        // and then aborted on its stale token WITHOUT clearing it, so only this
        // completion can, and a stuck spinner is the symptom otherwise.
        isLoading = false
        notificationCenter.post(name: .eventsRepositoryDidReload, object: self)
    }

    /// Full reload as a fresh authoritative refresh intent — the entry point
    /// every direct caller (launch, paging, and filter change) uses. It
    /// mints a new generation token so any older in-flight read is superseded.
    @discardableResult
    func reload(trigger: String = "direct") async -> EventsRepositoryReloadOutcome {
        // A full read subsumes any pending scoped delta, so cancel and clear it.
        // The token bump below then supersedes any debounce task already past
        // its sleep (its pre-consume guard sees the newer generation). Only this
        // DIRECT entry clears pending work — the token-scoped fallback below must
        // not, or it could wipe a newer schedule it does not own.
        pendingReload?.cancel()
        pendingReload = nil
        pendingChangeSet = nil
        pendingReloadTriggers = []
        let token = nextRefreshToken()
        // INSTALL full-refresh ownership up front and HOLD it across the read —
        // exactly as `ContactsRepository.reload()` does. A scoped change that
        // arrives while this reload's read is still in flight then reads
        // `inFlightChangeSet` (in `scheduleDebouncedReload`) and inherits
        // `.fullRefresh` (`.fullRefresh.merging(scoped) == .fullRefresh`), so its
        // successor performs a FULL read rather than patching only its keys onto
        // a base this reload has not published yet. Clearing ownership to nil
        // here — the previous behavior — let that successor patch one key onto
        // the stale pre-reload base and silently drop the rest of the projection.
        inFlightChangeSet = (token, .fullRefresh)
        let outcome = await reload(token: token, trigger: trigger)
        // Release ownership only if it is still ours: a newer refresh that
        // superseded us mid-read installed its own entry and must keep it.
        if inFlightChangeSet?.token == token {
            inFlightChangeSet = nil
        }
        return outcome
    }

    /// Token-scoped full reload. `token` is either freshly minted (a direct
    /// `reload()`) or handed down from a delta `refresh` that fell back here — in
    /// which case it deliberately reuses that token so the fallback does not
    /// supersede the refresh intent it belongs to.
    @discardableResult
    private func reload(token: Int, trigger: String) async -> EventsRepositoryReloadOutcome {
        // A fallback reload may already be superseded before it even starts;
        // guard before touching `isLoading` or issuing a read.
        guard token == refreshGeneration else { return .superseded }
        let requestedFilter = filter
        isLoading = true
        Self.reloadLog.info(
            "events window reload started",
            metadata: [
                "trigger": .string(trigger),
                "generation": .stringConvertible(token),
                "filter": .string(String(describing: requestedFilter)),
                "from": .stringConvertible(windowStart.timeIntervalSince1970),
                "to": .stringConvertible(windowEnd.timeIntervalSince1970),
            ]
        )
        let fetchResult: SyncService.EventFetchResult
        switch requestedFilter {
        case .linked:
            fetchResult = await service.allLinkedEventsResult()
        case .showAll, .hasAttendees, .physicalLocation:
            fetchResult = await service.fetchEventsRangeResult(from: windowStart, to: windowEnd)
        }
        let fetched = fetchResult.eventsOrEmpty

        if let readBarrierForTesting { await readBarrierForTesting() }

        // A newer refresh/reload superseded us, or the filter changed while this
        // read was in flight (that selection started its own reload). Early-out
        // before the extra link-count scan and before touching published state.
        guard token == refreshGeneration, requestedFilter == filter else { return .superseded }
        // Refresh the per-event link counts before publishing so the snapshot the
        // list applies already sees them (one bulk scan, not a per-row read).
        let refreshedLinkCounts = await service.linkCountsByEndpointID(ofKind: .event)
        // Re-check after the second await: nothing may be published if a newer
        // request has since superseded this one.
        guard token == refreshGeneration, requestedFilter == filter else { return .superseded }
        events = sortOrder.sorted(fetched)
        linkCountsByID = refreshedLinkCounts
        hasLoadedOnce = true
        // Flip BEFORE posting so synchronous observers see the
        // post-load state. See ContactsRepository.reload() for the full
        // rationale.
        isLoading = false
        let status: String
        switch fetchResult {
        case .success: status = "published"
        case .failure: status = "failed"
        }
        #if DEBUG && targetEnvironment(macCatalyst)
        benchmarkLastReloadSucceeded = status == "published"
        #endif
        Self.reloadLog.info(
            "events window reload finished",
            metadata: [
                "trigger": .string(trigger),
                "generation": .stringConvertible(token),
                "status": .string(status),
                "events": .stringConvertible(events.count),
            ]
        )
        notificationCenter.post(name: .eventsRepositoryDidReload, object: self)
        switch fetchResult {
        case .success:
            return .published(itemCount: events.count)
        case .failure(let message):
            return .failed(message: message)
        }
    }

    /// Extend the loaded window one month further back and reload — the
    /// events-list twin of `EventLinkSheet.loadOlderMonth()`. Repeatable;
    /// each call reveals one more month. Sidecar-only (manual) events in the
    /// revealed month surface too, so this is not gated on calendar access.
    func loadOlderMonth() async {
        windowStart = Calendar.current.date(byAdding: .month, value: -1, to: windowStart) ?? windowStart
        // The loaded list no longer covers the widened window, so a delta racing
        // the reload must rebuild rather than patch a base missing the newly
        // revealed month. `reload()` re-arms it on completion.
        hasLoadedOnce = false
        await reload(trigger: "paging-older")
    }

    /// Extend the loaded window one month further forward and reload.
    /// Symmetric with `loadOlderMonth()` (the link sheet's forward paging
    /// jumps a whole year, but the list reads better month-by-month).
    func loadLaterMonth() async {
        windowEnd = Calendar.current.date(byAdding: .month, value: 1, to: windowEnd) ?? windowEnd
        hasLoadedOnce = false
        await reload(trigger: "paging-later")
    }

    var filtered: [Event] {
        let candidates: [Event]
        switch filter {
        case .showAll, .linked:
            candidates = events
        case .hasAttendees:
            candidates = events.filter { !$0.attendees.isEmpty }
        case .physicalLocation:
            // Keep only events whose location names a real place: non-empty and
            // not a web/video-call link (Zoom/Meet/http(s) URLs are dropped).
            candidates = events.filter { EventLocationMatcher.isPhysicalLocation($0.location) }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        let needle = trimmed.lowercased()
        return candidates.filter { e in
            e.title.lowercased().contains(needle)
                || (e.location ?? "").lowercased().contains(needle)
                || (e.eventKitNotes ?? "").lowercased().contains(needle)
        }
    }

    /// Number of live links touching `event` (any far-endpoint kind), for the
    /// "N links" list badge. Zero for an event with no links; callers hide the
    /// badge on zero. Keyed by the lowercased event UUID, matching how the
    /// sidecar stores an event endpoint id.
    func linkCount(for event: Event) -> Int {
        linkCountsByID[event.id.uuidString.lowercased()] ?? 0
    }
}
