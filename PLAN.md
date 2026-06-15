# GuessWhoSync — Plan

A Swift package that treats the system Contacts store and EventKit as the canonical data sources, and uses iCloud-synced JSON sidecar files only for fields that don't fit there.

This document is the spec.

---

## 1. Goals

1. **Canonical data in Contacts.** Anything the Contacts framework can represent is stored there.
2. **Canonical data in EventKit.** Anything the EventKit framework can represent is stored there.
3. **Sidecars for the rest.** GuessWho-specific fields live in per-entity JSON files synced through an iCloud folder.
4. **Stable cross-device identity.** Every contact GuessWhoSync touches gets a stable UUID, embedded as a `guesswho://contact/<uuid>` URL in `urlAddresses`. The UUID is the same on every device after sync converges.
5. **Deterministic conflict resolution.** When multiple devices independently assigned a UUID to the same contact, every device picks the same winner without coordination.
6. **Per-field LWW sidecars.** Concurrent edits to *different* fields both survive. Concurrent edits to the *same* field collapse via Last-Writer-Wins.
7. **Test-first.** All semantics are exercised by unit tests against in-memory mocks that satisfy the same protocols as the real stores.

## 2. Non-goals (v1)

- Writing to EventKit events. Events are **read-only**; only their sidecars are mutable.
- Background sync (`NSFilePresenter` wiring). The host calls `reconcile…()` explicitly.
- Tombstone garbage collection.
- Non-iCloud Contacts sources (Exchange, Google CardDAV). v1 makes no guarantees; behavior is "best effort, may drift."
- Cross-iCloud-account sync. Single user, single iCloud account.

## 3. Identity

### 3.1 Why we need our own UUID

`CNContact.identifier` is **device-local**. The same logical contact has a different `identifier` on each device after iCloud sync. We cannot use it as a stable cross-device key.

EventKit is different: `EKEvent.calendarItemExternalIdentifier` is documented as stable across the same iCloud account, so events use it directly without a GuessWho-assigned UUID.

### 3.2 The GuessWho URL

For every contact GuessWhoSync touches, we add an entry to `CNContact.urlAddresses`:

- **label:** `"GuessWho"` (custom; displays as "guesswho" in the system Contacts UI)
- **value:** `guesswho://contact/<uuid>` — no query parameters

The URL is the only field we add to the contact. It syncs via CardDAV without loss and is visible in the system Contacts app. No timestamp in the URL — UUID-alphabetical reconciliation (§3.3) gives convergence without depending on clocks.

### 3.3 Reconciliation rules

When the package reconciles a contact's identity, it inspects every `urlAddresses` entry whose value starts with `guesswho://contact/` and applies the following rules.

**Candidate extraction.**
- A *valid* candidate has the form `guesswho://contact/<uuid>` where `<uuid>` is a parseable UUID v4 string. Any other shape is *malformed*.

**Case A — no valid candidate (none present, or only malformed entries):**
1. Remove all malformed `guesswho://contact/…` URLs.
2. Assign a fresh UUID, append `guesswho://contact/<new>` to `urlAddresses`, save the contact. (Any sidecar that happens to share the malformed text is left untouched and will appear as an orphan in §3.4.)

**Case B — exactly one valid candidate, no malformed siblings:**
- Untouched.

**Case C — exactly one valid candidate plus one or more malformed siblings:**
- Keep the valid one. Remove the malformed entries. Save.

**Case D — N valid candidates (N ≥ 2), with or without malformed siblings:**
1. Sort the valid UUIDs as ASCII strings; the smallest is the **winner**.
2. Build the merge target: start with the winner's existing sidecar if present, otherwise an empty envelope with `entityID = winner UUID` and `fields = [:]`. For each *loser* UUID with an existing sidecar, rebase that sidecar onto the winner UUID (copy of the loser envelope with `entityID` set to the winner UUID; `fields` unchanged), then set `merged = merge(merged, rebased)` per §5.3. Write `merged` at the winner UUID. Delete each loser sidecar file.
3. Remove every losing `guesswho://contact/…` URL and every malformed `guesswho://contact/…` URL from `urlAddresses`. Keep the winner.
4. Save the contact.

(The rebase step is the only place the package deliberately changes a sidecar's `entityID`. It's safe because identity reconciliation owns both the URLs and the sidecar IDs; no other caller observes the loser sidecar after this step.)

Convergence: once every device has reconciled the same merged contact, every device's `urlAddresses` contains exactly one GuessWho URL pointing at one merged sidecar.

### 3.4 Orphan sidecars

A sidecar file is *orphan* if no contact carries its UUID in `urlAddresses` after a full identity reconcile pass.

**v1 policy:** orphan sidecars are **kept**, not deleted. The canonical case is a user deleting a contact on one device while another device writes to the same sidecar. A second, equally common case is **transient orphans during in-flight CardDAV sync**: device X reconciles before the contact carrying the matching `guesswho://` URL has arrived. Both cases look identical to the algorithm, so the rule is conservative.

Orphans surface in `IdentityReconcileReport.orphanSidecars`. **Host UIs MUST NOT auto-delete from this list** — orphans may be transient. Only act on explicit user input.

A v2 policy could auto-GC orphans older than a threshold (long enough for any reasonable sync to complete). Deferred — see §10.

## 4. Storage Boundary

| Data lives where? | Examples |
|---|---|
| **Contacts store (canonical, writable)** | Name, phone, email, postal address, birthday, organization, `urlAddresses` (including our GuessWho URL) |
| **EventKit (canonical, read-only)** | Calendar events, attendees, location, recurrence — read but never written by this package |
| **Sidecar (writable)** | GuessWho-specific fields with no Contacts/EventKit home. v1 ships the storage primitive; callers define the field set. |

## 5. Sidecar Format

### 5.1 Filesystem layout

The package takes a **root `URL`** at init. The host decides whether that root is in a ubiquity container, a Documents folder, or a temp directory (tests use the last). Layout:

```
<root>/
  contacts/<uuid>.json
  events/<eventExternalID-safe>.json
```

One file per entity. `NSFileVersion` reports conflicts per-file, so a conflict on contact A never blocks contact B.

**Filename safety.** Contact UUIDs are lowercase hex + dashes, safe as-is. Event external identifiers are opaque strings that may contain `/`, `:`, or other characters illegal in filenames. The package percent-encodes every character outside `[A-Za-z0-9._-]` before using them as filenames; the inverse transform is applied on read. iCloud Drive volumes are case-**insensitive** by default, so two `calendarItemExternalIdentifier`s differing only in ASCII case would collide. v1 assumes this does not happen in practice for iCloud-source calendars (where the external ID is a UUID); the assumption is documented and will be revisited if violated. The stored `entityID` field inside the envelope is always the original (untransformed) string.

### 5.2 File schema

```json
{
  "schemaVersion": 1,
  "entityID": "<contact UUID or event externalID, untransformed>",
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

**`schemaVersion`** — bumped on breaking envelope changes; readers refuse to merge or write unknown versions (see §6).

**`entityID`** — the canonical UUID string (contacts) or the raw `calendarItemExternalIdentifier` (events). No `guesswho://` prefix. The directory the file lives in (`contacts/` vs `events/`) disambiguates kind; there is no `kind` field.

**`fields`** — map of field name to *cell*. Each cell is either a **value cell** or a **tombstone cell**:
- Value cell: `{ "value": <JSONValue>, "modifiedAt": <ISO8601 UTC>, "modifiedBy": <string> }`
- Tombstone cell: `{ "deleted": true, "modifiedAt": <ISO8601 UTC>, "modifiedBy": <string> }`

Exactly one of `value` and `deleted` must be present. Both is invalid; the cell is treated as malformed.

`<JSONValue>` is any JSON value: `null`, `bool`, `number`, `string`, `array<JSONValue>`, `object<string, JSONValue>`. The package treats it opaquely.

### 5.3 Per-field LWW merge

To merge two envelopes `a` and `b` for the same entity:

```
merged.entityID      = a.entityID  // must equal b.entityID; else fail
merged.schemaVersion = 1
merged.fields[k] for each k in (a.fields ∪ b.fields):
    if only a has k: use a.fields[k]
    if only b has k: use b.fields[k]
    if both have k:  use the cell with larger (modifiedAt, modifiedBy)
                     (ISO8601 lexicographic, then string lexicographic)
```

A tombstone is a valid cell. Tombstones survive merges; they are not stripped, so a tombstone keeps suppressing a stale value-write from a device that hasn't seen the delete yet.

**Properties.** This merge is **commutative** (`merge(a, b) == merge(b, a)`) and **associative** (`merge(merge(a, b), c) == merge(a, merge(b, c))`). Both are required for convergence when ≥3 devices merge in different orders. §9 asserts both.

**Malformed input handling.**

| Condition | Behavior |
|---|---|
| `modifiedAt` not ISO8601 | The cell is malformed → treated as absent. The other side's cell wins (or the field is absent from the merge if both sides are malformed). |
| Cell has neither `value` nor `deleted` | Malformed → treated as absent. |
| Cell has both `value` and `deleted` | Malformed → treated as absent. |
| `entityID` mismatch between `a` and `b` | Merge fails; reported in `ReconcileReport`. No write. |
| `schemaVersion` ≠ 1 on either side | Merge refuses. The non-v1 envelope is left intact. Reported. |

Malformed cells from a single side propagate as absent into the merge result; the merge does not preserve the malformed cell.

### 5.4 Clock skew is acknowledged, not solved

Device clocks can disagree. A device with a fast clock can "win" LWW for a field. We accept this because the sidecar holds non-critical data and per-field granularity already removes the bigger failure mode (whole-file clobber of disjoint edits). The package logs `modifiedBy` on every write.

### 5.5 Tombstone lifecycle

Tombstones live forever in v1. GC is deferred (§10).

## 6. iCloud Conflict Handling

When iCloud presents multiple versions of the same sidecar (current + `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`), the package's `reconcileSidecars()`:

1. **Collect.** For each conflicted file: gather the bytes of the current version and each conflict version.
2. **Parse.** Decode each version into an envelope. A version whose bytes fail to parse, or whose `schemaVersion` ≠ 1, is **skipped** — not used in the merge and not deleted. It is reported in `SidecarReconcileReport` so a human can investigate. (Skipping is conservative: never silently destroy data we can't read.)
3. **N-way fold.** Fold every parseable v1 envelope (current + conflict versions) with §5.3 merge from left to right. Because merge is associative, the fold order does not matter. If only one parseable envelope survives, that *is* the result.
4. **Write back.**
   - If the *current* version was parseable: overwrite it with the merged envelope. Mark each non-skipped conflict version `isResolved = true` and `remove()` it. Leave skipped versions in conflict.
   - If the *current* version was unparseable but at least one conflict version parsed: write the merge to a sibling file `<originalName>.recovered.<timestamp>.json` and report it. Leave the original current and all conflict versions intact (the human must triage). This prevents silent data destruction.
   - If **no** version parsed: leave everything in conflict, report all skipped versions.
5. **No conflict** on a file is a no-op.

**Deletion is not a conflict.** `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` never returns a "deletion version" — versions always have bytes. A delete done on another device reaches this device as a file removal handled outside this API (orphan policy §3.4; future `NSFilePresenter` wiring §10).

## 7. Public API Surface

### 7.1 Models

The package owns its own plain-Swift models — not `CNContact`/`EKEvent` — so mocks don't have to forge framework types. Adapters convert at the boundary.

`Contact` and `Event` are plain-Swift mirrors of the §4 canonical field families. The two fields the identity reconciler depends on are spelled out; the rest are finalized during implementation as callers ask for them.

```swift
public struct Contact: Hashable, Sendable {
    public var localID: String                       // device-local CNContact.identifier
    public var urlAddresses: [LabeledValue]          // includes the GuessWho URL when assigned
    public var postalAddresses: [LabeledPostalAddress] // structured, component-for-component (see below)
    // plus name, phone, email, birthday, organization — see §4
}

public struct Event: Hashable, Sendable {
    public var externalID: String               // calendarItemExternalIdentifier
    // plus title, dates, location, notes — see §4
}

public struct LabeledValue: Hashable, Sendable {
    public var label: String                    // e.g. "home", "work", "GuessWho"
    public var value: String
}

// Postal addresses are structured, not a single-line string, so callers can
// edit components (street/city/zip/…) independently and round-trip them
// losslessly through CNPostalAddress.
public struct PostalAddress: Hashable, Sendable, Codable {
    public var street: String
    public var subLocality: String
    public var city: String
    public var subAdministrativeArea: String
    public var state: String
    public var postalCode: String
    public var country: String
    public var isoCountryCode: String
}

public struct LabeledPostalAddress: Hashable, Sendable, Codable {
    public var label: String                    // e.g. "home", "work"
    public var value: PostalAddress
}

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum SidecarKind: String, Sendable { case contact, event }

public struct SidecarKey: Hashable, Sendable {
    public let kind: SidecarKind
    public let id: String                       // contact UUID or event externalID
}

public struct SidecarEnvelope: Sendable {
    public let entityID: String
    public let fields: [String: SidecarCell]
}

public enum SidecarCell: Sendable {
    case value(JSONValue, modifiedAt: Date, modifiedBy: String)
    case tombstone(modifiedAt: Date, modifiedBy: String)
}
```

### 7.2 Protocols

```swift
public protocol ContactStoreProtocol {
    func fetchAll() throws -> [Contact]
    func fetch(localID: String) throws -> Contact?
    func save(_ contact: Contact) throws
}

public protocol EventStoreProtocol {
    func fetchEvents(in: DateInterval) throws -> [Event]
    func fetch(externalID: String) throws -> Event?
    // No save: events are read-only.
}

public protocol SidecarStoreProtocol {
    func read(_ key: SidecarKey) throws -> SidecarEnvelope?
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws
    func delete(_ key: SidecarKey) throws
    func allKeys() throws -> [SidecarKey]

    /// Walks every conflicted file. For each, the store hands the caller all
    /// version bytes; the caller returns one of three resolutions per file.
    /// The store applies the resolution against `NSFileVersion`, leaving
    /// `NSFileVersion` semantics hidden inside the implementation.
    func reconcileConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome]
}

public enum ConflictResolution: Sendable {
    /// Write `merged` as current; mark every conflict version isResolved=true,
    /// remove(). Versions whose bytes appear in `skip` are left in conflict.
    /// Matching is byte-equality on the version bytes; if two conflict versions
    /// are byte-identical, they are treated as the same outcome (all matching
    /// versions skipped together, or all marked resolved together).
    case write(merged: SidecarEnvelope, skip: [Data])
    /// Write `merged` to a sibling file; leave original current and all
    /// conflict versions intact. Used when current is unparseable (§6).
    case writeRecoverySibling(merged: SidecarEnvelope, suffix: String)
    /// Leave everything in conflict.
    case leave
}
```

The orchestrator (§7.3) calls `reconcileConflicts` and supplies the merge logic via the closure. The store owns the `NSFileVersion` calls; the closure owns the policy (§6).

**Closure error handling.** If `resolve` throws for a given file, the store records a failure outcome for that file (`mergedVersionCount = 0`, `skippedReasons` containing the thrown error description) and continues with the next file. `reconcileConflicts` itself never throws on a single-file failure; it only throws on store-level IO errors (e.g., can't enumerate the directory).

### 7.3 Orchestrator

```swift
public final class GuessWhoSync {
    public init(contacts: ContactStoreProtocol,
                events: EventStoreProtocol,
                sidecars: SidecarStoreProtocol,
                deviceID: String)

    // Identity reconciliation (§3.3). Idempotent.
    public func reconcileContactIdentities() throws -> IdentityReconcileReport

    // iCloud conflict resolution for sidecars (§6). Idempotent.
    public func reconcileSidecars() throws -> SidecarReconcileReport

    // Read.
    public func sidecar(at key: SidecarKey) throws -> SidecarEnvelope?

    // Write a single field. Read-modify-write on the current envelope.
    public func setField(_ name: String, value: JSONValue, at key: SidecarKey) throws

    // Delete a single field — writes a tombstone, does not remove the key.
    public func deleteField(_ name: String, at key: SidecarKey) throws
}

public struct IdentityReconcileReport: Sendable {
    public struct ContactOutcome: Sendable {
        public let localID: String
        public let assignedUUID: String?              // newly assigned, if any
        public let mergedLoserUUIDs: [String]         // sidecars merged into the winner
        public let removedMalformedURLs: [String]
        public let errors: [String]
    }
    public let contactOutcomes: [ContactOutcome]
    public let orphanSidecars: [SidecarKey]            // present but no contact carries the UUID
}

public struct SidecarReconcileReport: Sendable {
    public struct FileOutcome: Sendable {
        public let key: SidecarKey
        public let mergedVersionCount: Int
        public let skippedReasons: [String]            // bad JSON, unknown schemaVersion, etc.
    }
    public let fileOutcomes: [FileOutcome]
}
```

**`setField` semantics.** Read the current envelope (or start with an empty one), set or replace the named cell with a fresh `(value, now, deviceID)`, write the whole envelope back. Single-process; the file-system store serializes writes per file (a brief in-memory lock keyed by `SidecarKey`). Cross-process concurrency on the same device is out of scope (§10).

**Identity is the caller's responsibility.** `SidecarKey` requires an ID, so writing to a contact's sidecar presumes the contact already has a GuessWho UUID. Callers must run `reconcileContactIdentities()` first (e.g., at app launch) to ensure every contact has a UUID; the resulting `IdentityReconcileReport.contactOutcomes` exposes the assigned UUID per contact.

**Deriving a `SidecarKey` from a `Contact`.** Find the `LabeledValue` in `urlAddresses` whose `value` starts with `guesswho://contact/`, parse the suffix as a UUID, and build `SidecarKey(kind: .contact, id: uuid)`. After `reconcileContactIdentities()` returns, exactly one such URL is present per touched contact. The package exposes this as a static helper on `SidecarKey`:

```swift
extension SidecarKey {
    public static func forContact(_ contact: Contact) -> SidecarKey?
    public static func forEvent(_ event: Event) -> SidecarKey
}
```

`forContact` returns nil if no GuessWho URL is present (caller forgot to reconcile, or contact is brand-new). `forEvent` is total because the event's `externalID` is the canonical key.

### 7.4 Mocks

`InMemoryContactStore`, `InMemoryEventStore`, `InMemorySidecarStore` ship in a `GuessWhoSyncTesting` module. Each is a full implementation backed by a dictionary. The orchestrator runs unchanged against mocks (unit tests) and the real adapters (production).

`FileSystemSidecarStore` is the real `SidecarStoreProtocol` implementation, wrapping a directory `URL` plus `NSFileVersion`.

## 8. Modules / Platforms

- **Package name:** `GuessWhoSync`
- **Modules:**
  - `GuessWhoSync` — protocols, models, orchestrator, `FileSystemSidecarStore`, real Contacts/EventKit adapters
  - `GuessWhoSyncTesting` — in-memory mocks. Importable by host apps' tests too.
- **Platforms:** iOS 17+, macOS 14+. Catalyst inherits from iOS.
- **No external dependencies.** Foundation, Contacts, EventKit only.

## 9. Test Matrix

### 9.1 Contact field edits (mocks)
- create / read / update / delete name, phone, email, postal address, birthday, organization
- adding/removing URLs preserves the GuessWho URL when present
- save→fetch roundtrip is identity

### 9.2 Sidecar IO (in-memory and filesystem)
- write then read returns the same envelope
- overwriting a field stamps `modifiedAt = now()` and `modifiedBy = deviceID`
- delete writes a tombstone, not a key removal
- read of a missing key returns nil
- filename encoding: an event with an externalID containing `/` round-trips through write→read

### 9.3 Identity reconciliation (§3.3)
- Case A (no valid candidate): UUID assigned, URL appended
- Case A with malformed URLs that happen to name existing sidecars: malformed URLs removed, fresh UUID assigned, those sidecars become orphans
- Case B (one valid, no malformed): no-op
- Case C (one valid + malformed siblings): malformed removed, valid kept
- Case D, two valid candidates: lex-smallest wins; loser URL removed; loser sidecar merged
- Case D, two valid candidates, both UUIDs already have sidecars with overlapping and disjoint fields: winner UUID ends up with the per-field LWW merge of both; loser file deleted
- Case D, three valid candidates: still lex-smallest of all three wins; both losers merged into it
- repeated reconcile on a stable contact is a no-op (idempotence)

### 9.4 Per-field LWW merge (§5.3)
- disjoint fields: both survive
- same field, different times: later wins
- same field, same `modifiedAt`: lex-larger `modifiedBy` wins
- tombstone vs. live value: later `modifiedAt` wins; tombstone, if it wins, survives the merge
- **associativity:** for three envelopes `a`, `b`, `c`: `merge(merge(a, b), c)` equals `merge(a, merge(b, c))`
- malformed `modifiedAt` on a cell: cell treated as absent; other side wins
- both `value` and `deleted` set: cell treated as absent
- entityID mismatch: merge fails with an error
- schemaVersion ≠ 1 on either side: merge refuses; neither envelope is written

### 9.5 Sidecar reconciliation under conflict (§6)
- two conflict versions, both parseable v1: merged result written, both losers `remove()`d
- three conflict versions: N-way fold produces the right merged envelope
- one conflict version has unparseable bytes: it is skipped (left in conflict, reported); the others merge normally
- one conflict version has `schemaVersion = 99`: same — skipped, reported, left intact
- *current* version is unparseable, one conflict version is valid: merged result written to `<name>.recovered.<timestamp>.json`; original current and all conflict versions left intact
- no version parses: every version left in conflict, all reported, nothing written

### 9.6 Combined identity + sidecar
- two devices independently assign UUIDs A and B to the same contact, each with a populated sidecar; after `reconcileContactIdentities()` the contact has exactly one GuessWho URL (lex-smaller of A and B), one sidecar at that UUID, containing the per-field merge of A's and B's fields
- contact deleted on device X while device Y writes a sidecar for its UUID: after reconcile on device X (which sees the deletion), the sidecar appears in `IdentityReconcileReport.orphanSidecars` and is **not** deleted

### 9.7 Event sidecars
- event lookup by `externalID` works
- writing a sidecar for an event does not mutate the event in the mock
- per-field LWW rules apply identically to event sidecars

## 10. Open Questions Deliberately Deferred

1. **`NSFileVersion` in tests.** Hard to fabricate real iCloud conflicts in unit tests. Plan: hide `NSFileVersion` behind `SidecarStoreProtocol.reconcileConflict(at:resolve:)` (§7.2). The in-memory store ships a scripted-conflict mode (the test injects `[(SidecarKey, [Data])]`); the file-system store uses real `NSFileVersion`.
2. **Background sync.** v1 requires the host to call `reconcile…()` explicitly. v2 may register an `NSFilePresenter`.
3. **Tombstone GC.** Tombstones live forever in v1.
4. **Orphan-sidecar auto-GC.** v1 keeps orphans. v2 may add a policy.

## 11. Implementation Order

Each phase ends with passing tests for the listed sections.

1. **Models + protocols.** §7.1, §7.2 type declarations. No logic. (No tests yet.)
2. **In-memory stores.** `InMemoryContactStore`, `InMemoryEventStore`, `InMemorySidecarStore`. Tests: §9.1, §9.2 (in-memory rows only).
3. **Per-field LWW merge function.** A pure function `merge(_ a: SidecarEnvelope, _ b: SidecarEnvelope) -> Result<SidecarEnvelope, MergeError>`. Tests: §9.4.
4. **Identity reconciler.** `GuessWhoSync.reconcileContactIdentities()` against in-memory stores. Tests: §9.3, §9.6.
5. **Sidecar conflict reconciler.** `GuessWhoSync.reconcileSidecars()` against in-memory stores with a scripted-conflict mode. Tests: §9.5.
6. **Event sidecars.** Tests: §9.7.
7. **`FileSystemSidecarStore`.** Tests: §9.2 (filesystem rows), real-conflict integration tests using `NSFileVersion.add(of:withContentsOf:)`.
8. **Real `CNContactStore` / `EKEventStore` adapters.** Smoke-tested on device; not unit-tested.
