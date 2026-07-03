import Foundation
import GuessWhoSync

// `@unchecked Sendable`: every access to the mutable dictionaries below is
// bracketed by the per-instance `lock` (see each method body), satisfying the
// `EventStoreProtocol: Sendable` contract the engine's background-hop
// overloads rely on.
public final class InMemoryEventStore: EventStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var eventsByEventKitID: [String: Event]
    private var createCounter: Int = 0
    /// Test-only translation map: legacy `eventIdentifier` (case-sensitive) →
    /// `eventKitID` (= `calendarItemExternalIdentifier`). Drives
    /// `fetch(legacyEventIdentifier:)` so migration tests can simulate
    /// EventKit's two-namespace lookup without a real `EKEventStore`.
    private var legacyToEventKitID: [String: String] = [:]

    public init(events: [Event] = []) {
        var initial: [String: Event] = [:]
        for event in events {
            guard let ekid = event.eventKitID else { continue }
            initial[ekid] = event
        }
        self.eventsByEventKitID = initial
    }

    // MARK: - Authorization

    /// Simulated authorization state. Defaults to `.authorized` so existing
    /// tests that never opt into a permission flow see a granted store. Tests
    /// that exercise the gate can drive it via `setAuthorizationStatus`.
    private var authorizationStatus: StoreAuthorizationStatus = .authorized

    public func eventsAuthorizationStatus() -> StoreAuthorizationStatus {
        lock.lock()
        defer { lock.unlock() }
        return authorizationStatus
    }

    public func requestEventsAccess() async -> StoreAccessResult {
        // Delegate the locked mutation to a synchronous helper that keeps the
        // lock strictly synchronous: the lock is taken and released entirely
        // inside `grantIfNeeded()`, with no suspension point in between.
        grantIfNeeded()
    }

    /// Synchronous, lock-guarded request side-effect. Models the OS: a thrown
    /// request (when the test asked for one) returns `.denied` carrying the
    /// description; otherwise a `.notDetermined` store grants and an
    /// already-decided store returns its existing verdict unchanged.
    private func grantIfNeeded() -> StoreAccessResult {
        lock.lock()
        defer { lock.unlock() }
        if let description = requestFailureDescription {
            return StoreAccessResult(status: .denied, failureDescription: description)
        }
        if authorizationStatus == .notDetermined {
            authorizationStatus = .authorized
        }
        return StoreAccessResult(status: authorizationStatus)
    }

    /// Test hook — drive the simulated events authorization state.
    public func setAuthorizationStatus(_ status: StoreAuthorizationStatus) {
        lock.lock()
        defer { lock.unlock() }
        authorizationStatus = status
    }

    /// Test hook — when non-nil, the next `requestEventsAccess()` models a
    /// thrown OS request: it returns `.denied` carrying this description and
    /// leaves the stored status untouched. Mirrors the real adapter's
    /// catch-block behavior.
    private var requestFailureDescription: String?
    public func setRequestFailure(_ description: String?) {
        lock.lock()
        defer { lock.unlock() }
        requestFailureDescription = description
    }

    // MARK: - Reads

    public func fetchEvents(in interval: DateInterval) throws -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return eventsByEventKitID.values.filter { event in
            event.startDate <= interval.end && event.endDate >= interval.start
        }
    }

    public func fetch(eventKitID: String) throws -> Event? {
        lock.lock()
        defer { lock.unlock() }
        return eventsByEventKitID[eventKitID]
    }

    public func fetchEvents(on day: Date) throws -> [Event] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        let interval = DateInterval(start: start, end: end)
        lock.lock()
        defer { lock.unlock() }
        return eventsByEventKitID.values.filter { event in
            event.startDate >= start && event.startDate < end
                && event.startDate <= interval.end && event.endDate >= interval.start
        }
    }

    public func fetch(legacyEventIdentifier: String) throws -> Event? {
        lock.lock()
        defer { lock.unlock() }
        guard let ekid = legacyToEventKitID[legacyEventIdentifier] else { return nil }
        return eventsByEventKitID[ekid]
    }

    public func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        let inWindow = eventsByEventKitID.values.filter { event in
            event.startDate <= interval.end && event.endDate >= interval.start
        }
        guard !text.isEmpty else { return Array(inWindow) }
        let needle = text.lowercased()
        return inWindow.filter { event in
            if event.title.lowercased().contains(needle) { return true }
            if let location = event.location, location.lowercased().contains(needle) { return true }
            return false
        }
    }

    public func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] {
        let normalized: Set<String> = Set(
            emails
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !normalized.isEmpty, limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let matches = eventsByEventKitID.values.filter { event in
            guard event.startDate <= interval.end, event.endDate >= interval.start else { return false }
            return event.attendees.contains { attendee in
                guard let email = attendee.email?.lowercased() else { return false }
                return normalized.contains(email)
            }
        }
        return matches
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Writes

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event {
        lock.lock()
        defer { lock.unlock() }
        createCounter += 1
        let ekid = "ek-\(createCounter)"
        let event = Event(
            id: UUID(),
            eventKitID: ekid,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            eventKitNotes: nil
        )
        eventsByEventKitID[ekid] = event
        return event
    }

    public func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var existing = eventsByEventKitID[eventKitID] else {
            throw EventStoreError.eventNotFound(eventKitID: eventKitID)
        }
        existing.title = title
        existing.startDate = startDate
        existing.endDate = endDate
        existing.isAllDay = isAllDay
        existing.location = location
        eventsByEventKitID[eventKitID] = existing
    }

    // MARK: - Test-only helpers

    /// Remove an event by `eventKitID` to simulate "deleted from EventKit"
    /// (drives the Option C cache-fallback tests).
    public func removeEvent(eventKitID: String) {
        lock.lock()
        defer { lock.unlock() }
        eventsByEventKitID.removeValue(forKey: eventKitID)
    }

    /// Test-only: register a translation from a legacy (case-sensitive)
    /// `eventIdentifier` to the canonical `eventKitID`
    /// (= `calendarItemExternalIdentifier`). Drives
    /// `fetch(legacyEventIdentifier:)` so migration tests can simulate
    /// EventKit's `event(withIdentifier:)` lookup without a real
    /// `EKEventStore`.
    public func setLegacyTranslation(_ legacy: String, to ekid: String) {
        lock.lock()
        defer { lock.unlock() }
        legacyToEventKitID[legacy] = ekid
    }

    /// Test-only: insert an `Event` keyed by its own `eventKitID`, bypassing
    /// the create-event auto-id-mint path. Used by migration tests that
    /// need a deterministic eventKitID rather than the `"ek-N"` counter.
    public func _injectForTest(event: Event) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let ekid = event.eventKitID else { return }
        eventsByEventKitID[ekid] = event
    }
}
