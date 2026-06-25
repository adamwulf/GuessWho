import Foundation
import GuessWhoSync

@MainActor
@Observable
final class SyncService {
    enum SidecarLocation: Equatable {
        case iCloud(URL)
        case localFallback(URL, reason: String)
        // Fail-closed: no writable sidecar root could be resolved. Reads
        // return safe defaults, writes are refused with this reason.
        // Better than silently writing to a purgeable tmp dir.
        case unavailable(reason: String)
    }

    enum ContactsAuthorization: Equatable {
        case notRequested
        case denied
        case restricted
        case authorized
    }

    enum EventsAuthorization: Equatable {
        case notRequested
        case denied
        case restricted
        case authorized
    }

    private(set) var sidecarLocation: SidecarLocation
    private(set) var contactsAuthorization: ContactsAuthorization
    private(set) var eventsAuthorization: EventsAuthorization
    private(set) var lastError: String?

    // Exposed so view-models that mint records carrying a writer ID
    // (e.g. NotesStore stamping ContactNote.modifiedBy) stamp with the
    // same identifier the package's setField will stamp the outer cell
    // with. Same source, same value — avoids drifting writer-ID schemes.
    let deviceID: String

    private let contactsAdapter: CNContactStoreAdapter
    private let eventsAdapter: EKEventStoreAdapter
    private let sync: GuessWhoSync?
    // nil only when `sidecarLocation == .unavailable` — favorites need a
    // writable root, same as `sync`. The unqualified `FavoritesStore`
    // refers to the package type; the app-side view-model with the same
    // name lives outside this file and never collides here.
    private let favoritesStore: FavoritesStore?

    // Known v1 limitation: sidecarLocation and sync are resolved once
    // in init() and never refreshed. If the app launches while iCloud
    // Drive is offline and the user signs in mid-session, the app
    // remains in .localFallback (or .unavailable) until relaunch.
    // A future refreshSidecarLocation() could rebuild `sync` on
    // ScenePhase.active transitions, but rebuilding the sidecar root
    // mid-session has implications (in-flight ops, cache state) that
    // are out of scope for the v1 sample.
    init() {
        // The Contacts adapter (isolated to its own actor) owns the one true
        // CNContactStore for fetch/save work AND for the permission request —
        // SyncService no longer constructs an Apple store of its own. The
        // adapter vends a neutral `StoreAuthorizationStatus`, so this target
        // never imports `Contacts` to reason about permission state.
        let adapter = CNContactStoreAdapter()
        self.contactsAdapter = adapter
        // Device-local persistence for the contact change-history cursor, handed
        // to the package's GuessWhoSync so its watcher can advance it. Lives in
        // the container's Application Support — NOT the sidecar root, which can be
        // iCloud-backed: a CNContactStore history token is per-device, so syncing
        // it would make another device think it was caught up and skip real edits.
        let cursorStore = ContactSyncCursorStore(url: Self.contactCursorURL())

        // The EventKit adapter constructs and owns its own EKEventStore (its
        // `init()` defaults `store:` to a fresh EKEventStore) and runs the
        // events permission request itself. SyncService holds no EKEventStore.
        let ekAdapter = EKEventStoreAdapter()
        self.eventsAdapter = ekAdapter

        let location = Self.resolveSidecarLocation()
        self.sidecarLocation = location

        let id = Self.stableDeviceID()
        self.deviceID = id

        switch location {
        case .iCloud(let url):
            let sidecarStore = FileSystemSidecarStore(root: url)
            self.sync = GuessWhoSync(
                contacts: adapter,
                events: ekAdapter,
                sidecars: sidecarStore,
                deviceID: id,
                contactCursorStore: cursorStore
            )
            // Favorites.json lives as a sibling of the sidecar
            // `contacts/`/`events/`/`links/` directories under the same
            // root the sidecar store uses.
            self.favoritesStore = FavoritesStore(root: url)
        case .localFallback(let url, let reason):
            // Worth a breadcrumb so debug builds can see when iCloud
            // failed to provision and we fell back to Application
            // Support. Not user-actionable here — the banner explains
            // the trade-off (local-only, no cross-device sync).
            NSLog("[GuessWho] storage fallback to local: %@", reason)
            let sidecarStore = FileSystemSidecarStore(root: url)
            self.sync = GuessWhoSync(
                contacts: adapter,
                events: ekAdapter,
                sidecars: sidecarStore,
                deviceID: id,
                contactCursorStore: cursorStore
            )
            self.favoritesStore = FavoritesStore(root: url)
        case .unavailable(let reason):
            // Hard failure — neither iCloud nor Application Support was
            // writable. Log loudly so it surfaces in Console.app even if
            // the user never sees the banner.
            NSLog("[GuessWho] storage unavailable: %@", reason)
            self.sync = nil
            self.favoritesStore = nil
        }

        // Seed the UI-facing state from the adapters' current system status so
        // the first render is accurate (e.g. a previously-denied user sees the
        // denied gate immediately, not a flash of "Requesting…"). Both reads
        // are cheap, instance-independent system-state lookups: the contacts
        // adapter's is `nonisolated` so it needs no actor hop, and the events
        // adapter is a plain class. The launch-time request methods refine
        // this once the user responds.
        self.contactsAuthorization = Self.mapContacts(adapter.contactsAuthorizationStatus())
        self.eventsAuthorization = Self.mapEvents(ekAdapter.eventsAuthorizationStatus())
    }

    func requestContactsAccessIfNeeded() async {
        // The adapter owns the CNContactStore and runs the request on it,
        // returning a neutral status (`.limited` already collapsed to
        // `.authorized`). SyncService maps it to its UI-facing enum and — when
        // the request THREW (not a plain user-denial) — restores the same
        // `lastError` write the pre-adapter code made.
        let result = await contactsAdapter.requestContactsAccess()
        contactsAuthorization = Self.mapContacts(result.status)
        if let description = result.failureDescription {
            lastError = "Contacts access request failed: \(description)"
        }
    }

    func requestEventsAccessIfNeeded() async {
        // The adapter owns the EKEventStore and runs the request on it,
        // preserving the prior semantics internally (fullAccess / pre-17
        // authorized → authorized, writeOnly → denied, the iOS17/macOS14
        // `requestFullAccessToEvents` vs legacy `requestAccess(to:)` branch).
        // A thrown request restores the same `lastError` write as before.
        let result = await eventsAdapter.requestEventsAccess()
        eventsAuthorization = Self.mapEvents(result.status)
        if let description = result.failureDescription {
            lastError = "Events access request failed: \(description)"
        }
    }

    // Routes the windowed read through the orchestrator's Option-C projection
    // (`sync.eventsWindow`). EventKit inclusion is gated here — the orchestrator
    // stays permission-agnostic.
    func fetchEventsRange(from start: Date, to end: Date) -> [Event] {
        guard let sync else { return [] }
        let includeEventKit = (eventsAuthorization == .authorized)
        do {
            return try sync.eventsWindow(from: start, to: end, includeEventKit: includeEventKit)
        } catch {
            lastError = "fetchEvents failed: \(error.localizedDescription)"
            return []
        }
    }

    // Sidecar-only read; does NOT require eventsAuthorization. The package's
    // `event(at:)` falls back to the cached projection when EventKit access is
    // denied or the live event is gone.
    func event(uuid: String) -> Event? {
        guard let sync else { return nil }
        do {
            return try sync.event(at: SidecarKey(kind: .event, id: uuid))
        } catch {
            lastError = "event fetch failed: \(error.localizedDescription)"
            return nil
        }
    }

    // Reverse lookup — sidecar event UUID currently pointing at `ekid`, or nil.
    func eventUUID(forEventKitID ekid: String) -> UUID? {
        guard let sync else { return nil }
        do {
            return try sync.eventUUID(forEventKitID: ekid)
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

    /// Link-existing: takes an EventKit identifier and either reuses the
    /// existing sidecar (when one already points at this ekid) or mints a
    /// fresh UUID-keyed sidecar seeded from the live snapshot.
    @discardableResult
    func linkEvent(toEventKitID ekid: String) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        guard eventsAuthorization == .authorized else { throw SidecarUnavailableError() }
        // Pre-dedup: if a sidecar already points at this ekid, return its UUID
        // and skip the mint.
        if let existing = try sync.eventUUID(forEventKitID: ekid) {
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

    /// Edit an event's fields. When the sidecar is linked, the EKEvent is
    /// updated (requires authorized access) and the cache is refreshed from
    /// the post-write read; when unlinked, the cache cells are written
    /// directly (no permission required).
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
        // If the sidecar is linked AND the EKEvent resolves live, this is an
        // EKEventStore write — gate it on authorized access. The orchestrator
        // handles the unlinked/dead-pointer branches sidecar-only.
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

    // MARK: - Refresh (debounced, silent)

    private static let refreshDebounceInterval: TimeInterval = 60

    /// Per-session debounce: maps a sidecar key to the last refresh time.
    /// In-memory only (cleared on launch). @MainActor guarantees serial access.
    private var recentlyRefreshed: [SidecarKey: Date] = [:]

    /// Silent best-effort refresh of an event sidecar's cache cells. Skipped
    /// when the entry was refreshed within `refreshDebounceInterval` seconds.
    /// Errors surface via `lastError` rather than throwing.
    func refreshEvent(uuid: String) {
        guard let sync else { return }
        let key = SidecarKey(kind: .event, id: uuid)
        let now = Date()
        if let last = recentlyRefreshed[key],
           now.timeIntervalSince(last) < Self.refreshDebounceInterval
        {
            return
        }
        do {
            _ = try sync.refreshEventCache(at: key)
            recentlyRefreshed[key] = now
        } catch {
            lastError = "refresh event failed: \(error.localizedDescription)"
        }
    }

    /// Silent refresh for every event linked to `contactUUID`. Uses the same
    /// debounce window as `refreshEvent`. Initial-load-only pattern — callers
    /// invoke this once when the contact loads, not on every redraw.
    func refreshLinkedEvents(forContactUUID contactUUID: String) {
        guard let sync else { return }
        let endpoint = SidecarKey(kind: .contact, id: contactUUID)
        let links: [Link]
        do {
            links = try sync.links(at: endpoint).filter { $0.deletedAt == nil }
        } catch {
            lastError = "refresh linked events failed: \(error.localizedDescription)"
            return
        }
        for link in links {
            let other = Self.otherEndpoint(of: link, from: endpoint)
            guard other.kind == .event else { continue }
            refreshEvent(uuid: other.id)
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

    @discardableResult
    func addEventNote(body: String, forEventUUID uuid: String) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addNote(at: SidecarKey(kind: .event, id: uuid), body: body)
    }

    func editEventNote(id: UUID, newBody: String, forEventUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.editNote(at: SidecarKey(kind: .event, id: uuid), id: id, newBody: newBody)
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

    // MARK: - Calendar search (link-sheet backing reads)

    /// EventKit events whose start falls on the given calendar day. Returns
    /// `[]` when calendar access is denied — gated here so the orchestrator
    /// stays permission-agnostic.
    func eventsOnDay(_ day: Date) -> [Event] {
        guard eventsAuthorization == .authorized else { return [] }
        do {
            return try eventsAdapter.fetchEvents(on: day)
        } catch {
            lastError = "events-on-day failed: \(error.localizedDescription)"
            return []
        }
    }

    /// EventKit events matching `text` within `interval`. Returns `[]` when
    /// access is denied. Empty `text` returns all events in the interval.
    func searchCalendarEvents(text: String, in interval: DateInterval) -> [Event] {
        guard eventsAuthorization == .authorized else { return [] }
        do {
            return try eventsAdapter.searchEvents(matching: text, in: interval)
        } catch {
            lastError = "search events failed: \(error.localizedDescription)"
            return []
        }
    }

    /// EventKit events where any of `emails` appears as an attendee. Backs
    /// the contact detail "Recent Events" section. Scans a 10y-past / 1y-
    /// future window via the package's async wrapper (which hops to a
    /// background queue), most-recent first, capped at `limit`. Returns `[]`
    /// when calendar access is denied or `emails` is empty.
    func recentEvents(forEmails emails: Set<String>, limit: Int = 10) async -> [Event] {
        guard eventsAuthorization == .authorized, let sync, !emails.isEmpty else { return [] }
        do {
            return try await sync.recentEvents(matchingEmails: emails, limit: limit)
        } catch {
            lastError = "recent events lookup failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Migration

    /// Best-effort one-shot migration of legacy event sidecars to the
    /// UUID-keyed shape. Idempotent — safe to call on every launch. Does NOT
    /// require any permission. Called from
    /// `GuessWhoAppDelegate.didFinishLaunchingWithOptions` BEFORE any
    /// permission gate so it runs even when Contacts/Events access is denied.
    func migrateEventsIfNeeded() {
        guard let sync else { return }
        _ = try? sync.migrateEventsToSidecarFirst()
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
    /// used by this service for authorization and writes. UI clients should
    /// retain and read this repository instead of fetching Contacts directly.
    func makeContactsRepository() -> ContactsRepository {
        ContactsRepository(contacts: contactsAdapter)
    }

    /// Fetches one contact by localID without enumerating the whole store.
    /// Returns nil when the contact does not exist or access is not granted.
    /// Use instead of `fetchAll().first { $0.localID == ... }` — routes through
    /// `unifiedContact(withIdentifier:)`, O(1) against the store.
    func fetch(localID: String) async -> Contact? {
        guard contactsAuthorization == .authorized else { return nil }
        do {
            return try await contactsAdapter.fetch(localID: localID)
        } catch {
            lastError = "fetch failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Contact change history (incremental external sync)

    /// Start the package-owned external-contact-change watcher. The package now
    /// owns the `.CNContactStoreDidChange` observer, the change-history cursor,
    /// and the coalescing; it posts `.guessWhoContactsDidChange` when an external
    /// edit lands. The repositories subscribe to that notification. Call once at
    /// launch, after the initial reload, so the watcher begins observing for
    /// subsequent edits. A no-op when storage is unavailable (`sync == nil`).
    func startContactChangeWatcher() {
        sync?.startContactChangeWatcher()
    }

    func sidecar(for contact: Contact) -> SidecarEnvelope? {
        guard let uuid = guessWhoUUID(in: contact) else { return nil }
        guard let sync else { return nil }
        do {
            return try sync.sidecar(at: SidecarKey(kind: .contact, id: uuid))
        } catch {
            lastError = "sidecar read failed: \(error.localizedDescription)"
            return nil
        }
    }

    func guessWhoUUID(in contact: Contact) -> String? {
        for url in contact.urlAddresses {
            if let uuid = SidecarKey.parseGuessWhoContactURL(url.value) {
                return uuid
            }
        }
        return nil
    }

    func reconcile(localID: String) async throws -> IdentityReconcileReport.ContactOutcome {
        guard let sync else {
            throw SidecarUnavailableError()
        }
        return try await sync.reconcileContactIdentity(localID: localID)
    }

    /// Returns the contact's GuessWho UUID, minting one via reconcile if the
    /// contact has not yet been stamped. Used at sidecar/Contacts seams where
    /// the caller needs a UUID to link/favorite/etc. but the user has not yet
    /// opened the contact's detail view (which is the other reconcile trigger).
    /// Throws if reconcile fails or — pathologically — fails to assign a UUID.
    func reconcileIfNeeded(contact: Contact) async throws -> String {
        if let existing = guessWhoUUID(in: contact) {
            return existing
        }
        let outcome = try await reconcile(localID: contact.localID)
        if let assigned = outcome.assignedUUID {
            return assigned
        }
        // Reconcile finished without setting assignedUUID — Cases B/C/D may
        // stamp the on-disk contact without populating that field (e.g. dup
        // GuessWho URLs cleaned up on a contact whose in-memory Contact
        // struct was stale). Re-fetch the single record (post-write, so it
        // must hit the store) and read the freshly written UUID.
        if let fresh = try? await contactsAdapter.fetch(localID: contact.localID),
           let stamped = guessWhoUUID(in: fresh) {
            return stamped
        }
        throw ReconcileAssignmentFailedError()
    }

    // MARK: - Edit

    /// Fetches a `Contact` for editing in the SwiftUI editor. Goes
    /// through the adapter actor (the same path `fetchAll` uses) so
    /// the editor sees the same field set as the rest of the app and
    /// no main-thread fetch is required.
    func fetchContactForEditing(localID: String) async throws -> Contact? {
        try await contactsAdapter.fetch(localID: localID)
    }

    /// Writes the edited contact back through the adapter.
    ///
    /// **Caller contract:** `await repository.reload()` after this
    /// returns so the list-view caches reflect the changes. SyncService
    /// intentionally does NOT touch the repository — ContactsRepository
    /// already holds SyncService, so injecting the reverse direction
    /// adds coupling without an upside (every current caller already
    /// reloads after its own post-save dance — `performInlineSave` runs
    /// performReconcile → loadContact → repository.reload).
    func saveContact(_ contact: Contact) async throws {
        try await contactsAdapter.save(contact)
    }

    /// Deletes the contact identified by `localID`.
    ///
    /// **Caller contract:** `await repository.reload()` after this
    /// returns. See `saveContact` for rationale.
    func deleteContact(localID: String) async throws {
        try await contactsAdapter.delete(localID: localID)
    }

    // MARK: - Notes

    func notes(forContactUUID uuid: String) -> [ContactNote] {
        guard let sync else { return [] }
        do {
            return try sync.notes(at: SidecarKey(kind: .contact, id: uuid))
        } catch {
            lastError = "notes read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addNote(body: String, forContactUUID uuid: String) throws -> UUID {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addNote(at: SidecarKey(kind: .contact, id: uuid), body: body)
    }

    func editNote(id: UUID, newBody: String, forContactUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.editNote(at: SidecarKey(kind: .contact, id: uuid), id: id, newBody: newBody)
    }

    func deleteNote(id: UUID, forContactUUID uuid: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.deleteNote(at: SidecarKey(kind: .contact, id: uuid), id: id)
    }

    // MARK: - Contact Links

    func contactLinks(forContactUUID uuid: String) -> [Link] {
        guard let sync else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: uuid)
        do {
            let all = try sync.links(at: endpoint)
            return all.filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .contact
            }
        } catch {
            lastError = "links read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addContactLink(fromUUID: String, toUUID: String, note: String) throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addLink(
            from: SidecarKey(kind: .contact, id: fromUUID),
            to: SidecarKey(kind: .contact, id: toUUID),
            note: note
        )
    }

    func setContactLinkNote(id: UUID, note: String) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.setLinkNote(id: id, note: note)
    }

    func removeContactLink(id: UUID) throws {
        guard let sync else { throw SidecarUnavailableError() }
        try sync.removeLink(id: id)
    }

    // MARK: - Contact ↔ Event links

    func eventLinks(forContactUUID uuid: String) -> [Link] {
        guard let sync else { return [] }
        let endpoint = SidecarKey(kind: .contact, id: uuid)
        do {
            let all = try sync.links(at: endpoint)
            return all.filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .event
            }
        } catch {
            lastError = "event links read failed: \(error.localizedDescription)"
            return []
        }
    }

    func contactLinks(forEventUUID uuid: String) -> [Link] {
        guard let sync else { return [] }
        let endpoint = SidecarKey(kind: .event, id: uuid)
        do {
            let all = try sync.links(at: endpoint)
            return all.filter { link in
                link.deletedAt == nil && Self.otherEndpoint(of: link, from: endpoint).kind == .contact
            }
        } catch {
            lastError = "contact links read failed: \(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func addContactEventLink(contactUUID: String, eventUUID: String, note: String) throws -> Link {
        guard let sync else { throw SidecarUnavailableError() }
        return try sync.addLink(
            from: SidecarKey(kind: .contact, id: contactUUID),
            to: SidecarKey(kind: .event, id: eventUUID),
            note: note
        )
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
        let fm = FileManager.default
        if let ubiquity = fm.url(forUbiquityContainerIdentifier: "iCloud.com.milestonemade.guesswho") {
            let documents = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            do {
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                return .iCloud(documents)
            } catch {
                // iCloud container exists but is unwritable — try local
                // fallback before giving up.
                if let local = try? localFallbackURL() {
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

        if let local = try? localFallbackURL() {
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

    /// Device-local file backing the contact change-history cursor. Always in
    /// the container's Application Support (`.userDomainMask`), independent of
    /// where the sidecar root resolves — the cursor must never ride iCloud. If
    /// Application Support cannot be resolved, fall back to a temp-dir path so
    /// the store is always constructible; a lost cursor just forces one full
    /// reload, which is safe.
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

    /// Map the package-vended neutral status onto the UI-facing contacts enum.
    /// `.notDetermined` becomes `.notRequested`; the adapter has already
    /// collapsed `.limited` into `.authorized`.
    private static func mapContacts(_ status: StoreAuthorizationStatus) -> ContactsAuthorization {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notRequested
        }
    }

    /// Map the package-vended neutral status onto the UI-facing events enum.
    /// The adapter has already collapsed `.fullAccess` / pre-17 `.authorized`
    /// into `.authorized` and `.writeOnly` into `.denied`.
    private static func mapEvents(_ status: StoreAuthorizationStatus) -> EventsAuthorization {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notRequested
        }
    }
}

struct SidecarUnavailableError: Error, LocalizedError {
    var errorDescription: String? {
        "Sidecar storage is unavailable. Cannot read or write GuessWho data."
    }
}

struct ReconcileAssignmentFailedError: Error, LocalizedError {
    var errorDescription: String? {
        "Could not assign an identity to this contact."
    }
}
