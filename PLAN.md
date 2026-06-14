# GuessWhoSync — Plan

A Swift package that treats the system Contacts store and EventKit as the canonical data sources, and uses iCloud-synced JSON sidecar files only for fields that don't fit there.

This document is the spec. It records the decisions that have been made, the open questions that have been deliberately deferred, and the design that the first implementation will follow.

---

## 1. Goals

1. **Canonical data in Contacts.** Anything the Contacts framework can represent is stored there.
2. **Canonical data in EventKit.** Anything the EventKit framework can represent is stored there.
3. **Sidecars for the rest.** Custom GuessWho-specific fields live in per-entity JSON files synced through an iCloud folder.
4. **Stable cross-device identity.** Every contact GuessWhoSync touches gets a stable GuessWho UUID, embedded as a `guesswho://contact/<uuid>?t=<iso8601>&d=<deviceID>` URL in the contact's `urlAddresses`. The UUID is the same on every device after sync converges.
5. **Deterministic conflict resolution.** When multiple devices independently assigned a UUID to the same contact, every device picks the same winner without coordination.
6. **Test-first.** All semantics — identity, sidecar IO, conflict resolution — are exercised by unit tests against in-memory mocks that satisfy the same protocols as the real stores.

## 2. Non-goals (v1)

- Writing to EventKit events. Events are **read-only** from the package's perspective; only their sidecar files are mutable.
- Per-field LWW timestamps. The sidecar is the unit of LWW in v1. Field-level merge is a v2 consideration.
- Auto-installing a CloudKit container, an `NSFilePresenter`, or any background sync infrastructure. The host app drives reconcile cycles by calling into the package.
- Cross-iCloud-account sync. Single user, single iCloud account.
- Handling Contacts that live in non-iCloud sources (Exchange, Google CardDAV). v1 documents this as out of scope and does not actively prevent it; behavior is "best effort, may drift."

## 3. Identity & URLs

### 3.1 Why we need our own UUID

`CNContact.identifier` is **device-local**. The same logical contact has a different `identifier` on each device after iCloud sync. We cannot use it as a stable cross-device key.

EventKit is different: `EKEvent.calendarItemExternalIdentifier` is documented as stable across the same iCloud account, so events can use it directly without a GuessWho-assigned UUID.

### 3.2 The GuessWho URL

For every contact GuessWhoSync touches, we add an entry to `CNContact.urlAddresses` with:

- **label:** `"GuessWho"` (custom label, will display as "guesswho" in the system Contacts UI; acceptable)
- **value:** `guesswho://contact/<uuid>`
  - `uuid` — random v4 UUID assigned on first touch

No timestamp or device ID is embedded — see §3.5 for why.

### 3.3 Why a URL and not a custom field

`CNContact` exposes a fixed set of fields. URLs are one of the few free-form-string lists. They sync via CardDAV without loss and are visible/editable in the system Contacts app (a feature, not a bug — users can see what we did). No private API, no postprocessor on import/export.

### 3.4 Why we don't embed a clock

The earlier design embedded a write timestamp in the URL so we could pick "first write wins" deterministically. We dropped that because:

- It made every URL depend on the device clock, which is unreliable across devices.
- For convergence, we don't actually need "first wins" — we need *every device to pick the same winner from the same input*. UUID-alphabetical does that, with no clock involved.

The trade-off: the winning UUID is effectively random per concurrent-assignment pair, rather than "the one created first." Since UUIDs are random anyway, this is invisible to the user.

### 3.5 Reconciliation when multiple GuessWho URLs are present

If a contact's `urlAddresses` contains more than one `guesswho://contact/…` entry (which happens when two devices independently assigned a UUID before iCloud merged them):

1. **Pick a winner.** Sort the candidate UUIDs as strings (ASCII lexicographic) and pick the first. Deterministic across devices — every device reaches the same conclusion from the same merged contact.
2. **Merge sidecars.** For each losing UUID, merge its sidecar into the winning UUID's sidecar with LWW semantics (see §5.3), then delete the loser sidecar file.
3. **Rewrite the contact.** Remove the losing URLs from `urlAddresses` and save.

This converges: once every device has reconciled the same contact, every device's `urlAddresses` contains exactly one GuessWho URL, and that UUID points at one merged sidecar.

## 4. Storage Boundary

| Data lives where? | Examples |
|---|---|
| **Contacts store (canonical, writable)** | Name, phone, email, postal address, birthday, organization, `urlAddresses` (including our GuessWho URL) |
| **EventKit (canonical, read-only)** | Calendar events, attendees, location, recurrence — read but never written by this package |
| **Sidecar (writable)** | GuessWho-specific fields with no Contacts/EventKit home. v1 ships with the storage primitive and an empty schema; the host app defines the field set. |

The package does **not** define what business fields go in the sidecar. It defines the *envelope* and the merge semantics; the caller passes opaque field data.

## 5. Sidecar Format

### 5.1 Filesystem layout

The package is given a **root `URL`** at init. The host decides whether that root is in a ubiquity container, a Documents folder, or a temp directory (tests use the last). Layout:

```
<root>/
  contacts/
    <uuid>.json
  events/
    <eventExternalID>.json
```

One file per entity. This matters because `NSFileVersion` reports conflicts per-file — keeping contacts in separate files means a conflict on contact A never blocks contact B.

### 5.2 File schema

```json
{
  "schemaVersion": 1,
  "kind": "contact",                          // or "event"
  "entityID": "<uuid or external id>",
  "modifiedAt": "2026-06-14T22:00:00.000Z",   // = max of any field's modifiedAt
  "modifiedBy": "<deviceID>",                 // device that wrote the most-recent field
  "fields": {
    "nickname": {
      "value": "Bear",
      "modifiedAt": "2026-06-14T20:15:00.000Z",
      "modifiedBy": "device-A"
    },
    "notes": {
      "value": "Met at WWDC",
      "modifiedAt": "2026-06-14T22:00:00.000Z",
      "modifiedBy": "device-B"
    },
    "petName": {
      "deleted": true,
      "modifiedAt": "2026-06-13T10:00:00.000Z",
      "modifiedBy": "device-A"
    }
  }
}
```

- `schemaVersion` — bumped on breaking envelope changes; readers reject unknown versions rather than guessing.
- `kind` + `entityID` — self-describes which entity it belongs to (defense against accidental moves).
- Envelope-level `modifiedAt` / `modifiedBy` — derived from the fields. Equals `max((field.modifiedAt, field.modifiedBy))` across all fields. Used as a fast comparison key without parsing the whole `fields` map.
- Each field is either a value cell `{value, modifiedAt, modifiedBy}` or a tombstone `{deleted: true, modifiedAt, modifiedBy}`. Field deletion writes a tombstone rather than removing the key, so a stale "I still have this value" write from another device can't resurrect it.

### 5.3 LWW rule (v1: per-field)

When two envelopes for the same entity must be merged, the merged envelope's `fields` map is computed by:

```
for each field name in (a.fields ∪ b.fields):
    pick the entry whose (modifiedAt, modifiedBy) tuple is lexicographically larger
    (ISO8601 timestamp first, deviceID as tiebreak)
```

If the winning entry for a field is a tombstone, the field stays deleted in the merged envelope (tombstone is kept, not stripped, so it can continue to suppress stale writes from devices that haven't seen the delete).

After merging the `fields` map, the envelope-level `modifiedAt` / `modifiedBy` are recomputed as the max across all surviving entries.

Concurrent edits to *different* fields both survive. Concurrent edits to the *same* field collapse to whichever device's clock was later (with `modifiedBy` as a deterministic tiebreak).

### 5.4 Clock skew is acknowledged, not solved

Device clocks can disagree. A device with a fast clock can "win" LWW for a particular field by virtue of skew. We accept this because:
- The sidecar holds non-critical auxiliary data.
- Canonical data lives in the system stores.
- Per-field granularity already eliminates the bigger failure mode (whole-file clobber of disjoint edits).

The package logs `modifiedBy` on every write so a debugging human can see who wrote what.

### 5.5 Tombstone lifecycle

Tombstones are cheap (one small JSON object per deleted field) and v1 never garbage-collects them. A v2 cleanup pass could remove tombstones older than some threshold (e.g., 90 days) once we're confident no live device is still holding a stale value from before the delete. Deferred — see §10.

## 6. iCloud Conflict Handling

When two devices write the same sidecar concurrently, iCloud presents one as the current version and the others through `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`. Each `NSFileVersion` exposes:

- `url` — readable bytes of that version
- `modificationDate` — wall-clock from the device that wrote it
- `localizedNameOfSavingComputer` — informational
- `persistentIdentifier` — opaque handle

The package's `reconcile()` entry point:

1. Lists conflict versions for each sidecar.
2. Parses each version's bytes as a sidecar envelope.
3. Applies the §5.3 LWW rule using the envelope's `modifiedAt`/`modifiedBy` (not `NSFileVersion.modificationDate` — the envelope is the source of truth and survives copy/move).
4. Writes the winner to the current version, calls `replaceItem(at:options:)` if needed, marks losers `isResolved = true` and `remove()`s them.

The package does **not** install an `NSFilePresenter` in v1. The host app calls `reconcile()` on a schedule it chooses (app launch, foreground, manual). v2 may add presenter wiring.

## 7. Public API Surface

### 7.1 Protocols (the DI seams)

```swift
public protocol ContactStoreProtocol {
    func fetchAll() throws -> [Contact]
    func fetch(localID: String) throws -> Contact?
    func save(_ contact: Contact) throws
    // (focused set; mirrors the slice of CNContactStore we actually use)
}

public protocol EventStoreProtocol {
    func fetchEvents(in: DateInterval) throws -> [Event]
    func fetch(externalID: String) throws -> Event?
    // read-only — no save
}

public protocol SidecarStoreProtocol {
    func read(kind: SidecarKind, id: String) throws -> SidecarEnvelope?
    func write(_ envelope: SidecarEnvelope) throws
    func delete(kind: SidecarKind, id: String) throws
    func reconcile() throws -> ReconcileReport
}
```

`Contact` and `Event` are plain Swift structs the package owns — *not* `CNContact`/`EKEvent` — so the mocks don't need to forge framework types. The real adapter maps `CNContact <-> Contact` and `EKEvent -> Event` at the boundary.

### 7.2 The orchestrator

```swift
public final class GuessWhoSync {
    public init(contacts: ContactStoreProtocol,
                events: EventStoreProtocol,
                sidecars: SidecarStoreProtocol,
                deviceID: String,
                clock: @escaping () -> Date = Date.init)

    // Ensure every contact has exactly one canonical GuessWho URL.
    // Performs the §3.5 reconciliation.
    public func reconcileContactIdentities() throws -> IdentityReconcileReport

    // Resolve iCloud sidecar conflicts (§6).
    public func reconcileSidecars() throws -> ReconcileReport

    // Look up the sidecar for a given contact/event by its canonical key.
    public func sidecar(for contact: Contact) throws -> SidecarEnvelope?
    public func sidecar(for event: Event) throws -> SidecarEnvelope?

    // Set one field on a contact's or event's sidecar. Stamps the current clock and deviceID.
    public func setField(_ name: String, value: JSONValue, for contact: Contact) throws
    public func setField(_ name: String, value: JSONValue, for event: Event) throws

    // Delete a field — writes a tombstone rather than removing the key.
    public func deleteField(_ name: String, for contact: Contact) throws
    public func deleteField(_ name: String, for event: Event) throws
}
```

`clock` is injected so tests can drive time deterministically.

### 7.3 Mocks

`InMemoryContactStore` and `InMemoryEventStore` ship in a test-support module. They are full implementations of the protocols backed by `[String: Contact]` / `[String: Event]` dictionaries. The same orchestrator code runs against mocks in tests and against real `CNContactStore`/`EKEventStore` adapters in production.

`InMemorySidecarStore` and `FileSystemSidecarStore` both implement `SidecarStoreProtocol`. The in-memory one is the fast path for unit tests; the filesystem one is used for integration tests and production (pointed at a ubiquity container or a temp dir).

## 8. Module / Platform Decisions

- **Package name:** `GuessWhoSync`
- **Modules:**
  - `GuessWhoSync` — protocols, models, orchestrator, file-system sidecar store, real Contacts/EventKit adapters
  - `GuessWhoSyncTesting` — in-memory mocks, test helpers, time-control utilities. Importable by host apps for their own tests.
- **Platforms:** iOS 17+, macOS 14+. Catalyst inherits from iOS. (Aligns with what GuessWho itself targets; can lower later if needed.)
- **No external dependencies.** Foundation, Contacts, EventKit only.

## 9. Test Matrix

### 9.1 Contact field edits (via mock)
- create / read / update / delete name, phone, email, postal address, birthday
- adding/removing URLs preserves GuessWho URL
- saving a contact roundtrips unchanged

### 9.2 Sidecar edits (in-memory and filesystem stores)
- write then read returns the same envelope
- overwriting bumps `modifiedAt` and sets `modifiedBy` to the configured device ID
- delete removes the file (and removes nothing else)
- read of a missing entity returns nil, not throws

### 9.3 GuessWho URL assignment
- a contact with no GuessWho URL gets one on first reconcile
- a contact with one GuessWho URL is untouched
- a contact with two GuessWho URLs: ASCII-lexicographically-smaller UUID wins; loser URL removed; sidecars merged
- a contact with three or more GuessWho URLs reconciles to the smallest, merging all loser sidecars
- a contact whose only GuessWho URL is malformed (not a valid UUID) is treated as missing and reassigned

### 9.4 Sidecar LWW conflict resolution (per-field)
- two envelopes editing disjoint fields: merged envelope contains the union, each field keeps its own timestamps
- two envelopes editing the same field at different times: later `modifiedAt` wins
- tie on a field's `modifiedAt`: lexicographically larger `modifiedBy` wins
- envelope-level `modifiedAt` / `modifiedBy` after merge equal the max across all surviving field entries
- tombstone vs. value on the same field: whichever has the later `modifiedAt` wins; if the tombstone wins, the field stays deleted and the tombstone survives the merge
- two tombstones for the same field: later tombstone is kept
- value-then-tombstone on one device merged with a stale value-only on another: tombstone wins iff its `modifiedAt` is later (expected behavior)
- entity with no conflicts is untouched
- envelope with unknown `schemaVersion` is left alone and reported in the reconcile report (no destructive write)
- merging an envelope with itself is a no-op (idempotence)
- merge is commutative: `merge(a, b)` equals `merge(b, a)` for any pair

### 9.5 Combined identity + sidecar reconciliation
- two devices independently assign UUIDs A and B, each with a populated sidecar; after reconcile the contact has one URL (oldest), one sidecar at that UUID, containing the LWW merge of A and B's `fields`
- repeated reconcile is idempotent (no churn on a stable state)

### 9.6 Event sidecar
- event lookup by `calendarItemExternalIdentifier` works
- writing a sidecar for an event does not mutate the event itself in the mock
- reading an event with no sidecar returns nil
- LWW rules apply identically to event sidecars

### 9.7 Filesystem sidecar store (integration)
- run §9.2 against `FileSystemSidecarStore` pointed at a `tmpDir`
- conflict resolution: inject two files with the same name into a synthetic "conflict" state (using `NSFileVersion.add(of:withContentsOf:)` if practical, or by simulating the conflict-version array via a protocol seam — see §10)

## 10. Open Questions Deliberately Deferred

These are recorded so we don't re-discover them later. None block v1.

1. **`NSFileVersion` in tests.** Real iCloud conflicts are hard to fabricate in unit tests. Plan: hide `NSFileVersion` behind a small protocol (`FileVersionListing`) so the conflict-resolution algorithm is testable with fakes. The filesystem store uses the real `NSFileVersion` implementation; tests use a fake that returns scripted conflict versions. To revisit during implementation.
2. **Background sync.** v1 requires the host to call `reconcile…()` explicitly. v2 may register an `NSFilePresenter` and expose a stream of "sidecar changed" events.
3. **Tombstone garbage collection.** Tombstones live forever in v1. A v2 pass could remove tombstones older than a threshold (e.g., 90 days) once we're confident no live device is holding a pre-delete value. Deferred.
4. **Non-iCloud Contacts sources.** Documented out of scope. May need a filter at the boundary in v2 (e.g., skip contacts whose `containerIdentifier` isn't iCloud).
5. **Migration of `schemaVersion`.** v1 envelopes are v1. Writing a forward-compat migration is deferred until we ship a v2 schema.
6. **Concurrent writers within a single device.** The filesystem store assumes single-process access; cross-process coordination on a phone is uncommon but possible (e.g., Share Extension). Deferred.

## 11. Implementation Order

1. Models (`Contact`, `Event`, `SidecarEnvelope`, `JSONValue`) and protocols.
2. `InMemoryContactStore`, `InMemoryEventStore`, `InMemorySidecarStore` with full test coverage of §9.1–9.4 against the mocks.
3. Identity reconciler + sidecar merge logic + tests for §9.5–9.6.
4. `FileSystemSidecarStore` + integration tests for §9.7.
5. Real `CNContactStore` / `EKEventStore` adapters. Smoke-tested against a development device; not unit-tested.
6. Documentation pass.
