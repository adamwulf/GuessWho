import Foundation
import GuessWhoSync

/// Stub events repository. Wired up so the Events tab has a real
/// repository to bind against, but until SyncService gains an EventKit-
/// backed EventStoreProtocol (today it ships with NoopEventStore), every
/// reload returns an empty list. The list view renders a
/// ContentUnavailableView in that case.
@MainActor
@Observable
final class EventsRepository {
    private(set) var events: [Event] = []
    private(set) var isLoading: Bool = false

    var searchText: String = ""

    init() {}

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        // Intentional no-op for v1. Replace with a SyncService.fetchEvents
        // call once an EventKit adapter lands.
        events = []
    }

    var filtered: [Event] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return events }
        let needle = trimmed.lowercased()
        return events.filter { e in
            e.title.lowercased().contains(needle)
                || (e.location ?? "").lowercased().contains(needle)
                || (e.notes ?? "").lowercased().contains(needle)
        }
    }
}
