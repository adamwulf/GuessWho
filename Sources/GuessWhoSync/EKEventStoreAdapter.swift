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
        // The cell value may be *either* identifier type — the resolver tries
        // both and returns nil only if both lookups fail.
        if let item = store.calendarItems(withExternalIdentifier: eventKitID).first(where: { $0 is EKEvent }) as? EKEvent {
            return Self.toEvent(item)
        }
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return events }
        let needle = trimmed.lowercased()
        return events.filter { event in
            if event.title.lowercased().contains(needle) { return true }
            if let location = event.location, location.lowercased().contains(needle) { return true }
            return false
        }
    }

    // MARK: - Writes

    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event {
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
            // The just-created EKEvent must have a calendarItemExternalIdentifier
            // — but if it somehow doesn't, surface eventNotFound for safety.
            throw EventStoreError.eventNotFound(eventKitID: ekEvent.eventIdentifier ?? "")
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
        // Resolve via the same dual-namespace path as `fetch(eventKitID:)`.
        let ekEvent: EKEvent
        if let item = store.calendarItems(withExternalIdentifier: eventKitID).first(where: { $0 is EKEvent }) as? EKEvent {
            ekEvent = item
        } else if let legacy = store.event(withIdentifier: eventKitID) {
            ekEvent = legacy
        } else {
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
        let attendees = (e.attendees ?? []).map(Self.toAttendee)
        return Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: e.title ?? "",
            startDate: e.startDate,
            endDate: e.endDate,
            isAllDay: e.isAllDay,
            location: location,
            eventKitNotes: notes,
            attendees: attendees
        )
    }

    /// Convert an `EKParticipant` into our `EventAttendee` model.
    /// `participant.name` is preferred; when nil we fall back to the email
    /// (parsed from the `mailto:` URL) so the row still has *something* to
    /// render. Email is extracted from `participant.url` when it carries a
    /// `mailto:` scheme — that's the only address shape EventKit exposes.
    private static func toAttendee(_ p: EKParticipant) -> EventAttendee {
        let email = Self.email(from: p.url)
        let name = p.name?.isEmpty == false ? p.name! : (email ?? "")
        return EventAttendee(name: name, email: email)
    }

    // `internal` (not `private`) so `EventAttendeeTests` can drive the
    // mailto parser with synthetic URLs — `EKParticipant` has no public
    // initializer, so testing through `toAttendee` from XCTest isn't
    // feasible. Surface area stays small: pure URL → String? function
    // with no side effects, marked `static`.
    static func email(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "mailto" else { return nil }
        // mailto: URLs are opaque — `URLComponents.path` doesn't help here.
        // Strip the scheme prefix off the original `absoluteString` (using
        // the actual scheme length to tolerate `MAILTO:`/`Mailto:` etc.),
        // drop any `?headers` after the address, then percent-decode so
        // an international invitee whose ICS payload encoded `@` as `%40`
        // still matches a contact whose email is stored in plain ASCII.
        let raw = url.absoluteString
        let prefixCount = scheme.count + 1 // scheme + ":"
        guard raw.count > prefixCount else { return nil }
        let specifier = raw.dropFirst(prefixCount)
        let beforeQuery = specifier.split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(specifier)
        let decoded = beforeQuery.removingPercentEncoding ?? beforeQuery
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
