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

    private(set) var sidecarLocation: SidecarLocation
    // The package's neutral `StoreAuthorizationStatus` is the UI-facing
    // authorization type directly — its four cases (`.notDetermined`,
    // `.authorized`, `.denied`, `.restricted`) are exactly what the gate and
    // banners switch on, so there is no app-side enum or mapping to maintain.
    private(set) var contactsAuthorization: StoreAuthorizationStatus = .notDetermined
    private(set) var eventsAuthorization: StoreAuthorizationStatus = .notDetermined
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

        // Authorization starts at `.notDetermined`; `init` does NOT read system
        // status (an init can't `await`, and an instance-independent status read
        // here would only buy a single frame before the launch-time request
        // methods run anyway). `GuessWhoAppDelegate` awaits
        // `requestContactsAccessIfNeeded()` / `requestEventsAccessIfNeeded()`
        // immediately after construction, which populates the real status before
        // first interaction.
    }

    func requestContactsAccessIfNeeded() async {
        // The adapter owns the CNContactStore and runs the request on it,
        // returning the neutral `StoreAuthorizationStatus` the UI binds to
        // directly (`.limited` already collapsed to `.authorized`). When the
        // request THREW (not a plain user-denial) we restore the same
        // `lastError` write the pre-adapter code made.
        let result = await contactsAdapter.requestContactsAccess()
        contactsAuthorization = result.status
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
        eventsAuthorization = result.status
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

    /// Silent refresh of every event sidecar in `eventUUIDs`. Uses the same
    /// per-event debounce window as `refreshEvent`. Initial-load-only pattern —
    /// callers invoke this once when a contact loads, not on every redraw.
    ///
    /// The contact endpoint is resolved by the repository
    /// (`ContactsRepository.linkedEventUUIDs(for:)`) so the bare event UUIDs
    /// arrive pre-resolved here — SyncService no longer builds a `.contact`
    /// `SidecarKey` to walk the links. This is an event-cache concern that stays
    /// on SyncService until the deferred event-identity migration.
    func refreshLinkedEvents(eventUUIDs: [String]) {
        guard sync != nil else { return }
        for uuid in eventUUIDs {
            refreshEvent(uuid: uuid)
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
        // Stage 6, Step 0: hand the repository the SAME sidecar engine and
        // favorites store this service holds (both Optional — nil in the
        // `.unavailable` storage state) so it can reconcile-on-write and key
        // the contact-favorite path itself. Pure wiring; no behavior change yet
        // (no repository write callers exist until sub-phase 6b).
        ContactsRepository(contacts: contactsAdapter, sync: sync, favorites: favoritesStore)
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

    // The CONTACT-sidecar surface (`sidecar(for:)`, the bare-UUID
    // notes/links/event-link methods) and the CONTACT-identity translation
    // (`guessWhoUUID(in:)`, `reconcile(localID:)`, `reconcileIfNeeded(contact:)`)
    // were removed in Stage 6: the app now keys every contact-sidecar operation
    // on a `ContactID` through `ContactsRepository`, and reconcile is a
    // package-INTERNAL, WRITE-ONLY side effect of a sidecar/favorite write
    // (resolve-or-mint). SyncService performs no contact-identity translation.
    // (The EVENT sidecar surface and the SHARED
    // favorites methods remain — events are out of Stage 6 scope, and favorites
    // are contact+event shared via `FavoriteKind`.)

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
    /// **Caller contract:** refresh the repository cache after this returns so
    /// the list-view caches reflect the changes. SyncService intentionally does
    /// NOT touch the repository — ContactsRepository already holds SyncService,
    /// so injecting the reverse direction adds coupling without an upside (every
    /// current caller already refreshes after its own post-save dance — Stage 6's
    /// `performInlineSave` runs `refreshContact(localID:)` →
    /// `loadContact(preferFresh:)`; no reconcile, since a CONTACT-field edit is
    /// not a sidecar write — 6f).
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

    // MARK: - Contact ↔ Event links (event side)
    //
    // The CONTACT-keyed notes/links/event-link methods (notes/addNote/editNote/
    // deleteNote, contactLinks/addContactLink/setContactLinkNote/
    // removeContactLink, eventLinks, addContactEventLink) moved onto
    // `ContactsRepository` keyed on `ContactID` in Stage 6 — they no longer take
    // a bare contact UUID. The EVENT-side reads below stay here until the
    // deferred event-identity migration.

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
}

struct SidecarUnavailableError: Error, LocalizedError {
    var errorDescription: String? {
        "Sidecar storage is unavailable. Cannot read or write GuessWho data."
    }
}
