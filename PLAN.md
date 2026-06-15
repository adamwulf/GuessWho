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

**Per-contact reconcile.** Hosts that want explicit per-contact control (a "Reconcile this contact" button on a detail page) call `reconcileContactIdentity(localID:)` (§7.3) instead of the all-contacts sweep. The per-contact entry point runs the same Case A/B/C/D logic above for one localID and returns the same `ContactOutcome`. It intentionally does **not** populate `orphanSidecars` — orphan detection requires the global set of carried UUIDs across every contact (§3.4), which a per-contact call cannot see.

Convergence: once every device has reconciled the same merged contact, every device's `urlAddresses` contains exactly one GuessWho URL pointing at one merged sidecar.

### 3.4 Orphan sidecars

A sidecar file is *orphan* if no contact carries its UUID in `urlAddresses` after a full identity reconcile pass.

**v1 policy:** orphan sidecars are **kept**, not deleted. The canonical case is a user deleting a contact on one device while another device writes to the same sidecar. A second, equally common case is **transient orphans during in-flight CardDAV sync**: device X reconciles before the contact carrying the matching `guesswho://` URL has arrived. Both cases look identical to the algorithm, so the rule is conservative.

Orphans surface in `IdentityReconcileReport.orphanSidecars`. **Host UIs MUST NOT auto-delete from this list** — orphans may be transient. Only act on explicit user input.

A v2 policy could auto-GC orphans older than a threshold (long enough for any reasonable sync to complete). Deferred — see §10.

## 4. Storage Boundary

| Data lives where? | Examples |
|---|---|
| **Contacts store (canonical, writable)** | Every `CNContact` field the framework exposes except `note` (gated by `com.apple.developer.contacts.notes` entitlement; deferred until we obtain it). Specifically: `identifier` (carried as `Contact.localID` for store reads/writes); `contactType`; the full name family (`namePrefix`, `givenName`, `middleName`, `familyName`, `previousFamilyName`, `nameSuffix`, `nickname`, plus phonetic given/middle/family); the full work family (`jobTitle`, `departmentName`, `organizationName`, `phoneticOrganizationName`); `phoneNumbers`, `emailAddresses`, `postalAddresses`, `urlAddresses` (including our GuessWho URL); `birthday`, `nonGregorianBirthday`, and labeled `dates` (anniversary, custom); `socialProfiles`; `instantMessageAddresses`; `contactRelations`; `imageDataAvailable` (raw `imageData`/`thumbnailImageData` are loaded on demand, not carried on `Contact`). |
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

`Contact` is a faithful mirror of `CNContact`: every property the framework exposes is represented, **except `note`**, which Apple gates behind the `com.apple.developer.contacts.notes` entitlement (deferred until the app has it). `Event` is a plain-Swift mirror of the §4 canonical event fields.

**Codable.** Every model type below conforms to `Codable` so the value graph composes for sidecar emission, on-disk caching, and test fixtures (a `Contact` snapshot may be embedded inside a sidecar field as a `JSONValue.object`). The sidecar types (`SidecarEnvelope`, `SidecarCell`, `JSONValue`, `SidecarKey`, `SidecarKind`) are the literal payload of the JSON files in §5.2; `JSONValue` and `SidecarCell` use hand-rolled `Codable` because the JSON layout (dynamic value shapes and a present-or-absent `deleted: true` discriminator) does not match the compiler-synthesized form.

```swift
public struct Contact: Hashable, Sendable, Codable {
    public var localID: String                              // device-local CNContact.identifier
    public var contactType: ContactType                     // .person or .organization

    // Names — full CNContact name family
    public var namePrefix: String
    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var previousFamilyName: String
    public var nameSuffix: String
    public var nickname: String
    public var phoneticGivenName: String
    public var phoneticMiddleName: String
    public var phoneticFamilyName: String

    // Work
    public var jobTitle: String
    public var departmentName: String
    public var organizationName: String
    public var phoneticOrganizationName: String

    // Addresses & contact channels
    public var phoneNumbers: [LabeledValue]
    public var emailAddresses: [LabeledValue]
    public var postalAddresses: [LabeledPostalAddress]
    public var urlAddresses: [LabeledValue]                 // includes the GuessWho URL when assigned

    // Dates
    public var birthday: DateComponents?
    public var nonGregorianBirthday: DateComponents?
    public var dates: [LabeledDate]                         // anniversary, custom

    // Social / messaging / relations
    public var socialProfiles: [LabeledSocialProfile]
    public var instantMessageAddresses: [LabeledInstantMessageAddress]
    public var contactRelations: [LabeledContactRelation]

    // Image presence flag only — image bytes are loaded on demand (see below)
    public var imageDataAvailable: Bool
}

public enum ContactType: String, Sendable, Codable {
    case person, organization
}

public struct Event: Hashable, Sendable, Codable {
    public var externalID: String               // calendarItemExternalIdentifier
    // plus title, dates, location, notes — see §4
}

public struct LabeledValue: Hashable, Sendable, Codable {
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

// Parallel labeled wrappers for the structured CNContact arrays. The labeled
// pattern matches LabeledPostalAddress — no generic LabeledValue<T>, so existing
// String-valued LabeledValue consumers don't break.

public struct LabeledDate: Hashable, Sendable, Codable {
    public var label: String                    // e.g. "anniversary", custom
    public var value: DateComponents
}

public struct SocialProfile: Hashable, Sendable, Codable {
    public var urlString: String
    public var username: String
    public var userIdentifier: String
    public var service: String                  // e.g. "Twitter", "Facebook"
}

public struct LabeledSocialProfile: Hashable, Sendable, Codable {
    public var label: String
    public var value: SocialProfile
}

public struct InstantMessageAddress: Hashable, Sendable, Codable {
    public var username: String
    public var service: String                  // e.g. "Skype", "Jabber"
}

public struct LabeledInstantMessageAddress: Hashable, Sendable, Codable {
    public var label: String
    public var value: InstantMessageAddress
}

public struct ContactRelation: Hashable, Sendable, Codable {
    public var name: String                     // CNContactRelation.name
}

public struct LabeledContactRelation: Hashable, Sendable, Codable {
    public var label: String                    // e.g. "mother", "father", custom
    public var value: ContactRelation
}

public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    // Hand-rolled Codable (init(from:)/encode(to:)) — the JSON layout is
    // dynamic so the compiler-synthesized form would not match §5.2.
}

public enum SidecarKind: String, Sendable, Codable { case contact, event }

public struct SidecarKey: Hashable, Sendable, Codable {
    public let kind: SidecarKind
    public let id: String                       // contact UUID or event externalID
}

public struct SidecarEnvelope: Sendable, Codable {
    public let schemaVersion: Int               // §5.2 — must equal 1 on write
    public let entityID: String
    public let fields: [String: SidecarCell]
}

public enum SidecarCell: Sendable, Codable {
    case value(JSONValue, modifiedAt: Date, modifiedBy: String)
    case tombstone(modifiedAt: Date, modifiedBy: String)
    // Hand-rolled Codable — the value/tombstone discriminator in §5.2 is a
    // present-or-absent `deleted: true` flag, not the compiler default.
}
```

### 7.2 Protocols

```swift
public protocol ContactStoreProtocol {
    func fetchAll() throws -> [Contact]
    func fetch(localID: String) throws -> Contact?
    func save(_ contact: Contact) throws

    // Image bytes are loaded on demand so bulk fetches don't pay the cost.
    // Distinguish three outcomes:
    //   • Contact does not exist                → throws ContactStoreError.contactNotFound(localID)
    //   • Contact exists, no image is attached  → returns nil
    //   • Contact exists, image bytes available → returns the bytes
    // The `imageDataAvailable` flag on Contact reflects the store's last-seen
    // truth; it can fall out of sync if another process mutates the contact
    // between fetch and load. In that race, `loadImageData` returns the
    // currently truthful answer (nil if no image now, bytes if newly attached),
    // and a follow-up `fetch(localID:)` corrects `imageDataAvailable`
    // (the bulk `fetchAll()` path is exempt — see §7.4).
    func loadImageData(localID: String) throws -> Data?
    func loadThumbnailImageData(localID: String) throws -> Data?
}

public enum ContactStoreError: Error, Sendable {
    case contactNotFound(localID: String)
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

    // Single-contact identity reconciliation (§3.3). Same per-contact logic
    // as reconcileContactIdentities(), but scoped to one localID. Throws
    // ContactStoreError.contactNotFound if the localID is unknown. Does NOT
    // detect orphan sidecars — that requires the global set of carried UUIDs.
    public func reconcileContactIdentity(localID: String) throws -> IdentityReconcileReport.ContactOutcome

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

**Image data in `InMemoryContactStore`.** Because `Contact` does not carry image bytes, the in-memory store keeps a parallel `[localID: (image: Data?, thumbnail: Data?)]` sideband. It exposes a test-only setter so test fixtures can attach bytes:

```swift
extension InMemoryContactStore {
    public func setImageData(_ image: Data?, thumbnail: Data?, for localID: String)
}
```

`save(_:)` clears the sideband entry **only on a true→false transition** of `imageDataAvailable` — i.e., the previously stored `Contact` for this localID had `imageDataAvailable == true` and the incoming save has it as `false`. A save that arrives with `imageDataAvailable == false` for a contact whose stored flag was already `false` (or for a brand-new contact) does **not** touch the sideband. Without this rule, a routine read/modify/write (`fetch → mutate one field → save`) would wipe bytes the caller never intended to touch, because §7.2 explicitly tolerates the flag lagging the truth. This mirrors the partial-update strategy the real `CNContactStoreAdapter` uses in §10.5 — `save(_:)` only mutates state that the caller has provably changed.

Setting `imageDataAvailable = true` without calling `setImageData(...)` leaves the sideband empty (the "available flag is stale-true" race described in §7.2). Conversely, calling `setImageData(image: someBytes, ...)` while the stored `Contact` carries `imageDataAvailable == false` leaves the stored flag false momentarily — the next call to `fetch(localID:)` auto-corrects `imageDataAvailable` against the sideband's current truth before returning the `Contact`. `fetchAll()` does **not** correct the flag: it is the cheap bulk path and must not peek at image bytes or the sideband (§9.1 `testFetchAllDoesNotTouchImageBytes`); callers who need the corrected flag for a specific contact follow up with `fetch(localID:)` or call `loadImageData(localID:)` and treat the bytes result as the source of truth. (`save(_:)` is *not* required to flip the flag; the in-memory store corrects it on the single-contact read path. The real `CNContactStoreAdapter` is exempt — it has no sideband to peek at — but its flag matches `CNContact.imageDataAvailable` byte-for-byte, which the OS keeps consistent.)

`loadImageData` / `loadThumbnailImageData` honor the §7.2 contract — throw `ContactStoreError.contactNotFound` when the contact is absent; otherwise return the sideband bytes (or nil if no bytes are currently attached), independent of the `imageDataAvailable` flag value at the moment of the call.

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

Each bullet below names one test. The full `Contact` model is exercised — every field carried on `Contact` survives a write/read cycle byte-for-byte, and every structured-array field is exercised with create / read / update / delete.

**Identity URL handling.**
- `testAddingAndRemovingURLsPreservesGuessWhoURL` — adding / removing other `urlAddresses` entries leaves any `guesswho://contact/…` URL intact.

**Scalar round-trips.**
- `testRoundtripContactTypePersonAndOrganization` — both enum cases survive write→fetch.
- `testRoundtripNameFamilyPreservesEveryField` — all ten name fields (`namePrefix`, `givenName`, `middleName`, `familyName`, `previousFamilyName`, `nameSuffix`, `nickname`, plus phonetic given/middle/family) round-trip identically.
- `testRoundtripWorkFamilyPreservesEveryField` — `jobTitle`, `departmentName`, `organizationName`, `phoneticOrganizationName`.

**Date round-trips. `DateComponents` equality alone is not enough — the test must assert the calendar identifier.**
- `testRoundtripBirthdayPreservesCalendarIdentifier` — a Gregorian `birthday` round-trips with `value.calendar?.identifier == .gregorian`.
- `testRoundtripNonGregorianBirthdayPreservesCalendarIdentifier` — a non-Gregorian `nonGregorianBirthday` (e.g., `.hebrew`, `.chinese`) round-trips with its calendar identifier preserved, independently of `birthday`.
- `testRoundtripLabeledDatesPreserveLabelAndCalendarIdentifier` — entries in `dates` round-trip with both label and per-entry calendar identifier preserved (a custom-label `DateComponents` carrying a non-Gregorian calendar must survive).

**Structured-array round-trips + CRUD.** For each array field below, the test exercises create (add an entry), read (fetch matches), update (mutate one entry, fetch matches), and delete (remove an entry, fetch reflects the removal). Round-trip is asserted on every component, not just one.
- `testCRUDPhoneNumbers` — labeled string, label preserved.
- `testCRUDEmailAddresses` — labeled string, label preserved.
- `testCRUDPostalAddresses` — every component of `PostalAddress` (street, subLocality, city, subAdministrativeArea, state, postalCode, country, isoCountryCode) plus label.
- `testCRUDURLAddresses` — labeled string, label preserved, GuessWho URL untouched.
- `testCRUDSocialProfiles` — all four components of `SocialProfile` (`urlString`, `username`, `userIdentifier`, `service`) plus label.
- `testCRUDInstantMessageAddresses` — both components of `InstantMessageAddress` (`username`, `service`) plus label.
- `testCRUDContactRelations` — `ContactRelation.name` plus label.

**Image data — flag + on-demand bytes invariants (§7.2 / §7.4).**
- `testFetchAllDoesNotTouchImageBytes` — `fetchAll()` returns `Contact`s with `imageDataAvailable` populated but does not call into the image sideband (assert via a counting wrapper around the in-memory store).
- `testLoadImageDataReturnsBytesWhenAttached` — after `setImageData(image, thumbnail: nil, for: localID)`, a subsequent `fetch(localID:)` reports `imageDataAvailable == true` and `loadImageData(localID:)` returns the same bytes.
- `testLoadThumbnailDataIsIndependentOfImage` — attaching only a thumbnail leaves `loadImageData` returning nil while `loadThumbnailImageData` returns the bytes.
- `testLoadImageDataReturnsNilWhenNotAvailable` — for a contact with `imageDataAvailable == false`, `loadImageData` returns nil (no throw).
- `testLoadImageDataThrowsContactNotFoundForUnknownLocalID` — looking up an unknown localID throws `ContactStoreError.contactNotFound(localID:)`.
- `testLoadImageDataReturnsNilWhenAvailableFlagIsStaleTrue` — if `imageDataAvailable == true` is persisted but the sideband bytes are absent (race / external mutation), `loadImageData` returns nil and a follow-up `fetch(localID:)` resets `imageDataAvailable` to false. (`fetchAll()` is exempt — it returns the persisted flag unchanged; see `testFetchAllDoesNotTouchImageBytes`.)
- `testLoadImageDataReturnsBytesWhenAvailableFlagIsStaleFalse` — the opposite race: `imageDataAvailable == false` is persisted but the sideband already carries bytes (an external setter ran after the last save). `loadImageData` returns the bytes; a follow-up `fetch(localID:)` updates `imageDataAvailable` to true so the flag re-syncs with the truth. (Again, `fetchAll()` is exempt.)
- `testSaveOnlyClearsSidebandOnTrueToFalseTransition` — saving a `Contact` with `imageDataAvailable = false` when the previously stored `Contact` already had `imageDataAvailable = false` (or no prior contact existed) leaves the sideband untouched; saving with a true→false transition drops the sideband bytes. Together these prevent routine read/modify/write from destroying bytes the caller never touched.

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

### 9.8 Single-contact reconciliation (§3.3, per-contact)
Tests mirror §9.3 through `reconcileContactIdentity(localID:)`:
- Case A scoped to one contact: target gets a fresh UUID; a bystander contact in the same store is untouched (no URL added, no save)
- Case D scoped to one contact: loser sidecars merged into the winner, loser URLs removed from the target only; winner sidecar carries the union of loser fields
- idempotence: a second call on a stable contact returns an outcome with `assignedUUID == nil`, `mergedLoserUUIDs == []`, `errors == []`, and the stored contact is byte-identical
- unknown `localID` throws `ContactStoreError.contactNotFound(localID:)` (no silent no-op)
- unrelated sidecars (for UUIDs not carried by the target) are left in place — single-contact reconcile never sweeps orphans

## 10. Open Questions Deliberately Deferred

1. **`NSFileVersion` in tests.** Hard to fabricate real iCloud conflicts in unit tests. Plan: hide `NSFileVersion` behind `SidecarStoreProtocol.reconcileConflict(at:resolve:)` (§7.2). The in-memory store ships a scripted-conflict mode (the test injects `[(SidecarKey, [Data])]`); the file-system store uses real `NSFileVersion`.
2. **Background sync.** v1 requires the host to call `reconcile…()` explicitly. v2 may register an `NSFilePresenter`.
3. **Tombstone GC.** Tombstones live forever in v1.
4. **Orphan-sidecar auto-GC.** v1 keeps orphans. v2 may add a policy.
5. **`CNContact.note`.** Apple gates `CNContactNoteKey` behind the `com.apple.developer.contacts.notes` entitlement. We don't have it yet, and `Contact` carries no `note` property — the field is the single deliberate gap vs. `CNContact`. To avoid silently clobbering pre-existing notes when a host app reads, modifies, and writes a contact back through `CNContactStoreAdapter`, the adapter **omits `CNContactNoteKey` from every fetch descriptor** AND uses a partial-update save path: `save(_:)` reads the existing contact for the localID, mutates only the keys `Contact` represents, and submits the resulting `CNMutableContact` via `CNSaveRequest.update(_:)` so untouched keys (including `note`) remain in place.

**Array-key semantics in partial-update.** For the keys `Contact` represents that are array-valued (`urlAddresses`, `phoneNumbers`, `emailAddresses`, `postalAddresses`, `socialProfiles`, `instantMessageAddresses`, `contactRelations`, `dates`), the partial-update path **replaces the entire array** — it does not perform per-entry merge. Identity reconciliation depends on this: §3.3 Case C and Case D remove entries from `urlAddresses` and the save must make those removals stick. The §7.4 in-memory store enforces the same semantics so the mock and the real adapter behave identically.

`save(_:)` for a brand-new contact (no existing localID) cannot carry a `note` value and never will until the entitlement lands. When the entitlement is granted: add `note: String` to `Contact`, include `CNContactNoteKey` in the fetch descriptor, drop this caveat, and add a `testRoundtripNotePreservesContent` row to §9.1.

## 11. Implementation Order

Each phase ends with passing tests for the listed sections. Status markers:
✅ verified by unit test, 🟡 verified by production smoke (2026-06-14), 🔴 unverified.

1. ✅ **Models + protocols.** §7.1, §7.2 type declarations. No logic. (No tests yet.)
2. ✅ **In-memory stores.** `InMemoryContactStore`, `InMemoryEventStore`, `InMemorySidecarStore`. Tests: §9.1, §9.2 (in-memory rows only).
3. ✅ **Per-field LWW merge function.** A pure function `merge(_ a: SidecarEnvelope, _ b: SidecarEnvelope) -> Result<SidecarEnvelope, MergeError>`. Tests: §9.4.
4. ✅ **Identity reconciler.** `GuessWhoSync.reconcileContactIdentities()` and `reconcileContactIdentity(localID:)` against in-memory stores. Tests: §9.3, §9.6, §9.8.
5. ✅ **Sidecar conflict reconciler.** `GuessWhoSync.reconcileSidecars()` against in-memory stores with a scripted-conflict mode. Tests: §9.5.
6. ✅ **Event sidecars.** Tests: §9.7.
7. ✅🟡 **`FileSystemSidecarStore`.** Tests: §9.2 (filesystem rows), real-conflict integration tests using `NSFileVersion.add(of:withContentsOf:)`. ✅ unit-tested; 🟡 production-smoked on 2026-06-14 against the real iCloud ubiquity container `iCloud.com.milestonemade.guesswho` — a `setField` call from the sample app produced a valid v1 envelope at `Documents/contacts/<uuid>.json` with correct `schemaVersion`, `entityID`, and a LWW cell carrying the device-ID tiebreaker. Real two-device `NSFileVersion` conflict path is still 🔴.
8. 🟡🔴 **Real `CNContactStore` / `EKEventStore` adapters.** Smoke-tested on device; not unit-tested. `CNContactStoreAdapter`: 🟡 Case A reconcile + `save(_:)` partial-update verified on 2026-06-14 (Mac Catalyst) — wrote `guesswho://contact/<uuid>` to a real `CNContact` and macOS Contacts.app showed the URL. `EKEventStoreAdapter`: 🔴 untouched by the sample app, no smoke yet.

### 11.1 Verification gaps for the next agent

The items below are load-bearing for v1 but not yet demonstrated in production. They should be the next agent's prioritized hit list before any new features land.

**High priority (correctness-of-design risks):**
- 🔴 **§12 timestamped notes — single-device CRUD.** Add three notes via the sample app's bottom input, inline-edit one, swipe-delete one. Re-launch. Confirm the two live notes appear in `(createdAt, id)` ascending order. (See §12 for the full feature spec.)
- 🔴 **§12 timestamped notes — two-device convergence.** Device A creates note X, device B creates note Y, both offline. After both come online and reconcile, both devices show `[X, Y]`.
- 🔴 **§3.3 Case D in production.** Tonight only exercised Case A. Construct a contact with two `guesswho://contact/<uuid>` URLs (each pointing at a populated sidecar, each with one note per §12 for a richer test), reconcile, and confirm: loser URL gone from the contact, winner sidecar carries the union of fields *including both notes*, loser sidecar file deleted from iCloud.
- 🔴 **§3.3 Case C in production.** Construct a contact with one valid GuessWho URL plus one malformed sibling, reconcile, confirm the malformed URL is removed.
- 🔴 **§9.6 multi-device convergence in production.** Two real iCloud-signed-in devices, each reconciling the same contact independently. Observe that after both devices reconcile, both end up at the lex-smaller UUID with merged sidecar fields.

**Medium priority (sync-mechanism risks):**
- 🔴 **§10.5 partial-update preserves untouched native fields.** The partial-update save path is still load-bearing for any `CNContact` field we don't model. Pick a contact that already has a Notes-app `note` value (the convenient canary), reconcile it through the sample app, confirm `note` survives byte-for-byte. Downgraded from high since we're no longer in the contacts-notes business — but the partial-update contract itself is unchanged.
- 🔴 **§12 timestamped notes — two-device edit/delete race.** Device A edits note X; device B deletes note X. Confirm both devices converge to the same state (newer stamp wins). Medium priority because §12.6 unit tests exercise this case exhaustively; the production smoke is confirmation, not discovery.
- 🔴 **§6 `NSFileVersion` conflict resolution on real iCloud.** Force two devices to write the same sidecar offline, bring them online, watch `reconcileSidecars()` resolve the conflict per §6 rules.
- 🔴 **§3.4 orphan sidecar detection in production.** Reconcile a contact, delete it from Contacts on the same device, run `reconcileContactIdentities()` (all-contacts sweep), confirm the sidecar appears in `IdentityReconcileReport.orphanSidecars` and is **not** auto-deleted.

**Low priority (out of scope for v1 sample, but blocks v2):**
- 🔴 **`EKEventStoreAdapter` minimum smoke.** Fetch one event, write a sidecar, fetch by externalID. Establishes the event path is viable before any event UI lands.
- 🔴 **Filesystem-layout safety on iCloud Drive case-insensitivity (§5.1).** Two events whose `externalID` differs only in ASCII case would collide. v1 assumes this does not happen for iCloud-source calendars (where externalIDs are UUIDs). Worth a one-shot check once event smoke is up.

When any item above flips from 🔴 to 🟡, update its status here AND note the smoke procedure in a short paragraph below it so the next reader can re-run the check.

## 12. Timestamped Notes (Sidecar-Only Feature)

Every contact carries a list of timestamped notes, stored in the sidecar. `CNContact.note` is never read or written — the entitlement gate is out of scope (§10.5).

### 12.1 Data model

A new Codable type in `Sources/GuessWhoSync/ContactNote.swift`:

```swift
public struct ContactNote: Hashable, Sendable, Codable {
    public var id: UUID            // minted at create; stable across edits and merges
    public var createdAt: Date     // immutable after creation
    public var modifiedAt: Date    // bumped on body edit and on delete
    public var modifiedBy: String  // device ID — same source as SidecarCell.modifiedBy
    public var body: String        // plain text; cleared to "" on delete
    public var deleted: Bool       // soft-delete tombstone; survives merges
}
```

`Contact` does **not** gain a notes property. `Contact` is the `CNContact` mirror; `ContactNote` is sidecar-only.

ID is a UUID, not a content hash — two devices typing the same body simultaneously are two distinct notes.

**Clock source.** `createdAt`/`modifiedAt` are `Date()` at the moment of mutation, the same source the package uses for `SidecarCell.modifiedAt`. No injectable clock.

### 12.2 JSON shape

The sidecar envelope (§5.2) is unchanged. A well-known field key `"notes"` holds the list as the cell's `JSONValue`:

```json
"notes": {
  "value": [
    {
      "id": "9F4A-…",
      "createdAt": "2026-06-14T20:15:00.000Z",
      "modifiedAt": "2026-06-14T20:15:00.000Z",
      "modifiedBy": "device-A",
      "body": "Met at WWDC.",
      "deleted": false
    }
  ],
  "modifiedAt": "2026-06-14T20:15:00.000Z",
  "modifiedBy": "device-A"
}
```

The outer cell's `modifiedAt`/`modifiedBy` are the max `(modifiedAt, modifiedBy)` across the inner notes — including tombstoned notes — under §5.3's lex ordering. **The codec enforces this invariant on every encode** (see `encodeCell` in §12.5), so the on-disk envelope always satisfies it regardless of whether the cell was last written by a local `setField` or by `mergeNotesCell`.

**Empty list ⇒ absent.** A merged list of zero notes is encoded by *omitting* the `"notes"` field from the envelope. There is no "empty cell" representation. Equivalently: an absent `"notes"` field decodes to `[]`. This removes the only case where the outer-cell stamp would be undefined.

**Date encoding.** `createdAt` / `modifiedAt` are encoded as ISO8601 strings with fixed millisecond precision and a `Z` suffix (e.g. `"2026-06-14T20:15:00.000Z"`). The codec pins this strategy so that §5.3's "ISO8601 lex on `modifiedAt`" rule produces the same ordering whether the implementation compares re-serialized strings or in-memory `Date` values. **The decoder is permissive**: it accepts any form parseable by `ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]`, with a fallback to the same formatter without `.withFractionalSeconds`. This covers `Z`/`+00:00` and millisecond/no-fraction variants, so a note written by a peer with a slightly different encoder does not get silently dropped by the lenient element-level decoder in §12.3. Be permissive on input, strict on output.

### 12.3 Merge semantics — per-note LWW

The generic per-field LWW (§5.3) is wrong for notes: it would clobber a sibling note another device added concurrently. The per-note branch dispatches **only when both sides of `merge(a, b)` have the key `"notes"`**. If only one side has it, that side's cell is kept verbatim (the generic merge path, unchanged from §5.3). If neither side has it, the key is absent from the result.

**§5.3 override.** The per-note rules in §12.3 intentionally override §5.3's "malformed → absent" rule for the `"notes"` key — in two places. First, the both-sided merge (steps 1–4 below): a malformed side decodes to `[]`, the other side's valid notes survive the union. Second, the one-sided pass-through (paragraph below the steps): a malformed cell on the only side that has the key is kept verbatim, not dropped — the next reader normalizes it via the lenient decoder. Both overrides are safe: we lose no data we could have kept.

When both sides have `"notes"`:

1. Decode each side's cell into `[ContactNote]`.
   - A cell that fails to decode as a list of `ContactNote` — including a §5.2 tombstone cell (`{deleted: true, …}`), which is well-formed at the §5.2 level but is not a notes-list shape — is treated as `[]`.
   - The decoder is **lenient at the element level**: a single malformed array entry (missing `id`, bad `createdAt`, extra junk) is dropped; the remaining valid entries are kept. A completely undecodable cell is `[]`.
2. For each note ID in the union of both lists:
   - If only one side has the note: keep it.
   - If both have it: keep the one with the larger `(modifiedAt, modifiedBy)` (ISO8601 lex on `modifiedAt`, then string lex on `modifiedBy`). Applies symmetrically to live and tombstoned notes — same rule §5.3 uses on cells.
3. Tombstoned notes are kept in the list (they suppress earlier-stamped resurrection — same lifecycle as §5.5). UI filters them out.
4. If the merged list is empty, omit the `"notes"` key from the result envelope entirely (per §12.2). Otherwise the outer cell's `modifiedAt`/`modifiedBy` is the max across all merged notes' stamps, including tombstones.

A **malformed one-sided cell** (one side has `"notes"` but it doesn't decode) passes through verbatim under the "only one side has it" rule of §12.3's dispatch paragraph. The next reader normalizes it via the lenient decoder; no rewrite is forced.

There is no outer-cell tombstone path — "delete all" is N per-note tombstones. The merge function never produces an outer-cell tombstone for `"notes"`.

**Edit-vs-create.** Create mints a new UUID + `createdAt = modifiedAt = now`, `deleted = false`. Edit mutates `body`, bumps `modifiedAt`, leaves `id`/`createdAt`/`deleted` unchanged. Delete sets `deleted = true`, **clears `body` to `""`**, bumps `modifiedAt`. `createdAt` is never bumped post-creation.

`SidecarMerge.swift` grows a `mergeNotesCell(_:_:)` free function invoked from `merge(_:_:)` when (a) `key == "notes"` and (b) both `a.fields` and `b.fields` contain the key.

### 12.4 Interaction with the iCloud conflict reconciler

`reconcileSidecars()` (§6) is unchanged. It folds N envelopes via `merge(_:_:)`, which now dispatches to per-note merge for `"notes"`. The N-way iCloud conflict path converges per-note automatically.

Identity reconciliation (§3.3) is orthogonal — Case D's rebase step calls `merge(_:_:)`, so notes from a loser sidecar are folded into the winner without new code.

### 12.5 Sample-app UI

The sample app gains its first user-facing edit surface.

**ContactDetailView additions:**
- **Notes section** below the existing contact info.
- **List rows** sorted by `(createdAt, id)` **ascending** — `createdAt` primary, `id` (UUID string lex) tiebreak. Deterministic across devices even when two notes share a `createdAt`. Each row shows body (multi-line bodies render with their embedded newlines preserved — this is SwiftUI `Text` default behavior, no custom rendering required), relative time of `createdAt`, and an "edited" badge if `modifiedAt > createdAt`. Tombstoned notes are filtered out.
- **Always-visible empty `TextEditor` pinned below the list.** Return always inserts a newline; the **Send button** beside the input is the only way to commit. The button is disabled when the body is empty or whitespace-only. On submit, mints a new `ContactNote`, appends to the bottom, clears the input. No separate "+" button, no modal sheet.
- **Tap an existing note → inline edit.** The row swaps to an editable `TextEditor`; Return inserts a newline. The edit commits via two equivalent paths: **(a) Done button** on the row (discoverable, especially on Mac Catalyst), or **(b) any tap outside the editing row** (the existing focus-loss path). Both bump `modifiedAt`/`modifiedBy` and write the updated cell. **If `body` is unchanged from the value captured into the editor at edit-start, commit is a no-op** — no stamp bump, no write. (The "edit-start" snapshot, not the current on-disk value: this matters when a reconcile lands mid-edit and rewrites the on-disk body — a user who only inspected must not silently win LWW against the reconciled-in change.) Done is **not** disabled on an empty `body` — committing a cleared body is a deliberate "this note is now blank" edit, distinct from "delete the note." Users who want to remove the note entirely use swipe-delete or the context-menu Delete. No separate cancel gesture — discard requires deleting the note.
- **Swipe-to-delete** sets `deleted = true`, clears `body`, bumps `modifiedAt`. The row disappears immediately; the tombstone persists.

**Mid-edit vs `reconcileSidecars()`.** If a reconcile lands while the user is editing note X (rewriting the cell with a newer copy of X from another device), the in-progress edit is **not aborted**. On commit, the NotesStore re-reads, replaces X by ID with its locally-edited copy, writes. LWW resolves which version survives on the next merge. No UI prompt, no merge dialog.

**Codec and store.** `NotesCellCodec` lives **in the package** (`Sources/GuessWhoSync/`) alongside `ContactNote`, because the package's `mergeNotesCell` needs it. The codec exposes three operations:

- `decode(SidecarCell?) -> [ContactNote]` — lenient per §12.3 step 1; an absent cell, a malformed cell, or a §5.2 tombstone cell all return `[]`; malformed array elements are dropped.
- `encodeValue([ContactNote]) -> JSONValue` — used by `NotesStore` to pass the list into `GuessWhoSync.setField` (which takes a `JSONValue`, and stamps its own outer `modifiedAt`/`modifiedBy` from `Date()` / deviceID).
- `encodeCell([ContactNote]) -> SidecarCell?` — used by `mergeNotesCell`; recomputes the outer `(modifiedAt, modifiedBy)` as the max across inner notes per §12.2; returns `nil` when the list is empty so the merge can omit the key per §12.3 step 4.

A sample-app-side `NotesStore` view-model reads the current cell via `decode`, applies the mutation in memory, calls `encodeValue` to get a `JSONValue`, and writes via `GuessWhoSync.setField`. `modifiedBy` reuses the package's existing per-install device-ID source verbatim. The outer cell stamp `setField` writes is `Date()` / deviceID — equal to the just-mutated note's stamp because they share the same clock and writer — so the §12.2 outer-stamp invariant holds. The next merge re-derives it via `encodeCell` regardless.

**Concurrency model.** `GuessWhoSync.setField` already takes the `sidecarLocks` per-key lock around its read-merge-write, so two concurrent `setField` calls on the same key serialize. The sample-app NotesStore does its own read-decode-mutate-encode in memory *before* calling `setField`, which means a second `setField` between the read and the write loses the in-memory mutation against the on-disk state. We accept this race: every write is timestamped, LWW on the next merge converges the result.

- For a **body edit** that loses the race, the worst case is a single dropped edit the user sees in the next refresh and can retype.
- For a **swipe-delete** that loses the race against a concurrent edit, the deletion may briefly appear successful (the row vanishes from the UI) before the racing edit re-resurrects the note on the next reconcile if its stamp is newer. v1 accepts this; the user re-issues the delete.

No `mutateField` primitive in v1.

The DEBUG "Write debug field" button is retained — unrelated.

### 12.6 Test plan

**Unit tests (new):**
- `NotesCellCodecTests`: round-trip `[ContactNote]` ↔ `SidecarCell` (including empty list and all-tombstones); decode of an absent field returns `[]`; decode of a §5.2-shape tombstone cell returns `[]`; decode of a partially-malformed array drops the bad element and keeps the good ones.
- `NotesMergeTests` (§9.4 addition):
  - Same ID, both sides, larger `(modifiedAt, modifiedBy)` wins.
  - Parallel creates (different IDs) both survive.
  - Edit vs. delete on same ID, different stamps: newer stamp wins.
  - Edit vs. delete on same ID, **identical `modifiedAt`**: `modifiedBy` lex tiebreak determines winner.
  - Tombstone vs. older edit on same ID: tombstone wins.
  - Two tombstones for the same ID with different stamps: larger-stamp tombstone wins.
  - Only-one-side has `"notes"`: result equals that side's cell verbatim (no codec round-trip).
  - Empty merged list: result envelope has no `"notes"` key.
  - Both sides have malformed `"notes"` cells: result envelope has no `"notes"` key.
  - Outer-cell `modifiedAt`/`modifiedBy` equals the max across all merged notes (including tombstones).
  - `encodeCell([])` returns `nil`; `encodeCell([...non-empty...])` returns a `.value` cell whose stamp is the max across the inner notes.
  - Commutativity and associativity across randomized 3-note lists.
- `NotesEnvelopeTests` (§9.5 addition):
  - 3-way N-fold via `reconcileSidecars()` with three disjoint notes — all three appear in the result.
  - 3-way N-fold where two of the three carry a tombstone for the same ID at different stamps — the later tombstone wins; no live note resurrects.

**Sample-app smoke tests (§11.1 additions, all 🔴):**
- 🔴 **Single-device notes CRUD.** Add three via bottom input, inline-edit one, swipe-delete one. Re-launch. List shows two live notes in `(createdAt, id)` ascending order.
- 🔴 **Two-device convergence.** A creates X, B creates Y, both offline. After sync + reconcile, both devices show `[X, Y]`.
- 🔴 **Two-device edit/delete race.** A edits X; B deletes X. Newer-timestamp wins, both devices converge to the same state.

**Case A/B/C** smokes — unchanged. **Case D** — extend so each pre-merge contact's sidecar carries one note; after reconcile, the winner holds both. No new code path; the per-note merge runs automatically.

### 12.7 Slot in §11.1

Promote ahead of existing 🔴 items — notes are the first user-visible sidecar feature.

1. **NEW 🔴 (high)** — `ContactNote` model, `NotesCellCodec`, and per-note merge branch in `SidecarMerge.swift`.
2. **NEW 🔴 (high)** — Sample-app notes UI.
3. **NEW 🔴 (high)** — Two-device notes convergence smoke.
4. Existing 🔴 §3.3 Case C and Case D smokes — unchanged priority; Case D extended per §12.6.
5. **Downgrade** the former §10.5 `CNContact.note` smoke to medium and add it to the medium-priority list in §11.1, reframed as "partial-update preserves untouched native fields, witnessed by `note`." We're no longer in the contacts-notes business, but the partial-update path still has to be proven to leave native fields alone — `note` remains the convenient canary.
