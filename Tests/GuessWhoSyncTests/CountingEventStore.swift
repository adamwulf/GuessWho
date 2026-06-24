import Foundation
@testable import GuessWhoSync

/// Test-only wrapper around any `EventStoreProtocol` that counts per-method
/// invocations. Used by `EventWindowTests` to assert the windowed-read path
/// makes exactly one `fetchEvents(in:)` call and zero `fetch(eventKitID:)`
/// calls (the EVENT_STRATEGY_PLAN.md C-WINDOW-FETCH invariant).
final class CountingEventStore: EventStoreProtocol {
    private let inner: EventStoreProtocol
    private let lock = NSLock()

    private(set) var fetchEventsInIntervalCount: Int = 0
    private(set) var fetchEventKitIDCount: Int = 0
    private(set) var fetchLegacyEventIdentifierCount: Int = 0
    private(set) var fetchEventsOnDayCount: Int = 0
    private(set) var searchEventsCount: Int = 0
    private(set) var eventsWithAttendeeCount: Int = 0
    private(set) var createEventCount: Int = 0
    private(set) var updateEventCount: Int = 0

    init(wrapping inner: EventStoreProtocol) {
        self.inner = inner
    }

    func fetchEvents(in interval: DateInterval) throws -> [Event] {
        lock.lock()
        fetchEventsInIntervalCount += 1
        lock.unlock()
        return try inner.fetchEvents(in: interval)
    }

    func fetch(eventKitID: String) throws -> Event? {
        lock.lock()
        fetchEventKitIDCount += 1
        lock.unlock()
        return try inner.fetch(eventKitID: eventKitID)
    }

    func fetch(legacyEventIdentifier: String) throws -> Event? {
        lock.lock()
        fetchLegacyEventIdentifierCount += 1
        lock.unlock()
        return try inner.fetch(legacyEventIdentifier: legacyEventIdentifier)
    }

    func fetchEvents(on day: Date) throws -> [Event] {
        lock.lock()
        fetchEventsOnDayCount += 1
        lock.unlock()
        return try inner.fetchEvents(on: day)
    }

    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] {
        lock.lock()
        searchEventsCount += 1
        lock.unlock()
        return try inner.searchEvents(matching: text, in: interval)
    }

    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] {
        lock.lock()
        eventsWithAttendeeCount += 1
        lock.unlock()
        return try inner.eventsWithAttendee(matchingEmails: emails, in: interval, limit: limit)
    }

    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event {
        lock.lock()
        createEventCount += 1
        lock.unlock()
        return try inner.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location
        )
    }

    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws {
        lock.lock()
        updateEventCount += 1
        lock.unlock()
        try inner.updateEvent(
            eventKitID: eventKitID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location
        )
    }
}
