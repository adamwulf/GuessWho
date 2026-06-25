#if canImport(EventKit)
import EventKit
import Foundation

// `@unchecked Sendable`: the adapter holds a single immutable `let store`,
// adds no mutable state of its own, and only ever issues read / request / save
// calls on that store — it never mutates shared adapter state across threads.
// That is the basis for the unchecked conformance; it lets
// `requestEventsAccess()` be `async` (it awaits EventKit's permission prompt)
// without the caller's `sending`-check flagging a data race when it hops off
// the caller's actor. Mirrors the rationale behind `GuessWhoSync`'s own
// `@unchecked Sendable`.
public final class EKEventStoreAdapter: EventStoreProtocol, @unchecked Sendable {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: - Authorization

    /// Current events authorization, collapsed to the neutral status.
    /// `EKEventStore.authorizationStatus` is a static system-state read, so
    /// this does not touch the instance store; it lives here to keep the auth
    /// surface behind the adapter port.
    public func eventsAuthorizationStatus() -> StoreAuthorizationStatus {
        Self.mapAuthorization(EKEventStore.authorizationStatus(for: .event))
    }

    /// Prompt for events access on this adapter's store and return the
    /// resulting `StoreAccessResult`. Preserves the prior `SyncService`
    /// semantics: only `.notDetermined` triggers a prompt;
    /// `requestFullAccessToEvents()` is used on iOS 17 / macOS 14+, the legacy
    /// `requestAccess(to:)` before that. A thrown error surfaces as `.denied`
    /// with a non-nil `failureDescription` (the error's `localizedDescription`)
    /// so the caller can restore its error-state write.
    public func requestEventsAccess() async -> StoreAccessResult {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            do {
                let granted: Bool
                if #available(iOS 17.0, macOS 14.0, *) {
                    granted = try await store.requestFullAccessToEvents()
                } else {
                    granted = try await store.requestAccess(to: .event)
                }
                return StoreAccessResult(status: granted ? .authorized : .denied)
            } catch {
                return StoreAccessResult(status: .denied, failureDescription: error.localizedDescription)
            }
        default:
            return StoreAccessResult(status: Self.mapAuthorization(status))
        }
    }

    /// Collapse EventKit's status to the neutral package status. `.fullAccess`
    /// and the pre-iOS-17 `.authorized` map to `.authorized`; `.writeOnly`
    /// maps to `.denied` because write-only access cannot read events, which
    /// the app treats as no access for its read-driven UI.
    private static func mapAuthorization(_ status: EKAuthorizationStatus) -> StoreAuthorizationStatus {
        switch status {
        case .fullAccess: return .authorized
        case .authorized: return .authorized
        case .writeOnly: return .denied
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
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
        guard !normalized.isEmpty, limit > 0, interval.start < interval.end else { return [] }

        // EventKit's `predicateForEvents(withStart:end:calendars:)` caps each
        // predicate at a 4-year span; longer windows silently return nothing.
        // Chunk the requested interval into ≤4-year slices, walk each, and
        // collapse multiple hits per `calendarItemExternalIdentifier` so:
        //   • a multi-day event straddling a chunk boundary isn't counted
        //     twice, and
        //   • a recurring event (every occurrence shares the same
        //     calendarItemExternalIdentifier) collapses to ONE row showing
        //     the most-recent occurrence's date. A plain dict-assignment
        //     dedupe would pick whichever occurrence happened to be visited
        //     last — nondeterministic and almost never "most recent."
        var dedupe: [String: Event] = [:]
        for chunk in Self.chunked(interval: interval, maxYears: 4) {
            let predicate = store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: nil)
            let ekEvents = store.events(matching: predicate)
            for ek in ekEvents {
                let participants = ek.attendees ?? []
                let matches = participants.contains { p in
                    guard let email = Self.email(from: p.url)?.lowercased() else { return false }
                    return normalized.contains(email)
                }
                guard matches, let event = Self.toEvent(ek), let ekid = event.eventKitID else { continue }
                if let existing = dedupe[ekid], existing.startDate >= event.startDate { continue }
                dedupe[ekid] = event
            }
        }

        return dedupe.values
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
            .map { $0 }
    }

    /// Split `interval` into back-to-back slices each no longer than `maxYears`
    /// years. Used to walk EventKit's 4-year-per-predicate ceiling without
    /// silently losing events past the limit.
    private static func chunked(interval: DateInterval, maxYears: Int) -> [DateInterval] {
        var chunks: [DateInterval] = []
        let calendar = Calendar(identifier: .gregorian)
        var cursor = interval.start
        while cursor < interval.end {
            let next = calendar.date(byAdding: .year, value: maxYears, to: cursor) ?? interval.end
            let end = min(next, interval.end)
            chunks.append(DateInterval(start: cursor, end: end))
            cursor = end
        }
        return chunks
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
        // drop any `?headers` and/or `#fragment` after the address (RFC 6068
        // doesn't define a mailto fragment but defensive against future
        // producers), then percent-decode so an international invitee whose
        // ICS payload encoded `@` as `%40` still matches a contact whose
        // email is stored in plain ASCII.
        let raw = url.absoluteString
        let prefixCount = scheme.count + 1 // scheme + ":"
        guard raw.count > prefixCount else { return nil }
        let specifier = raw.dropFirst(prefixCount)
        let addressEnd = specifier.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? specifier.endIndex
        let address = String(specifier[..<addressEnd])
        let decoded = address.removingPercentEncoding ?? address
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
