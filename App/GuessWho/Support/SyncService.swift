import Foundation
import GuessWhoSync
import GuessWhoLogging

@MainActor
@Observable
final class SyncService {
    /// Storage-resolution breadcrumbs route through swift-log to
    /// `<AppGroup>/Logs/app.log` (echoed to Console). The `[GuessWho]` prefix is
    /// a developer-facing log body — exempt from the no-internal-vocabulary rule
    /// (see GuessWhoLogging notes).
    private static let log = GuessWhoLog.logger("app.sync-service")

    enum SidecarLocation: Equatable {
        case iCloud(URL)
        case localFallback(URL, reason: String)
        // Fail-closed: no writable sidecar root resolved. Reads return safe
        // defaults, writes are refused with this reason — better than silently
        // writing to a purgeable tmp dir.
        case unavailable(reason: String)
    }

    private(set) var sidecarLocation: SidecarLocation
    // The package's neutral `StoreAuthorizationStatus` is the UI-facing type
    // directly — its four cases (`.notDetermined`, `.authorized`, `.denied`,
    // `.restricted`) are exactly what the gate and banners switch on, so there's
    // no app-side enum or mapping to maintain.
    private(set) var contactsAuthorization: StoreAuthorizationStatus = .notDetermined
    private(set) var eventsAuthorization: StoreAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    // Exposed so view-models that mint records carrying a writer ID (e.g.
    // NotesStore stamping ContactNote.modifiedBy) use the same identifier the
    // package's setField stamps the outer cell with — same source, same value,
    // no drifting writer-ID schemes.
    let deviceID: String

    // Protocol-typed (not the concrete CN/EK adapters) so the designated
    // initializer below can inject the package's in-memory fakes for tests.
    // Every member this service calls is part of the port protocols; the
    // production convenience `init()` still constructs the real adapters.
    private let contactsAdapter: ContactStoreProtocol
    private let eventsAdapter: EventStoreProtocol
    private let sync: GuessWhoSync?
    // nil only when `sidecarLocation == .unavailable` — favorites need a
    // writable root, like `sync`. The unqualified `FavoritesStore` is the
    // package type; the same-named app-side view-model lives outside this file
    // and never collides here.
    private let favoritesStore: FavoritesStore?

    // Known v1 limitation: sidecarLocation and sync are resolved once in init()
    // and never refreshed. If the app launches with iCloud Drive offline and the
    // user signs in mid-session, it stays in .localFallback (or .unavailable)
    // until relaunch. A future refreshSidecarLocation() could rebuild `sync` on
    // ScenePhase.active, but rebuilding the root mid-session (in-flight ops,
    // cache state) is out of scope for the v1 sample.
    /// Production wiring: the Contacts adapter (its own actor) owns the one
    /// true CNContactStore for fetch/save AND the permission request, and the
    /// EventKit adapter constructs and owns its own EKEventStore — SyncService
    /// constructs no Apple store of its own and never imports Contacts/EventKit
    /// to reason about permission. The cursor URL lives in the container's
    /// Application Support, NOT the (possibly iCloud-backed) sidecar root: a
    /// CNContactStore history token is per-device, so syncing it would make
    /// another device think it was caught up and skip real edits.
    convenience init() {
        self.init(
            contactsAdapter: CNContactStoreAdapter(),
            eventsAdapter: EKEventStoreAdapter(),
            sidecarLocation: Self.resolveSidecarLocation(),
            deviceID: Self.stableDeviceID(),
            contactCursorURL: Self.contactCursorURL()
        )
    }

    /// Designated initializer with every port injectable. Internal so
    /// @testable tests can construct the service over the package's in-memory
    /// fakes (`InMemoryContactStore` / `InMemoryEventStore`) and a temp-dir
    /// `sidecarLocation` — the location's URL is just a root directory; the
    /// store construction below is identical for a real iCloud Documents URL
    /// and a test temp dir. Production code uses the convenience `init()`.
    init(
        contactsAdapter: ContactStoreProtocol,
        eventsAdapter: EventStoreProtocol,
        sidecarLocation location: SidecarLocation,
        deviceID id: String,
        contactCursorURL: URL
    ) {
        self.contactsAdapter = contactsAdapter
        self.eventsAdapter = eventsAdapter
        // Device-local persistence for the contact change-history cursor,
        // handed to GuessWhoSync so its watcher can advance it.
        let cursorStore = ContactSyncCursorStore(url: contactCursorURL)

        self.sidecarLocation = location
        self.deviceID = id

        switch location {
        case .iCloud(let url):
            let sidecarStore = FileSystemSidecarStore(root: url)
            self.sync = GuessWhoSync(
                contacts: contactsAdapter,
                events: eventsAdapter,
                sidecars: sidecarStore,
                deviceID: id,
                contactCursorStore: cursorStore
            )
            // Favorites.json is a sibling of the sidecar
            // `contacts/`/`events/`/`links/` directories under the same root.
            self.favoritesStore = FavoritesStore(root: url)
        case .localFallback(let url, let reason):
            // Breadcrumb so debug builds can see iCloud failed to provision and
            // we fell back to Application Support. Not user-actionable here — the
            // banner explains the trade-off (local-only, no cross-device sync).
            Self.log.notice("storage fallback to local", ["reason": reason])
            let sidecarStore = FileSystemSidecarStore(root: url)
            self.sync = GuessWhoSync(
                contacts: contactsAdapter,
                events: eventsAdapter,
                sidecars: sidecarStore,
                deviceID: id,
                contactCursorStore: cursorStore
            )
            self.favoritesStore = FavoritesStore(root: url)
        case .unavailable(let reason):
            // Hard failure — neither iCloud nor Application Support was writable.
            // Log loudly so it surfaces in Console.app even if the user never
            // sees the banner.
            Self.log.error("storage unavailable", ["reason": reason])
            self.sync = nil
            self.favoritesStore = nil
        }

        // Authorization starts at `.notDetermined`; `init` does NOT read system
        // status (an init can't `await`, and a status read here would only buy a
        // single frame before the launch-time request methods run).
        // `GuessWhoAppDelegate` awaits `requestContactsAccessIfNeeded()` /
        // `requestEventsAccessIfNeeded()` right after construction, populating
        // the real status before first interaction.
    }

    func requestContactsAccessIfNeeded() async {
        // The adapter runs the request on its CNContactStore, returning the
        // neutral `StoreAuthorizationStatus` the UI binds to directly (`.limited`
        // already collapsed to `.authorized`). A thrown request (not a plain
        // user-denial) sets `lastError`.
        let result = await contactsAdapter.requestContactsAccess()
        contactsAuthorization = result.status
        if let description = result.failureDescription {
            lastError = "Contacts access request failed: \(description)"
        }
    }

    func requestEventsAccessIfNeeded() async {
        // The adapter runs the request on its EKEventStore, mapping status
        // internally (fullAccess / pre-17 authorized → authorized, writeOnly →
        // denied; iOS17/macOS14 `requestFullAccessToEvents` vs legacy
        // `requestAccess(to:)`). A thrown request sets `lastError`.
        let result = await eventsAdapter.requestEventsAccess()
        eventsAuthorization = result.status
        if let description = result.failureDescription {
            lastError = "Events access request failed: \(description)"
        }
    }

    // Routes the windowed read through the orchestrator's Option-C projection
    // (`sync.eventsWindow`). EventKit inclusion is gated here so the orchestrator
    // stays permission-agnostic. `async` — the window read is a synchronous
    // EventKit query plus a coordinated read of every event sidecar, so it
    // rides the orchestrator's background-hop overload rather than blocking
    // the main actor.
    func fetchEventsRange(from start: Date, to end: Date) async -> [Event] {
        guard let sync else { return [] }
        // Hard ordering: the window read must never see pre-migration keys.
        // Memoized — free after the first completion.
        await migrateEventsIfNeeded()
        let includeEventKit = (eventsAuthorization == .authorized)
        do {
            return try await sync.eventsWindow(from: start, to: end, includeEventKit: includeEventKit)
        } catch {
            lastError = "fetchEvents failed: \(error.localizedDescription)"
            return []
        }
    }

    // Sidecar-only read; does NOT require eventsAuthorization. `event(at:)`
    // falls back to the cached projection when EventKit access is denied or the
    // live event is gone.
    func event(uuid: String) -> Event? {
        guard let sync else { return nil }
        do {
            return try sync.event(at: SidecarKey(kind: .event, id: uuid))
        } catch {
            lastError = "event fetch failed: \(error.localizedDescription)"
            return nil
        }
    }

    // Reverse lookup — sidecar event UUID currently pointing at `ekid`, or
    // nil. `async`: the lookup walks every event sidecar, so it rides the
    // engine's background-hop overload.
    func eventUUID(forEventKitID ekid: String) async -> UUID? {
        guard let sync else { return nil }
        do {
            return try await sync.eventUUID(forEventKitID: ekid)
        } catch {
            lastError = "eventUUID lookup failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Event lifecycle (sidecar-only writes)

    /// Sidecar-only manual event. Not gated by eventsAuthorization — under
    /// the v1 write-path, write-only users land here.
    @discardableResult
    func createManualEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.createManualEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location
        )
    }

    /// Create both a calendar event and its sidecar. Requires authorized read
    /// access so we can write to the EKEventStore.
    @discardableResult
    func createLinkedEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        guard eventsAuthorization == .authorized else { throw SidecarUnavailableError() }
        return try sync.createLinkedEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location
        )
    }

    /// Link-existing: from an EventKit identifier, reuses the existing sidecar
    /// (if one already points at this ekid) or mints a fresh UUID-keyed sidecar
    /// seeded from the live snapshot. `async` for the pre-dedup lookup (an
    /// every-event-sidecar walk); the single EventKit fetch and one-envelope
    /// mint write stay synchronous, bounded work.
    @discardableResult
    func linkEvent(toEventKitID ekid: String) async throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        guard eventsAuthorization == .authorized else { throw SidecarUnavailableError() }
        // Pre-dedup: if a sidecar already points at this ekid, return it, no mint.
        if let existing = try await sync.eventUUID(forEventKitID: ekid) {
            return existing
        }
        guard let snapshot = try eventsAdapter.fetch(eventKitID: ekid) else {
            throw EventStoreError.eventNotFound(eventKitID: ekid)
        }
        return try sync.linkEvent(toEventKitID: ekid, snapshot: snapshot)
    }

    /// Whole-event soft-delete on the sidecar; the EKEvent is untouched.
    func deleteEvent(uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deleteEvent(at: SidecarKey(kind: .event, id: uuid))
    }

    /// Edit an event's fields. Linked: the EKEvent is updated (requires
    /// authorized access) and the cache refreshed from the post-write read.
    /// Unlinked: the cache cells are written directly (no permission required).
    func updateEvent(
        uuid: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws {
        guard let sync else { throw SidecarUnavailableError() }
        let key = SidecarKey(kind: .event, id: uuid)
        // Linked AND the EKEvent resolves live → an EKEventStore write, so gate
        // on authorized access. The orchestrator handles the unlinked/dead-pointer
        // branches sidecar-only.
        if let projected = try sync.event(at: key),
           let ekid = projected.eventKitID,
           let _ = try eventsAdapter.fetch(eventKitID: ekid)
        {
            guard eventsAuthorization == .authorized else { throw SidecarUnavailableError() }
        }
        try sync.updateEventFields(
            at: key,
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location
        )
    }

    /// Stamp `lastViewed = now` on the event sidecar. Best-effort and silent
    /// (a failed stamp must never break opening the detail view); errors
    /// surface via `lastError`. A no-op inside the package when no sidecar
    /// exists at `uuid` — callers stamp AFTER adopt-on-load has resolved the
    /// real sidecar UUID.
    func stampEventViewed(uuid: String) {
        guard let sync else { return }
        do {
            try sync.stampEventViewed(at: SidecarKey(kind: .event, id: uuid))
        } catch {
            lastError = "stamp event viewed failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Refresh (debounced, silent)

    private static let refreshDebounceInterval: TimeInterval = 60

    /// Per-session debounce: sidecar key → last refresh time. In-memory only
    /// (cleared on launch). @MainActor guarantees serial access.
    private var recentlyRefreshed: [SidecarKey: Date] = [:]

    /// Silent best-effort refresh of an event sidecar's cache cells. Skipped
    /// when the entry was refreshed within `refreshDebounceInterval` seconds.
    /// Errors surface via `lastError` rather than throwing. `async` — the
    /// refresh is a coordinated sidecar read + EventKit lookup + possible
    /// write-back, hopped off the main actor by the engine's async overload.
    /// The debounce stamp is written BEFORE the await (marking the attempt,
    /// not the completion) so overlapping callers can't double-refresh the
    /// same key mid-flight.
    func refreshEvent(uuid: String) async {
        guard let sync else { return }
        let key = SidecarKey(kind: .event, id: uuid)
        let now = Date()
        if let last = recentlyRefreshed[key],
           now.timeIntervalSince(last) < Self.refreshDebounceInterval
        {
            return
        }
        recentlyRefreshed[key] = now
        do {
            _ = try await sync.refreshEventCache(at: key)
        } catch {
            lastError = "refresh event failed: \(error.localizedDescription)"
        }
    }

    /// Silent refresh of every event sidecar in `eventUUIDs`, sharing
    /// `refreshEvent`'s per-event debounce. Initial-load-only — callers invoke
    /// it once when a contact loads, not on every redraw.
    ///
    /// The event UUIDs arrive pre-resolved from the contact's own links (the
    /// repository/detail view resolves them), so SyncService builds no
    /// `.contact` `SidecarKey` to walk the links. An event-cache concern that
    /// stays here until the deferred event-identity migration.
    func refreshLinkedEvents(eventUUIDs: [String]) async {
        guard sync != nil else { return }
        for uuid in eventUUIDs {
            await refreshEvent(uuid: uuid)
        }
    }

    // MARK: - Event notes (sidecar-only)

    func eventNotes(forEventUUID uuid: String) -> [ContactNote] {
        guard let sync else { return [] }
        do {
            return try sync.notes(at: SidecarKey(kind: .event, id: uuid))
        } catch {
            lastError = "event notes read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// `createdAt` is the note's user-visible date (defaults to now).
    @discardableResult
    func addEventNote(body: String, createdAt: Date = Date(), forEventUUID uuid: String) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addNote(at: SidecarKey(kind: .event, id: uuid), body: body, createdAt: createdAt)
    }

    /// A non-nil `createdAt` re-stamps the note's user-visible date; nil keeps it.
    func editEventNote(id: UUID, newBody: String, createdAt: Date? = nil, forEventUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.editNote(at: SidecarKey(kind: .event, id: uuid), id: id, newBody: newBody, createdAt: createdAt)
    }

    func deleteEventNote(id: UUID, forEventUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deleteNote(at: SidecarKey(kind: .event, id: uuid), id: id)
    }

    // MARK: - Event tags

    func eventTags(forEventUUID uuid: String) -> [EventTag] {
        guard let sync else { return [] }
        do {
            return try sync.tags(at: SidecarKey(kind: .event, id: uuid))
        } catch {
            lastError = "event tags read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addEventTag(text: String, forEventUUID uuid: String) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addTag(at: SidecarKey(kind: .event, id: uuid), text: text)
    }

    func editEventTag(id: UUID, text: String, forEventUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.editTag(at: SidecarKey(kind: .event, id: uuid), id: id, text: text)
    }

    func deleteEventTag(id: UUID, forEventUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deleteTag(at: SidecarKey(kind: .event, id: uuid), id: id)
    }

    // MARK: - Link-sheet backing reads

    /// Every sidecar-backed event (manual + linked), projected via Option C.
    /// Sidecar-only read — NOT gated on eventsAuthorization, so custom events
    /// stay reachable for write-only users. Backs the link sheet's search
    /// pool: merging these in makes app-created events findable even when
    /// their date falls outside the loaded calendar window. `async`: the walk
    /// covers every event sidecar, so it rides the engine's background-hop
    /// overload.
    func allSidecarEvents() async -> [Event] {
        guard let sync else { return [] }
        do {
            return try await sync.allEvents()
        } catch {
            lastError = "all events read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// The `limit` most-recently-linked events (by link `createdAt`, newest
    /// first, deduped per event). Backs the link sheet's "Recently Linked"
    /// section. Sidecar-only read — NOT gated on eventsAuthorization.
    /// `async`: the walk covers every link sidecar, so it rides the engine's
    /// background-hop overload.
    func recentlyLinkedEvents(limit: Int) async -> [Event] {
        guard let sync else { return [] }
        do {
            return try await sync.recentlyLinkedEvents(limit: limit)
        } catch {
            lastError = "recently linked read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// EventKit events matched to a contact by attendee `emails` OR by street
    /// `addresses` appearing in the event's location text. Backs the contact
    /// detail "Recent Events" section. Scans a 10y-past / 1y-future window via
    /// the package's async wrapper (which hops to a background queue),
    /// most-recent first, capped at `limit`. Returns `[]` when calendar access
    /// is denied or BOTH `emails` and `addresses` are empty.
    func recentEvents(
        forEmails emails: Set<String>,
        addresses: Set<String> = [],
        limit: Int = 10
    ) async -> [Event] {
        guard eventsAuthorization == .authorized, let sync,
              !(emails.isEmpty && addresses.isEmpty) else { return [] }
        do {
            return try await sync.recentEvents(
                matchingEmails: emails, matchingLocations: addresses, limit: limit
            )
        } catch {
            lastError = "recent events lookup failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Guides (imported Apple Maps guides)

    /// Store a decoded guide share link as a guide + its places. Returns the
    /// new guide's UUID. Pure storage — fetching/decoding the URL is
    /// `GuideImporter`'s job, and MapKit resolution runs afterwards.
    @discardableResult
    func importGuide(from snapshot: MapsGuideURL.Snapshot, sourceURL: String?) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.createGuide(from: snapshot, sourceURL: sourceURL)
    }

    /// Every live guide. `async`: the walk covers every guide sidecar, so it
    /// rides the engine's background-hop overload.
    func allGuides() async -> [MapsGuide] {
        guard let sync else { return [] }
        do {
            return try await sync.allGuides()
        } catch {
            lastError = "guides read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Every live place across all guides — the guides list derives its
    /// per-guide place counts from this single walk.
    func allPlaces() async -> [MapsPlace] {
        guard let sync else { return [] }
        do {
            return try await sync.allPlaces()
        } catch {
            lastError = "places read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Imported guides whose places' addresses contain any of `streetLines`
    /// (a contact's structured street lines) — the contact detail's guide rows.
    /// Walks every guide + place sidecar via the background-hop overloads, so
    /// it's safe to call from a view `.task`. Returns `[]` for an empty needle
    /// set (a contact with no street address matches nothing).
    func guides(containingAddresses streetLines: Set<String>) async -> [GuideAddressMatcher.Match] {
        let needles = Set(
            streetLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !needles.isEmpty else { return [] }
        async let fetchedGuides = allGuides()
        async let fetchedPlaces = allPlaces()
        return GuideAddressMatcher.guides(
            containingAnyOf: needles, guides: await fetchedGuides, places: await fetchedPlaces
        )
    }

    /// Imported guides whose places' street lines appear inside `location`
    /// (an event's free-text location) — the event detail's guide rows. Same
    /// background-hop walk as `guides(containingAddresses:)`.
    func guides(matchingLocation location: String?) async -> [GuideAddressMatcher.Match] {
        guard let location,
              !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        async let fetchedGuides = allGuides()
        async let fetchedPlaces = allPlaces()
        return GuideAddressMatcher.guides(
            appearingIn: location, guides: await fetchedGuides, places: await fetchedPlaces
        )
    }

    /// Imported guides that contain a place at `place`'s address — the reverse
    /// lookup powering the place detail's "Guides" section. Derives `place`'s
    /// street-line needle (`GuideAddressMatcher.streetNeedle`) and reuses
    /// `guides(containingAddresses:)`, so a resolved place always lists at least
    /// its own guide. Returns `[]` for an unresolved place-ID entry with no
    /// address yet.
    func guides(containingPlace place: MapsPlace) async -> [MapsGuide] {
        guard let needle = GuideAddressMatcher.streetNeedle(for: place) else { return [] }
        return await guides(containingAddresses: [needle]).map { $0.guide }
    }

    /// The live places in `guideID`, in the guide's shared order.
    func places(inGuide guideID: UUID) async -> [MapsPlace] {
        guard let sync else { return [] }
        do {
            return try await sync.places(inGuide: guideID)
        } catch {
            lastError = "places read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Fill a place's display fields from a MapKit place-ID resolution and
    /// stamp it resolved.
    func markPlaceResolved(
        uuid: String,
        name: String,
        address: String?,
        latitude: Double?,
        longitude: Double?
    ) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.markPlaceResolved(
            at: SidecarKey(kind: .place, id: uuid),
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude
        )
    }

    /// Stamp `lastViewed = now` on the guide sidecar. Best-effort and silent
    /// (a failed stamp must never break opening the guide); errors surface via
    /// `lastError`. A no-op inside the package when no sidecar exists at
    /// `uuid`. Mirrors `stampEventViewed(uuid:)`.
    func stampGuideViewed(uuid: String) {
        guard let sync else { return }
        do {
            try sync.stampGuideViewed(at: SidecarKey(kind: .guide, id: uuid))
        } catch {
            lastError = "stamp guide viewed failed: \(error.localizedDescription)"
        }
    }

    /// Stamp `lastViewed = now` on the place sidecar. Best-effort and silent
    /// (a failed stamp must never break opening the place). A no-op inside the
    /// package when no sidecar exists at `uuid`. Mirrors `stampGuideViewed`.
    func stampPlaceViewed(uuid: String) {
        guard let sync else { return }
        do {
            try sync.stampPlaceViewed(at: SidecarKey(kind: .place, id: uuid))
        } catch {
            lastError = "stamp place viewed failed: \(error.localizedDescription)"
        }
    }

    /// Soft-delete a guide and every place in it.
    func deleteGuide(uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deleteGuide(at: SidecarKey(kind: .guide, id: uuid))
    }

    /// Persist a drag-reorder of a guide's places into `orderedIDs` order.
    /// Best-effort and silent; errors surface via `lastError`. Only meaningful
    /// for the "Guide Order" sort, whose backing cell this rewrites.
    func reorderPlaces(inGuide guideID: UUID, orderedIDs: [UUID]) {
        guard let sync else { return }
        do {
            try sync.reorderPlaces(inGuide: guideID, orderedIDs: orderedIDs)
        } catch {
            lastError = "reorder places failed: \(error.localizedDescription)"
        }
    }

    /// Soft-delete a single place.
    func deletePlace(uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deletePlace(at: SidecarKey(kind: .place, id: uuid))
    }

    // MARK: - Migration

    /// The one-shot migration run, memoized so every await after the first
    /// completion returns immediately. @MainActor makes the check-and-set
    /// atomic (no double-start).
    private var eventMigration: Task<Void, Never>?

    /// Best-effort one-shot migration of legacy event sidecars to the UUID-keyed
    /// shape. Idempotent (safe every launch) and permission-free. Awaited at
    /// the head of the launch events Task in `GuessWhoAppDelegate` — regardless
    /// of permission state — with the sidecar walk hopped off the main actor by
    /// the engine's async `migrateEventsToSidecarFirst()` overload (a
    /// `DispatchQueue.global` continuation hop, not the cooperative pool), so
    /// launch no longer blocks on it. `fetchEventsRange` ALSO awaits this,
    /// making migration-before-window-read a hard guarantee even for a
    /// notification-driven events reload that fires before the launch Task's
    /// explicit await.
    func migrateEventsIfNeeded() async {
        guard let sync else { return }
        if eventMigration == nil {
            eventMigration = Task {
                _ = try? await sync.migrateEventsToSidecarFirst()
            }
        }
        await eventMigration?.value
    }

    func fetchAll() async -> [Contact] {
        guard contactsAuthorization == .authorized else { return [] }
        do {
            return try await contactsAdapter.fetchAll()
        } catch {
            lastError = "fetchAll failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Builds the package-owned contact read repository over the same adapter
    /// this service uses for authorization and writes. UI clients should retain
    /// and read this repository instead of fetching Contacts directly.
    func makeContactsRepository() -> ContactsRepository {
        // Hand the repository the SAME sidecar engine and favorites store this
        // service holds (both nil in the `.unavailable` storage state) so it can
        // reconcile-on-write and key the contact-favorite path itself.
        ContactsRepository(contacts: contactsAdapter, sync: sync, favorites: favoritesStore)
    }

    // MARK: - Contact change history (incremental external sync)

    /// Start the package-owned external-contact-change watcher. The package owns
    /// the `.CNContactStoreDidChange` observer, the change-history cursor, and
    /// the coalescing, and posts `.guessWhoContactsDidChange` (which the
    /// repositories subscribe to) when an external edit lands. Call once at
    /// launch, after the initial reload. A no-op when storage is unavailable
    /// (`sync == nil`).
    func startContactChangeWatcher() {
        sync?.startContactChangeWatcher()
    }

    /// The package-owned sidecar-file watcher: an `NSMetadataQuery` over the
    /// iCloud sidecar root that posts `.guessWhoSidecarsDidChange` when files
    /// arrive/change (remote edits, `notYetDownloaded` files materializing).
    /// Owned here — not by `GuessWhoSync` — because the engine deliberately
    /// hides the store behind `SidecarStoreProtocol` and doesn't know the
    /// root URL; this service resolved it. Retained for the process lifetime
    /// once started.
    private var sidecarFileWatcher: SidecarFileWatcher?

    /// Start watching the iCloud sidecar root for file changes. Idempotent.
    /// A no-op unless storage resolved to `.iCloud`: a local-fallback root
    /// has no cloudd arrivals to observe (only our own writes, which the
    /// repositories already handle synchronously), and the ubiquitous query
    /// scope wouldn't match it anyway.
    func startSidecarFileWatcher() {
        guard case .iCloud(let root) = sidecarLocation else { return }
        guard let sync else { return }
        if sidecarFileWatcher == nil {
            sidecarFileWatcher = SidecarFileWatcher(root: root, sync: sync)
        }
        sidecarFileWatcher?.start()
    }

    // SyncService performs no contact-identity translation: the app keys every
    // contact-sidecar operation on a `ContactID` through `ContactsRepository`,
    // and reconcile is a package-INTERNAL, WRITE-ONLY side effect of a
    // sidecar/favorite write (resolve-or-mint). The EVENT sidecar surface and the
    // SHARED favorites methods (contact+event, via `FavoriteKind`) live here.

    // MARK: - Edit

    /// Writes the edited contact back through the adapter.
    ///
    /// **Caller contract:** refresh the repository cache after this returns so
    /// the list-view caches reflect the change. SyncService intentionally does
    /// NOT touch the repository — ContactsRepository already holds SyncService,
    /// so the reverse direction adds coupling with no upside. Contact detail
    /// editing routes through `ContactsRepository.saveContact(_:for:)`, which
    /// refreshes the edited record inside the package; no reconcile, since a
    /// CONTACT-field edit is not a sidecar write.
    func saveContact(_ contact: Contact) async throws {
        try await contactsAdapter.save(contact)
    }

    // MARK: - Contact ↔ Event links (event side)
    //
    // The CONTACT-keyed notes/links/event-link methods live on
    // `ContactsRepository` (keyed on `ContactID`). The EVENT-side reads below
    // stay here until the deferred event-identity migration.

    /// `async`: the link read walks every link sidecar, so it rides the
    /// engine's background-hop overload rather than blocking the main actor.
    func contactLinks(forEventUUID uuid: String) async -> [Link] {
        guard let sync else { return [] }
        let endpoint = SidecarKey(kind: .event, id: uuid)
        do {
            let all = try await sync.links(at: endpoint)
            return all.filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .contact
            }
        } catch {
            lastError = "contact links read failed: \(error.localizedDescription)"
            return []
        }
    }

    func removeLink(id: UUID) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.removeLink(id: id)
    }

    static func otherEndpoint(of link: Link, from endpoint: SidecarKey) -> SidecarKey {
        link.endpointA == endpoint ? link.endpointB : link.endpointA
    }

    func recordError(_ message: String) {
        lastError = message
    }

    // MARK: - Favorites

    /// Current ordered favorites list. Returns `[]` when storage is
    /// unavailable or the on-disk file is missing / unreadable; errors
    /// surface via `lastError`.
    func favorites() -> [Favorite] {
        guard let favoritesStore else { return [] }
        do {
            return try favoritesStore.loadAll()
        } catch {
            lastError = "favorites read failed: \(error.localizedDescription)"
            return []
        }
    }

    /// `false` on error or when storage is unavailable.
    func isFavorite(kind: FavoriteKind, id: String) -> Bool {
        guard let favoritesStore else { return false }
        do {
            return try favoritesStore.isFavorite(kind: kind, id: id)
        } catch {
            lastError = "favorites lookup failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Returns the new state: `true` if just added, `false` if removed.
    @discardableResult
    func toggleFavorite(kind: FavoriteKind, id: String) throws -> Bool {
        guard let favoritesStore else { throw SidecarUnavailableError() }
        return try favoritesStore.toggle(kind: kind, id: id, now: Date())
    }

    /// Persist a full ordered list. Used by reorder/move and by the swipe-
    /// to-unfavorite path's reorder primitive.
    func setFavoritesOrder(_ items: [Favorite]) throws {
        guard let favoritesStore else { throw SidecarUnavailableError() }
        try favoritesStore.setAll(items)
    }

    // MARK: - Private

    private static func resolveSidecarLocation() -> SidecarLocation {
        resolveSidecarLocation(
            ubiquityContainerURL: FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudContainer.id
            ),
            localFallback: localFallbackURL
        )
    }

    /// The storage-resolution ladder with its two environment probes injected:
    /// iCloud container Documents → local Application Support → unavailable.
    /// Internal so @testable tests can drive every rung with plain temp-dir
    /// URLs and a throwing fallback — `url(forUbiquityContainerIdentifier:)`
    /// and the real Application Support are unreachable from a unit test.
    static func resolveSidecarLocation(
        ubiquityContainerURL: URL?,
        localFallback: () throws -> URL
    ) -> SidecarLocation {
        let fm = FileManager.default
        if let ubiquity = ubiquityContainerURL {
            let documents = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            do {
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                return .iCloud(documents)
            } catch {
                // iCloud container exists but is unwritable — try local fallback
                // before giving up.
                if let local = try? localFallback() {
                    return .localFallback(
                        local,
                        reason: "iCloud container found but its Documents folder is unwritable: \(error.localizedDescription)"
                    )
                }
                return .unavailable(
                    reason: "iCloud container is unwritable and no local fallback directory is available."
                )
            }
        }

        if let local = try? localFallback() {
            return .localFallback(
                local,
                reason: "iCloud Drive is unavailable. Sign in to iCloud and enable iCloud Drive to sync across devices."
            )
        }
        return .unavailable(
            reason: "No writable storage location is available. Application Support is unavailable on this device."
        )
    }

    private static func localFallbackURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("GuessWhoSidecars", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Device-local file backing the contact change-history cursor. Always in the
    /// container's Application Support (`.userDomainMask`), independent of the
    /// sidecar root — the cursor must never ride iCloud. Falls back to a temp-dir
    /// path if Application Support can't be resolved, so the store is always
    /// constructible; a lost cursor just forces one safe full reload.
    private static func contactCursorURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("GuessWhoSync", isDirectory: true)
        return dir.appendingPathComponent("contacts-change-cursor")
    }

    private static func stableDeviceID() -> String {
        let defaults = UserDefaults.standard
        let key = "com.milestonemade.guesswho.deviceID"
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: key)
        return fresh
    }
}

// The app's local `SidecarUnavailableError` copy was removed in favor of the
// package's public type (its doc comment always planned this): two same-named
// types meant an app-side `catch is SidecarUnavailableError` bound the local
// one and silently missed package-thrown errors. Every `throw
// SidecarUnavailableError()` above now resolves to `GuessWhoSync`'s type, so
// service-thrown and repository-thrown storage-unavailable errors are one
// catchable type. (Caught by the SyncService unit tests, which type-check the
// thrown error.)
