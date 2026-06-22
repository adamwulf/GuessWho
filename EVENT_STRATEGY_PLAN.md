# GuessWhoSync — Event Strategy Plan (Sidecar-First Events)

A migration plan to pivot the event model from **EventKit-canonical, read-only, sidecar-optional** to **sidecar-first, EventKit-link-optional** (design "Option C"). Every event becomes a first-class sidecar entity that may optionally carry an `eventKitID` linking it to a live EventKit event.

This document follows the conventions of `PLAN.md` (numbered sections, tables, concrete file paths and signatures). It is a companion spec: where it changes a `PLAN.md` rule, it says so explicitly. Section numbers here are **local to this document** (E1–E7 + sub-sections) and do not renumber `PLAN.md`.

---

## E0. Summary of the pivot

| Dimension | Today (PLAN.md §2, §4) | After this plan |
|---|---|---|
| Event source of truth | EventKit; sidecar optional | Sidecar always exists; EventKit optional via `eventKitID` |
| Event sidecar key | `event.externalID` (= today an **`eventIdentifier`** despite being misnamed externalID — `EKEventStoreAdapter.toEvent` emits `e.eventIdentifier` at `Sources/GuessWhoSync/EKEventStoreAdapter.swift:23`) | Minted GuessWho **event UUID** (lowercased), like contacts |
| EventKit pointer cell | n/a | Always stores **`calendarItemExternalIdentifier`** (canonical cross-device id, `PLAN.md §3.1`). Migration translates legacy `eventIdentifier` → `calendarItemExternalIdentifier` (E5.2). |
| EventKit writes | Forbidden (`PLAN.md §2`: "Events are read-only") | Allowed for linked events (title/start/end/location) |
| Notes / contacts / tags on events | n/a (only contact↔event links existed) | Always sidecar; never EventKit |
| Display values | EventKit live values | EventKit live if linked & present, else sidecar cache |
| Deleted-from-EventKit | (event vanishes from list) | Silent fallback to cache; `eventKitID` retained |

This is a breaking change to `PLAN.md §2` ("Writing to EventKit events. Events are read-only") and to the §4 storage-boundary row for events ("per-event keyed by `calendarItemExternalIdentifier`"). Both are amended in E1; the full list of `PLAN.md` locations to amend is enumerated in E8 step 0.

**Identifier-namespace pin (was a blocker — see B-IDENTITY in the round-1/round-2 reviews).** The new `eventKitID` sidecar cell stores the **`calendarItemExternalIdentifier`** — the stable cross-device EventKit identifier (`PLAN.md §3.1`). It is **not** an `eventIdentifier`. The legacy sidecar files and the `(.event, id)` link endpoints on disk today carry `eventIdentifier` strings (the adapter has always emitted those at `EKEventStoreAdapter.swift:23`, despite the misleading "externalID" name in the API). Migration MUST translate each legacy `eventIdentifier` to its `calendarItemExternalIdentifier` by resolving the EKEvent via `store.event(withIdentifier:)` and reading `.calendarItemExternalIdentifier`. If the event no longer exists in EventKit (no translation possible) the migration writes the legacy `eventIdentifier` string into the `eventKitID` cell as a **dead pointer** — the cell is set, but `fetch(eventKitID:)` cannot resolve it, and Option C silent-fallback-to-cache renders the cached values. See E5.2 for the algorithm and E1.6 for the dual-namespace `fetch(eventKitID:)` resolver (tries `calendarItems(withExternalIdentifier:)` first, then falls back to `event(withIdentifier:)` so dead-pointer rows still resolve when their EventKit event is later re-found by `eventIdentifier`).

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
| `eventKitID` | `note` | non-empty string (the EventKit `calendarItemExternalIdentifier`). When unlinked: the cell carries `deletedAt` per `PLAN.md §5.5` soft-delete and **retains its prior string value** (the value is never written as `null` — `.note` validation in `SidecarField.swift:77-80` requires `.string`). | Pointer OUT to an EventKit event. Soft-deleted ↔ unlinked. |
| `titleCache` | `note` | string | Cached EventKit (or manual) title |
| `startCache` | `date` | ISO8601 string | Cached start |
| `endCache` | `date` | ISO8601 string | Cached end |
| `isAllDayCache` | `checkbox` | bool | Cached all-day flag |
| `locationCache` | `note` | string (empty when no location) | Cached location |
| `eventKitNotesCache` | `note` | string | Cached EventKit notes string |
| `deletedAt` | `note` | ISO8601 string | Envelope-level whole-event soft-delete tombstone. Mirrors the link `deletedAt` cell from `PLAN.md §13.2`. Once set, `allEvents()` and `eventsWindow(from:to:)` filter the event out; raw `sidecars.read` / `event(at:)` still returns it so callers can audit. For linked events, the EKEvent is NOT deleted from the user's calendar (out of scope; sidecar-only delete). |

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

**Filename safety (PLAN.md §5.1).** The two `.event` branches in `FileSystemSidecarStore` are treated **independently** (they were conflated in an earlier revision, producing a contradictory instruction — see B-FILESTORE):

- `safeFilename` `.event` branch (`Sources/GuessWhoSync/FileSystemSidecarStore.swift:353-360`): change to the lowercased-UUID path. New event keys are UUIDs; lowercasing them is safe and matches `.contact`/`.link`. (A UUID happens to percent-encode to itself, so legacy externalID-named files that may briefly exist alongside until migration deletes them are still written safely too — but new writes go through the lowercasing branch.)
- `listKeys` `.event` branch (`…:393-395`): **keep `removingPercentEncoding` permanently**. New UUID filenames contain no percent-encodable characters, so `removingPercentEncoding` is the identity for them. Legacy externalID filenames (case-sensitive, may contain `/`, `:`, uppercase) must round-trip through the decode path so migration can `read` and `delete` them. There is **no** "change `listKeys` to lowercasing" step — that would corrupt legacy keys and silently break migration.

**Case-collision avoidance (was a blocker — see B-IDENTITY / R1.B4).** Legacy event ids are case-sensitive (`eventIdentifier` strings often contain uppercase). The migration's `legacyEventIdentifier → newEventUUID` map MUST key on the **original-case** legacy id taken straight from `sidecars.allKeys()` (which, per the bullet above, comes from the percent-decode path that preserves case). Only the **new event UUID side** is lowercased (via `SidecarKey.init`'s new `.event` branch above). Concretely: don't `.lowercased()` the legacy key when reading it for the map; only lowercase the freshly-minted UUID when writing the new sidecar.

Migration (E5) renames the old files; until it runs, `read` of a not-yet-migrated externalID key still works via the percent-decode path, but **no new code should touch any legacy event key after migration completes** — the migration is the only legacy-key reader/writer. Migration runs **before** any event read (E5.3).

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
    /// eventKitID set; `id` is a STABLE synthesized UUID derived from the
    /// `eventKitID` (so SwiftUI / EventReference identity is stable across
    /// repeat fetches — was N-EPHEMERAL-ROW-ID). The orchestrator/app maps to
    /// the real sidecar UUID via eventKitID (see E2.2). isLinked == true.
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
    // calendarItemExternalIdentifier is the cross-device canonical id
    // (PLAN.md §3.1). Adapter never emits eventIdentifier for new sidecars;
    // legacy sidecars whose eventKitID cell still holds an eventIdentifier
    // are tolerated only by fetch(eventKitID:)'s dual-namespace resolver
    // and by migration's translation step (E5.2).
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

> NOTE: today's adapter keys on `e.eventIdentifier` (`…:23`), the link-sheet should key on `calendarItemExternalIdentifier` (the stable cross-device id per `PLAN.md §3.1`). This corrects an existing latent mismatch (`SidecarKey.forEvent` used externalID but the adapter emitted `eventIdentifier`). Use `calendarItemExternalIdentifier` consistently for all NEW writes. The migration still has to deal with on-disk `eventIdentifier` strings — see E5.2 / the dual-namespace `fetch(eventKitID:)` below.

New methods:
- `fetch(eventKitID:)` — **dual-namespace resolver.** First try `store.calendarItems(withExternalIdentifier:)` → first `EKEvent` (the new canonical path). If that returns nil, fall back to `store.event(withIdentifier:)` (the legacy `eventIdentifier` path) — this catches the **dead-pointer case** where migration could not translate a legacy `eventIdentifier` to a `calendarItemExternalIdentifier` (the EKEvent was unavailable at migration time but is now reachable). Returns nil if both lookups fail. Document in the method's doc-comment that the cell value may be *either* identifier type, and the resolver tries both.
- `fetchEvents(on:)` — build a one-day `DateInterval` (`startOfDay … startOfNextDay`) and reuse the predicate path.
- `searchEvents(matching:in:)` — fetch the interval, filter on `title`/`location` case-insensitively in-process (EventKit has no text predicate).
- `createEvent(...)` — `EKEvent(eventStore:)`, set fields, `calendar = store.defaultCalendarForNewEvents` (throw `EventStoreError.noWritableCalendar` if nil), `try store.save(_:span:.thisEvent commit:true)`, return `toEvent` (whose `eventKitID` is the new EKEvent's `calendarItemExternalIdentifier`).
- `updateEvent(eventKitID:...)` — resolve the `EKEvent` via the same dual-namespace path as `fetch(eventKitID:)`; if nil, throw `EventStoreError.eventNotFound(eventKitID:)`; mutate the five fields; `try store.save(_:span:.thisEvent commit:true)`.

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
    /// sidecar already pointing at the same eventKitID (see E7 Q1 — link-sheet
    /// callers MUST call eventUUID(forEventKitID:) first per the mandated sheet
    /// behavior in E3.2 / C-SHEET-DEDUP).
    @discardableResult
    public func linkEvent(toEventKitID ekid: String,
                          snapshot ekEvent: Event) throws -> UUID

    /// Adopt an EXISTING manual (sidecar-only) event into a linked event.
    /// Writes the eventKitID cell (live, not soft-deleted) on the existing
    /// sidecar at `key`, then calls refreshEventCache(at:) so EventKit live
    /// values overwrite the manual cache cells (Option C: live-wins-when-linked,
    /// per C-MANUAL-TO-LINK / E2.5's "Link to a calendar event" button).
    /// Throws if `key` has no sidecar.
    public func linkExistingSidecar(at key: SidecarKey, toEventKitID ekid: String) throws

    /// Soft-delete the eventKitID cell so the event is no longer linked to
    /// EventKit. Bumps the cell's `modifiedAt`/`modifiedBy`/`deletedAt`; the
    /// cell's `value` is retained (per E1.2 — .note validation requires .string).
    /// Cache cells are NOT touched; the next display read uses them.
    /// Cross-device note: unlink and refresh-cache touch DISJOINT cells, so
    /// (Device A unlinks) + (Device B refreshes cache) converges under §5.3
    /// LWW to an unlinked event with fresh cache — correct Option C behavior.
    public func unlinkEvent(at key: SidecarKey) throws

    /// Whole-event soft-delete. Writes the well-known `deletedAt` cell on the
    /// envelope (E1.2). The EKEvent is NOT deleted (sidecar-only).
    /// allEvents()/eventsWindow filter the event out; raw sidecar reads still
    /// return it. Cross-device: another device that hasn't seen the delete can
    /// resurrect cells via §5.3 — accepted hazard, matches the link `deletedAt`
    /// pattern in PLAN.md §13.7.
    public func deleteEvent(at key: SidecarKey) throws

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
    /// nil. O(N events). Used by the link sheet (mandatory pre-link dedup, see
    /// C-SHEET-DEDUP / E3.2) and by migration.
    ///
    /// Tie-break contract (was C-LEXMIN-CONTRACT in the reviews — folded in
    /// here, not just stated in E5.4): when ≥2 sidecars currently point at
    /// `ekid`, returns the **lexicographically-smallest** event UUID — sort
    /// `id.uuidString` ascending — so two devices independently scanning their
    /// own sidecars converge on the same answer. Sidecars whose `eventKitID`
    /// cell is **soft-deleted** (unlinked, per `unlinkEvent(at:)`) are
    /// excluded from the scan, so an unlinked-then-relinked sidecar cannot
    /// shadow a live one.
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

    /// Live (non-deleted) tags, sorted by (createdAt, id.uuidString) like
    /// notes(at:) in GuessWhoSync+Notes.swift:72-75. Returns [EventTag] so
    /// callers have the per-instance id to pass to editTag/deleteTag — the
    /// [String] alternative is unusable because edit/delete take id: UUID
    /// (was B-TAGS — resolved).
    public func tags(at key: SidecarKey) throws -> [EventTag]
}
```

**`EventTag` model** — new file `Sources/GuessWhoSync/EventTag.swift`, mirroring `ContactNote` (`Sources/GuessWhoSync/ContactNote.swift`):

```swift
public struct EventTag: Hashable, Sendable {
    /// Per-instance UUID — the field-instance cell key for this tag (mirrors
    /// ContactNote.id). Caller passes this into editTag(at:id:text:) and
    /// deleteTag(at:id:).
    public let id: UUID
    /// The tag's user-visible text — the inner `value` string of the .note
    /// cell whose `field == GuessWhoSync.eventTagFieldName`.
    public let text: String
    /// Creation timestamp from the cell's underlying SidecarField. Optional
    /// because the field stores it as Date but legacy data may omit it.
    public let createdAt: Date?
    /// Mirrors ContactNote.deletedAt — non-nil for soft-deleted tags. `tags(at:)`
    /// excludes deleted instances; this field is exposed for raw audit only.
    public let deletedAt: Date?
}
```

(Conformances: `Hashable` for SwiftUI `ForEach`/`id:` usage, `Sendable` for cross-actor passing. Not `Identifiable` — keep it parallel to `ContactNote` which is also not `Identifiable`, callers use `\.id` explicitly.)

**Implementation notes for the well-known cell writes.** `createManualEvent` / `linkEvent` / `refreshEventCache` / `unlinkEvent` / `deleteEvent` write the group-(a) cells with a private `writeWellKnownCell(at:key:field:type:value:)` helper that mirrors `addField`'s cell-construction (`Sources/GuessWhoSync/GuessWhoSync.swift:43-63`) but uses a **fixed cell key** instead of a minted UUID, under the per-key `sidecarLocks.withLock` discipline. Each cell's inner `value` uses `SidecarField.makeInnerValue(field:type:value:createdAt:)` (`Sources/GuessWhoSync/SidecarField.swift:93-105`) so `SidecarField.decode` still reads them.

**Date-string canonicalization (N-ISO8601).** All cache-cell write paths that serialize a `Date` (`startCache`, `endCache`, the `deletedAt` envelope-level cell when added) MUST use `SidecarISO8601.string(from:)` (same as `addLink` at `Sources/GuessWhoSync/GuessWhoSync.swift:185`); read paths MUST use `SidecarISO8601.date(from:)`. Do NOT reach for a raw `ISO8601DateFormatter` — fractional-second policy differences would break the round-trip and `PLAN.md §7.1` warns against this exact mistake. `writeWellKnownCell` should accept a `Date` for `.date`-typed cells and apply the canonicalizer internally so callers can't bypass it.

**Unlink mechanics.** `unlinkEvent(at:)` uses `writeWellKnownCell` to overwrite the `eventKitID` cell as soft-deleted: same `value` string (per E1.2), new `modifiedAt`/`modifiedBy`, `deletedAt = now`. It does NOT touch cache cells. See E1.2 for the cell-shape rationale and §5.3 LWW disjoint-cell convergence note.

**Whole-event delete mechanics.** `deleteEvent(at:)` writes the envelope-level `deletedAt` well-known cell with the current ISO8601 timestamp. The cell behaves like the link `deletedAt` cell (`PLAN.md §13.2`); per-cell LWW applies, so two devices that delete and edit concurrently are governed by §5.3. `allEvents()` and the new `eventsWindow(from:to:)` filter `deletedAt`-bearing envelopes out. Raw `event(at:)` returns the envelope (callers wanting an audit/undelete path can read it).

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
| `fetchEventsRange(from:to:) -> [Event]` (`:148`) — adapter `fetchEvents(in:)` | `fetchEventsRange(from:to:) -> [Event]` — calls `sync.eventsWindow(from:to:, includeEventKit: eventsAuthorization == .authorized)` (E2.2). The `includeEventKit` flag is the **permission seam** (was C-WINDOW-PERMISSION): the orchestrator stays permission-agnostic; `SyncService` is the only place that knows about `eventsAuthorization`. |
| `event(externalID:) -> Event?` (`:158`) | `event(uuid:) -> Event?` — `sync.event(at: SidecarKey(kind:.event,id:uuid))`. Sidecar-only read; **does NOT require** `eventsAuthorization == .authorized` (the package internally tries `events.fetch(eventKitID:)` and falls back to cache, which works fine when the adapter returns nil under denied permission). |
| (none) | `eventUUID(forEventKitID:) -> UUID?`, `linkEvent(toEventKitID:) throws -> UUID`, `linkExistingSidecar(uuid:toEventKitID:) throws`, `unlinkEvent(uuid:) throws`, `deleteEvent(uuid:) throws`, `createManualEvent(...) throws -> UUID`, `createLinkedEvent(...) throws -> UUID`, `updateEvent(uuid:fields…) throws`, `refreshEvent(uuid:)`, `refreshLinkedEvents(forContactUUID:)`, `addEventNote/.../tags(...)`, `eventsOnDay(_:)`, `searchCalendarEvents(text:in:)`, `migrateEventsIfNeeded()` |
| `contactLinks(forEventID externalID:)` (`:295`) | `contactLinks(forEventUUID uuid:)` — endpoint is `SidecarKey(kind:.event,id:uuid)` |
| `addContactEventLink(contactUUID:eventID:note:)` (`:310`) | `addContactEventLink(contactUUID:eventUUID:note:)` |

All new event-mutating methods follow the existing `guard let sync else { throw SidecarUnavailableError() }` pattern (`:219`, `:248`, etc.) and record errors via `lastError`. `eventsAuthorization` gating (`:149`, `:159`) stays for the EventKit-touching write paths (`createLinkedEvent`, `updateEvent` when the underlying event is linked-and-live, `linkExistingSidecar`); sidecar-only reads and writes (manual events, notes, tags, unlink, delete) do **not** require calendar authorization.

**`.writeOnly` mapping (was C-DENIED-TO-AUTHORIZED follow-up).** `SyncService.requestEventsAccessIfNeeded` maps `.writeOnly` → `.denied` at `SyncService.swift:123-125`. Under the new write path, a write-only user is routed to manual-only — `createLinkedEvent` and `linkExistingSidecar` are unavailable to them even though EventKit would technically permit the write. Accepted for v1; documenting it so the limitation isn't a surprise later.

**Debounce state for refresh.** `SyncService` owns the in-memory `recentlyRefreshed: [SidecarKey: Date]` map described in E4 / C-REFRESH-FANOUT. `refreshEvent(uuid:)` and `refreshLinkedEvents(forContactUUID:)` consult and update it; entries are cleared on app launch (the service is re-instantiated). No persistence.

**Permission-flip behavior (was C-DENIED-TO-AUTHORIZED).** v1 decision: after a `denied → authorized` transition (already observed by `RootView.swift:53-57`), do **NOT** auto-prompt the user to adopt their existing manual events. The per-event "Link to a calendar event" button (E2.5) remains the only adoption path. Rationale: auto-prompting at permission-flip time is intrusive and unpredictable; the user adopts events one-by-one when they care about a specific event.

### E2.2 Windowed list read — `eventsWindow(from:to:)`

The events list (E2.3) must show **both** linked events (EventKit-window) and manual sidecar-only events. New orchestrator method (in `GuessWhoSync+Events.swift`):

```swift
/// Events to display for a date window: the union of
///   (a) every sidecar event whose effective start∈[from,to] (manual + linked,
///       projected via Option C using the in-window EventKit batch from
///       step 1 below — NEVER per-sidecar fetch(eventKitID:) calls), and
///   (b) EventKit events in [from,to] that have NO sidecar (ephemeral display
///       rows; no sidecar mint — see auto-adoption decision below).
///
/// `includeEventKit` (default true) gates the EventKit half. The app layer
/// (SyncService) passes false when eventsAuthorization != .authorized so the
/// orchestrator stays permission-agnostic (was C-WINDOW-PERMISSION).
public func eventsWindow(from: Date, to: Date, includeEventKit: Bool = true) throws -> [Event]
```

**Per-event fetch must NOT happen here (was C-WINDOW-FETCH).** Naive Option C projection per sidecar would call `events.fetch(eventKitID:)` once per linked sidecar — O(N) EventKit traffic, contradicting E4's "bound EventKit traffic" claim. Instead:

1. **One** EventKit batch call: when `includeEventKit`, `events.fetchEvents(in: DateInterval(start: from, end: to))` returns every in-window EventKit event. Index it by `calendarItemExternalIdentifier` into a local `[String: Event]`.
2. Iterate `sidecars.allKeys()` for `.event`. For each sidecar:
   - Skip if envelope-level `deletedAt` is set.
   - Decode the well-known cells into a cached `Event`.
   - If linked AND the in-window batch has an entry for the `eventKitID`, overlay live values (Option C live-when-present).
   - If linked but NOT in the in-window batch, use the cache as-is (the EventKit event either falls outside the window or is deleted — either way no per-event fetch).
   - Filter by `startDate ∈ [from, to]`.
3. Add EventKit-only ephemeral rows: for any in-window EventKit event whose `eventKitID` no sidecar references, emit it as an unlinked-display row.

**Auto-adoption decision (E7 Q2, default chosen):** When the list window surfaces an EventKit event with no matching sidecar (`eventUUID(forEventKitID:) == nil`), we **do not** auto-create a sidecar (that would mint sidecars for the user's entire calendar). Instead the list shows EventKit-window events as *ephemeral, unlinked-display* rows; a sidecar is minted only when the user acts on the event (links it, adds a note/tag/contact, or edits a field). This keeps sidecar count proportional to user intent, matching how contacts only get a sidecar UUID when GuessWho touches them (`PLAN.md §3`). `eventsWindow` therefore returns sidecar events ∪ EventKit-window events, deduped by `eventKitID`, with sidecar events winning the projection.

**Ephemeral-row stable id (was N-EPHEMERAL-ROW-ID).** For an unlinked-display row, do NOT use `Event.id = UUID()` (a fresh placeholder per fetch causes SwiftUI churn / broken NavigationLink targets). Derive a stable UUID from the `eventKitID` instead — e.g. UUIDv5-style or a deterministic SHA-256-then-truncate hash of the `eventKitID` string. The synthesized UUID is used ONLY for SwiftUI identity / `EventReference` nav tokens; it never lands on disk. (`Event.init` in `Sources/GuessWhoSync/Event.swift` should expose this synthesizer so both `EKEventStoreAdapter.toEvent` and `eventsWindow`'s ephemeral path produce identical ids for the same `eventKitID`.)

### E2.3 `EventsRepository` — `App/GuessWho/Support/EventsRepository.swift`

`reload()` (`App/GuessWho/Support/EventsRepository.swift:18-26`) changes the data source from `service.fetchEventsRange` (adapter-only) to the windowed union read. Mirror the **existing two-statement form** (was N-RELOAD-COSMETIC — the prior revision proposed a single-expression rewrite that needlessly changed structure):

```swift
func reload() async {
    isLoading = true
    defer { isLoading = false }
    let now = Date()
    let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
    let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
    let fetched = service.fetchEventsRange(from: start, to: end)   // now union+projected
    events = fetched.sorted { $0.startDate < $1.startDate }
}
```

`filtered` (`:28-37`) updates `.notes` → `.eventKitNotes` and additionally matches GuessWho event notes/tags if we want them searchable (default: keep matching title/location/eventKitNotes only — tags get their own filter later, deferred).

Confirm `service.fetchEventsRange` still returns `[Event]` and that the `-30/+90` window is still desired for the union read (manual events outside that window won't show — a future-dated manual "Add Other" event 91+ days out is invisible until a wider read; accepted for v1).

`Event` exposes `id: UUID`; switch `ForEach(events, id: \.externalID)` in the list (E2.4) to `id: \.id`. (Drop the "`Identifiable`-friendly" phrasing — `Event` is not declared `Identifiable`, callers use `\.id` explicitly. See N-EVENT-IDENTIFIABLE.)

### E2.4 `EventsListView` — `App/GuessWho/EventsListView.swift`

- The authorization switch (`App/GuessWho/EventsListView.swift:10-31`) no longer fully gates the list. With sidecar-first events, **manual events display even with no calendar permission.** The `.denied`/`.notRequested` branches change from a full-screen `ContentUnavailableView` to: show the list of sidecar-only events plus a dismissible banner ("Enable Calendar access in Settings to see and link calendar events").
- **`.restricted` is NOT a hard block** (was C-RESTRICTED). A restricted user can still own sidecar-only events (e.g. created before restriction). Treat `.restricted` like `.denied` for **display** — show manual sidecar-only events with the same banner. But suppress the link-sheet's calendar-browsing affordances and the "+ → link calendar event" path (and disable `createLinkedEvent` per E3.3), since EventKit access is genuinely off-limits.
- `ForEach(events, id: \.externalID)` → `id: \.id` (`:47`).
- `NavigationLink(value: EventReference(externalID: event.externalID))` → `EventReference(eventUUID: event.id.uuidString)` (E2.6).
- A new "+" toolbar button → presents the **link sheet** (E3) for creating/linking an event. (Today there is no create affordance in the list.) Disabled / hidden when `eventsAuthorization == .restricted` (manual-only flow still reachable via the Add-Other form path in the link sheet — see E3.3).
- `EventRow` (`:69-81`) gains a small "linked"/"manual" indicator (e.g. a `calendar` vs `calendar.badge.plus` glyph) and may show a tag chip row.
- **Row swipe action (delete)** → `service.deleteEvent(uuid:)` → soft-deletes the envelope (see `deleteEvent(at:)` in E1.7). Confirmation alert: "Remove from GuessWho? (Won't delete from Calendar.)"

### E2.5 `EventDetailView` — `App/GuessWho/EventDetailView.swift`

- `let externalID: String` → `let eventUUID: String` (`App/GuessWho/EventDetailView.swift:7`).
- `@State private var event: Event?` stays; `reload()` (`:125-135`) calls `service.event(uuid: eventUUID)` and **triggers a silent cache refresh** (Option C refresh trigger (a) — E4): `service.refreshEvent(uuid: eventUUID)` before/after the read.
- `detailsSection` (`:42-75`) renders the projected `Event` (already Option-C-correct). `event.notes` → `event.eventKitNotes` (`:68`). Add an **editable** path: tapping a field opens an edit form that calls `service.updateEvent(uuid:…)` (write routing handled in the package, E1.7).
- New **GuessWho Notes** section (event notes via `service.notes(forEventUUID:)` + add/edit/delete), modeled exactly on the contact `NotesStore` UI (`PLAN.md §12.3`). These are separate from `eventKitNotes`.
- New **Tags** section (add/remove tag chips) via `service.tags(forEventUUID:)`.
- `linkedContactsSection` (`:77-93`) and `ContactPickerSheet` (`:157-231`) keep working; the event endpoint becomes `SidecarKey(kind:.event, id: eventUUID)` (`:97`), and `addContactEventLink` takes `eventUUID:` (`:140`).
- If `event.eventKitID == nil` (manual event), show a **"Link to a calendar event"** button. Presents the link sheet in link-mode; on row-tap of an EventKit event, the callback invokes `service.linkExistingSidecar(uuid:toEventKitID:)` (which wraps `GuessWhoSync.linkExistingSidecar(at:toEventKitID:)` from E1.7 — writes the `eventKitID` cell on the existing sidecar then calls `refreshEventCache` so live EventKit values overwrite the manual cache cells). Disabled / hidden when `eventsAuthorization` is `.denied`/`.restricted` (`.notRequested` prompts first); footnote "Enable Calendar to link this event to your calendar."
- If `event.isLinked` but EventKit fetch returned cache (deleted), show a subtle "Not found in Calendar — showing saved details" footnote (Option C silent fallback; no destructive prompt).
- If `event.isLinked` (live or dead-pointer), show an **"Unlink from Calendar"** destructive button (was C-UNLINK). Calls `service.unlinkEvent(uuid:)` → `GuessWhoSync.unlinkEvent(at:)` (soft-deletes the `eventKitID` cell, preserves cache). After unlink the view re-projects: the event now displays from cache, the "Link to a calendar event" button reappears.
- A **"Delete event"** destructive button at the bottom of the detail (was C-EVENT-DELETE) → `service.deleteEvent(uuid:)` → `GuessWhoSync.deleteEvent(at:)` (writes envelope-level `deletedAt`). Same confirmation prompt as the row-swipe in E2.4. After delete the view pops back to the events list (which already filters `deletedAt` envelopes out via `allEvents()`/`eventsWindow`).

### E2.6 `NavigationReferences` — `App/GuessWho/Support/NavigationReferences.swift`

`EventReference` (`App/GuessWho/Support/NavigationReferences.swift:8-10`) changes its field from `externalID` to `eventUUID`. **Lowercase in `init`** (was N-UUID-CASE-NAV) so the nav token matches the lowercased `.event` SidecarKey id convention (`SidecarKey.parseGuessWhoContactURL` already does this for contacts at `SidecarKey.swift:55`):

```swift
struct EventReference: Hashable {
    let eventUUID: String
    init(eventUUID: String) { self.eventUUID = eventUUID.lowercased() }
}
```

**Complete call-site list (was B-CALLSITES — earlier revision was missing PeopleListView and OrganizationsListView, mis-cited `EventDetailView.swift:102` as an EventReference site when it's actually a ContactReference).** There are **three** separate `navigationDestination(for: EventReference.self)` registrations in the app — all three must be updated:

| File | Line(s) | What to change |
|---|---|---|
| `App/GuessWho/Support/NavigationReferences.swift` | `8-10` (struct), `20-22` (destination body in `contactAndEventDestinations`) | Rename field; pass `eventUUID: ref.eventUUID` to `EventDetailView` |
| `App/GuessWho/PeopleListView.swift` | `48-50` (its own `navigationDestination(for: EventReference.self)`) | `EventDetailView(externalID: ref.externalID)` → `EventDetailView(eventUUID: ref.eventUUID)` |
| `App/GuessWho/OrganizationsListView.swift` | `48-50` (same pattern as PeopleListView) | Same as above |
| `App/GuessWho/EventsListView.swift` | `48` (`NavigationLink(value: EventReference(externalID:))`) | Build `EventReference(eventUUID: event.id.uuidString)` |
| `App/GuessWho/EventDetailView.swift` | `7` (`let externalID: String`) | Rename field (also covered in E2.5). **Note**: line 102 is a `ContactReference(localID:)`, NOT an `EventReference` — do not modify it. |
| `App/GuessWho/ContactDetailView.swift` | `327` (`NavigationLink(value: EventReference(externalID: other.id))`) | `EventReference(eventUUID: other.id)` (`other.id` is the event UUID after the rename of the link endpoint id-space) |

`EventDetailView(externalID:)` is the public initializer that disappears — every constructor call site is captured above. After the rename, a `git grep -n 'EventReference(externalID:'` and `git grep -n 'EventDetailView(externalID:'` should both return zero matches.

### E2.7 `ContactDetailView` event section — `App/GuessWho/ContactDetailView.swift`

- `linkedEventRow` (`App/GuessWho/ContactDetailView.swift:324-345`) calls `service.event(externalID: other.id)` → `service.event(uuid: other.id)`. Because the link's event endpoint id is now the event UUID, `other.id` is directly the sidecar key id.
- `reloadEventLinks` (`:358-364`) is the **contact-side refresh trigger (b)** (Option C: "user views a contact with linked events → refresh all linked events for that contact"). After loading `eventLinks`, call a new `service.refreshLinkedEvents(forContactUUID:)` that loops once with the bound described in E4 (per-eventKitID debounce + initial-load-only firing).
- `addEventLink(eventID:note:)` (`:366-374`) → `addEventLink(eventUUID:note:)`. **Does NOT refire `refreshLinkedEvents`** — see C-REFRESH-FANOUT in E4. The fresh link's event is refreshed when the user navigates to its detail view (trigger a).
- `EventPickerSheet` (`App/GuessWho/ContactDetailView.swift:835-916`) is **replaced** by the new shared link sheet (E3) in link-to-existing mode; or kept as a thin wrapper that returns an event UUID. Default: replace with the shared `EventLinkSheet`, configured to call back with an event UUID (linking an existing EventKit event mints/returns a sidecar UUID via `service.linkEvent(toEventKitID:)`).
- **If `EventPickerSheet` is retained as a wrapper** instead of replaced (was N-FOURTH-NOTES-SITE), `ContactDetailView.swift:914` reads `(e.notes ?? "")` inside `EventPickerSheet.filtered` — this is a **fourth** `.notes` → `.eventKitNotes` rename site that was missing from E1.1's site list. The full set of rename sites then becomes: `EventsRepository.swift:35`, `EventDetailView.swift:68`, `EventDetailView.swift:914`-region wrapper code (if reused), plus `ContactDetailView.swift:914` itself. If the wrapper is replaced as the default recommends, this concern disappears.

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
| Search field (top) | Filters title + location across whatever range is currently loaded. **When `search` is non-empty AND zero local hits**: show an inline "Search older events" row (was C-SEARCH-DISCOVERABILITY — the prior `(and/or service.searchCalendarEvents(...))` parenthetical was the undecided behavior that produces the discoverability trap) that, on tap, calls `service.searchCalendarEvents(text:in:)` over a **3-year-back** interval (`today-3y … today+365d`) and merges results into the loaded view. | local filter over `loadedDays`; on-demand `service.searchCalendarEvents(text:in: DateInterval(today-3y, today+365d))` |
| "Add Other" button (create mode) | Switches to a **manual-entry form** (no `eventKitID`); on save → `service.createManualEvent(...)` → sidecar-only event; calls `onCreated(newUUID)` and dismisses | `service.createManualEvent(title:start:end:isAllDay:location:)` |
| "Add Other" button (**link mode**) — was C-ADDOTHER-LINKMODE | Manual-entry form gains a **Note** field (the link note). On save: `createManualEvent(...)` then `onLinked(newUUID, linkNote)` so the caller (e.g. `ContactDetailView.addEventLink`) creates the contact↔event link immediately. The user's intent "link to this contact" must not be silently dropped after the manual event is minted. | `service.createManualEvent(...)` → caller's `onLinked` callback |
| "Add to Calendar" toggle on the Add-Other form (create mode) — was C-CREATE-LINKED-UI | When ON, save calls `service.createLinkedEvent(...)` (writes a sidecar AND creates an EKEvent in `defaultCalendarForNewEvents`) instead of `createManualEvent`. Toggle is **disabled** when `eventsAuthorization != .authorized` or `.restricted` with footnote "Enable Calendar to add events to your calendar." | `service.createLinkedEvent(title:start:end:isAllDay:location:)` |
| Tap an event row (link mode) — was C-SHEET-DEDUP | **MANDATORY**: sheet first calls `service.eventUUID(forEventKitID:)`. If non-nil, reuse that UUID (no mint). If nil, call `service.linkEvent(toEventKitID:snapshot:)` to mint. Either way, fire `onLinked(eventUUID, linkNote)`. This makes the dedup behavior unavoidable (E1.7's "caller checks if it wants edit-existing behavior" is too permissive for the link-sheet path — it would produce single-device duplicates on innocent re-tap). | `service.eventUUID(forEventKitID:)` then optional `service.linkEvent(toEventKitID:snapshot:)` |
| Tap an event row (create mode) | Same dedup-first path as link mode, then `onCreated(eventUUID)` and navigates to the new event detail | Same as above |

**Partial-failure handling.** Minting the sidecar (`linkEvent`) and creating the contact↔event link (`addContactEventLink` inside the caller's `onLinked`) are two separate writes with the sheet dismissal in between. If `onLinked` throws (e.g. `SidecarUnavailableError` from `addContactEventLink`), the minted sidecar exists but no contact-link does — surface the error via `service.recordError` (existing path used by `EventDetailView`); the orphan sidecar is harmless (it shows up in the Events list as a linked event with no contact attached) and the user can retry the link from the contact view.

### E3.3 No-permission fallback

On presentation, check `service.eventsAuthorization`:
- If `.notRequested` or `.denied`: **skip the calendar list entirely.** Go straight to the manual-entry form (`manualEntry = true`) with a top banner: *"Enable Calendar access in Settings to link events from your calendar."* The only outcome is a sidecar-only event via `service.createManualEvent(...)`. (Mirrors the `EventsListView` banner approach, E2.4.) The "Add to Calendar" toggle on the Add-Other form is disabled (`createLinkedEvent` requires write access).
- If `.restricted` (was C-RESTRICTED): same as `.denied` for sidecar-only flow — manual-entry only, "Add to Calendar" toggle disabled, calendar-browsing affordances suppressed. Do NOT attempt to call into EventKit.
- If `.authorized`: show the today-section + show-more + pull-to-refresh list described above, with the "Add Other" button always available and the "Add to Calendar" toggle enabled.

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
3. Live → write `titleCache`/`startCache`/`endCache`/`isAllDayCache`/`locationCache`/`eventKitNotesCache` cells (only those whose value changed, to avoid stamp churn — compare the **decoded current cell value** first, like the notes "no-op if unchanged" rule in `PLAN.md §12.3`). Return the live-projected `Event`.

Refresh is best-effort and swallows EventKit read errors into `lastError` (consistent with `SyncService` patterns). It is **never** triggered for the full list (E2.2) — only per-event on detail view and per-contact on contact view, to bound EventKit traffic.

**List browsing never advances the cache (was C-LIST-CACHE-STALE).** The list path in E2.2 reads live EventKit values via the single in-window `fetchEvents(in:)` batch and overlays them onto sidecars at projection time, but does NOT write back to the cache cells — only the detail-view (trigger a) and contact-view (trigger b) paths invoke `refreshEventCache(at:)`. Consequence: a sidecar whose user never opens detail keeps a potentially-stale cache; when the EKEvent is later deleted, Option C fallback renders whatever cache existed at the last detail/contact visit. This is an accepted tradeoff for bounding EventKit traffic from the list view. The `.EKEventStoreChanged` reload at `RootView.swift:67-69` narrows the staleness window — while the app is foregrounded, a calendar change re-fires the list read and re-projects from fresh EventKit values (cache still not written, but display is live).

**Cross-device write amplification is bounded (was C-WRITE-AMPLIFICATION).** When EventKit changes once and N devices each visit the event's detail or its linked contact, each device executes its own `refreshEventCache(at:)` and writes the changed cells with its own `deviceID`/`modifiedAt`. Per §5.3 LWW the later write wins; intermediate writes are wasted bytes but cause no convergence problem. Bound: **at most one cache write per device per actual EventKit change**, not per view (the "only changed cells" rule in step 3 above keeps repeat detail visits to zero writes). This is silent to the user but not silent to the sync layer — acknowledged as the cost of caching live values for offline fallback.

**`refreshLinkedEvents(forContactUUID:)` bound (was C-REFRESH-FANOUT).** The contact-view trigger (b) loops every linked event and calls `refreshEventCache(at:)`. Without a bound, a contact with 20 linked events runs 20 synchronous `events.fetch(eventKitID:)` calls on the main actor on every contact-view appearance — a visible hitch and an "every-view-is-N-EventKit-calls" violation of E4's bounded-traffic goal. v1 bound:

1. **Per-eventKitID debounce window** (in-memory): `SyncService` keeps a per-session `recentlyRefreshed: [SidecarKey: Date]` map. `refreshLinkedEvents` and `refreshEvent` (trigger a) skip a sidecar whose entry is newer than `now - 60s`. Map lives in `SyncService` (which is already `@MainActor`), so no extra synchronization; cleared on app launch. Skips do NOT count as errors. (60 s is the v1 default — tunable; under it the user just sees Option C cache, which is by design.)
2. **Initial-load-only firing on the contact view**: `reloadEventLinks` calls `refreshLinkedEvents(forContactUUID:)` on first appearance only, NOT on subsequent `addEventLink`/`removeEventLink`. A freshly-added link's event refreshes when the user navigates to its detail view (trigger a).
3. Each `events.fetch(eventKitID:)` stays on the main actor for now — moving the fetch off-main is a future optimization tracked in E7 if main-actor hitches surface in practice.

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

1. **Per legacy event sidecar — translate identifier, mint UUID, rewrite envelope** (`for key in sidecars.allKeys() where key.kind == .event`):
   - If `UUID(uuidString: key.id) != nil` **and** the envelope already has an `eventKitID` cell → already migrated; skip.
   - Otherwise treat `key.id` as a legacy `eventIdentifier` string **in its original case** (read from the percent-decode path in `listKeys`, see E1.4; do NOT lowercase). Mint `newUUID = UUID()`.
   - **Translate identifier (was B-IDENTITY):**
     - Resolve the EKEvent via `store.event(withIdentifier: legacyEventIdentifier)` — i.e. through the adapter, a one-shot `events.fetch(legacyEventIdentifier:)` helper that uses ONLY the `eventIdentifier` resolver (NOT the dual-namespace `fetch(eventKitID:)`, since here we know the input is a legacy `eventIdentifier`).
     - If resolved: let `ekid = ekEvent.calendarItemExternalIdentifier` (the new canonical id). Store that in the `eventKitID` cell. Seed cache cells (`titleCache`, `startCache`, etc.) from `ekEvent`.
     - If NOT resolved (EKEvent no longer exists at migration time): write the `eventKitID` cell with the **original `legacyEventIdentifier` string** as a **dead pointer**. Leave cache cells empty. The dual-namespace `fetch(eventKitID:)` (E1.6) will still resolve this if the EKEvent ever reappears under the same `eventIdentifier`; otherwise Option C silent-fallback-to-cache renders blank values forever (acceptable — the alternative is dropping the sidecar entirely, which would orphan any notes/tags/contact-links the user attached to it).
   - Read the legacy envelope. Build a new envelope with `entityID = newUUID.uuidString`:
     - Apply the `eventKitID` cell as computed above (a regular `.note` cell, not soft-deleted — this event IS linked, even if dead-pointer).
     - Copy any pre-existing field-instance cells (notes the user already attached to the event) **verbatim** into the new envelope (their UUID keys are preserved; merge-safe).
     - Cache cells per the resolved/unresolved branch above. All `Date` → `String` serialization uses `SidecarISO8601.string(from:)` per N-ISO8601.
   - `sidecars.write(newEnvelope, at: SidecarKey(kind:.event, id: newUUID.uuidString))` (the new UUID is lowercased automatically by `SidecarKey.init`'s `.event` branch added in E1.4).
   - `sidecars.delete(SidecarKey(kind:.event, id: legacyEventIdentifier))` (the old, possibly percent-encoded, original-case file).
   - Record `(legacyEventIdentifier, newUUID)` in the migration map. The map key is the **original-case** `legacyEventIdentifier` — DO NOT lowercase, since case-sensitive `eventIdentifier` strings are still being read by `Link.decodeEndpoint` from legacy links until step 2 rewrites them.

2. **Rewrite contact↔event link endpoints — needs a new event-specific helper** (was B-LINKREWRITE). The existing `rewriteLinkEndpoints` (`Sources/GuessWhoSync/GuessWhoSync.swift:664-729`) is hardcoded to `.contact` endpoints (pre-screen at `:677-678`, winner pick at `:689-690`, winner kind hardcoded at `:697`/`:704`). It cannot be reused as-is.

   Add either a **generalized helper** that takes the matched/rewritten `SidecarKind` as a parameter, or a **new event-specific** method that mirrors the same shape. Sketch:

   ```swift
   /// Migration-only helper: rewrite (.event, legacyEventIdentifier) endpoints
   /// to (.event, newEventUUID) per the provided mapping. Preserves the
   /// per-key-locked re-read-and-write invariants from §13.4 (one write per
   /// link, locks acquired in sorted UUID order, no other endpoint touched).
   /// Returns the link UUIDs whose endpoint A and/or B was rewritten.
   private func rewriteEventLinkEndpoints(mapping: [String: UUID]) throws -> [UUID]
   ```

   Implementation mirrors `rewriteLinkEndpoints` but: the pre-screen is `preAEnd.kind == .event && mapping[preAEnd.id] != nil` (and B-side); the winner is `mapping[aEnd.id]?.uuidString.lowercased()`; the rewritten endpoint cell carries `SidecarKey(kind: .event, id: winnerLowercased)`. Per-link `sidecarLocks.withLock` and the inner re-read-under-lock pattern are kept verbatim. Each link gets at most one envelope write.

   Lookup key for the mapping is the **original-case `legacyEventIdentifier`** that came out of `Link.decodeEndpoint(...)`. Critical: until step 2 finishes, `Link.decodeEndpoint` (which routes through `SidecarKey.init`) must NOT lowercase the `.event` endpoint id. Two safe orderings exist:
   - (a) Run migration **before** flipping `SidecarKey.init`'s `.event` branch to lowercasing. The E1.4 change to `SidecarKey.init` is gated on a `MigrationFlag`-style toggle: legacy decode preserves case until migration completes, then the flag flips. (Implementation-heavy; rejected.)
   - (b) **Adopted**: `SidecarKey.init`'s `.event` branch lowercases unconditionally (E1.4), but the migration map is keyed by `legacyEventIdentifier.lowercased()`, AND step 1's `legacyEventIdentifier` (read from `key.id` after `listKeys` percent-decode) is fed through the same `.lowercased()` step before being used as the map key. Net: the migration map's domain is lowercased legacy ids, the EKEvent lookup (`store.event(withIdentifier:)`) is fed the **original-case** legacy id (case-sensitive, EventKit requires it), and link rewrite matches against the lowercased decoded endpoint id. Step 1 must therefore remember **both** the original-case id (for `store.event(withIdentifier:)`) and the lowercased id (for the map key + the file `sidecars.delete`). This requires reading `listKeys`'s decoded basename twice (once with `.lowercased()` for the map, once without for EventKit) — see B-IDENTITY case-collision fix.

   Record rewritten link IDs.

All writes go through the per-key `sidecarLocks` discipline. The migration is **idempotent** (step 1's skip clause + step 2's no-op-on-already-rewritten endpoint shape) and safe to call at every launch until it converges; cheap once done (all keys already UUID + eventKitID, all link endpoints already UUID).

### E5.3 When it runs

Called once early, **before any event read**, and crucially **before any contacts-permission gate** (was B-MIGRATION-TRIGGER). Migration is a pure sidecar-store operation; it does not require Contacts or EventKit permission (the EventKit fetch in step 1 is best-effort and the dead-pointer branch handles the unauthorized case the same as the gone-event case).

**Exact placement:** at the top of `RootView`'s **unconditional** `.task` modifier (`App/GuessWho/RootView.swift:41`), BEFORE `requestContactsAccessIfNeeded`. `GuessWhoApp.swift` has no `.task` (it's a 13-line `WindowGroup` shell), so the natural-sounding "GuessWhoApp `.task`" placement is not real and must not be invented. The contacts-gated `ensureRepositoriesAndLoad` (`RootView.swift:107-116`) is also wrong — it only fires for `contactsAuthorization == .authorized`, silently skipping migration for any user who has denied or not-yet-granted Contacts.

```swift
.task {
    if let sync = service.sync {
        try? sync.migrateEventsToSidecarFirst()   // sidecar-only; no perms needed
    }
    await service.requestContactsAccessIfNeeded()
    await service.requestEventsAccessIfNeeded()
    if service.contactsAuthorization == .authorized {
        ensureRepositoriesAndLoad()
    }
}
```

Wrapper method on `SyncService` is fine (`migrateEventsIfNeeded()`), but its single line is `try? sync?.migrateEventsToSidecarFirst()` and it must be guarded only by `guard let sync` — not by `eventsAuthorization` and not by `contactsAuthorization`.

Because the FS store's filename branch still decodes percent-encoded legacy names during the transition (E1.4), the legacy files remain readable until migration deletes them. The migration is idempotent; running it on every launch is the chosen v1 behavior (a "migration ran" flag on the sidecar root is a future optimization).

### E5.4 Cross-device migration safety

Two devices may run the migration independently and mint different UUIDs for the same legacy `eventIdentifier` — producing two UUID sidecars that share one `eventKitID`. This is the event analogue of `PLAN.md §3.3` Case D. Default (E7 Q1): leave both; the lex-min tie-break is part of `eventUUID(forEventKitID:)`'s contract (see E1.7 — folded in there for visibility), so both devices display the same one. Defer true merge to a follow-up. Document this in the report's `skipped`/notes. (A full event-identity reconcile mirroring §3.3 is the clean fix; scoped out of this migration to keep it bounded.)

Additional cross-device wrinkle (was B-IDENTITY consequence): two devices may also disagree about whether a legacy `eventIdentifier` translates — Device A finds the EKEvent and writes `calendarItemExternalIdentifier` into the `eventKitID` cell, Device B doesn't and writes the legacy `eventIdentifier` (dead pointer). They sync; per §5.3 LWW the later write to the `eventKitID` cell wins. This is harmless: both values are valid inputs to the dual-namespace `fetch(eventKitID:)` resolver (E1.6), so display works regardless. The cell stays at whichever identifier last won; we do NOT proactively rewrite it from `refreshEventCache` (which only touches cache cells, not the pointer cell), since a stable LWW-resolved pointer is fine for the resolver.

---

## E6. Test matrix

Tests live in `Tests/GuessWhoSyncTests/` using Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), matching `InMemoryEventStoreTests.swift` and `LinkTests.swift` style, against the in-memory mocks in `Sources/GuessWhoSyncTesting/`.

### E6.1 Mock changes — `Sources/GuessWhoSyncTesting/InMemoryEventStore.swift` + new `CountingEventStore`

`InMemoryEventStore` (`Sources/GuessWhoSyncTesting/InMemoryEventStore.swift:4-29`) gains:
- Storage keyed by `eventKitID` (still a `[String: Event]`, but the key is the EventKit external id).
- `fetch(eventKitID:)`, `fetchEvents(on:)`, `searchEvents(matching:in:)`.
- `createEvent(...)` — mints an `eventKitID` (e.g. `"ek-\(count)"`), stores, returns the Event; a test-visible counter for determinism.
- `updateEvent(eventKitID:...)` — mutates the stored Event; throws `EventStoreError.eventNotFound` if absent.
- A test-only `removeEvent(eventKitID:)` to simulate "deleted from EventKit" (drives the Option C fallback tests).

New file `Tests/GuessWhoSyncTests/CountingEventStore.swift` (was N-COUNTING-EVENT-STORE) — wraps an `EventStoreProtocol`, counts per-method invocations, forwards to an inner store. Mirrors `Tests/GuessWhoSyncTests/CountingSidecarStore.swift` but for events. Used by `EventWindowTests` to assert `fetchEvents(in:)` is called exactly once and `fetch(eventKitID:)` is called zero times for the list path (the C-WINDOW-FETCH invariant).

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
- `createLinkedEventCreatesEKEventAndSidecar` (was C-CREATE-LINKED-UI test) — `createLinkedEvent(...)` calls into `InMemoryEventStore.createEvent`, mints a sidecar with the new `eventKitID`, cache cells seeded from the returned `Event`; `event(at:)` projects live values.
- `linkEventStoresEventKitIDAndCache` — `linkEvent(toEventKitID:snapshot:)` writes the `eventKitID` + cache cells; `event(at:)` projects EventKit-live values when the mock event exists.
- `linkExistingSidecarAdoptsManualEvent` (was C-MANUAL-TO-LINK test) — `createManualEvent` with title "Manual"; pre-create an EKEvent with title "Live"; `linkExistingSidecar(at:toEventKitID:)`; assert the `eventKitID` cell is now set and `event(at:)` returns title "Live" (live-wins-when-linked) AND `titleCache` cell now also reads "Live" (the post-link refresh wrote it).
- `displayPrefersLiveOverCacheWhenLinked` — seed cache with stale title; mock EventKit returns a fresh title; `event(at:)` returns the fresh one.
- `displayFallsBackToCacheWhenEventKitGone` — link, then `removeEvent(eventKitID:)`; `event(at:)` returns cached values and `eventKitID` is still set (no auto-unlink).
- `updateLinkedEventWritesEventKitAndRefreshesCache` — `updateEventFields` on a linked-live event mutates the mock EKEvent and updates the cache cells.
- `updateUnlinkedEventWritesCacheOnly` — `updateEventFields` on a manual event writes cache cells, never calls EventKit. Assert via `CountingEventStore` (E6.1) that `updateEvent` is called zero times.
- `updateLinkedButDeletedWritesCacheOnly` — linked event whose EKEvent is gone: edit writes cache, does not throw, does not unlink.
- `eventUUIDForEventKitIDReverseLookup` — round-trips; nil when none.
- `eventUUIDForEventKitIDExcludesUnlinkedAndPicksLexMin` (was C-LEXMIN-CONTRACT test) — two sidecars share `ekid`, both linked: returns the lex-min UUID. Then `unlinkEvent` the lex-min one: returns the other (soft-deleted excluded from scan).
- `unlinkEventSoftDeletesEventKitIDCellPreservesValue` (was C-UNLINK test) — `unlinkEvent(at:)` on a linked event: `eventKitID` cell now has `deletedAt`, but its `value` string is unchanged; cache cells untouched; `event(at:)` returns cached values; `isLinked == false`.
- `unlinkVsRefreshDisjointCellsConverge` — Device-A unlink, Device-B refresh from EKEvent: merge yields the unlink cell (soft-deleted) AND the refreshed cache cells; final display is unlinked with fresh cache.
- `deleteEventWritesDeletedAtCellAndFiltersFromAllEvents` (was C-EVENT-DELETE test) — `deleteEvent(at:)` writes the envelope-level `deletedAt`; `allEvents()` omits it; raw `sidecars.read` still returns it; EKEvent (if linked) still exists.
- `deleteThenWriteFieldsResurrectsCellsButFilteredAway` — soft-deleted envelope + a later `updateEventFields` write: cache cells exist with new stamps but `allEvents()` still filters via `deletedAt`. (Documents the §5.5 hazard for events.)
- `refreshEventCacheNoOpForUnlinked` / `refreshEventCacheUpdatesFromEventKit` / `refreshEventCacheNoOpWhenGone`.
- `refreshEventCacheOnlyWritesChangedCells` — pre-seed cache that already matches the EKEvent; assert no sidecar write fires (via `CountingSidecarStore`).

**`Tests/GuessWhoSyncTests/EventNotesTagsTests.swift`** — notes on an event key (reusing `addNote/notes` against a `.event` key); tags via `addTag/editTag/deleteTag/tags`; `NoteTypeMismatch`-style: a tag is a `.note` field with `field == "tag"`; `tags(at:)` excludes notes and vice versa; soft-delete excludes from `tags(at:)` but raw `fields(at:)` retains. Specifically:
- `tagsAtReturnsEventTagWithIdMatchingFieldInstance` (was B-TAGS test) — add three tags; `tags(at:)` returns `[EventTag]` of length 3; each `EventTag.id` matches the field-instance UUID; `editTag(at:, id:, text:)` updates the text and `tags(at:)` reflects it; `deleteTag(at:, id:)` removes it.
- `tagsAndNotesDiscriminatedByFieldName` — add 1 note and 1 tag on the same event key; `notes(at:)` returns the note only; `tags(at:)` returns the tag only.
- `noteWhoseBodyContainsWordTagIsStillANote` — content discriminator vs field-name discriminator (N4 clean-confirmed).

**`Tests/GuessWhoSyncTests/EventMigrationTests.swift`** — drive `migrateEventsToSidecarFirst()`:
- `migratesLegacyEventIdentifierKeyedSidecarTranslatesToCalendarItemExternalIdentifier` — seed an `InMemorySidecarStore` with an `events/<legacyEventIdentifier>` envelope (entityID = legacyEventIdentifier, plus a note instance); pre-seed the `InMemoryEventStore` with an EKEvent whose `eventIdentifier == legacy` AND `calendarItemExternalIdentifier == ekid-new`; run migration; assert a new UUID-keyed envelope exists with `eventKitID` cell = `ekid-new` (NOT the legacy id), the note instance preserved, and the old key deleted.
- `migratesLegacyEventIdentifierWithGoneEKEventToDeadPointer` (was B-IDENTITY test) — seed a legacy envelope but DO NOT pre-seed any EKEvent; run migration; assert the new UUID envelope's `eventKitID` cell holds the **original legacy `eventIdentifier` string** (dead pointer), cache cells empty, `event(at:)` returns cached empty values, `isLinked == true`.
- `migrationIsIdempotent` — second run is a no-op; report has no new migrations.
- `migrationRewritesLinkEndpoints` — pre-seed a `Link` with `endpointB = (.event, legacyEventIdentifier)`; after migration the link carries `(.event, newUUID.lowercased())` in one write; `report.rewrittenLinkIDs == [link.id]` (mirrors `LinkCaseDRewriteTests`). Drives the new `rewriteEventLinkEndpoints` helper.
- `migrationPreservesCaseSensitiveLegacyIDs` (was B-IDENTITY case-collision test) — seed two legacy event sidecars with ids differing only in case (`AbC123` vs `abc123`); assert each gets its own UUID sidecar, the map keys are lowercased but the `store.event(withIdentifier:)` calls use the original cases, and links pointing at each are rewritten correctly.
- `migrationSeedsCacheFromEventKitWhenPresent` / `leavesCacheEmptyWhenEventKitGone`.
- `crossDeviceTwoUUIDsForSameEventKitID` — two migrations on the same legacy id (simulated) produce two UUID sidecars sharing an eventKitID; `eventUUID(forEventKitID:)` returns the deterministic (lex-min) one (documents E7 Q1 default).

**`Tests/GuessWhoSyncTests/EventWindowTests.swift`** — `eventsWindow(from:to:)` returns the union of sidecar events and EventKit-window events deduped by `eventKitID`; manual events with no EventKit presence still appear; EventKit-only events (no sidecar) appear as unlinked-display rows. Specifically:
- `eventsWindowSinglesOnesFetchInWindow` (was C-WINDOW-FETCH test) — wrap the in-memory event store in `CountingEventStore`; seed 5 linked sidecars and 5 EKEvents all in-window; call `eventsWindow(...)`; assert `CountingEventStore.fetchEventsInIntervalCount == 1` AND `fetchEventKitIDCount == 0` (no per-sidecar fetch). Also assert each returned linked event projects live values (cache overlay).
- `eventsWindowExcludesDeletedEnvelopes` — soft-delete an event via `deleteEvent`; assert it's missing from the window output.
- `eventsWindowIncludeEventKitFalseReturnsSidecarOnly` — pass `includeEventKit: false`; assert no EventKit fetch fires; only sidecar events returned (manual + linked-with-cache).
- `eventsWindowEphemeralRowsUseStableID` (was N-EPHEMERAL-ROW-ID test) — call `eventsWindow(...)` twice; assert un-adopted EKEvent rows have identical `Event.id` across the two calls (derived from `eventKitID`).

### E6.4 PLAN.md §9.7 update

`PLAN.md §9.7 "Event sidecars"` (`PLAN.md:759-762`) is rewritten:
- ~~"event lookup by externalID works"~~ → "event lookup by `eventKitID` (`calendarItemExternalIdentifier`) works via the dual-namespace resolver; event sidecars keyed by minted UUID."
- "writing a sidecar for an event does not mutate the EventKit event **unless the edit targets a linked field, in which case it writes EventKit via `updateEvent`**" (Option C).
- "per-field LWW rules apply identically to event sidecars" — retained.
- Add: "Option C display projection: live-when-linked-and-present, cache otherwise"; "no auto-unlink on EventKit deletion"; "whole-event soft-delete via envelope-level `deletedAt` cell, mirroring link `deletedAt`."
- Add: "unlink and refresh touch disjoint cells (eventKitID vs cache cells), converging cleanly under §5.3."

---

## E7. Open questions (truly still open after the round-1/round-2 reviews)

The following are decided and folded into the relevant sections (not "open" anymore — listed here as a pointer index): identifier-namespace pivot (B-IDENTITY → E0/E1.6/E5.2), filename branch split (B-FILESTORE → E1.4), event-specific link rewrite (B-LINKREWRITE → E5.2), full call-site list (B-CALLSITES → E2.6), `EventTag` definition (B-TAGS → E1.7), migration trigger placement (B-MIGRATION-TRIGGER → E5.3), unlink (C-UNLINK → E1.7/E2.5), whole-event delete (C-EVENT-DELETE → E1.7/E1.2/E2.4/E2.5), create-linked UI (C-CREATE-LINKED-UI → E3.2), manual-to-link adoption (C-MANUAL-TO-LINK → E1.7/E2.5), lex-min contract (C-LEXMIN-CONTRACT → E1.7), single-batch window fetch (C-WINDOW-FETCH → E2.2), link-mode Add-Other onLinked (C-ADDOTHER-LINKMODE → E3.2), mandatory sheet dedup (C-SHEET-DEDUP → E3.2), search discoverability (C-SEARCH-DISCOVERABILITY → E3.2), permission-flip behavior (C-DENIED-TO-AUTHORIZED → E2.1), permission seam (C-WINDOW-PERMISSION → E2.1/E2.2), `.restricted` policy (C-RESTRICTED → E2.4/E3.3), list-cache-stale acknowledgement (C-LIST-CACHE-STALE → E4), write amplification (C-WRITE-AMPLIFICATION → E4), refresh-fanout debounce (C-REFRESH-FANOUT → E4), eventKitID cell null-vs-soft-delete (C-EVENTKITID-CELL-NULL → E1.2).

Remaining truly-open questions for human sign-off:

1. **Duplicate event UUIDs for one `eventKitID` (cross-device / double-link).** Two devices that migrate independently, or that link the same EventKit event before the link sheet dedup (C-SHEET-DEDUP) catches it, produce two sidecar UUIDs sharing an eventKitID. **v1 default:** do not auto-merge; `eventUUID(forEventKitID:)` returns the lex-smallest deterministically so both devices display the same one (E1.7 contract); full event-identity reconcile (mirroring `PLAN.md §3.3` Case D) is deferred. *Needs human sign-off if true convergence is required for v1.* Mitigation: link-sheet dedup (C-SHEET-DEDUP) eliminates the single-device path; only cross-device-pre-sync remains.

2. **Auto-adoption of calendar events into sidecars.** Should every EventKit event in the list window get a sidecar? **Default: no** — mint a sidecar only when the user acts (link/note/tag/contact/edit), keeping sidecar count proportional to intent (E2.2). *Confirm this matches the product intent for the events list.*

3. **`eventKitNotes` vs GuessWho notes.** EventKit's own notes string is cached (`eventKitNotesCache`) and displayed read-only; GuessWho event notes are separate sidecar instances. **Default: keep them distinct**; editing EventKit notes is out of scope (we never write EKEvent.notes). *Confirm we don't want to surface an "edit calendar notes" path.*

4. **Which calendar receives `createLinkedEvent` / `createEvent`?** **Default:** `EKEventStore.defaultCalendarForNewEvents`; throw `EventStoreError.noWritableCalendar` if nil. *Confirm no calendar-picker is needed for v1.*

5. **Pull-to-refresh year granularity.** Spec says "previous year per pull." **Default:** exactly 365-day chunks anchored at `today`, unbounded backward on repeated pulls. *Confirm 1-year chunks (vs. month/quarter) are the desired UX.*

6. **`refreshLinkedEvents` main-actor cost.** The v1 bound is per-eventKitID 60 s debounce + initial-load-only firing (E4 / C-REFRESH-FANOUT). If profiling on real contacts with many linked events still shows a visible hitch, move `events.fetch(eventKitID:)` off the main actor (the `recentlyRefreshed` map stays main-actor; the fetches dispatch through). Tracked here so it isn't lost.

---

## E8. Implementation order (suggested)

Mirrors `PLAN.md §11`'s phased, test-each-phase approach. **PLAN.md amendments come FIRST** (was N-AMENDMENT-SEQUENCING) so the spec doesn't contradict the code while in flight — §2's "events are read-only" non-goal and §4's "per-event keyed by externalID" boundary statement actively misdirect any reader of the in-progress code if left as the final step.

0. **PLAN.md amendments (do this first).** Edit every location below before touching any code; once amended, the spec is internally consistent and reviewers can grade the in-flight code against it. The full enumeration (was N-PLAN-AMENDMENTS — earlier revisions listed only a subset):

   | PLAN.md location | What to change |
   |---|---|
   | §2 (non-goals list, "Writing to EventKit events. Events are read-only") | Drop the "events are read-only" bullet. Replace with: "Writing arbitrary EventKit metadata (e.g. attendees) — only title/start/end/location/isAllDay are writable for linked events; notes remain GuessWho-sidecar-only." |
   | §3.1 line 45 ("events use it directly without a GuessWho-assigned UUID") | Replace: "events also receive a GuessWho-assigned UUID at sidecar-mint time; `eventKitID` is a separate pointer cell." |
   | §4 line 97 ("per-event keyed by `calendarItemExternalIdentifier`") | Replace: "linked events: title/start/end/location/isAllDay are canonical in EventKit, mirrored into the sidecar cache cells (E1.2); manual events: canonical in the sidecar cache cells; per-event sidecar keyed by minted UUID, with an `eventKitID` cell pointing OUT to EventKit." |
   | §5.1 lines 108 / 114 ("events keyed by externalID") | Replace: "events keyed by minted UUID, mirroring contacts. Filenames are `<uuid-lowercased>.json`." |
   | §5.2 lines 121 / 157 / 161-164 (event envelope mention "externalID") | Replace with "event UUID"; explicit note that events use the same envelope shape as contacts plus the well-known cells listed in EVENT_STRATEGY_PLAN.md E1.2. |
   | §7.1 lines 325-326 / 434 / 639 (`forEvent` "total because externalID is canonical") | Replace rationale: "`forEvent` is total because every `Event` has a `UUID id`." Update any code-block signature that takes `Event.externalID`. |
   | §7.2 lines 480-481 (`// No save: events are read-only.`) | Replace with the new write methods listed in EVENT_STRATEGY_PLAN.md E1.5 (`createEvent`, `updateEvent`); note linked-only write semantics. |
   | §9.7 lines 759-762 (Event sidecars) | Rewrite per E6.4 below: lookup by `eventKitID`; sidecar UUID-keyed; writes target EventKit when linked; Option C projection rule; no auto-unlink. |

1. **Model + protocol + mock.** `Event` (E1.1) including the stable-id-from-eventKitID synthesizer for ephemeral rows, `EventStoreProtocol` (E1.5), `EventStoreError`, `EventTag` (E1.7), `InMemoryEventStore` + `CountingEventStore` (E6.1), `SidecarKey` (E1.4 — both the lowercasing branch AND the `safeFilename` change; keep `listKeys` percent-decode untouched). Tests: E6.2 mock/key tests compile and pass.
2. **Orchestrator event API.** `GuessWhoSync+Events.swift` (E1.7) including `unlinkEvent`, `deleteEvent`, `linkExistingSidecar`, `createLinkedEvent`, lex-min `eventUUID(forEventKitID:)`, and `eventsWindow` (E2.2 single-batch fetch). Tests: `EventSidecarTests`, `EventNotesTagsTests`, `EventWindowTests` (E6.3).
3. **Migration.** `migrateEventsToSidecarFirst()` (E5) including the identifier-translation step and `rewriteEventLinkEndpoints` helper. Tests: `EventMigrationTests`.
4. **EventKit adapter writes.** `EKEventStoreAdapter` (E1.6) including the dual-namespace `fetch(eventKitID:)`. Smoke: `AdapterSmokeTests` conformance + on-device smoke (deferred, like `PLAN.md §11.1`).
5. **App layer (non-UI).** `SyncService` (E2.1) including the debounce map, the `includeEventKit` flag, `migrateEventsIfNeeded()` wrapper.
6. **App layer (UI).** `EventsRepository`/`EventsListView`/`EventDetailView`/`NavigationReferences`/`PeopleListView`/`OrganizationsListView`/`ContactDetailView` (E2.3–E2.7). `RootView.swift:41` `.task` gains the migration call BEFORE `requestContactsAccessIfNeeded` (E5.3).
7. **Link sheet.** `EventLinkSheet.swift` (E3) including the link-mode Add-Other path with Note field, the "Add to Calendar" toggle, the mandatory `eventUUID(forEventKitID:)` dedup, the empty-state "Search older events" affordance, and the `.restricted`-aware fallback.
