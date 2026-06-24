import Foundation
import EventKit
import GuessWhoSync

extension Notification.Name {
    /// Posted by `EventsRepository.reload()` after a fetch completes.
    /// Parallels `.contactsRepositoryDidReload`; UIKit list controllers
    /// subscribe to re-apply a diffable snapshot.
    static let eventsRepositoryDidReload = Notification.Name("EventsRepositoryDidReload")
}

@MainActor
@Observable
final class EventsRepository: NSObject {
    private let service: SyncService

    private(set) var events: [Event] = []
    private(set) var isLoading: Bool = false

    var searchText: String = ""

    init(service: SyncService) {
        self.service = service
        super.init()
        // Refresh on any external store change that can affect the events list:
        // a Calendar.app edit (`.EKEventStoreChanged`) or a contact change
        // (`.guessWhoContactsDidChange`, which can alter attendee rendering).
        // The repo owns its own refresh path; the AppDelegate registers no
        // observers. Selector-based registrations are held weakly and auto-
        // cleaned on release (this repo lives for the whole process), so there
        // is no `deinit` or token bookkeeping.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(storeDidChange(_:)), name: .EKEventStoreChanged, object: nil)
        center.addObserver(self, selector: #selector(storeDidChange(_:)), name: .guessWhoContactsDidChange, object: nil)
    }

    /// Reloads the events list. `nonisolated` because the selector API delivers
    /// on the posting thread; hops to the main actor to do the work.
    @objc
    private nonisolated func storeDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            await self?.reload()
        }
    }

    func reload() async {
        isLoading = true
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        let fetched = service.fetchEventsRange(from: start, to: end)
        events = fetched.sorted { $0.startDate < $1.startDate }
        // Flip BEFORE posting so synchronous observers see the
        // post-load state. See ContactsRepository.reload() for the full
        // rationale.
        isLoading = false
        NotificationCenter.default.post(name: .eventsRepositoryDidReload, object: self)
    }

    var filtered: [Event] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return events }
        let needle = trimmed.lowercased()
        return events.filter { e in
            e.title.lowercased().contains(needle)
                || (e.location ?? "").lowercased().contains(needle)
                || (e.eventKitNotes ?? "").lowercased().contains(needle)
        }
    }
}
