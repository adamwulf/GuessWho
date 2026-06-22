#if canImport(EventKit)
import EventKit
import Foundation

public final class EKEventStoreAdapter: EventStoreProtocol {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: - Reads

    public func fetchEvents(in interval: DateInterval) throws -> [Event] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).compactMap(Self.toEvent)
    }

    public func fetch(eventKitID: String) throws -> Event? {
        // Dual-namespace resolver: try the new canonical
        // `calendarItemExternalIdentifier` path first, then fall back to the
        // legacy `eventIdentifier` path so dead-pointer migration rows still
        // resolve when their EKEvent is later re-found by `eventIdentifier`.
        // TODO(phase 4): wire up the canonical
        // `store.calendarItems(withExternalIdentifier:)` path. For now the
        // adapter only resolves through the legacy `event(withIdentifier:)`
        // path; full dual-namespace lookup is finalized in phase 4 along
        // with the on-device smoke harness.
        if let ekEvent = store.event(withIdentifier: eventKitID) {
            return Self.toEvent(ekEvent)
        }
        return nil
    }

    public func fetchEvents(on day: Date) throws -> [Event] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        return try fetchEvents(in: DateInterval(start: start, end: end))
    }

    public func fetch(legacyEventIdentifier: String) throws -> Event? {
        // Migration-only: resolve a pre-pivot `eventIdentifier` to an Event
        // whose `eventKitID` is the canonical
        // `calendarItemExternalIdentifier`. `store.event(withIdentifier:)`
        // takes the legacy `eventIdentifier` string and returns the EKEvent;
        // `toEvent` then reads `calendarItemExternalIdentifier`. Returns nil
        // when the EKEvent no longer exists.
        guard let ekEvent = store.event(withIdentifier: legacyEventIdentifier) else { return nil }
        return Self.toEvent(ekEvent)
    }

    public func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] {
        let events = try fetchEvents(in: interval)
        guard !text.isEmpty else { return events }
        let needle = text.lowercased()
        return events.filter { event in
            if event.title.lowercased().contains(needle) { return true }
            if let location = event.location, location.lowercased().contains(needle) { return true }
            return false
        }
    }

    // MARK: - Writes (phase 4 wires these up fully; the protocol requires them)

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event {
        // TODO(phase 4): finalize the EKEvent creation path per
        // EVENT_STRATEGY_PLAN.md E1.6 — defaultCalendarForNewEvents lookup,
        // span/commit semantics, etc.
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw EventStoreError.noWritableCalendar
        }
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = title
        ekEvent.startDate = startDate
        ekEvent.endDate = endDate
        ekEvent.isAllDay = isAllDay
        ekEvent.location = location
        ekEvent.calendar = calendar
        try store.save(ekEvent, span: .thisEvent, commit: true)
        guard let event = Self.toEvent(ekEvent) else {
            throw EventStoreError.noWritableCalendar
        }
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
        // TODO(phase 4): use the dual-namespace resolver here too.
        guard let ekEvent = store.event(withIdentifier: eventKitID) else {
            throw EventStoreError.eventNotFound(eventKitID: eventKitID)
        }
        ekEvent.title = title
        ekEvent.startDate = startDate
        ekEvent.endDate = endDate
        ekEvent.isAllDay = isAllDay
        ekEvent.location = location
        try store.save(ekEvent, span: .thisEvent, commit: true)
    }

    // MARK: - Conversion

    private static func toEvent(_ e: EKEvent) -> Event? {
        // calendarItemExternalIdentifier is the cross-device canonical id.
        // The adapter never emits eventIdentifier for new sidecars; legacy
        // sidecars whose eventKitID cell still holds an eventIdentifier are
        // tolerated by `fetch(eventKitID:)`'s dual-namespace resolver (and
        // by migration's translation step).
        guard let ekid = e.calendarItemExternalIdentifier, !ekid.isEmpty else { return nil }
        let location = (e.location?.isEmpty ?? true) ? nil : e.location
        let notes = (e.notes?.isEmpty ?? true) ? nil : e.notes
        return Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: e.title ?? "",
            startDate: e.startDate,
            endDate: e.endDate,
            isAllDay: e.isAllDay,
            location: location,
            eventKitNotes: notes
        )
    }
}

#endif
