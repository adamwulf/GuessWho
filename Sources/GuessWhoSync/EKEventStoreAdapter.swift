#if canImport(EventKit)
import EventKit
import Foundation
import Logging

// `@unchecked Sendable`: the adapter holds one immutable, thread-safe EventKit
// store. Its window-flight/cache state is isolated by one `NSCondition`; the
// observer token is installed during init and touched again only in deinit.
// That is the basis for the unchecked conformance; it lets
// `requestEventsAccess()` be `async` (it awaits EventKit's permission prompt)
// without the caller's `sending`-check flagging a data race when it hops off
// the caller's actor. Mirrors the rationale behind `GuessWhoSync`'s own
// `@unchecked Sendable`.
public final class EKEventStoreAdapter: EventStoreProtocol, @unchecked Sendable {
    private let store: EKEventStore

    /// Injectable only so tests can count and gate the exact expensive
    /// `events(matching:)` boundary without reading the developer's calendars.
    typealias FetchEventsWork = @Sendable (EKEventStore, DateInterval) throws -> [Event]
    typealias AuthorizationStatusWork = @Sendable () -> StoreAuthorizationStatus
    private let fetchEventsWork: FetchEventsWork
    private let authorizationStatusWork: AuthorizationStatusWork
    private let windowFetches: EventWindowFetchCoordinator
    private let notificationCenter: NotificationCenter
    private var eventStoreChangedObserver: NSObjectProtocol?

    /// One start/finish pair per underlying EventKit enumeration. The UUID and
    /// exact interval let a launch log correlate this adapter work with the
    /// repository's trigger breadcrumbs without relying on a profiler stack.
    fileprivate static let fetchLog = Logger(label: "sync.eventkit-fetch")

    public convenience init(store: EKEventStore = EKEventStore()) {
        self.init(
            store: store,
            notificationCenter: .default,
            fetchEventsWork: { store, interval in
                try Self.fetchEventsDirectly(store: store, interval: interval)
            },
            authorizationStatusWork: {
                Self.mapAuthorization(EKEventStore.authorizationStatus(for: .event))
            }
        )
    }

    /// Store-free test seam for the blocking EventKit enumeration and access
    /// status. Production always uses the public convenience initializer.
    init(
        store: EKEventStore = EKEventStore(),
        notificationCenter: NotificationCenter,
        cacheLifetime: TimeInterval = 20,
        fetchEventsWork: @escaping FetchEventsWork,
        authorizationStatusWork: @escaping AuthorizationStatusWork
    ) {
        self.store = store
        self.fetchEventsWork = fetchEventsWork
        self.authorizationStatusWork = authorizationStatusWork
        self.windowFetches = EventWindowFetchCoordinator(
            cacheLifetime: cacheLifetime,
            maximumCacheEntries: 4
        )
        self.notificationCenter = notificationCenter
        self.eventStoreChangedObserver = nil
        self.eventStoreChangedObserver = notificationCenter.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.windowFetches.invalidate(reason: "EKEventStoreChanged")
        }
    }

    deinit {
        if let eventStoreChangedObserver {
            notificationCenter.removeObserver(eventStoreChangedObserver)
        }
    }

    // MARK: - Authorization

    /// Current events authorization, collapsed to the neutral status.
    /// `EKEventStore.authorizationStatus` is a static system-state read, so
    /// this does not touch the instance store; it lives here to keep the auth
    /// surface behind the adapter port.
    public func eventsAuthorizationStatus() -> StoreAuthorizationStatus {
        let status = authorizationStatusWork()
        windowFetches.authorizationDidResolve(to: status)
        return status
    }

    /// Prompt for events access on this adapter's store and return the
    /// resulting `StoreAccessResult`. Only `.notDetermined` triggers a prompt;
    /// `requestFullAccessToEvents()` is used on iOS 17 / macOS 14+, the legacy
    /// `requestAccess(to:)` before that. A thrown error surfaces as `.denied`
    /// with a non-nil `failureDescription` (the error's `localizedDescription`)
    /// so the caller can restore its error-state write.
    public func requestEventsAccess() async -> StoreAccessResult {
        // The prompt can change read access without producing a store-change
        // notification. Invalidate both before and after it so no pre-prompt
        // result can mask the new permission state.
        windowFetches.invalidate(reason: "calendar-access-request")
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
                let result = StoreAccessResult(status: granted ? .authorized : .denied)
                windowFetches.authorizationDidResolve(to: result.status)
                return result
            } catch {
                let result = StoreAccessResult(status: .denied, failureDescription: error.localizedDescription)
                windowFetches.authorizationDidResolve(to: result.status)
                return result
            }
        default:
            let result = StoreAccessResult(status: Self.mapAuthorization(status))
            windowFetches.authorizationDidResolve(to: result.status)
            return result
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
        let authorization = authorizationStatusWork()
        windowFetches.authorizationDidResolve(to: authorization)

        // Preserve the no-access behavior exactly: without read permission we
        // always ask EventKit and return what it returns. In particular, an
        // empty denied/not-determined result never enters the cache and cannot
        // mask a later permission grant.
        guard authorization == .authorized else {
            return try runUnderlyingWindowFetch(in: interval)
        }

        return try windowFetches.fetch(interval: interval) { [self] in
            try runUnderlyingWindowFetch(in: interval)
        }
    }

    /// The one expensive raw EventKit enumeration. Coalescing surrounds this
    /// operation; `GuessWhoSync.eventsWindow` still receives the exact same raw
    /// batch and applies its sidecar overlay/membership rules unchanged.
    private func runUnderlyingWindowFetch(in interval: DateInterval) throws -> [Event] {
        let fetchID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        Self.fetchLog.info(
            "EventKit window fetch started",
            metadata: [
                "fetchID": .string(fetchID),
                "from": .stringConvertible(interval.start.timeIntervalSince1970),
                "to": .stringConvertible(interval.end.timeIntervalSince1970),
            ]
        )
        do {
            let result = try fetchEventsWork(store, interval)
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startedAt
            Self.fetchLog.info(
                "EventKit window fetch finished",
                metadata: [
                    "fetchID": .string(fetchID),
                    "from": .stringConvertible(interval.start.timeIntervalSince1970),
                    "to": .stringConvertible(interval.end.timeIntervalSince1970),
                    "events": .stringConvertible(result.count),
                    "durationMs": .stringConvertible(Double(elapsedNanos) / 1_000_000),
                ]
            )
            return result
        } catch {
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startedAt
            Self.fetchLog.error(
                "EventKit window fetch failed",
                metadata: [
                    "fetchID": .string(fetchID),
                    "from": .stringConvertible(interval.start.timeIntervalSince1970),
                    "to": .stringConvertible(interval.end.timeIntervalSince1970),
                    "durationMs": .stringConvertible(Double(elapsedNanos) / 1_000_000),
                    "error": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }

    private static func fetchEventsDirectly(
        store: EKEventStore,
        interval: DateInterval
    ) throws -> [Event] {
        // EventKit's `predicateForEvents(withStart:end:calendars:)` caps each
        // predicate at a 4-year span; longer windows silently drop everything
        // past the cap. Chunk like `eventsWithAttendee` does, but dedupe on
        // (eventKitID, startDate) rather than eventKitID alone: this read
        // returns OCCURRENCES, so distinct occurrences of a recurring event
        // must all survive — only the same occurrence re-seen across a chunk
        // boundary (a multi-day event straddling the seam) collapses.
        var seen: Set<String> = []
        var result: [Event] = []
        for chunk in Self.chunked(interval: interval, maxYears: 4) {
            let predicate = store.predicateForEvents(withStart: chunk.start, end: chunk.end, calendars: nil)
            for event in store.events(matching: predicate).compactMap(Self.toEvent) {
                let key = "\(event.eventKitID ?? "")|\(event.startDate.timeIntervalSinceReferenceDate)"
                if seen.insert(key).inserted {
                    result.append(event)
                }
            }
        }
        return result
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
        orLocations locations: Set<String> = [],
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] {
        let normalized: Set<String> = Set(
            emails
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        // Street lines used to match an event's free-text location. Kept in
        // their original case — `EventLocationMatcher` lowercases both sides.
        let locationNeedles: Set<String> = Set(
            locations
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard limit > 0, interval.start < interval.end,
              !(normalized.isEmpty && locationNeedles.isEmpty) else { return [] }

        let fetchID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        Self.fetchLog.info(
            "EventKit attendee window fetch started",
            metadata: [
                "fetchID": .string(fetchID),
                "from": .stringConvertible(interval.start.timeIntervalSince1970),
                "to": .stringConvertible(interval.end.timeIntervalSince1970),
                "emails": .stringConvertible(normalized.count),
                "locations": .stringConvertible(locationNeedles.count),
                "limit": .stringConvertible(limit),
            ]
        )

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
                let matchesEmail = !normalized.isEmpty && participants.contains { p in
                    guard let email = Self.email(from: p.url)?.lowercased() else { return false }
                    return normalized.contains(email)
                }
                let matchesLocation = EventLocationMatcher.matches(
                    location: ek.location, anyOf: locationNeedles
                )
                guard matchesEmail || matchesLocation,
                      let event = Self.toEvent(ek), let ekid = event.eventKitID else { continue }
                if let existing = dedupe[ekid], existing.startDate >= event.startDate { continue }
                dedupe[ekid] = event
            }
        }

        let result = dedupe.values
            .sorted { $0.startDate > $1.startDate }
            .prefix(limit)
            .map { $0 }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startedAt
        Self.fetchLog.info(
            "EventKit attendee window fetch finished",
            metadata: [
                "fetchID": .string(fetchID),
                "from": .stringConvertible(interval.start.timeIntervalSince1970),
                "to": .stringConvertible(interval.end.timeIntervalSince1970),
                "events": .stringConvertible(result.count),
                "durationMs": .stringConvertible(Double(elapsedNanos) / 1_000_000),
            ]
        )
        return result
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
        // Do not wait for EventKit's asynchronous notification: once our own
        // commit succeeds, no caller may reuse a window captured before it.
        windowFetches.invalidate(reason: "event-created")
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
        windowFetches.invalidate(reason: "event-updated")
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
        // Mirror the source calendar's name + color so the list can
        // disambiguate the same event duplicated across calendars.
        let calendar = e.calendar
        let calendarName = (calendar?.title.isEmpty ?? true) ? nil : calendar?.title
        let calendarColorHex = calendar?.cgColor.flatMap(Self.hexString(from:))
        return Event(
            id: Event.stableID(forEventKitID: ekid),
            eventKitID: ekid,
            title: e.title ?? "",
            startDate: e.startDate,
            endDate: e.endDate,
            isAllDay: e.isAllDay,
            location: location,
            eventKitNotes: notes,
            attendees: attendees,
            calendarName: calendarName,
            calendarColorHex: calendarColorHex,
            // EKEvent.creationDate is nil for some synced/imported events —
            // the model tolerates it (sorts treat nil as oldest).
            createdAt: e.creationDate
        )
    }

    /// Convert a `CGColor` to an `#RRGGBB` hex string. EventKit calendar
    /// colors are RGB, but we convert through the sRGB space defensively so a
    /// grayscale or otherwise-modeled color still yields sensible channels.
    /// Returns nil if the color can't be resolved into RGB components.
    static func hexString(from cgColor: CGColor) -> String? {
        guard
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
            let components = converted.components,
            components.count >= 3
        else { return nil }
        // UInt32 bridges to the CUnsignedInt that the %X specifier expects.
        let clamp = { (value: CGFloat) -> UInt32 in
            UInt32((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", clamp(components[0]), clamp(components[1]), clamp(components[2]))
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

    /// Test-only observation proving a second identical caller joined the
    /// existing flight before a gated fake EventKit query is released.
    func inFlightWindowCallerCountForTesting(_ interval: DateInterval) -> Int {
        windowFetches.inFlightCallerCount(for: interval)
    }
}

/// Synchronous generation cache around EventKit's synchronous window query.
///
/// `EventStoreProtocol.fetchEvents(in:)` is intentionally synchronous, while
/// production callers already move it to a background queue. `NSCondition`
/// therefore supplies the same single-flight discipline as `PlaceCorpusCache`:
/// one caller performs a given generation/window query and concurrent callers
/// wait for its exact `Result`. Different windows remain independent.
///
/// Invalidation is linearized under the same condition lock. It advances the
/// generation and clears every cache entry. A caller arriving afterwards can
/// neither hit nor join old-generation work. If invalidation races an active
/// query, that query's result is discarded and all of its callers retry in the
/// new generation, which is stronger than merely preventing stale cache fill.
private final class EventWindowFetchCoordinator: @unchecked Sendable {
    private struct WindowKey: Hashable {
        let start: Date
        let end: Date

        init(_ interval: DateInterval) {
            self.start = interval.start
            self.end = interval.end
        }
    }

    private struct FlightKey: Hashable {
        let generation: UInt64
        let window: WindowKey
    }

    private enum FlightOutcome {
        case result(Result<[Event], Error>)
        case invalidated
    }

    private final class Flight {
        var callerCount = 1
        var outcome: FlightOutcome?
    }

    private struct CacheEntry {
        let events: [Event]
        let capturedAt: UInt64
        var lastUse: UInt64
    }

    private let condition = NSCondition()
    private let cacheLifetimeNanos: UInt64
    private let maximumCacheEntries: Int
    private var generation: UInt64 = 0
    private var lastAuthorization: StoreAuthorizationStatus?
    private var flights: [FlightKey: Flight] = [:]
    private var cache: [WindowKey: CacheEntry] = [:]
    private var useCounter: UInt64 = 0

    init(cacheLifetime: TimeInterval, maximumCacheEntries: Int) {
        self.cacheLifetimeNanos = UInt64(max(0, cacheLifetime) * 1_000_000_000)
        self.maximumCacheEntries = max(1, maximumCacheEntries)
    }

    /// Detect TCC changes even when EventKit emits no store-change
    /// notification. The first observed status establishes the baseline; every
    /// later transition advances the same generation as a store change.
    func authorizationDidResolve(to status: StoreAuthorizationStatus) {
        condition.lock()
        defer { condition.unlock() }
        guard let previous = lastAuthorization else {
            lastAuthorization = status
            return
        }
        guard previous != status else { return }
        lastAuthorization = status
        invalidateLocked(reason: "calendar-access-changed")
    }

    func invalidate(reason: String) {
        condition.lock()
        invalidateLocked(reason: reason)
        condition.unlock()
    }

    private func invalidateLocked(reason: String) {
        generation &+= 1
        cache.removeAll(keepingCapacity: true)
        condition.broadcast()
        EKEventStoreAdapter.fetchLog.info(
            "EventKit window cache invalidated",
            metadata: [
                "reason": .string(reason),
                "generation": .stringConvertible(generation),
            ]
        )
    }

    func fetch(
        interval: DateInterval,
        operation: () throws -> [Event]
    ) throws -> [Event] {
        let window = WindowKey(interval)

        while true {
            condition.lock()
            let activeGeneration = generation
            let now = DispatchTime.now().uptimeNanoseconds
            purgeExpiredEntries(now: now)

            if var entry = cache[window] {
                useCounter &+= 1
                entry.lastUse = useCounter
                cache[window] = entry
                condition.unlock()
                EKEventStoreAdapter.fetchLog.info(
                    "EventKit window fetch cache hit",
                    metadata: [
                        "generation": .stringConvertible(activeGeneration),
                        "from": .stringConvertible(interval.start.timeIntervalSince1970),
                        "to": .stringConvertible(interval.end.timeIntervalSince1970),
                    ]
                )
                return entry.events
            }

            let key = FlightKey(generation: activeGeneration, window: window)
            if let flight = flights[key] {
                flight.callerCount += 1
                let callerCount = flight.callerCount
                EKEventStoreAdapter.fetchLog.info(
                    "EventKit window fetch joined",
                    metadata: [
                        "generation": .stringConvertible(activeGeneration),
                        "callers": .stringConvertible(callerCount),
                        "from": .stringConvertible(interval.start.timeIntervalSince1970),
                        "to": .stringConvertible(interval.end.timeIntervalSince1970),
                    ]
                )
                while flight.outcome == nil && generation == activeGeneration {
                    condition.wait()
                }
                guard generation == activeGeneration,
                      let outcome = flight.outcome
                else {
                    condition.unlock()
                    continue
                }
                condition.unlock()
                switch outcome {
                case .result(let result):
                    return try result.get()
                case .invalidated:
                    continue
                }
            }

            let flight = Flight()
            flights[key] = flight
            condition.unlock()

            let result = Result { try operation() }

            condition.lock()
            if generation != activeGeneration {
                flight.outcome = .invalidated
                flights.removeValue(forKey: key)
                condition.broadcast()
                condition.unlock()
                continue
            }

            if case .success(let events) = result, cacheLifetimeNanos > 0 {
                useCounter &+= 1
                evictLeastRecentlyUsedEntryIfNeeded(for: window)
                cache[window] = CacheEntry(
                    events: events,
                    capturedAt: DispatchTime.now().uptimeNanoseconds,
                    lastUse: useCounter
                )
            }
            flight.outcome = .result(result)
            flights.removeValue(forKey: key)
            condition.broadcast()
            condition.unlock()
            return try result.get()
        }
    }

    func inFlightCallerCount(for interval: DateInterval) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return flights[FlightKey(generation: generation, window: WindowKey(interval))]?.callerCount ?? 0
    }

    private func purgeExpiredEntries(now: UInt64) {
        guard cacheLifetimeNanos > 0 else {
            cache.removeAll(keepingCapacity: true)
            return
        }
        cache = cache.filter { _, entry in
            now >= entry.capturedAt && now - entry.capturedAt <= cacheLifetimeNanos
        }
    }

    private func evictLeastRecentlyUsedEntryIfNeeded(for window: WindowKey) {
        guard cache[window] == nil, cache.count >= maximumCacheEntries,
              let oldest = cache.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
        else { return }
        cache.removeValue(forKey: oldest)
    }
}

#endif
