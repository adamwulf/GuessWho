import Foundation

/// `Sendable` is part of the port contract, not a convenience: the engine's
/// continuation-hop overloads (`eventsWindow`, `recentEvents`, the migration
/// scan) capture the conformer and drive it from `DispatchQueue.global`, and
/// `@MainActor` callers (SyncService) hold it across actor boundaries — every
/// conformer is ALREADY crossing threads. `EKEventStoreAdapter` is
/// `@unchecked Sendable` over an immutable, thread-safe `EKEventStore`; the
/// test fakes guard their mutable state with a per-instance `NSLock`.
public protocol EventStoreProtocol: Sendable {
    // MARK: - Authorization
    //
    // The adapter owns the one true `EKEventStore`, so the permission request
    // runs here rather than in a store the app constructs. Both surface a
    // neutral `StoreAuthorizationStatus` (the adapter collapses EventKit's
    // `.fullAccess` / pre-17 `.authorized` to `.authorized` and `.writeOnly`
    // to `.denied`) so the app target never imports `EventKit` to read state.

    /// Current events authorization, collapsed to the neutral status. A cheap
    /// system-state read; does not enumerate the store.
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus

    /// Prompt for events access on this adapter's store and return the
    /// resulting `StoreAccessResult`. Uses `requestFullAccessToEvents()` on iOS
    /// 17 / macOS 14+, falling back to the legacy `requestAccess(to:)` before
    /// that. A thrown request surfaces as `.denied` with a non-nil
    /// `failureDescription` so the caller can restore its error-state write.
    func requestEventsAccess() async -> StoreAccessResult

    // MARK: - Reads (EventKit-keyed)

    /// All EventKit events intersecting `interval`. Each returned Event has
    /// `eventKitID` set; `id` is a STABLE synthesized UUID derived from the
    /// `eventKitID` (so SwiftUI / EventReference identity is stable across
    /// repeat fetches). The orchestrator/app maps to the real sidecar UUID
    /// via `eventKitID`. `isLinked == true`.
    ///
    /// Adapter implementations may chunk the interval internally (EventKit's
    /// `predicateForEvents` caps each predicate at 4 years); callers may pass
    /// a window of any length without worrying about that limit.
    func fetchEvents(in interval: DateInterval) throws -> [Event]

    /// One EventKit event by its `calendarItemExternalIdentifier`, or nil if
    /// it no longer exists. The dual-namespace adapter implementation may
    /// also resolve legacy `eventIdentifier` strings as a fallback so
    /// dead-pointer migration rows still resolve when the EKEvent is later
    /// re-found by `eventIdentifier`.
    func fetch(eventKitID: String) throws -> Event?

    /// EventKit events whose start falls on the given calendar day (host's
    /// current calendar). Backs the link sheet's per-day sections.
    func fetchEvents(on day: Date) throws -> [Event]

    /// EventKit events matching `text` (title OR location, case-insensitive)
    /// within `interval`. Backs the link sheet search. Empty `text` returns
    /// all events in the interval.
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event]

    /// EventKit events in `interval` that match a contact by attendee email OR
    /// by location. An event matches when any address in `emails` appears among
    /// its `attendees` (case-insensitive), OR when its free-text `location`
    /// contains any street line in `locations` as a contiguous run of words
    /// (see `EventLocationMatcher`). Backs the contact detail "Recent Events"
    /// section: pass the contact's email addresses and street lines, get back
    /// the events the contact appears on or is located at. Results are
    /// de-duplicated across both signals, sorted by `startDate` descending
    /// (most-recent first) and truncated to `limit`. Returns `[]` when BOTH
    /// `emails` and `locations` are empty.
    ///
    /// Adapter implementations may chunk the interval internally (EventKit's
    /// `predicateForEvents` caps each predicate at 4 years); callers may pass
    /// a window of any length without worrying about that limit.
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event]

    /// Migration-only: resolve a legacy `eventIdentifier` (the pre-pivot
    /// sidecar key shape) to an Event whose `eventKitID` is the canonical
    /// `calendarItemExternalIdentifier`. Returns nil if the EKEvent no longer
    /// exists. Used by `migrateEventsToSidecarFirst` (E5.2) to translate
    /// legacy sidecar keys to the new identifier namespace. The adapter
    /// implements this via `store.event(withIdentifier:)`; the in-memory mock
    /// implements it via a test-set translation map.
    func fetch(legacyEventIdentifier: String) throws -> Event?

    // MARK: - Writes (linked events only; Option C)

    /// Create a brand-new EventKit event from the given fields in the host's
    /// default calendar. Returns the created event (with `eventKitID`
    /// populated). Used when the user creates an event that SHOULD land in
    /// their calendar. (Manual "Add Other" events do NOT call this — they
    /// are sidecar-only.)
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event

    /// Update an existing EventKit event's title/start/end/location/isAllDay.
    /// Partial-update semantics: fetch the existing EKEvent, mutate only
    /// these fields, commit. Throws if `eventKitID` no longer resolves to a
    /// live event. Notes are NOT written (GuessWho notes live in the sidecar).
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws
}
