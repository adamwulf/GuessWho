import Foundation
import EventKit
import GuessWhoSync

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

    var title: String {
        switch self {
        case .showAll: "All Events"
        case .linked: "Linked"
        case .hasAttendees: "Has Attendees"
        }
    }
}

@MainActor
@Observable
final class EventsRepository: NSObject {
    private let service: SyncService

    private(set) var events: [Event] = []
    private(set) var isLoading: Bool = false

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
            NotificationCenter.default.post(name: .eventsRepositoryDidReload, object: self)
            Task { [weak self] in
                await self?.reload()
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
            NotificationCenter.default.post(name: .eventsRepositoryDidReload, object: self)
        }
    }

    /// Absolute bounds of the loaded window. `reload()` always fetches
    /// exactly this range, so the debounced external-change reloads keep a
    /// user-extended window instead of snapping back to the default. Seeded
    /// at launch with the list's original −30d/+90d window; the paging
    /// methods below are the only writers.
    private(set) var windowStart: Date
    private(set) var windowEnd: Date

    init(service: SyncService) {
        self.service = service
        let now = Date()
        self.windowStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        self.windowEnd = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        super.init()
        // Refresh on any external store change that can affect the events list:
        // a Calendar.app edit (`.EKEventStoreChanged`), a contact change
        // (`.guessWhoContactsDidChange`, which can alter attendee rendering),
        // or sidecar files changing on disk (`.guessWhoSidecarsDidChange` —
        // an event sidecar arriving from another device, or a
        // `notYetDownloaded` one materializing). All three funnel through the
        // same debounced reload, which is READ-ONLY over sidecars — so a
        // sidecar post can never re-trigger itself.
        // The repo owns its own refresh path; the AppDelegate registers no
        // observers. Selector-based registrations are held weakly and auto-
        // cleaned on release (this repo lives for the whole process), so there
        // is no `deinit` or token bookkeeping.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(storeDidChange(_:)), name: .EKEventStoreChanged, object: nil)
        center.addObserver(self, selector: #selector(storeDidChange(_:)), name: .guessWhoContactsDidChange, object: nil)
        center.addObserver(self, selector: #selector(storeDidChange(_:)), name: .guessWhoSidecarsDidChange, object: nil)
    }

    /// Reloads the events list. `nonisolated` because the selector API delivers
    /// on the posting thread; hops to the main actor to do the work.
    ///
    /// Debounced: `.EKEventStoreChanged` fires in bursts during background
    /// calendar sync (and `.guessWhoContactsDidChange` during contact sync),
    /// and each reload walks every event sidecar plus an EventKit window
    /// query. The trailing debounce collapses a burst into one reload after
    /// the last notification. Direct `reload()` calls stay immediate.
    @objc
    private nonisolated func storeDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            self?.scheduleDebouncedReload()
        }
    }

    /// The pending debounced reload, if any. Replaced (and the prior one
    /// cancelled) on every notification, so only the trailing edge fires.
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
        let requestedFilter = filter
        isLoading = true
        let fetched: [Event]
        switch requestedFilter {
        case .linked:
            fetched = await service.allLinkedEvents()
        case .showAll, .hasAttendees:
            fetched = await service.fetchEventsRange(from: windowStart, to: windowEnd)
        }

        // The filter can change while its asynchronous backing read is in
        // flight. Never let an older request overwrite the newer selection;
        // that selection has already started its own reload from `didSet`.
        guard requestedFilter == filter else { return }
        events = sortOrder.sorted(fetched)
        // Flip BEFORE posting so synchronous observers see the
        // post-load state. See ContactsRepository.reload() for the full
        // rationale.
        isLoading = false
        NotificationCenter.default.post(name: .eventsRepositoryDidReload, object: self)
    }

    /// Extend the loaded window one month further back and reload — the
    /// events-list twin of `EventLinkSheet.loadOlderMonth()`. Repeatable;
    /// each call reveals one more month. Sidecar-only (manual) events in the
    /// revealed month surface too, so this is not gated on calendar access.
    func loadOlderMonth() async {
        windowStart = Calendar.current.date(byAdding: .month, value: -1, to: windowStart) ?? windowStart
        await reload()
    }

    /// Extend the loaded window one month further forward and reload.
    /// Symmetric with `loadOlderMonth()` (the link sheet's forward paging
    /// jumps a whole year, but the list reads better month-by-month).
    func loadLaterMonth() async {
        windowEnd = Calendar.current.date(byAdding: .month, value: 1, to: windowEnd) ?? windowEnd
        await reload()
    }

    var filtered: [Event] {
        let candidates: [Event]
        switch filter {
        case .showAll, .linked:
            candidates = events
        case .hasAttendees:
            candidates = events.filter { !$0.attendees.isEmpty }
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
}
