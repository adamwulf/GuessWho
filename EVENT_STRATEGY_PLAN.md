# GuessWhoSync — Event Strategy Plan (Sidecar-First Events)

A migration plan to pivot the event model from **EventKit-canonical, read-only, sidecar-optional** to **sidecar-first, EventKit-link-optional** (design "Option C"). Every event becomes a first-class sidecar entity that may optionally carry an `eventKitID` linking it to a live EventKit event.

This document follows the conventions of `PLAN.md` (numbered sections, tables, concrete file paths and signatures). It is a companion spec: where it changes a `PLAN.md` rule, it says so explicitly. Section numbers here are **local to this document** (E1–E7 + sub-sections) and do not renumber `PLAN.md`.

---

## E0. Summary of the pivot

| Dimension | Today (PLAN.md §2, §4) | After this plan |
|---|---|---|
| Event source of truth | EventKit; sidecar optional | Sidecar always exists; EventKit optional via `eventKitID` |
| Event sidecar key | `event.externalID` (= `calendarItemExternalIdentifier`) | Minted GuessWho **event UUID** (lowercased), like contacts |
| EventKit writes | Forbidden (`PLAN.md §2`: "Events are read-only") | Allowed for linked events (title/start/end/location) |
| Notes / contacts / tags on events | n/a (only contact↔event links existed) | Always sidecar; never EventKit |
| Display values | EventKit live values | EventKit live if linked & present, else sidecar cache |
| Deleted-from-EventKit | (event vanishes from list) | Silent fallback to cache; `eventKitID` retained |

This is a breaking change to `PLAN.md §2` ("Writing to EventKit events. Events are read-only") and to the §4 storage-boundary row for events ("per-event keyed by `calendarItemExternalIdentifier`"). Both are amended in E1.

The core sidecar primitives are **unchanged**: the §5.2 envelope shape, §5.3 per-cell LWW merge, `deletedAt` soft-delete, the `reconcileSidecars()` conflict path, and the field-instance API (`addField`/`setField`/`deleteField`/`field`/`fields`) all carry over verbatim. We add: a new `Event` model, three new `EventStoreProtocol` methods, a small set of orchestrator event-convenience methods (modeled on `GuessWhoSync+Notes.swift`), an EventKit write path on the adapter (modeled on `CNContactStoreAdapter.save`), and a one-shot migration.

---

## E1. Data-model changes (GuessWhoSync package)

### E1.1 `Event` model — `Sources/GuessWhoSync/Event.swift`

The current `Event` (`Sources/GuessWhoSync/Event.swift:3-29`) is an EventKit mirror keyed by `externalID`. It gains a GuessWho UUID and an optional EventKit link. To preserve every call site that reads `event.title` / `event.startDate` / etc., we keep those property names and add the new fields.

**New shape:**

```swift
public struct Event: Hashable, Sendable, Codable {
    /// GuessWho event UUID — the sidecar key. Minted at create. Lowercased.
    /// This REPLACES externalID as the identity. (Was: calendarItemExternalIdentifier.)
    public var id: UUID

    /// Optional pointer OUT to an EventKit event. nil for manual ("Add Other")
    /// events. Set when the user links an event from their calendar. Never
    /// auto-cleared, even when the EventKit event is deleted (Option C).
    public var eventKitID: String?

    // Displayable fields. For a linked event whose EventKit event still
    // exists, these are refreshed from EventKit (the "live" values). For an
    // unlinked event, or a linked event whose EventKit event is gone, these
    // are the sidecar cache.
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var location: String?

    /// EventKit's own notes string. Display-only mirror of EKEvent.notes;
    /// distinct from GuessWho event notes (which are sidecar field-instances,
    /// see E1.3). Kept for parity with today's Event.notes.
    public var eventKitNotes: String?

    public init(
        id: UUID = UUID(),
        eventKitID: String? = nil,
        title: String = "",
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        eventKitNotes: String? = nil
    )
}
```

Notes:
- `notes` is renamed to `eventKitNotes` to disambiguate from GuessWho event notes (E1.3). The app's `EventsRepository.filtered` (`App/GuessWho/Support/EventsRepository.swift:35`) and `EventDetailView.detailsSection` (`App/GuessWho/EventDetailView.swift:68`) update to `eventKitNotes`.
- `id` is a `UUID` (was `externalID: String`). `SidecarKey.forEvent` changes accordingly (E1.4).
- `Event` remains `Codable` so a snapshot can be embedded in a sidecar `JSONValue` if ever needed (per `PLAN.md §7.1` Codable rule).

**Helper added to `Event`:**

```swift
extension Event {
    /// True iff this event points at an EventKit event (regardless of whether
    /// that event currently exists).
    public var isLinked: Bool { eventKitID != nil }
}
```

### E1.2 Event sidecar schema (the §5.2 envelope for events)

Event sidecars use the **same field-instance envelope** as contacts (`PLAN.md §5.2` — "`.event` … same as `.contact`"). The envelope's `entityID` is the **event UUID** (lowercased), not the externalID. Cells split into two groups:

**(a) Singleton "well-known" cells — fixed cell keys, one instance each.** These deviate from the "every field is multi-instance" rule for contacts (`PLAN.md §5.2`) the same way **links** deviate (`PLAN.md §5.2` table row for `.link` uses well-known cell names). We use fixed cell keys for the event's intrinsic scalar fields so reads are O(1) and writes target a known cell. Each is a §5.2 cell whose inner `value` follows the `{ field, type, value }` shape so the generic merge and `SidecarField` decode still apply.

| Cell key (envelope `fields` key) | Inner `type` | Inner `value` payload | Meaning |
|---|---|---|---|
| `eventKitID` | `note` | string, or cell soft-deleted/`value:null` when unlinked | The EventKit `calendarItemExternalIdentifier`. Pointer OUT. |
| `titleCache` | `note` | string | Cached EventKit (or manual) title |
| `startCache` | `date` | ISO8601 string | Cached start |
| `endCache` | `date` | ISO8601 string | Cached end |
| `isAllDayCache` | `checkbox` | bool | Cached all-day flag |
| `locationCache` | `note` | string (empty when no location) | Cached location |
| `eventKitNotesCache` | `note` | string | Cached EventKit notes string |

> Why fixed keys rather than minted-UUID instances: an event has exactly one title/start/end. Using well-known keys (like links) means the cache-refresh write (E4) is a deterministic per-cell write that LWW-merges cleanly across devices, and avoids accumulating duplicate cache instances. The `SidecarField` inner-value shape is preserved, so `merge(_:_:)` is untouched (`PLAN.md §5.3`).

**(b) Multi-instance cells — minted-UUID keys, zero-to-many.** These are real field-instances exactly like contact notes.

| Logical field | Inner `type` | Inner `value` | Convenience field name |
|---|---|---|---|
| Notes | `note` | string | `GuessWhoSync.contactNoteFieldName` (`"note"`) — reused |
| Tags | `note` | string (the tag text) | new `GuessWhoSync.eventTagFieldName` (`"tag"`) |

> Tags are `.note`-typed instances distinguished by `field == "tag"`, mirroring how notes are `.note`-typed instances distinguished by `field == "note"` (`Sources/GuessWhoSync/GuessWhoSync+Notes.swift:10`). No new `SidecarFieldType` is needed — `PLAN.md §5.2` says new feature types add new cell shapes, never new merge code. A future richer tag (color, etc.) can extend the inner object with extra keys (preserved on round-trip per §5.2).

**(c) Contact links** are **not** event sidecar cells. They remain independent `links/<uuid>.json` envelopes (`PLAN.md §13`). With events now keyed by UUID, a contact↔event link's event endpoint becomes `SidecarKey(kind: .event, id: <eventUUID>)` instead of `…id: <externalID>`. Migration (E5) rewrites existing link endpoints.

**Reserved cell-key namespace.** To prevent a future multi-instance field from colliding with a singleton cell key, the singleton keys above (`eventKitID`, `titleCache`, …) are reserved: `addField`/`addNote`/`addTag` mint random UUID keys (`UUID().uuidString`), which can never collide with these fixed strings. No code change needed — documenting the invariant.

### E1.3 Why a separate UUID instead of `externalID`

Mirrors `PLAN.md §3.1`'s contact rationale, inverted:
- A **manual** event ("Add Other") has no EventKit event, so there is no `calendarItemExternalIdentifier` to key on. It needs its own minted UUID.
- A **linked** event must survive EventKit deletion without losing its sidecar (Option C: "eventKitID stays set"). If we kept keying by externalID, deletion-then-recreation in Calendar would orphan the sidecar. A stable GuessWho UUID with `eventKitID` as a mutable pointer cell decouples identity from EventKit's lifecycle.
- Two devices that independently link the same EventKit event will mint two different event UUIDs. This is the analogue of `PLAN.md §3.3` Case D for contacts. **v1 decision (see E7 Q1):** we do **not** auto-merge duplicate event UUIDs sharing an `eventKitID`. We surface them and let the UI dedup, OR we add an event-identity reconcile pass. Defaulting to: surface only, dedup deferred — keeps this migration bounded.

### E1.4 `SidecarKey` changes — `Sources/GuessWhoSync/SidecarKey.swift`

`SidecarKey.init` currently lowercases `.contact`/`.link` ids but leaves `.event` untouched because event ids were opaque EventKit strings (`Sources/GuessWhoSync/SidecarKey.swift:13-19`). Now event ids are UUIDs, so `.event` joins the lowercasing branch:

```swift
switch kind {
case .contact, .link, .event:   // .event added
    self.id = id.lowercased()
}
```

`SidecarKey.forEvent(_:)` (`Sources/GuessWhoSync/SidecarKey.swift:67-69`) changes:

```swift
public static func forEvent(_ event: Event) -> SidecarKey {
    SidecarKey(kind: .event, id: event.id.uuidString)   // was: event.externalID
}
```

**Filename safety (PLAN.md §5.1).** With UUID event keys, the percent-encoding branch for events in `FileSystemSidecarStore.safeFilename` (`Sources/GuessWhoSync/FileSystemSidecarStore.swift:353-360`) and the decode branch in `listKeys` (`…:394-395`) become unnecessary — event filenames are now lowercase-UUID `.json` like contacts. **Keep the percent-encoding branch for backward compatibility** during migration (old files are still externalID-named on disk until migrated), but route new event keys through the lowercased-UUID branch. Concretely, change the `.event` cases in `safeFilename` and `listKeys` to the same `.contact`/`.link` lowercasing path. Migration (E5) renames the old files; until it runs, `read` of a not-yet-migrated externalID key would miss — which is why migration runs **before** any event read (E5.3).

### E1.5 `EventStoreProtocol` changes — `Sources/GuessWhoSync/EventStoreProtocol.swift`

Today (`Sources/GuessWhoSync/EventStoreProtocol.swift:3-6`):

```swift
public protocol EventStoreProtocol {
    func fetchEvents(in interval: DateInterval) throws -> [Event]
    func fetch(externalID: String) throws -> Event?
}
```

New surface — the methods now traffic in EventKit identifiers explicitly (the protocol speaks EventKit, the orchestrator owns UUID mapping):

```swift
public protocol EventStoreProtocol {
    // --- Reads (EventKit-keyed) ---

    /// All EventKit events intersecting `interval`. Each returned Event has
    /// eventKitID set and id == UUID() placeholder (orchestrator/app maps to
    /// the real sidecar UUID via eventKitID — see E2.2). isLinked == true.
    func fetchEvents(in interval: DateInterval) throws -> [Event]

    /// One EventKit event by its calendarItemExternalIdentifier, or nil if it
    /// no longer exists. Replaces today's fetch(externalID:).
    func fetch(eventKitID: String) throws -> Event?

    /// EventKit events whose start falls on the given calendar day (host's
    /// current calendar). Backs the link sheet's "Today" / per-day sections (E3).
    func fetchEvents(on day: Date) throws -> [Event]

    /// EventKit events matching `text` (title OR location, case-insensitive)
    /// within `interval`. Backs the link sheet search (E3). Empty `text`
    /// returns all events in the interval.
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event]

    // --- Writes (linked events only; Option C) ---

    /// Create a brand-new EventKit event from the given fields in the host's
    /// default calendar. Returns the created event (with eventKitID populated).
    /// Used when the user creates an event that SHOULD land in their calendar.
    /// (Manual "Add Other" events do NOT call this — they are sidecar-only.)
    func createEvent(title: String,
                     startDate: Date,
                     endDate: Date,
                     isAllDay: Bool,
                     location: String?) throws -> Event

    /// Update an existing EventKit event's title/start/end/location/isAllDay.
    /// Partial-update semantics (mirrors CNContactStoreAdapter.save): fetch the
    /// existing EKEvent, mutate only these fields, commit. Throws if the
    /// eventKitID no longer resolves to a live event. Notes are NOT written
    /// (GuessWho notes live in the sidecar).
    func updateEvent(eventKitID: String,
                     title: String,
                     startDate: Date,
                     endDate: Date,
                     isAllDay: Bool,
                     location: String?) throws
}
```

> `fetch(eventKitID:)` returning `nil` is the signal for "deleted from EventKit → fall back to cache" (Option C). The orchestrator never throws on a missing EventKit event during display refresh.

This amends `PLAN.md §7.2`'s "`// No save: events are read-only.`" comment — events are now writable for linked events. Add a note to `PLAN.md §2` non-goals removing the "Events are read-only" bullet, and to §4 changing the EventKit row to "canonical for **linked** event title/start/end/location; read-and-write."

### E1.6 `EKEventStoreAdapter` changes — `Sources/GuessWhoSync/EKEventStoreAdapter.swift`

The adapter (`Sources/GuessWhoSync/EKEventStoreAdapter.swift:5-36`) implements the new protocol. `toEvent` sets `eventKitID` and mints a placeholder `id`:

```swift
private static func toEvent(_ e: EKEvent) -> Event? {
    guard let ekid = e.calendarItemExternalIdentifier, !ekid.isEmpty else { return nil }
    return Event(
        id: UUID(),                 // placeholder; sidecar layer owns the real UUID
        eventKitID: ekid,
        title: e.title ?? "",
        startDate: e.startDate,
        endDate: e.endDate,
        isAllDay: e.isAllDay,
        location: (e.location?.isEmpty ?? true) ? nil : e.location,
        eventKitNotes: (e.notes?.isEmpty ?? true) ? nil : e.notes
    )
}
```

> NOTE: today's adapter keys on `e.eventIdentifier` (`…:23`), the link-sheet should key on `calendarItemExternalIdentifier` (the stable cross-device id per `PLAN.md §3.1`). This corrects an existing latent mismatch (`SidecarKey.forEvent` used externalID but the adapter emitted `eventIdentifier`). Use `calendarItemExternalIdentifier` consistently.

New methods:
- `fetch(eventKitID:)` — `store.calendarItems(withExternalIdentifier:)` → first `EKEvent`, or fall back to `store.event(withIdentifier:)` for legacy. Returns nil if none.
- `fetchEvents(on:)` — build a one-day `DateInterval` (`startOfDay … startOfNextDay`) and reuse the predicate path.
- `searchEvents(matching:in:)` — fetch the interval, filter on `title`/`location` case-insensitively in-process (EventKit has no text predicate).
- `createEvent(...)` — `EKEvent(eventStore:)`, set fields, `calendar = store.defaultCalendarForNewEvents`, `try store.save(_:span:.thisEvent commit:true)`, return `toEvent`.
- `updateEvent(eventKitID:...)` — resolve the `EKEvent`; if nil, throw `EventStoreError.eventNotFound(eventKitID:)`; mutate the five fields; `try store.save(_:span:.thisEvent commit:true)`.

New error type `Sources/GuessWhoSync/EventStoreError.swift`:

```swift
public enum EventStoreError: Error, Equatable {
    case eventNotFound(eventKitID: String)
    case noWritableCalendar
}
```

### E1.7 Orchestrator event API — new file `Sources/GuessWhoSync/GuessWhoSync+Events.swift`

Modeled on `GuessWhoSync+Notes.swift`. Adds an event-typed convenience layer over the existing field-instance + raw-cell primitives. **No new merge code.** Reserved-key writes go through a small private helper that writes one well-known cell (like the link cells in `addLink`, `Sources/GuessWhoSync/GuessWhoSync.swift:169-203`).

```swift
extension GuessWhoSync {
    // Well-known event cell keys (E1.2 group a).
    public static let eventKitIDCellKey       = "eventKitID"
    public static let eventTitleCacheKey      = "titleCache"
    public static let eventStartCacheKey      = "startCache"
    public static let eventEndCacheKey        = "endCache"
    public static let eventIsAllDayCacheKey   = "isAllDayCache"
    public static let eventLocationCacheKey   = "locationCache"
    public static let eventNotesCacheKey      = "eventKitNotesCache"

    // Well-known field name for event tag instances (E1.2 group b).
    public static let eventTagFieldName       = "tag"

    // ---- Lifecycle ----

    /// Create a sidecar-only (manual) event. Mints an event UUID, writes the
    /// cache cells from the supplied fields, leaves eventKitID unset. Returns
    /// the event UUID (the SidecarKey id).
    @discardableResult
    public func createManualEvent(title: String,
                                  startDate: Date,
                                  endDate: Date,
                                  isAllDay: Bool,
                                  location: String?) throws -> UUID

    /// Create a sidecar event linked to a freshly-created EventKit event. Calls
    /// events.createEvent(...) then writes the sidecar with eventKitID + cache.
    /// Returns the event UUID. (Used when the user wants the event in Calendar.)
    @discardableResult
    public func createLinkedEvent(title: String,
                                  startDate: Date,
                                  endDate: Date,
                                  isAllDay: Bool,
                                  location: String?) throws -> UUID

    /// Create a sidecar event that links to an EXISTING EventKit event the user
    /// picked in the link sheet (E3). Writes eventKitID + a cache snapshot taken
    /// from `ekEvent`. Returns the event UUID. Does NOT dedup against an existing
    /// sidecar already pointing at the same eventKitID (see E7 Q1 — caller checks
    /// via eventUUID(forEventKitID:) first if it wants edit-existing behavior).
    @discardableResult
    public func linkEvent(toEventKitID ekid: String,
                          snapshot ekEvent: Event) throws -> UUID

    // ---- Read / project ----

    /// Returns the displayable Event for a sidecar event UUID, applying the
    /// Option C display rule: if eventKitID is set AND events.fetch(eventKitID:)
    /// returns a live event, use the EventKit live values; otherwise use the
    /// cached cells. Returns nil if no sidecar exists at this key.
    public func event(at key: SidecarKey) throws -> Event?

    /// All sidecar events (every events/<uuid>.json), projected via the Option C
    /// display rule. O(N events) + one EventKit fetch per linked event — callers
    /// that render lists should prefer the windowed read in the app layer.
    public func allEvents() throws -> [Event]

    /// Reverse lookup: the sidecar event UUID currently pointing at `ekid`, or
    /// nil. O(N events). Used to avoid double-linking (E7 Q1) and by migration.
    public func eventUUID(forEventKitID ekid: String) throws -> UUID?

    // ---- Edit (Option C write routing) ----

    /// Edit title/start/end/location/isAllDay. If the event is linked AND its
    /// EventKit event still exists, the edit goes to EventKit via
    /// events.updateEvent(...) and the sidecar cache is refreshed from the
    /// post-write EventKit read. If unlinked (or EventKit event is gone), the
    /// edit writes the cache cells directly. Notes/tags are NEVER touched here.
    public func updateEventFields(at key: SidecarKey,
                                  title: String,
                                  startDate: Date,
                                  endDate: Date,
                                  isAllDay: Bool,
                                  location: String?) throws

    /// Refresh the sidecar cache cells from EventKit for a linked event. No-op
    /// for unlinked events or when the EventKit event is gone (Option C: do NOT
    /// auto-unlink). Returns the refreshed Event (or cached if not refreshable).
    @discardableResult
    public func refreshEventCache(at key: SidecarKey) throws -> Event?

    // ---- Notes (reuse contact-note machinery, event key) ----
    // addNote/editNote/deleteNote/notes already accept any SidecarKey
    // (GuessWhoSync+Notes.swift) — they work on event keys unchanged.

    // ---- Tags ----

    /// Add a tag instance (a .note-typed field with field == eventTagFieldName).
    @discardableResult
    public func addTag(at key: SidecarKey, text: String) throws -> UUID

    /// Edit a tag's text. Silent no-op if missing.
    public func editTag(at key: SidecarKey, id: UUID, text: String) throws

    /// Soft-delete a tag. Silent no-op if missing/already deleted.
    public func deleteTag(at key: SidecarKey, id: UUID) throws

    /// Live (non-deleted) tags, sorted by (createdAt, id) like notes(at:).
    public func tags(at key: SidecarKey) throws -> [String]   // or [EventTag]
}
```

**Implementation notes for the well-known cell writes.** `createManualEvent` / `linkEvent` / `refreshEventCache` write the group-(a) cells with a private `writeWellKnownCell(at:key:field:type:value:)` helper that mirrors `addField`'s cell-construction (`Sources/GuessWhoSync/GuessWhoSync.swift:43-63`) but uses a **fixed cell key** instead of a minted UUID, under the per-key `sidecarLocks.withLock` discipline. Each cell's inner `value` uses `SidecarField.makeInnerValue(field:type:value:createdAt:)` (`Sources/GuessWhoSync/SidecarField.swift:93-105`) so `SidecarField.decode` still reads them.

`event(at:)` reads the envelope once (`sidecars.read`), decodes the well-known cells into an `Event`, then — if `eventKitID` cell is live — calls `events.fetch(eventKitID:)` and overlays the live values onto the cached `Event`, preserving the sidecar UUID as `id`.

`updateEventFields` routing decision tree:
1. Read sidecar; if no `eventKitID` (or cell soft-deleted) → write cache cells. Done.
2. `eventKitID` present → `events.fetch(eventKitID:)`. If nil (deleted) → write cache cells only (do NOT unlink). Done.
3. Live → `events.updateEvent(eventKitID:...)`, then `refreshEventCache(at:)` reads back the post-write EventKit values into the cache.

### E1.8 `GuessWhoSync.init` — events store stays injected

No change to the `GuessWhoSync` constructor (`Sources/GuessWhoSync/GuessWhoSync.swift:10-20`) — it already takes `events: EventStoreProtocol`. The orchestrator now *calls* the new write methods on it.

---

## E2. App-layer changes

### E2.1 `SyncService` — `App/GuessWho/Support/SyncService.swift`

`SyncService` is the single funnel between views and the package (`App/GuessWho/Support/SyncService.swift:6-411`). The existing event methods (`fetchEventsRange`, `event(externalID:)`, the contact↔event link methods) are reworked to traffic in event UUIDs and to go through the orchestrator's new event API rather than the adapter directly.

| Today | After |
|---|---|
| `fetchEventsRange(from:to:) -> [Event]` (`:148`) — adapter `fetchEvents(in:)` | `fetchEventsRange(from:to:) -> [Event]` — calls `sync.eventsWindow(from:to:)` (E2.2), which merges EventKit-window events with sidecar events and applies Option C display |
| `event(externalID:) -> Event?` (`:158`) | `event(uuid:) -> Event?` — `sync.event(at: SidecarKey(kind:.event,id:uuid))` |
| (none) | `eventUUID(forEventKitID:) -> UUID?`, `linkEvent(toEventKitID:) throws -> UUID`, `createManualEvent(...) throws -> UUID`, `updateEvent(uuid:fields…) throws`, `refreshEvent(uuid:)`, `addEventNote/.../tags(...)`, `eventsOnDay(_:)`, `searchCalendarEvents(text:in:)` |
| `contactLinks(forEventID externalID:)` (`:295`) | `contactLinks(forEventUUID uuid:)` — endpoint is `SidecarKey(kind:.event,id:uuid)` |
| `addContactEventLink(contactUUID:eventID:note:)` (`:310`) | `addContactEventLink(contactUUID:eventUUID:note:)` |

All new event-mutating methods follow the existing `guard let sync else { throw SidecarUnavailableError() }` pattern (`:219`, `:248`, etc.) and record errors via `lastError`. `eventsAuthorization` gating (`:149`, `:159`) stays for the EventKit-touching paths; sidecar-only reads (manual events, notes, tags) do **not** require calendar authorization.

### E2.2 Windowed list read — `eventsWindow(from:to:)`

The events list (E2.3) must show **both** linked events (EventKit-window) and manual sidecar-only events. New orchestrator method (in `GuessWhoSync+Events.swift`):

```swift
/// Events to display for a date window: the union of
///   (a) every sidecar event whose effective start∈[from,to] (manual + linked), and
///   (b) EventKit events in [from,to] that have NO sidecar yet (auto-adopted —
///       see below), each given a freshly-minted sidecar on first sight.
/// Applies Option C display projection to every returned Event.
public func eventsWindow(from: Date, to: Date) throws -> [Event]
```

**Auto-adoption decision (E7 Q2, default chosen):** When the list window surfaces an EventKit event with no matching sidecar (`eventUUID(forEventKitID:) == nil`), we **do not** auto-create a sidecar (that would mint sidecars for the user's entire calendar). Instead the list shows EventKit-window events as *ephemeral, unlinked-display* rows; a sidecar is minted only when the user acts on the event (links it, adds a note/tag/contact, or edits a field). This keeps sidecar count proportional to user intent, matching how contacts only get a sidecar UUID when GuessWho touches them (`PLAN.md §3`). `eventsWindow` therefore returns sidecar events ∪ EventKit-window events, deduped by `eventKitID`, with sidecar events winning the projection.

### E2.3 `EventsRepository` — `App/GuessWho/Support/EventsRepository.swift`

`reload()` (`App/GuessWho/Support/EventsRepository.swift:18-26`) changes from `service.fetchEventsRange` (adapter-only) to the windowed union read:

```swift
func reload() async {
    isLoading = true
    defer { isLoading = false }
    let now = Date()
    let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
    let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
    events = service.fetchEventsRange(from: start, to: end)   // now union+projected
        .sorted { $0.startDate < $1.startDate }
}
```

`filtered` (`:28-37`) updates `.notes` → `.eventKitNotes` and additionally matches GuessWho event notes/tags if we want them searchable (default: keep matching title/location/eventKitNotes only — tags get their own filter later, deferred).

`Event` is now `Identifiable`-friendly via `id: UUID`; `ForEach(events, id: \.externalID)` in the list (E2.4) changes to `id: \.id`.

### E2.4 `EventsListView` — `App/GuessWho/EventsListView.swift`

- The authorization switch (`App/GuessWho/EventsListView.swift:10-31`) no longer fully gates the list. With sidecar-first events, **manual events display even with no calendar permission.** The `.denied`/`.notRequested` branches change from a full-screen `ContentUnavailableView` to: show the list of sidecar-only events plus a dismissible banner ("Enable Calendar access in Settings to see and link calendar events"). Only `.restricted` keeps the hard block (OS policy).
- `ForEach(events, id: \.externalID)` → `id: \.id` (`:47`).
- `NavigationLink(value: EventReference(externalID: event.externalID))` → `EventReference(eventUUID: event.id.uuidString)` (E2.6).
- A new "+" toolbar button → presents the **link sheet** (E3) for creating/linking an event. (Today there is no create affordance in the list.)
- `EventRow` (`:69-81`) gains a small "linked"/"manual" indicator (e.g. a `calendar` vs `calendar.badge.plus` glyph) and may show a tag chip row.

### E2.5 `EventDetailView` — `App/GuessWho/EventDetailView.swift`

- `let externalID: String` → `let eventUUID: String` (`App/GuessWho/EventDetailView.swift:7`).
- `@State private var event: Event?` stays; `reload()` (`:125-135`) calls `service.event(uuid: eventUUID)` and **triggers a silent cache refresh** (Option C refresh trigger (a) — E4): `service.refreshEvent(uuid: eventUUID)` before/after the read.
- `detailsSection` (`:42-75`) renders the projected `Event` (already Option-C-correct). `event.notes` → `event.eventKitNotes` (`:68`). Add an **editable** path: tapping a field opens an edit form that calls `service.updateEvent(uuid:…)` (write routing handled in the package, E1.7).
- New **GuessWho Notes** section (event notes via `service.notes(forEventUUID:)` + add/edit/delete), modeled exactly on the contact `NotesStore` UI (`PLAN.md §12.3`). These are separate from `eventKitNotes`.
- New **Tags** section (add/remove tag chips) via `service.tags(forEventUUID:)`.
- `linkedContactsSection` (`:77-93`) and `ContactPickerSheet` (`:157-231`) keep working; the event endpoint becomes `SidecarKey(kind:.event, id: eventUUID)` (`:97`), and `addContactEventLink` takes `eventUUID:` (`:140`).
- If `event.eventKitID == nil`, show a "Link to a calendar event" button (presents the link sheet in link-mode) so a manual event can later adopt an EventKit event.
- If `event.isLinked` but EventKit fetch returned cache (deleted), show a subtle "Not found in Calendar — showing saved details" footnote (Option C silent fallback; no destructive prompt).

### E2.6 `NavigationReferences` — `App/GuessWho/Support/NavigationReferences.swift`

`EventReference` (`App/GuessWho/Support/NavigationReferences.swift:8-10`) changes its field from `externalID` to `eventUUID`:

```swift
struct EventReference: Hashable {
    let eventUUID: String
}
```

`contactAndEventDestinations()` (`:20-22`) passes `eventUUID: ref.eventUUID` to `EventDetailView`. Every `EventReference(externalID:)` call site updates: `EventsListView.swift:48`, `EventDetailView.swift:102` builds `ContactReference` (unaffected), `ContactDetailView.swift:327` `NavigationLink(value: EventReference(externalID: other.id))` → `EventReference(eventUUID: other.id)` (now `other.id` is already the event UUID).

### E2.7 `ContactDetailView` event section — `App/GuessWho/ContactDetailView.swift`

- `linkedEventRow` (`App/GuessWho/ContactDetailView.swift:324-345`) calls `service.event(externalID: other.id)` → `service.event(uuid: other.id)`. Because the link's event endpoint id is now the event UUID, `other.id` is directly the sidecar key id.
- `reloadEventLinks` (`:358-364`) is the **contact-side refresh trigger (b)** (Option C: "user views a contact with linked events → refresh all linked events for that contact"). After loading `eventLinks`, iterate them and call `service.refreshEvent(uuid:)` for each event endpoint (E4). Implement as a new `service.refreshLinkedEvents(forContactUUID:)` that loops once.
- `addEventLink(eventID:note:)` (`:366-374`) → `addEventLink(eventUUID:note:)`.
- `EventPickerSheet` (`App/GuessWho/ContactDetailView.swift:835-916`) is **replaced** by the new shared link sheet (E3) in link-to-existing mode; or kept as a thin wrapper that returns an event UUID. Default: replace with the shared `EventLinkSheet`, configured to call back with an event UUID (linking an existing EventKit event mints/returns a sidecar UUID via `service.linkEvent(toEventKitID:)`).

### E2.8 `ContactLinksStore` / `ConnectionsSection`

`ContactLinksStore` (`App/GuessWho/ContactLinksStore.swift`) and `ConnectionsSection.swift` handle **contact↔contact** links only and have **no event awareness** (confirmed: `ConnectionsSection` renders contact-to-contact links exclusively). **No changes required** beyond the fact that `Link` endpoints of kind `.event` now carry UUIDs — which these files never construct or inspect. Left untouched.

---

## E3. Link-sheet UI (new SwiftUI view)

New file `App/GuessWho/EventLinkSheet.swift`. Used in two modes: (1) from the events list "+" to create/link an event, (2) from a contact or manual event to link an existing EventKit event. Both share the body; the difference is the completion callback.

### E3.1 View shape

```swift
struct EventLinkSheet: View {
    enum Mode {
        /// Create a standalone event (events list "+"). Callback returns the
        /// new event's UUID so the caller can navigate to it.
        case create(onCreated: (_ eventUUID: String) -> Void)
        /// Link an existing event to something (contact, or a manual event
        /// adopting EventKit). Callback returns the chosen event's UUID + note.
        case link(onLinked: (_ eventUUID: String, _ note: String) -> Void)
    }

    @Environment(SyncService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var search: String = ""
    @State private var loadedDays: [Date: [Event]] = [:]   // EventKit events by day
    @State private var expandedBeyondToday = false          // "Show more" tapped
    @State private var loadedForwardThrough: Date           // today + N days (start: today)
    @State private var loadedBackwardThrough: Date          // today - M years (start: today)
    @State private var manualEntry = false                  // "Add Other" / no-permission
    // manual-entry form fields:
    @State private var draftTitle = ""; @State private var draftStart = Date()
    @State private var draftEnd = Date(); @State private var draftLocation = ""
    @State private var draftAllDay = false
}
```

### E3.2 Behavior matrix

| Affordance | Behavior | Backing call |
|---|---|---|
| Default content | **Today's events only**, under a `Section("Today")` header | `service.eventsOnDay(Date())` → `EventStoreProtocol.fetchEvents(on:)` |
| "Show more" (below today) | Expands to **next 365 days**, sectioned by day (one `Section` per non-empty day, day-formatted header) | `service.eventsRange(from: today, to: today+365d)`, grouped by `Calendar.startOfDay` |
| Pull-to-refresh (top) | **Prepends the previous year** (today−1y … today), sectioned by day. Each subsequent pull loads another year further back, on demand | `service.eventsRange(from: loadedBackwardThrough−1y, to: loadedBackwardThrough)`; update `loadedBackwardThrough` |
| Search field (top) | Filters title + location across **whatever range is currently loaded** (today-only, +365, or +years-back) | local filter over `loadedDays` flattened (and/or `service.searchCalendarEvents(text:in:loadedInterval)`) |
| "Add Other" button | Switches to a **manual-entry form** (no `eventKitID`); on save → `service.createManualEvent(...)` → sidecar-only event | `service.createManualEvent(title:start:end:isAllDay:location:)` |
| Tap an event row (link mode) | Returns that event's UUID (linking mints/returns a sidecar via `service.linkEvent(toEventKitID:)`), + optional note | `service.linkEvent(toEventKitID:)` |
| Tap an event row (create mode) | Same link path, then navigates to the new event detail | `service.linkEvent(toEventKitID:)` |

### E3.3 No-permission fallback

On presentation, check `service.eventsAuthorization`:
- If **not** `.authorized`: **skip the calendar list entirely.** Go straight to the manual-entry form (`manualEntry = true`) with a top banner: *"Enable Calendar access in Settings to link events from your calendar."* The only outcome is a sidecar-only event via `service.createManualEvent(...)`. (Mirrors the `EventsListView` banner approach, E2.4.)
- If `.authorized`: show the today-section + show-more + pull-to-refresh list described above, with the "Add Other" button always available.

### E3.4 Sectioning + grouping helper

A small `private func grouped(_ events: [Event]) -> [(day: Date, events: [Event])]` keyed by `Calendar.current.startOfDay(for: $0.startDate)`, sorted ascending, today pinned to a `"Today"`-titled section and other days using a medium date-style header. Pull-to-refresh uses `.refreshable`; "show more" is a trailing `Button` row (not infinite scroll) to keep loading explicit and bounded.

---

## E4. Cache-refresh logic

Option C cache refresh fires **silently** at two trigger points, both in the app layer, both calling one orchestrator method (`refreshEventCache(at:)`, E1.7).

| Trigger | Where (file:symbol) | What it does |
|---|---|---|
| (a) User taps event → detail | `App/GuessWho/EventDetailView.swift` `reload()` (`:125`) → new `service.refreshEvent(uuid:)` | For the one event: if linked & live, write EventKit values into the cache cells, then re-project. No-op if unlinked or EventKit-gone. |
| (b) User views a contact with linked events | `App/GuessWho/ContactDetailView.swift` `reloadEventLinks()` (`:358`) → new `service.refreshLinkedEvents(forContactUUID:)` | Loop the contact's event-endpoint links; for each, `refreshEventCache(at:)`. One EventKit fetch per linked event. |

**Mechanics of `refreshEventCache(at:)`** (`GuessWhoSync+Events.swift`):
1. Read sidecar envelope; decode `eventKitID` cell. If absent/soft-deleted → return projected cached `Event` (no write).
2. `events.fetch(eventKitID:)`. If nil → return cached `Event` (Option C: do **not** unlink, do **not** write).
3. Live → write `titleCache`/`startCache`/`endCache`/`isAllDayCache`/`locationCache`/`eventKitNotesCache` cells (only those whose value changed, to avoid stamp churn — compare decoded current cell value first, like the notes "no-op if unchanged" rule in `PLAN.md §12.3`). Return the live-projected `Event`.

Refresh is best-effort and swallows EventKit read errors into `lastError` (consistent with `SyncService` patterns). It is **never** triggered for the full list (E2.2) — only per-event on detail view and per-contact on contact view, to bound EventKit traffic.

---

## E5. Migration (one-shot)

Existing sidecars are keyed by event externalID (`events/<externalID-safe>.json`, `PLAN.md §5.1`), and existing contact↔event `Link` envelopes carry `endpoint{A,B} = { kind: "event", id: "<externalID>" }`. The pivot needs UUID-keyed event sidecars with an `eventKitID` cell, and link endpoints rewritten to the new UUIDs.

### E5.1 Where it lives

New orchestrator method in `GuessWhoSync+Events.swift`:

```swift
/// One-shot migration from externalID-keyed event sidecars (pre-pivot) to
/// UUID-keyed sidecars with an eventKitID cell. Idempotent: a second run is a
/// no-op (already-migrated files have UUID names and an eventKitID cell).
/// Returns a report of migrated event keys and rewritten link IDs.
@discardableResult
public func migrateEventsToSidecarFirst() throws -> EventMigrationReport
```

with

```swift
public struct EventMigrationReport: Sendable {
    public let migratedEvents: [(oldExternalID: String, newUUID: UUID)]
    public let rewrittenLinkIDs: [UUID]
    public let skipped: [String]   // already-UUID-keyed, malformed, etc.
}
```

### E5.2 Algorithm

1. `for key in sidecars.allKeys() where key.kind == .event`:
   - If `UUID(uuidString: key.id) != nil` **and** the envelope already has an `eventKitID` cell → already migrated; skip.
   - Otherwise treat `key.id` as a legacy externalID. Mint `newUUID = UUID()`.
   - Read the legacy envelope. Build a new envelope with `entityID = newUUID.uuidString`:
     - Set the `eventKitID` cell `= .string(legacyExternalID)` (the legacy key WAS the EventKit external id — so every migrated event is treated as linked).
     - Copy any pre-existing field-instance cells (notes the user already attached to the event) **verbatim** into the new envelope (their UUID keys are preserved; merge-safe).
     - Seed cache cells (`titleCache` etc.) from a best-effort `events.fetch(eventKitID: legacyExternalID)`; if the EventKit event is gone, leave cache cells empty/absent (they'll populate on first refresh or stay blank).
   - `sidecars.write(newEnvelope, at: SidecarKey(kind:.event, id: newUUID.uuidString))`.
   - `sidecars.delete(SidecarKey(kind:.event, id: legacyExternalID))` (the old percent-encoded file).
   - Record `(legacyExternalID, newUUID)`.
2. Build `externalID → newUUID` map. Scan `allKeys() where .link`; for any link whose `endpointA`/`endpointB` is `(.event, legacyExternalID)`, rewrite that endpoint cell to `(.event, newUUID.uuidString)` — **one envelope write per link**, exactly mirroring `PLAN.md §13.4` Case-D rewrite (reuse the same per-key-locked re-read-and-write shape from `rewriteLinkEndpoints`, `Sources/GuessWhoSync/GuessWhoSync.swift:664-729`). Record rewritten link IDs.

All writes go through the per-key `sidecarLocks` discipline. The migration is **idempotent** (step 1's skip clause) and safe to call at every launch until it converges; cheap once done (all keys already UUID + eventKitID).

### E5.3 When it runs

Called once early in `SyncService.init` **after** `sync` is constructed and **before** the first event read — alongside the existing reconcile triggers (`PLAN.md §10.2`: launch + foreground). Concretely: a new `SyncService.migrateEventsIfNeeded()` invoked from app launch (e.g. in `GuessWhoApp` / `RootView` `.task`), guarded by `guard let sync`. Because the FS store's filename branch still decodes percent-encoded legacy names during the transition (E1.4), the legacy files remain readable until migration deletes them.

### E5.4 Cross-device migration safety

Two devices may run the migration independently and mint different UUIDs for the same legacy externalID — producing two UUID sidecars that share one `eventKitID`. This is the event analogue of `PLAN.md §3.3` Case D. Default (E7 Q1): leave both; surface via `eventUUID(forEventKitID:)` returning the lexicographically-smallest UUID deterministically (so both devices agree which to show), and defer true merge to a follow-up. Document this in the report's `skipped`/notes. (A full event-identity reconcile mirroring §3.3 is the clean fix; scoped out of this migration to keep it bounded.)

---

## E6. Test matrix

Tests live in `Tests/GuessWhoSyncTests/` using Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), matching `InMemoryEventStoreTests.swift` and `LinkTests.swift` style, against the in-memory mocks in `Sources/GuessWhoSyncTesting/`.

### E6.1 Mock changes — `Sources/GuessWhoSyncTesting/InMemoryEventStore.swift`

`InMemoryEventStore` (`Sources/GuessWhoSyncTesting/InMemoryEventStore.swift:4-29`) gains:
- Storage keyed by `eventKitID` (still a `[String: Event]`, but the key is the EventKit external id).
- `fetch(eventKitID:)`, `fetchEvents(on:)`, `searchEvents(matching:in:)`.
- `createEvent(...)` — mints an `eventKitID` (e.g. `"ek-\(count)"`), stores, returns the Event; a test-visible counter for determinism.
- `updateEvent(eventKitID:...)` — mutates the stored Event; throws `EventStoreError.eventNotFound` if absent.
- A test-only `removeEvent(eventKitID:)` to simulate "deleted from EventKit" (drives the Option C fallback tests).

### E6.2 Existing tests to change

| File | Change |
|---|---|
| `Tests/GuessWhoSyncTests/InMemoryEventStoreTests.swift` | `fetch(externalID:)` → `fetch(eventKitID:)`; the `event(id:start:)` helper sets `eventKitID` and asserts on it; add `fetchEvents(on:)` and `searchEvents(matching:in:)` cases. Keep the interval-intersection tests. |
| `Tests/GuessWhoSyncTests/LinkTests.swift` | `eventX` key (`:18`) stays valid (`.event` of an arbitrary id), but add UUID-shaped event keys to mirror the new identity; assert link round-trips with `.event` endpoints carrying UUIDs. |
| `Tests/GuessWhoSyncTests/AdapterSmokeTests.swift` | Still asserts conformance; add a smoke that `EKEventStoreAdapter` conforms to the *extended* `EventStoreProtocol` (compile-time check that the new methods exist). |
| `Tests/GuessWhoSyncTests/SidecarKeyTests.swift` | Add: `.event` keys lowercase their UUID id (new branch, E1.4); `forEvent(_:)` uses `event.id.uuidString`. |
| `Tests/GuessWhoSyncTests/FileSystemSidecarStoreTests.swift` | The "externalID containing `/` round-trips" case (`PLAN.md §9.2`) is retained for legacy decode, plus a new case: a UUID-keyed event file round-trips as a plain `<uuid>.json`. |

### E6.3 New test suites (new files)

**`Tests/GuessWhoSyncTests/EventSidecarTests.swift`** (`@Suite("EventSidecar")`) — orchestrator-level, in-memory stores, mirroring `LinkTests.makeOrchestrator()`:
- `createManualEventRoundTrip` — `createManualEvent` then `event(at:)` returns a projected Event with the right fields, `eventKitID == nil`, `isLinked == false`.
- `linkEventStoresEventKitIDAndCache` — `linkEvent(toEventKitID:snapshot:)` writes the `eventKitID` + cache cells; `event(at:)` projects EventKit-live values when the mock event exists.
- `displayPrefersLiveOverCacheWhenLinked` — seed cache with stale title; mock EventKit returns a fresh title; `event(at:)` returns the fresh one.
- `displayFallsBackToCacheWhenEventKitGone` — link, then `removeEvent(eventKitID:)`; `event(at:)` returns cached values and `eventKitID` is still set (no auto-unlink).
- `updateLinkedEventWritesEventKitAndRefreshesCache` — `updateEventFields` on a linked-live event mutates the mock EKEvent and updates the cache cells.
- `updateUnlinkedEventWritesCacheOnly` — `updateEventFields` on a manual event writes cache cells, never calls EventKit (assert via a counting/spying event store wrapper, mirroring `CountingSidecarStore`).
- `updateLinkedButDeletedWritesCacheOnly` — linked event whose EKEvent is gone: edit writes cache, does not throw, does not unlink.
- `eventUUIDForEventKitIDReverseLookup` — round-trips; nil when none.
- `refreshEventCacheNoOpForUnlinked` / `refreshEventCacheUpdatesFromEventKit` / `refreshEventCacheNoOpWhenGone`.

**`Tests/GuessWhoSyncTests/EventNotesTagsTests.swift`** — notes on an event key (reusing `addNote/notes` against a `.event` key); tags via `addTag/editTag/deleteTag/tags`; `NoteTypeMismatch`-style: a tag is a `.note` field with `field == "tag"`; `tags(at:)` excludes notes and vice versa; soft-delete excludes from `tags(at:)` but raw `fields(at:)` retains.

**`Tests/GuessWhoSyncTests/EventMigrationTests.swift`** — drive `migrateEventsToSidecarFirst()`:
- `migratesLegacyExternalIDKeyedSidecar` — seed an `InMemorySidecarStore` with an `events/<externalID>` envelope (entityID = externalID, plus a note instance); run migration; assert a new UUID-keyed envelope exists with an `eventKitID` cell = the old externalID, the note instance preserved, and the old key deleted.
- `migrationIsIdempotent` — second run is a no-op; report has no new migrations.
- `migrationRewritesLinkEndpoints` — pre-seed a `Link` with `endpointB = (.event, legacyExternalID)`; after migration the link carries `(.event, newUUID)` in one write; `report.rewrittenLinkIDs == [link.id]` (mirrors `LinkCaseDRewriteTests`).
- `migrationSeedsCacheFromEventKitWhenPresent` / `leavesCacheEmptyWhenEventKitGone`.
- `crossDeviceTwoUUIDsForSameEventKitID` — two migrations on the same legacy id (simulated) produce two UUID sidecars sharing an eventKitID; `eventUUID(forEventKitID:)` returns the deterministic (lex-min) one (documents E7 Q1 default).

**`Tests/GuessWhoSyncTests/EventWindowTests.swift`** — `eventsWindow(from:to:)` returns the union of sidecar events and EventKit-window events deduped by `eventKitID`; manual events with no EventKit presence still appear; EventKit-only events (no sidecar) appear as unlinked-display rows.

### E6.4 PLAN.md §9.7 update

`PLAN.md §9.7 "Event sidecars"` (`PLAN.md:759-762`) is rewritten:
- ~~"event lookup by externalID works"~~ → "event lookup by `eventKitID` works; event sidecars keyed by minted UUID."
- "writing a sidecar for an event does not mutate the EventKit event **unless the edit targets a linked field, in which case it writes EventKit via `updateEvent`**" (Option C).
- "per-field LWW rules apply identically to event sidecars" — retained.
- Add: "Option C display projection: live-when-linked-and-present, cache otherwise"; "no auto-unlink on EventKit deletion."

---

## E7. Open questions (defensible defaults chosen)

1. **Duplicate event UUIDs for one `eventKitID` (cross-device / double-link).** Two devices link the same EventKit event → two sidecar UUIDs. **Default:** do not auto-merge; `eventUUID(forEventKitID:)` returns the lex-smallest deterministically so both devices display the same one; full event-identity reconcile (mirroring `PLAN.md §3.3` Case D) is deferred. *Needs human sign-off if true convergence is required for v1.*

2. **Auto-adoption of calendar events into sidecars.** Should every EventKit event in the list window get a sidecar? **Default: no** — mint a sidecar only when the user acts (link/note/tag/contact/edit), keeping sidecar count proportional to intent (E2.2). *Confirm this matches the product intent for the events list.*

3. **`eventKitNotes` vs GuessWho notes.** EventKit's own notes string is cached (`eventKitNotesCache`) and displayed read-only; GuessWho event notes are separate sidecar instances. **Default: keep them distinct**; editing EventKit notes is out of scope (we never write EKEvent.notes). *Confirm we don't want to surface an "edit calendar notes" path.*

4. **Which calendar receives `createLinkedEvent` / `createEvent`?** **Default:** `EKEventStore.defaultCalendarForNewEvents`; throw `EventStoreError.noWritableCalendar` if nil. *Confirm no calendar-picker is needed for v1.*

5. **Pull-to-refresh year granularity.** Spec says "previous year per pull." **Default:** exactly 365-day chunks anchored at `today`, unbounded backward on repeated pulls. *Confirm 1-year chunks (vs. month/quarter) are the desired UX.*

---

## E8. Implementation order (suggested)

Mirrors `PLAN.md §11`'s phased, test-each-phase approach:

1. **Model + protocol + mock.** `Event` (E1.1), `EventStoreProtocol` (E1.5), `EventStoreError`, `InMemoryEventStore` (E6.1), `SidecarKey` (E1.4). Tests: E6.2 mock/key tests compile and pass.
2. **Orchestrator event API.** `GuessWhoSync+Events.swift` (E1.7) + `eventsWindow` (E2.2). Tests: `EventSidecarTests`, `EventNotesTagsTests`, `EventWindowTests` (E6.3).
3. **Migration.** `migrateEventsToSidecarFirst()` (E5). Tests: `EventMigrationTests`.
4. **EventKit adapter writes.** `EKEventStoreAdapter` (E1.6). Smoke: `AdapterSmokeTests` conformance + on-device smoke (deferred, like `PLAN.md §11.1`).
5. **App layer.** `SyncService` (E2.1), `EventsRepository`/`EventsListView`/`EventDetailView`/`NavigationReferences`/`ContactDetailView` (E2.3–E2.7).
6. **Link sheet.** `EventLinkSheet.swift` (E3), wired into list "+" and contact/manual-event link flows, no-permission fallback.
7. **PLAN.md amendments.** §2 (drop read-only), §4 (event row), §7.2 (event protocol), §9.7 (event sidecar tests).
