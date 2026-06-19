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
- Soft-delete garbage collection. `deletedAt`-set cells, notes, and links live forever in v1 (Core Semantics).
- Non-iCloud Contacts sources (Exchange, Google CardDAV). v1 makes no guarantees; behavior is "best effort, may drift."
- Cross-iCloud-account sync. Single user, single iCloud account.

## Core Semantics

Five primitives govern every read, write, and merge in this package. Every later section is an application of these — when something here says "per Core Semantics," that's the rule, not a restatement.

1. **Storage boundary.** Whatever the Contacts or EventKit frameworks can represent lives there. Writes to Contacts are best-effort — CardDAV handles sync; it's not our problem. Everything else lives in sidecar files (§4, §5).
2. **Disk is Truth; writes are atomic.** Every mutation is one envelope write to one file. There is no "half-written" state on disk. `NSFileVersion` reports conflicts per-file (§6).
3. **LWW everywhere, per-cell, on `(modifiedAt, modifiedBy)`.** Every sidecar cell — contact field, event field, link cell — competes via §5.3 whole-cell LWW. The winning cell brings its `value`, stamps, and `deletedAt` as one atomic unit. New feature types add new cell shapes, never new merge code.
4. **`deletedAt` is the only delete mechanism.** A cell with `deletedAt == nil` (or absent) is **live**. A cell with `deletedAt` set is **deleted**. Delete = set `deletedAt`; undelete = clear it. Both operations are normal cell writes that compete in LWW exactly like value edits. Soft-deleted cells survive forever in v1 (GC deferred — §10); the package never filters by `deletedAt` — callers decide what to render.
5. **FWW only for the GuessWho UUID.** The lone exception to LWW: when two devices independently assigned UUIDs to the same contact, the lex-smallest wins (§3.3 Case D) without further writes. All syncing devices converge on the same canonical identifier deterministically.

UUID collision is treated as impossible at every layer (122 bits of entropy from `UUID()`). Cross-process writers on a single device rely on the same astronomical-improbability stance as cross-device.

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
2. Build the merge target: start with the winner's existing sidecar if present, otherwise an empty envelope with `entityID = winner UUID` and `fields = [:]`. For each *loser* UUID with an existing sidecar, rebase that sidecar onto the winner UUID (copy of the loser envelope with `entityID` set to the winner UUID; `fields` unchanged), then set `merged = merge(merged, rebased)` per §5.3. Write `merged` at the winner UUID. Delete each loser sidecar file. Because `fields` is keyed by per-instance UUIDs (§5.2), the loser's and winner's keys cannot collide; the rebased merge is effectively a union, with §5.3 LWW running only on the (astronomically improbable) UUID-equal cells.
3. Remove every losing `guesswho://contact/…` URL and every malformed `guesswho://contact/…` URL from `urlAddresses`. Keep the winner.
4. Save the contact.

(The rebase step is the only place the package deliberately changes a sidecar's `entityID`. It's safe because identity reconciliation owns both the URLs and the sidecar IDs; no other caller observes the loser sidecar after this step.)

**Per-contact reconcile.** Hosts that want explicit per-contact control (a "Reconcile this contact" button on a detail page) call `reconcileContactIdentity(localID:)` (§7.3) instead of the all-contacts sweep. The per-contact entry point runs the same Case A/B/C/D logic above for one localID and returns the same `ContactOutcome`. It intentionally does **not** populate `orphanSidecars` — orphan detection requires the global set of carried UUIDs across every contact (§3.4), which a per-contact call cannot see.

Convergence: once every device has reconciled the same merged contact, every device's `urlAddresses` contains exactly one GuessWho URL pointing at one merged sidecar.

### 3.4 Orphan sidecars

A sidecar file is *orphan* if no contact carries its UUID in `urlAddresses` after a full identity reconcile pass. Two cases produce orphans and look identical to the algorithm: a user-driven delete on another device, or a transient gap during in-flight CardDAV sync.

**v1 policy:** orphans are kept, never auto-deleted. They surface in `IdentityReconcileReport.orphanSidecars`; host UIs MUST act only on explicit user input. v2 may add age-based GC — deferred (§10).

## 4. Storage Boundary

| Data lives where? | Examples |
|---|---|
| **Contacts store (canonical, writable)** | Every `CNContact` field the framework exposes except `note` (gated by `com.apple.developer.contacts.notes` entitlement; deferred until we obtain it). Specifically: `identifier` (carried as `Contact.localID` for store reads/writes); `contactType`; the full name family (`namePrefix`, `givenName`, `middleName`, `familyName`, `previousFamilyName`, `nameSuffix`, `nickname`, plus phonetic given/middle/family); the full work family (`jobTitle`, `departmentName`, `organizationName`, `phoneticOrganizationName`); `phoneNumbers`, `emailAddresses`, `postalAddresses`, `urlAddresses` (including our GuessWho URL); `birthday`, `nonGregorianBirthday`, and labeled `dates` (anniversary, custom); `socialProfiles`; `instantMessageAddresses`; `contactRelations`; `imageDataAvailable` (raw `imageData`/`thumbnailImageData` are loaded on demand, not carried on `Contact`). |
| **EventKit (canonical, read-only)** | Calendar events, attendees, location, recurrence — read but never written by this package |
| **Sidecar (writable)** | GuessWho-specific fields with no Contacts/EventKit home. v1 ships the storage primitive; callers define the field set. Three sidecar kinds: per-contact (keyed by GuessWho UUID), per-event (keyed by `calendarItemExternalIdentifier`), per-link (keyed by link UUID — see §13). |

## 5. Sidecar Format

### 5.1 Filesystem layout

The package takes a **root `URL`** at init. The host decides whether that root is in a ubiquity container, a Documents folder, or a temp directory (tests use the last). Layout:

```
<root>/
  contacts/<uuid>.json
  events/<eventExternalID-safe>.json
  links/<uuid>.json
```

One file per entity. `NSFileVersion` reports conflicts per-file, so a conflict on contact A never blocks contact B. Links live as independent files (§13) — a link is one atomic on-disk record, never split across multiple files.

**Filename safety.** Contact and link UUIDs are lowercase hex + dashes, safe as-is. Event external identifiers are opaque strings that may contain `/`, `:`, or other characters illegal in filenames. The package percent-encodes every character outside `[A-Za-z0-9._-]` before using them as filenames; the inverse transform is applied on read. The stored `entityID` field inside the envelope is always the original (untransformed) string.

### 5.2 File schema

```json
{
  "schemaVersion": 1,
  "entityID": "<contact UUID, event externalID, or link UUID — untransformed>",
  "fields": {
    "9F4A1B6E-...": {
      "value": {
        "field": "general notes",
        "type":  "note",
        "value": "Met at WWDC"
      },
      "modifiedAt": "2026-06-14T20:15:00.000Z",
      "modifiedBy": "device-A"
    },
    "C2D88F03-...": {
      "value": {
        "field": "anniversary",
        "type":  "date",
        "value": "2024-09-15"
      },
      "modifiedAt": "2026-06-14T22:00:00.000Z",
      "modifiedBy": "device-B"
    },
    "7B2C0901-...": {
      "value": {
        "field": "sent thank you note",
        "type":  "checkbox",
        "value": true
      },
      "modifiedAt": "2026-06-13T10:00:00.000Z",
      "modifiedBy": "device-A",
      "deletedAt": "2026-06-13T10:00:00.000Z"
    }
  }
}
```

**`schemaVersion`** — bumped on breaking envelope changes; readers refuse to merge or write unknown versions (see §6).

**`entityID`** — the canonical UUID string (contacts, links) or the raw `calendarItemExternalIdentifier` (events). No `guesswho://` prefix. The directory the file lives in (`contacts/` vs `events/` vs `links/`) disambiguates kind; there is no `kind` field.

**`fields`** — the map's keys and inner-value shape depend on the sidecar's `kind`:

| `SidecarKind` | `fields` key      | Inner cell `value` shape         | Where spec'd |
|---------------|-------------------|----------------------------------|--------------|
| `.contact`    | field-instance UUID string | `{ field, type, value, [createdAt, ...extensions] }` (this section) | §5.2 below |
| `.event`      | field-instance UUID string | same as `.contact`               | §5.2 below |
| `.link`       | well-known cell name (e.g. `endpointA`, `note`) | primitive `JSONValue` per the cell's role | §13.2 |

The rest of §5.2 specifies the contact/event shape. Link sidecars predate the field-instance pivot — see §13.2 for their cell layout. Everything else in §5 (envelope structure, cell stamps, `deletedAt`, §5.3 merge mechanics) applies uniformly to all three kinds; only the inner-value-object rule below is contact/event-only.

For contact and event sidecars: there are no singleton "well-known" field names — every field is multi-instance from the start (a contact can carry two `"general notes"` instances, three checkboxes, etc.). Field-instance UUIDs are minted at create and never reused.

Every cell has the same envelope shape:

```
{
  "value":      <JSONValue>,        // see "Cell value shape" below
  "modifiedAt": <ISO8601 UTC>,      // required
  "modifiedBy": <string>,           // required
  "deletedAt":  <ISO8601 UTC>       // optional — present iff the field is soft-deleted
}
```

A cell with `deletedAt` absent (or null) is **live**. A cell with `deletedAt` present is a **soft-deleted cell**: the field has been removed by the user. `value` is allowed to remain alongside `deletedAt` (a record of what was deleted) but readers MUST treat the field as absent — UI does not render it, and follow-up writes on this field bump `(modifiedAt, modifiedBy)` and clear `deletedAt` to undelete.

**Cell `value` shape (contact and event sidecars).** Every cell `value` is a JSON object with three required keys plus one optional:

| Key         | Type            | Mutability       | Meaning |
|-------------|-----------------|------------------|---------|
| `field`     | string          | mutable          | Caller-supplied human-readable field name (e.g. `"general notes"`, `"anniversary"`, `"sister"`). Opaque to the package — UI groups, sorts, or labels by it. |
| `type`      | enum string     | **immutable**    | Discriminator for the value's payload shape. v1 enum: `"note"` (payload is JSON string), `"date"` (payload is ISO8601 date string), `"checkbox"` (payload is JSON bool). More types land additively. |
| `value`     | `<JSONValue>`   | mutable          | The typed payload. Shape constrained by `type`. |
| `createdAt` | ISO8601 string  | **write-once**   | Optional. Stamped at `addField` time from the cell's first `modifiedAt`; preserved verbatim by every subsequent `setField`. Surfaces on `SidecarField.createdAt` (§7.1). Optional because a peer running an older package version may omit it; readers fall back to `cell.modifiedAt` when absent. |

Callers may extend the inner object with additional keys (e.g. `"label"`, `"icon"`); the package preserves them on round-trip but does not interpret them.

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

Per Core Semantics: LWW operates on the whole cell as one atomic unit. A soft-deleted cell that wins LWW keeps the field deleted; a live cell that wins LWW resurrects it.

**Properties.** This merge is **commutative** (`merge(a, b) == merge(b, a)`) and **associative** (`merge(merge(a, b), c) == merge(a, merge(b, c))`). Both are required for convergence when ≥3 devices merge in different orders. §9 asserts both.

**Malformed input handling.**

| Condition | Behavior |
|---|---|
| `modifiedAt` not ISO8601 | The cell is malformed → treated as absent. The other side's cell wins (or the field is absent from the merge if both sides are malformed). |
| `deletedAt` present but not ISO8601 | The cell is malformed → treated as absent. |
| `value` missing entirely (no `value` key at all) | Malformed → treated as absent. (`value: null` is valid; missing the key is not.) |
| Inner `value` object missing `field` or `type` keys | Malformed → cell treated as absent. (§5.2 mandates both keys; either being absent makes the cell uninterpretable.) |
| Inner `value` object has `type` set to an unknown enum string | Cell is kept on disk (forward-compatible); merge proceeds normally. The §7.3 `field`/`fields` decoded API omits unknown-type cells from its results. Callers who need the raw payload read it via `sidecar(at:)` and inspect the envelope directly. |
| `entityID` mismatch between `a` and `b` | Merge fails; reported in `ReconcileReport`. No write. |
| `schemaVersion` ≠ 1 on either side | Merge refuses. The non-v1 envelope is left intact. Reported. |

Malformed cells from a single side propagate as absent into the merge result; the merge does not preserve the malformed cell.

**Whole-cell LWW detail.** The winning cell brings *the entire inner-value object* (including the caller-supplied `field` label and any extension keys) along with stamps and `deletedAt`. A UI that concurrently renames the `field` label on one device while another device edits the `value` sees one cell win — winner's `field` and `value` survive together. Per-key-within-cell convergence is not provided.

`addField`'s per-`SidecarKey` lock serializes in-process writers; cross-process and cross-device collision avoidance relies on `UUID()` entropy per Core Semantics. The §7.3 type-immutability rule is enforced per device on write, not across the merge boundary.

### 5.4 Clock skew is acknowledged, not solved

Device clocks can disagree. A device with a fast clock can "win" LWW for a field. We accept this because the sidecar holds non-critical data and per-field granularity already removes the bigger failure mode (whole-file clobber of disjoint edits). The package logs `modifiedBy` on every write.

### 5.5 Soft-delete lifecycle

Per Core Semantics: `deletedAt` is the only delete mechanism, it's a normal cell write competing in LWW, and soft-deleted cells survive forever in v1 (GC deferred — §10). The same shape applies to link entity-level soft-delete (§13) and to notes (which are just field-instance cells — §12).

Soft-deleted cells must survive forever in v1 because they're the only thing preventing a stale value-write from a device that hasn't seen the delete from silently resurrecting a deleted field on the next merge.

## 6. iCloud Conflict Handling

When iCloud presents multiple versions of the same sidecar (current + `NSFileVersion.unresolvedConflictVersionsOfItem(at:)`), `reconcileSidecars()` converges in one pass for every key whose bytes it can read. Per Core Semantics: LWW always wins; disk is Truth; we never refuse to write when we have the data.

The pass for one conflicted file:

1. **Read current bytes.** If `currentVersionOfItem` is nil → pass `nil` to the resolver. If it exists but `Data(contentsOf:)` throws → **abort this pass for this key**: no write, no `remove()`, surface the error in `skippedReasons`. The bytes may be fine; we just can't access them right now (sandbox, transient I/O, iCloud not-yet-downloaded). Next reconcile retries.
2. **Read conflict bytes.** Same rule: a single conflict-version read failure aborts the pass for this key. We won't converge without considering every version's actual contents.
3. **Parse.** Decode each successfully-read version into an envelope. A version whose JSON / envelope decode fails, or whose `schemaVersion` ≠ 1, is dropped from the fold and reported in `skippedReasons`. Those bytes were garbage; we don't preserve garbage. An envelope whose `entityID` ≠ the file's key id is also dropped (it's wrong-routed data; folding it would propagate corruption).
4. **Fold.** Fold every parseable v1 envelope with §5.3 merge. Order doesn't matter (merge is associative + commutative).
5. **Write.** Overwrite the current with the folded envelope. The store first checks `merged.entityID == key.id` (defense-in-depth against a buggy resolver); a mismatch aborts the pass the same way a resolver throw does. Then `remove()` each conflict version FIRST and only set `version.isResolved = true` on success; surface any `remove()` failure in `skippedReasons` and leave `isResolved = false` for that version so the next pass retries. If no version parsed (all garbage), write an empty envelope at this key — every device still converges.
6. **Resolver throws.** The orchestrator's resolver doesn't throw. A third-party resolver that does produces no merged envelope; the store treats it the same as a read-failure abort: no write, no `remove()`, the throw surfaces in `skippedReasons`, conflict stays on disk for the next pass to retry. (Earlier we considered "always mark resolved on throw" but rejected it: destroying conflict bytes when we have no merged result to write is exactly the irreversible data loss this design is meant to avoid.)
7. **No conflict** on a file is a no-op.

The split is the safety/convergence balance: **parseable garbage is dropped (data was already gone); unreadable bytes abort (data might be fine — don't clobber it).**

The pre-pivot design tried to preserve unparseable bytes via a recovery-sibling file. That added a §6-step-4 branch, a `.recovered/` subdirectory, a deviceID parameter on the store, and a stuck-conflict failure mode. With one schemaVersion, atomic writes, and iCloud's transport, the "unparseable current" case is rare enough that converging beats preserving.

**`SidecarReconcileReport.FileOutcome.versionsConsidered`** counts how many version slots the resolver examined (current + conflict bytes that successfully read off disk). It includes unparseable ones — they contribute a `skippedReasons` entry but still counted as "considered." A non-zero `skippedReasons` with `versionsConsidered > 0` means some inputs participated and others were dropped.

**Deletion is not a conflict.** `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` never returns a "deletion version" — versions always have bytes. A delete done on another device reaches this device as a file removal handled outside this API (orphan policy §3.4; future `NSFilePresenter` wiring §10).

## 7. Public API Surface

### 7.1 Models

The package owns its own plain-Swift models — not `CNContact`/`EKEvent` — so mocks don't have to forge framework types. Adapters convert at the boundary.

`Contact` is a faithful mirror of `CNContact`: every property the framework exposes is represented, **except `note`**, which Apple gates behind the `com.apple.developer.contacts.notes` entitlement (deferred until the app has it). `Event` is a plain-Swift mirror of the §4 canonical event fields.

**Codable.** The plain value models that mirror Contacts/EventKit data conform to `Codable` so they compose for sidecar emission, on-disk caching, and test fixtures (a `Contact` snapshot may be embedded inside a sidecar field as a `JSONValue.object`). The sidecar payload types (`SidecarEnvelope`, `SidecarCell`, `JSONValue`, `SidecarKey`, `SidecarKind`) are also `Codable` because they are the literal JSON file format in §5.2. Decoded projection types such as `SidecarField` do not need to be `Codable`: they are API views derived from an envelope key plus a `SidecarCell`, not a separate on-disk shape. `JSONValue` uses hand-rolled `Codable` because the JSON layout (dynamic value shapes) does not match the compiler-synthesized form. `SidecarCell` is a plain struct (§5.2's one-shape-per-cell rule), so its `Codable` is compiler-synthesized.

**Date encoding strategy.** The `JSONEncoder` / `JSONDecoder` used for sidecar envelopes is configured with `dateEncodingStrategy = .iso8601` (fractional-second variant) and `dateDecodingStrategy = .iso8601` with a permissive fallback that also accepts the non-fractional variant. This makes the `Date` fields on `SidecarCell` (`modifiedAt`, `deletedAt`) serialize as the ISO8601 strings shown in §5.2, and lets envelopes written by a peer with a slightly different encoder still decode.

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

public enum SidecarKind: String, Sendable, Codable { case contact, event, link }

/// Discriminator for the payload shape of a SidecarField's value.
/// Encodes/decodes to/from a string per the §5.2 inner `type` key.
/// Immutable after a field is created (§7.3).
public enum SidecarFieldType: String, Sendable, Codable {
    case note      // payload is a JSON string (free text)
    case date      // payload is a JSON string (ISO8601)
    case checkbox  // payload is a JSON bool
}

/// A decoded view of one field-instance cell from a contact or event
/// SidecarEnvelope. Returned by the orchestrator's field-instance accessors
/// (§7.3). Not used for link sidecars (§13 — those have their own shape).
/// `modifiedAt` / `modifiedBy` / `deletedAt` come from the cell stamps;
/// `field` / `type` / `value` / `createdAt` come from the cell's inner
/// `value` object (§5.2).
public struct SidecarField: Sendable {
    public let id: UUID            // the cell's field-instance UUID (envelope key)
    public let field: String       // caller-supplied name (mutable)
    public let type: SidecarFieldType  // immutable after create
    public let value: JSONValue    // payload, shape constrained by `type`
    public let createdAt: Date?    // §5.2 "createdAt" inner-value key; nil if a peer omitted it
    public let modifiedAt: Date
    public let modifiedBy: String
    public let deletedAt: Date?
}

public struct SidecarKey: Hashable, Sendable, Codable {
    public let kind: SidecarKind
    public let id: String                       // contact UUID, event externalID, or link UUID
}

public struct SidecarEnvelope: Sendable, Codable {
    public let schemaVersion: Int               // §5.2 — must equal 1 on write
    public let entityID: String
    public let fields: [String: SidecarCell]
}

public struct SidecarCell: Sendable, Codable {
    public var value: JSONValue                 // may be .null; treated opaquely
    public var modifiedAt: Date
    public var modifiedBy: String
    public var deletedAt: Date?                 // nil = live; non-nil = soft-deleted (§5.5)
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
    // (+ download/requestDownload — see source)
}

@_spi(ConflictReconcile)
public protocol SidecarConflictReconciling: SidecarStoreProtocol {
    func keysWithUnresolvedConflicts() throws -> [SidecarKey]
    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> SidecarEnvelope
    ) throws -> SidecarReconcileReport.FileOutcome?
}
```

`SidecarStoreProtocol` is the public surface — anything a host UI or third-party backend needs. The conflict-reconcile plumbing is exposed via `@_spi(ConflictReconcile)`: visible to the orchestrator and the two shipping stores (which `@_spi(ConflictReconcile) import GuessWhoSync`), invisible to plain `import GuessWhoSync` callers. The resolver returns a merged `SidecarEnvelope` — no enum, no recovery sibling, no "leave in conflict" option for the success path.

The orchestrator's `reconcileSidecars()` casts its store via `as? SidecarConflictReconciling` to drive the loop. A backend that doesn't conform (e.g. a non-iCloud store with no multi-version conflicts) gets an empty report — `reconcileSidecars()` is still safe to call.

**Resolver contract.** The closure passed to `reconcileConflict(at:resolve:)`:
- MUST return an envelope whose `entityID == key.id`. The FS store asserts this at write time as defense-in-depth — a mismatched return aborts the pass with `versionsConsidered = 0`.
- SHOULD always converge (return a valid envelope even when no inputs parsed — e.g. an empty envelope at the right entityID).
- MAY throw, in which case the store treats this key as "abort the pass": no write, no `version.remove()`, error surfaces in `skippedReasons` with `versionsConsidered = 0`, and the conflict stays on disk for the next reconcile to retry. The orchestrator's resolver doesn't throw; this clause only matters for third-party resolvers.

**Store contract (success path).** The store calls `version.remove()` FIRST and only sets `version.isResolved = true` on success. If `remove()` throws, `isResolved` stays false so the next pass retries that version. Per-version `remove()` failures surface in `skippedReasons`; they don't fail the whole pass.

**Read failures.** If `Data(contentsOf:)` throws on the current or any conflict version (sandbox glitch, transient I/O, iCloud not-yet-downloaded), the store aborts the pass the same way a resolver throw does: `versionsConsidered = 0`, no write, no `remove()`, error in `skippedReasons`. The bytes might be fine; we don't clobber them.

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

    // Read the raw envelope (debug / advanced).
    public func sidecar(at key: SidecarKey) throws -> SidecarEnvelope?

    // ---------- Field-instance API ----------
    // The sidecar's `fields` map is keyed by per-instance UUIDs. Every field is
    // multi-instance — a contact may carry two "general notes" or three
    // checkboxes. The orchestrator owns instance UUIDs (mints them on add).

    /// Adds a new field instance. Mints a UUID, writes a cell whose inner value
    /// object is { field, type, value }. Returns the minted UUID.
    /// Throws `SidecarStoreError.typeValueMismatch` if `value` doesn't match
    /// the JSON shape `type` requires (e.g. `.checkbox` requires `.bool`).
    public func addField(at key: SidecarKey,
                         field: String,
                         type: SidecarFieldType,
                         value: JSONValue) throws -> UUID

    /// Mutates an existing field instance's caller-supplied name and/or value.
    /// Reads the existing cell to learn its immutable `type`; throws
    /// `SidecarStoreError.typeValueMismatch` if the new `value` doesn't match.
    /// Bumps `modifiedAt` / `modifiedBy` and clears `deletedAt` (undelete:
    /// writing to a soft-deleted cell brings it back as live). Silent no-op
    /// if the cell is missing.
    public func setField(at key: SidecarKey,
                         id: UUID,
                         field: String,
                         value: JSONValue) throws

    /// Soft-deletes a field instance by setting cell `deletedAt = now`,
    /// bumping `modifiedAt`/`modifiedBy`. The inner value object is preserved
    /// as a record of what was deleted. Silent no-op if already soft-deleted.
    public func deleteField(at key: SidecarKey, id: UUID) throws

    /// Returns one decoded field by id, or nil if the cell is missing,
    /// has an unknown `type`, or has the link-sidecar shape (§13.2).
    /// Soft-deleted fields are returned (callers filter on `deletedAt`).
    /// Precondition: `key.kind == .contact || key.kind == .event`.
    public func field(at key: SidecarKey, id: UUID) throws -> SidecarField?

    /// Returns every decoded field in the entity's sidecar, in unspecified
    /// order. Soft-deleted fields are returned. Callers filter / sort.
    /// Cells whose `type` is unknown to this package version are omitted
    /// from the decoded list (the raw envelope still carries them; see
    /// `sidecar(at:)` for the unfiltered view). This keeps forward-compatibility
    /// with future types added by newer peers.
    /// Precondition: `key.kind == .contact || key.kind == .event`. On a
    /// `.link` key the result is unspecified — use the §13.5 link API instead.
    public func fields(at key: SidecarKey) throws -> [SidecarField]
}

public struct IdentityReconcileReport: Sendable {
    public struct ContactOutcome: Sendable {
        public let localID: String
        public let assignedUUID: String?              // newly assigned, if any
        public let mergedLoserUUIDs: [String]         // sidecars merged into the winner
        public let removedMalformedURLs: [String]
        public let rewrittenLinkIDs: [UUID]           // §13.4 — link UUIDs whose
                                                      // endpoints were rewritten by
                                                      // this contact's Case-D collapse.
                                                      // Each link appears at most once,
                                                      // even if both its endpoints were
                                                      // rewritten in one pass. Lets an
                                                      // app-side graph cache (§14) re-read
                                                      // exactly the affected envelopes.
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

**Field-instance write semantics.** Every mutation (`addField`, `setField`, `deleteField`) is one read-modify-write on the entity's sidecar envelope. The file-system store serializes writes per file (a brief in-memory lock keyed by `SidecarKey`), so two concurrent `addField` calls for the same contact land at two different UUID keys with both new cells preserved in the resulting envelope — never a lost write. Writes from other processes on the same device surface as `NSFileVersion` conflicts and are handled by `reconcileSidecars()` (§6) — same code path as cross-device sync, no special-case needed.

**Type immutability.** `type` is fixed at create time. `setField(at:id:field:value:)` does not take a `type` parameter — it reads the existing cell to recover the immutable type, validates the new `value` against it, and writes. Callers who want to "change the type" of a field instance must call `deleteField` and then `addField` with a fresh instance UUID.

**`SidecarStoreError.typeValueMismatch`** — thrown by `addField` / `setField` when the JSON shape of `value` does not match the cell's `type`:
| `type`      | Required `JSONValue` shape |
|-------------|----------------------------|
| `.note`     | `.string`                  |
| `.date`     | `.string` (must be ISO8601-parseable; the orchestrator validates) |
| `.checkbox` | `.bool`                    |

**Identity is the caller's responsibility.** `SidecarKey` requires an ID, so writing to a contact's sidecar presumes the contact already has a GuessWho UUID. Callers must run `reconcileContactIdentities()` first (e.g., at app launch) to ensure every contact has a UUID; the resulting `IdentityReconcileReport.contactOutcomes` exposes the assigned UUID per contact.

**Deriving a `SidecarKey` from a `Contact`.** Find the `LabeledValue` in `urlAddresses` whose `value` starts with `guesswho://contact/`, parse the suffix as a UUID, and build `SidecarKey(kind: .contact, id: uuid)`. After `reconcileContactIdentities()` returns, exactly one such URL is present per touched contact. The package exposes this as a static helper on `SidecarKey`:

```swift
extension SidecarKey {
    public static func forContact(_ contact: Contact) -> SidecarKey?
    public static func forEvent(_ event: Event) -> SidecarKey
    public static func forLink(_ link: Link) -> SidecarKey
}
```

`forContact` returns nil if no GuessWho URL is present (caller forgot to reconcile, or contact is brand-new). `forEvent` is total because the event's `externalID` is the canonical key. `forLink` is total because the link's `id` is the canonical key.

### 7.4 Mocks

`InMemoryContactStore`, `InMemoryEventStore`, `InMemorySidecarStore` ship in a `GuessWhoSyncTesting` module. Each is a full implementation backed by a dictionary. The orchestrator runs unchanged against mocks (unit tests) and the real adapters (production).

**Image data in `InMemoryContactStore`.** Because `Contact` does not carry image bytes, the store keeps a parallel `[localID: (image: Data?, thumbnail: Data?)]` sideband. Test-only setter:

```swift
extension InMemoryContactStore {
    public func setImageData(_ image: Data?, thumbnail: Data?, for localID: String)
}
```

The invariants — designed so a routine `fetch → mutate one field → save` never wipes bytes:

| Call | Bytes (sideband) | Flag (`imageDataAvailable`) |
|---|---|---|
| `loadImageData` / `loadThumbnailImageData` | The truth. Returns current sideband bytes (nil if absent). Throws `contactNotFound` only when the contact is absent. | Ignored. |
| `fetch(localID:)` | Untouched. | Auto-corrected against current sideband truth before return. |
| `fetchAll()` | Untouched (cheap bulk path; never peeks — see §9.1). | Returned as-stored; may be stale. |
| `save(_:)` | Cleared **only** on a true→false transition of the flag from the previously stored `Contact`. New contact or already-false → sideband untouched. | Stored verbatim; not corrected. |

The real `CNContactStoreAdapter` has no sideband to peek at, but the OS keeps `CNContact.imageDataAvailable` byte-consistent with the underlying bytes, so the same observable contract holds. Same partial-update philosophy as §10.5.

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
- overwriting a field-instance cell (same instance UUID key) stamps `modifiedAt = now()` and `modifiedBy = deviceID`
- delete writes a soft-deleted cell (`deletedAt` set), not a key removal
- read of a missing key returns nil
- filename encoding: an event with an externalID containing `/` round-trips through write→read

### 9.3 Identity reconciliation (§3.3)
- Case A (no valid candidate): UUID assigned, URL appended
- Case A with malformed URLs that happen to name existing sidecars: malformed URLs removed, fresh UUID assigned, those sidecars become orphans
- Case B (one valid, no malformed): no-op
- Case C (one valid + malformed siblings): malformed removed, valid kept
- Case D, two valid candidates: lex-smallest wins; loser URL removed; loser sidecar merged
- Case D, two valid candidates, both UUIDs already have sidecars with overlapping and disjoint field-instance UUIDs: winner UUID ends up with the per-cell LWW merge of both; loser file deleted
- Case D, three valid candidates: still lex-smallest of all three wins; both losers merged into it
- repeated reconcile on a stable contact is a no-op (idempotence)

### 9.4 Per-field LWW merge (§5.3)
- disjoint field-instance UUIDs: both cells survive
- same field-instance UUID, different times: later wins
- same field-instance UUID, same `modifiedAt`: lex-larger `modifiedBy` wins
- soft-deleted cell vs. live value: later `modifiedAt` wins; soft-deleted cell, if it wins, survives the merge (`deletedAt` is preserved)
- **associativity:** for three envelopes `a`, `b`, `c`: `merge(merge(a, b), c)` equals `merge(a, merge(b, c))`
- malformed `modifiedAt` on a cell: cell treated as absent; other side wins
- malformed `deletedAt` on a cell (present but not ISO8601): cell treated as absent; other side wins
- missing `value` key on a cell (vs. `value: null`, which is valid): cell treated as absent
- entityID mismatch: merge fails with an error
- schemaVersion ≠ 1 on either side: merge refuses; neither envelope is written

### 9.5 Sidecar reconciliation under conflict (§6)
- current + one conflict version, both parseable v1: merged result written, conflict version `remove()`d
- current + two conflict versions, all parseable: N-way fold produces the right merged envelope, both conflicts removed
- one conflict version has unparseable bytes: it is dropped from the fold and reported in `skippedReasons`; the others merge normally; conflict is still cleared
- one conflict version has `schemaVersion = 99`: same — dropped from fold, reported, conflict cleared
- a parseable conflict envelope's `entityID` doesn't match the file's key id: dropped from the fold and reported; the others merge normally
- a parseable CURRENT envelope with mismatched entityID is also dropped (handles rename / restore-from-backup / buggy peer write)
- current absent, one conflict version is valid: merged result (the conflict envelope) becomes the new current
- no version parses: empty envelope written at this key; every device converges to the same byte state on next reconcile; all skipped versions reported
- meta-property: after **one** `reconcileSidecars()` call, `keysWithUnresolvedConflicts()` is empty for every key whose bytes were readable
- resolver throws: pass aborts for this key — no write, no `version.remove()`, error reported in `skippedReasons`, conflict stays for retry
- (host backend that conforms to `SidecarStoreProtocol` only — not `SidecarConflictReconciling` — `reconcileSidecars()` returns an empty report and does NOT throw)

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

   **When v1 hosts should call reconcile.** Until §10.2's background-sync wiring lands, hosts get stale data between iCloud landing a new envelope and the next reconcile call. Minimum-viable trigger set:
   - `reconcileContactIdentities()` at app launch (so every contact has a GuessWho UUID before any read goes to the sidecar layer) and on app foreground (so contacts added on another device get a UUID locally).
   - `reconcileSidecars()` at app launch, on app foreground, and after any direct sidecar write the host performs (so any NSFileVersion conflicts the OS surfaced get folded before the next read).
   Hosts may layer additional triggers — periodic polling, post-CardDAV-sync notifications, scene activation events — but the launch + foreground + post-write set is the minimum that keeps the visible state from drifting.
3. **Soft-delete GC.** `deletedAt`-set cells, notes, and links live forever in v1. GC may land in v2.
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
7. ✅🟡 **`FileSystemSidecarStore`.** Tests: §9.2 (filesystem rows), full §9.5 conflict matrix via the `SidecarUbiquityProvider` seam against an in-memory `FakeUbiquityProvider` (the seam abstracts `NSFileVersion` + ubiquity-download `URLResourceValues` behind an `@_spi(ConflictReconcile)` protocol so the 113-line `reconcileConflict` body is exercised on every CI run; production-side `NSFileVersionHandle` wraps the real APIs 1:1 — `FileSystemSidecarStore.swift` line coverage moved 60% → 97.78% in the same change). ✅ unit-tested; 🟡 production-smoked on 2026-06-14 against the real iCloud ubiquity container `iCloud.com.milestonemade.guesswho` using the pre-pivot singleton `setField` API — produced a valid v1 envelope at `Documents/contacts/<uuid>.json` with correct `schemaVersion`, `entityID`, and a LWW cell carrying the device-ID tiebreaker. The 🟡 smoke is preserved as a historical waypoint; the API has since shifted to the field-instance shape (§7.3), so a fresh smoke against `addField` / `setField(at:id:field:value:)` / `deleteField(at:id:)` is on the §11.1 hit list. Real two-device `NSFileVersion` conflict path (the `cloudd`-set `isConflict` flag that the in-memory fake cannot synthesize) is still 🔴.
8. 🟡🔴 **Real `CNContactStore` / `EKEventStore` adapters.** Smoke-tested on device; not unit-tested. `CNContactStoreAdapter`: 🟡 Case A reconcile + `save(_:)` partial-update verified on 2026-06-14 (Mac Catalyst) — wrote `guesswho://contact/<uuid>` to a real `CNContact` and macOS Contacts.app showed the URL. `EKEventStoreAdapter`: 🔴 untouched by the sample app, no smoke yet.
9. ✅ **Field-instance API + notes (§7.3, §12).** `addField` / `setField(at:id:field:value:)` / `deleteField(at:id:)` / `field(at:id:)` / `fields(at:)`; `SidecarFieldType`; `SidecarField`; `typeValueMismatch`. Foundation for every typed field (notes, dates, checkboxes). Tests: §12.4 (unit). Sample-app UI + production smokes still 🔴 — see §11.1.
10. ✅ **Entity links (§13).** `SidecarKind.link`, `Documents/links/` in `FileSystemSidecarStore`, `Link` model + Codable + envelope codec, five orchestrator methods (`addLink` / `setLinkNote` / `removeLink` / `link(id:)` / `links(at:)`), Case-D endpoint-rewrite step in both reconcile entry points, `rewrittenLinkIDs` on `ContactOutcome`. Tests: §13.6 (unit). Production smokes still 🔴 — see §11.1.
11. ✅ **Public API surface narrowed.** `SidecarConflictReconciling` is `@_spi(ConflictReconcile)`; conflict-reconcile plumbing invisible to plain `import GuessWhoSync` (PLAN §7.2). Resolver contract documented and enforced: entityID match (defense-in-depth FS-store assertion), read-failure / resolver-throws / mismatched-entityID all abort the pass with `versionsConsidered = 0` and conflict surface intact for retry. Tests: §9.5.

### 11.1 Verification gaps

The items below are load-bearing for v1 but not yet demonstrated in production (unit-test coverage exists for everything; what's missing is on-device behavior against the real Contacts/EventKit stores and real iCloud sync).

**High priority (correctness-of-design risks):**
- 🔴 **§7.3 field-instance API + §12 notes — single-device CRUD.** Add three notes via the sample app's bottom input, inline-edit one, swipe-delete one. Re-launch. Confirm the two live notes appear in `(createdAt, id)` ascending order. Exercises `addField` / `setField` / `deleteField` / `fields(at:)` (the foundation API for every future typed field — dates, checkboxes, etc.).
- 🔴 **§7.3 field-instance API + §12 notes — two-device convergence.** Device A creates note X, device B creates note Y, both offline. After both come online and reconcile, both devices show `[X, Y]`. Witnesses that two `addField` calls on the same contact, from different devices, land at two different UUID keys with no codec involved.
- 🔴 **§3.3 Case D in production.** Tonight only exercised Case A. Construct a contact with two `guesswho://contact/<uuid>` URLs (each pointing at a populated sidecar, each with one note per §12 for a richer test), reconcile, and confirm: loser URL gone from the contact, winner sidecar carries the union of fields *including both notes*, loser sidecar file deleted from iCloud.
- 🔴 **§3.3 Case C in production.** Construct a contact with one valid GuessWho URL plus one malformed sibling, reconcile, confirm the malformed URL is removed.
- 🔴 **§9.6 multi-device convergence in production.** Two real iCloud-signed-in devices, each reconciling the same contact independently. Observe that after both devices reconcile, both end up at the lex-smaller UUID with merged sidecar fields.

**Medium priority (sync-mechanism risks):**
- 🔴 **§10.5 partial-update preserves untouched native fields.** The partial-update save path is still load-bearing for any `CNContact` field we don't model. Pick a contact that already has a Notes-app `note` value (the convenient canary), reconcile it through the sample app, confirm `note` survives byte-for-byte. Downgraded from high since we're no longer in the contacts-notes business — but the partial-update contract itself is unchanged.
- 🔴 **§7.3 field-instance API + §12 notes — two-device edit/delete race.** Device A edits note X; device B deletes note X. Confirm both devices converge to the same state (newer stamp wins). Medium priority because §12.4 unit tests exercise this case exhaustively; the production smoke is confirmation, not discovery.
- 🔴 **§6 `NSFileVersion` conflict resolution on real iCloud.** Force two devices to write the same sidecar offline, bring them online, watch `reconcileSidecars()` resolve the conflict per §6 rules. (The §6 *logic* — every abort branch and the §11 step 11 contract — is now asserted on every CI run via the `SidecarUbiquityProvider` seam, so this 🔴 specifically covers the production `NSFileVersionHandle` wrapper against the `cloudd`-set `isConflict` flag, which the in-memory fake cannot synthesize.)
- 🔴 **§3.4 orphan sidecar detection in production.** Reconcile a contact, delete it from Contacts on the same device, run `reconcileContactIdentities()` (all-contacts sweep), confirm the sidecar appears in `IdentityReconcileReport.orphanSidecars` and is **not** auto-deleted.
- 🔴 **§13 links — two-device convergence.** Device A adds a person↔event link, device B independently adds a *different* link between the same two entities. After sync, both devices show both links (two distinct ids, no implicit dedup).
- 🔴 **§13.4 links — Case-D endpoint rewrite.** Each device independently mints a UUID for the same contact, each writes a link to a third party. After sync + Case D, both devices show one merged contact and the link's endpoint pointing at the winner UUID. The §3.3 Case D smoke above should also include one link whose endpoint references the merging contact.

**Low priority (out of scope for v1 sample, but blocks v2):**
- 🔴 **`EKEventStoreAdapter` minimum smoke.** Fetch one event, write a sidecar, fetch by externalID. Establishes the event path is viable before any event UI lands.

When any item above flips from 🔴 to 🟡, update its status here AND note the smoke procedure in a short paragraph below it so the next reader can re-run the check.

## 12. Timestamped Notes (Sidecar-Only Feature)

Notes are the first user-visible exercise of the generic field-instance API (§7.3). A "note" is a `SidecarField` (§7.1) with `type == .note` and `value == .string(body)`. Every contact may carry zero or more notes, mixed freely with other field types. Notes inherit everything from Core Semantics — LWW per cell, `deletedAt`-based delete, one envelope write per mutation. **The notes feature adds zero merge code and zero new types to the package.** `CNContact.note` is never read or written (§10.5).

### 12.1 Sample-app convenience wrapper

Sample-app code that wants a typed convenience can build a thin `ContactNote` wrapper locally (not in the package):

```swift
// Sample-app convenience (NOT in the package).
struct ContactNote {
    let id: UUID
    let body: String
    let createdAt: Date
    let modifiedAt: Date
    let modifiedBy: String
    let deletedAt: Date?

    init?(_ f: SidecarField) {
        guard f.type == .note, case .string(let body) = f.value else { return nil }
        self.id = f.id
        self.body = body
        self.createdAt = f.createdAt ?? f.modifiedAt   // see Note creation below
        self.modifiedAt = f.modifiedAt
        self.modifiedBy = f.modifiedBy
        self.deletedAt = f.deletedAt
    }
}
```

**`createdAt` is content, not stamp.** `createdAt` lives inside the inner value object (not as a cell stamp) so it never changes on edit or delete. `setField` preserves it verbatim. The wrapper falls back to `modifiedAt` if a peer running an older package version omitted it. Inner-value shape:

```json
{ "field": "general notes", "type": "note", "value": "Met at WWDC", "createdAt": "2026-06-14T20:15:00.000Z" }
```

### 12.2 Operations

Every note operation is a §7.3 call:

| Op | Call |
|---|---|
| Add | `addField(at: contactKey, field: label, type: .note, value: .string(body))` |
| Edit | `setField(at: contactKey, id: noteID, field: label, value: .string(newBody))` |
| Delete | `deleteField(at: contactKey, id: noteID)` |
| Fetch one | `field(at: contactKey, id: noteID)` |
| Fetch all | `fields(at: contactKey).filter { $0.type == .note }` |

Concurrent `addField` calls on the same contact target different instance UUIDs — both survive. Concurrent edits to the same note race on the per-`SidecarKey` lock locally and on LWW across devices. Identity-reconcile Case D rebases the loser's notes into the winner's envelope via the same generic merge — no special-case code.

### 12.3 Sample-app UI

The sample app gains its first user-facing edit surface.

**ContactDetailView additions:**
- **Notes section** below the existing contact info.
- **List rows** sorted by `(createdAt, id)` **ascending** — `createdAt` primary, `id` (UUID string lex) tiebreak. Deterministic across devices even when two notes share a `createdAt`. Each row shows body (multi-line bodies render with embedded newlines preserved — SwiftUI `Text` default), relative time of `createdAt`, and an "edited" badge if `modifiedAt > createdAt`. Soft-deleted notes (`deletedAt != nil`) are filtered out by the sample-app code, not the package — `fields(at:)` returns them.
- **Always-visible empty `TextEditor` pinned below the list.** Return always inserts a newline; the **Send button** beside the input is the only way to commit. The button is disabled when the body is empty or whitespace-only. On submit, calls `addField(at: contactKey, field: "general notes", type: .note, value: .string(body))`, clears the input. No separate "+" button, no modal sheet.
- **Tap an existing note → inline edit.** The row swaps to an editable `TextEditor`; Return inserts a newline. The edit commits via two equivalent paths: **(a) Done button** on the row (discoverable, especially on Mac Catalyst), or **(b) any tap outside the editing row** (the existing focus-loss path). Both call `setField(at: contactKey, id: noteID, field: label, value: .string(newBody))`. **If `body` is unchanged from the value captured into the editor at edit-start, commit is a no-op** — no API call, no stamp bump. (The "edit-start" snapshot, not the current on-disk value: this matters when a reconcile lands mid-edit and rewrites the on-disk body — a user who only inspected must not silently win LWW against the reconciled-in change.) Done is **not** disabled on an empty `body` — committing a cleared body is a deliberate "this note is now blank" edit, distinct from "delete the note." Users who want to remove the note entirely use swipe-delete. No separate cancel gesture — discard requires deleting the note.
- **Swipe-to-delete** calls `deleteField(at: contactKey, id: noteID)`. The row disappears immediately; the soft-deleted note persists in the cell.

**Mid-edit vs `reconcileSidecars()`.** If a reconcile lands while the user is editing note X (rewriting X's cell with a newer copy from another device), the in-progress edit is **not aborted**. On commit, the sample-app code calls `setField` — the package's per-key lock serializes against the reconcile's write — and LWW resolves which version survives on the next merge. No UI prompt, no merge dialog.

The DEBUG button in the sample app calls `addField` with a synthesized `.note` value — retained as a smoke-test trigger.

### 12.4 Test plan

Notes ship no new package code; testing exercises the §7.3 field-instance API with `.note` values.

**Unit tests (in `GuessWhoSyncTests`, against `InMemorySidecarStore`):**
- `NoteAddRoundTrip` — `addField(type: .note, value: .string("body"))` then `field(at:id:)` returns the expected `SidecarField` (populated stamps, `createdAt != nil`).
- `NoteEditPreservesCreatedAt` — `setField` advances `modifiedAt`; `createdAt` unchanged.
- `NoteDeleteSetsDeletedAt` — `deleteField` flips `deletedAt`; caller-side `.filter { $0.deletedAt == nil }` excludes it.
- `NoteTypeMismatchThrows` — non-string values to `.note` throw `typeValueMismatch` on both `addField` and `setField`.
- `NoteParallelCreates` — two `addField` calls land at two distinct UUIDs; both survive.
- §9.4 additions: parallel-create merge, edit-vs-delete race.
- §9.5 addition: 3-way N-fold of three single-note envelopes preserves all three notes.

Case A/B/C smokes unchanged. Case D smoke extends to include one note per pre-merge sidecar so the post-reconcile winner sidecar holds both notes (no new code — §3.3 rebase rides on `merge(_:_:)`). Sample-app smokes (single-device CRUD, two-device convergence, two-device edit/delete race) are listed in §11.1.

## 13. Entity Links (Sidecar-Only Feature)

A `Link` connects two entities (contact or event) with a free-text note. Same shape works for person↔person, person↔event, person↔organization, org↔event, event↔event. `CNContactRelation` continues to round-trip via §7.1; `Link` is the orthogonal hard-reference path with a stable ID and a note attached.

**A link is one atomic on-disk record** at `Documents/links/<uuid>.json` (`SidecarKey(.link, link.id.uuidString)`) — no dual-write, no "canonical side" rule. Per Core Semantics: one envelope write per mutation, generic §5.3 LWW per cell, `deletedAt` is the only delete mechanism.

### 13.1 Data model

```swift
public struct Link: Hashable, Sendable, Codable {
    public var id: UUID                // minted at create; envelope's entityID
    public var endpointA: SidecarKey   // canonicalized via SidecarKey.init (lowercased for .contact)
    public var endpointB: SidecarKey
    public var note: String            // free text; "" when absent
    public var createdAt: Date         // immutable after creation
    public var modifiedAt: Date        // bumped on note edit, endpoint rewrite, or delete (derived)
    public var modifiedBy: String      // same source as SidecarCell.modifiedBy (derived)
    public var deletedAt: Date?        // nil = live; non-nil = soft-deleted
}
```

- **Endpoints are not order-normalized.** A→B and B→A are two distinct links (different `id`s). UI decides whether to render them as one edge.
- **Self-links allowed** (`endpointA == endpointB`). UI may reject; the package does not.
- **Clock source.** `Date()` at mutation time, no injectable clock.

### 13.2 Storage layout

Each link is one §5.2 sidecar envelope. The `fields` map carries five cells:

| Cell key       | Value (`JSONValue`)                              | Notes |
|----------------|--------------------------------------------------|-------|
| `endpointA`    | object: `{ "kind": "...", "id": "..." }`         | Mutable only by §13.4 Case-D rewrite |
| `endpointB`    | same                                             | Mutable only by §13.4 Case-D rewrite |
| `note`         | string                                           | The only user-driven mutable cell |
| `createdAt`    | string (ISO8601)                                 | Written once at create; never rewritten |
| `deletedAt`    | string (ISO8601) or `null`                       | Live when cell is absent OR `value: null`; soft-deleted when value is an ISO8601 string |

`Link` properties are **derived** from these cells:
- `id` ← envelope's `entityID`.
- `endpointA` / `endpointB` / `note` / `createdAt` ← cell `value`s.
- `modifiedAt` ← max `modifiedAt` across the four mutable cells (`createdAt`'s stamp is ignored).
- `modifiedBy` ← the `modifiedBy` of the cell contributing `modifiedAt` (lex tiebreak).
- `deletedAt` ← the `deletedAt` cell's `value` parsed as `Date`, or nil.

Single-sourced stamps: §5.3 cell stamps are ground truth; `Link.modifiedAt`/`modifiedBy`/`deletedAt` are projections. (Links predate the §7.3 field-instance pivot — they keep their own envelope shape because a link *is* an entity, not a field instance on another entity.)

**Codec.** `Link.init?(from envelope: SidecarEnvelope)` decodes the cells per the table; returns nil on any missing required cell or unparseable value. There is no inverse: mutations emit only the cells they change (§13.3), so on-disk stamps always reflect actual writes — round-tripping through a `Link` value would rewrite untouched cells.

**Read pattern.** `links(at: SidecarKey) -> [Link]` is O(N links) — scans `allKeys()` filtered to `.link`, decodes each, returns matches on either endpoint. `link(id:) -> Link?` is O(1). The app builds its own in-memory graph for fast queries (§14).

### 13.3 Mutations (one envelope write each)

| Op | Cells written | Cells preserved |
|---|---|---|
| Create | `endpointA`, `endpointB`, `note`, `createdAt` (all stamped now/deviceID) | n/a (new envelope) |
| Edit note | `note` only | endpoints, `createdAt`, `deletedAt` |
| Delete | `deletedAt` cell with ISO8601 value | `note`, endpoints, `createdAt` (so undelete preserves the note) |
| Undelete | `deletedAt` cell with `null` value | `note`, endpoints, `createdAt` |
| Case-D rewrite (§13.4) | affected endpoint cell(s) | everything else |

`merge(_:_:)` is untouched — link envelopes route through generic §5.3 LWW. A note-edit racing a delete converges per stamps; concurrent note edits converge per stamps. Same code path as contact/event envelopes in `reconcileSidecars()` (§6).

### 13.4 Case-D endpoint rewrite

When §3.3 Case D collapses loser UUID `L` into winner UUID `W`, any link with `endpointA` or `endpointB` equal to `(.contact, L)` must be rewritten to `(.contact, W)`. v1 does this — it is not deferred.

**Procedure.** After §3.3 merges `L`'s sidecar into `W`'s and deletes `L`'s file, the orchestrator scans all `.link` envelopes via `allKeys()`, decodes each, and for any link matching either endpoint writes a new envelope with the affected endpoint cell(s) rewritten — **one envelope write per link**, even when both endpoints change (e.g. a single reconcile pass collapsing `L1→W1` and `L2→W2`). The rewrite bumps `modifiedAt`/`modifiedBy` on rewritten cells only.

**Convergence is automatic.** Two devices independently running Case D produce identical endpoint payloads (lex-min winner per §3.3); concurrent stamps resolve via §5.3 cell LWW. A note-edit racing a rewrite hits a different cell — no clobber. After Case D, the rewritten endpoint cell is by construction the freshest, so derived `Link.modifiedAt`/`modifiedBy` reflect the rewriting device.

**Reporting and ordering.** Rewrite runs *after* the §3.3 winner sidecar is written and the loser file is deleted, *before* `reconcileContactIdentities()` returns. `IdentityReconcileReport.ContactOutcome.rewrittenLinkIDs` lists exactly which link envelopes were touched so app-side caches (§14) can re-read precisely those. `reconcileContactIdentity(localID:)` performs the same O(N links) scan scoped to that contact.

**Orphan endpoints** (link points at a UUID no live contact carries) are not rewritten and not considered stale — see §3.4. UI decides.

### 13.5 Public API

Added to `GuessWhoSync` (§7.3). Per §13.3, each method is one envelope read or write.

```swift
extension GuessWhoSync {
    /// Creates a link. Returns the minted Link. Never dedups (see below).
    public func addLink(from a: SidecarKey, to b: SidecarKey, note: String) throws -> Link

    /// Mutates the note. If the link is soft-deleted, also undeletes it
    /// (writes the deletedAt cell back to null). Silent no-op if missing.
    public func setLinkNote(id: UUID, note: String) throws

    /// Soft-deletes by writing deletedAt = now. Silent no-op if already soft-deleted.
    public func removeLink(id: UUID) throws

    /// Single link by id; nil if missing. Soft-deleted links are returned.
    public func link(id: UUID) throws -> Link?

    /// Every link with either endpoint matching `key`. Soft-deleted included.
    /// O(N links); apps may cache (§14).
    public func links(at key: SidecarKey) throws -> [Link]
}
```

Per Core Semantics, the package never filters by `deletedAt` — callers do. `addLink` never dedups: A→B can have multiple distinct `Link`s. UI that wants "edit existing if one exists, else create" calls `links(at:)` and decides.

### 13.6 Test plan

**Unit tests (new module `LinkTests`):**
- `LinkEnvelopeRoundTripTests`: build a `SidecarEnvelope` per §13.2 (live and soft-deleted variants), decode via `Link.init?(from:)`, assert all `Link` properties match (including derived `modifiedAt`/`modifiedBy`). `Link.init?` returns nil for any missing required cell.
- `LinkMergeTests` (§9.4 addition — link-shaped envelopes against the existing §5.3 merge, no new merge code): one test per row of §13.3's mutation table covering edit/delete/undelete/disjoint-cell stamp races.
- `LinkAPITests` (orchestrator-level, against in-memory stores):
  - `addLink` writes one envelope; `link(id:)` and `links(at: endpointA/B)` return it.
  - `addLink` twice with identical endpoints + note → two distinct ids (no-dedup policy).
  - `removeLink(X)` then `addLink(same endpoints)` → X soft-deleted, new one live, both surface via `links(at:)`.
  - `setLinkNote`: updates `note` cell; missing envelope is silent no-op; on a soft-deleted link, also flips `deletedAt` to null and stamps both cells fresh.
  - `removeLink`: writes `deletedAt` cell only; other cells byte-identical before/after; already-deleted is a silent no-op (no stamp churn).
  - `links(at:)` and `link(id:)` return soft-deleted links unchanged.
  - All endpoint type combos round-trip (event↔event, org↔contact, etc.) — package is type-agnostic.
- `LinkCaseDRewriteTests` (§9.3/§9.8 addition):
  - Pre-seed a link with `endpointB = (.contact, L)`. Run Case D collapsing `L → W`. Assert the link envelope now carries `endpointB = (.contact, W)`; `modifiedAt`/`modifiedBy` on the rewritten cell are bumped; `note` cell untouched. `IdentityReconcileReport.ContactOutcome.rewrittenLinkIDs == [link.id]`.
  - Single-contact `reconcileContactIdentity(localID:)` performs the same rewrite, and the returned `ContactOutcome.rewrittenLinkIDs` carries the same link UUID(s) as the all-contacts path.
  - No Case D ⇒ no rewrite (counter stays zero).
  - Multi-Case-D in one pass (two contacts): link with `endpointA = L1, endpointB = L2`, where `L1` and `L2` are losers belonging to two *different* contacts. After reconcile, link carries `(W1, W2)` in **exactly one** envelope write (assert via a counting wrapper around the in-memory sidecar store's `write`). Each contact's `ContactOutcome.rewrittenLinkIDs == [link.id]` (the same link appears in both outcomes — it was touched by both Case-Ds).
  - Multi-loser one contact: a single contact has two valid GuessWho URLs `L1` and `L2` collapsing to the same winner `W`; a link carries `endpointA = L1, endpointB = L2`. After reconcile, the link carries `(W, W)` in one envelope write; that one contact's `rewrittenLinkIDs == [link.id]` (the link appears once even though both its endpoints were rewritten).
  - Orphan endpoint untouched: pre-seed a link with `endpointA = (.contact, ORPHAN_UUID)` where no contact carries that UUID. Run Case D on an unrelated contact. The orphan-endpoint link is left byte-identical — not rewritten, not present in any `rewrittenLinkIDs` list.
  - Two devices independently rewrite the same link's endpoint: post-sync, LWW resolves to one stamp; endpoint value is identical on both devices.
  - Concurrent note-edit on device A and endpoint-rewrite on device B for the same link: after sync, both cells survive (disjoint cell LWW).

### 13.7 Out of scope and deferred

**Out of scope (spec choices, not deferrals):**
- **No link-typed schema** (e.g. `LinkType.metAt`). A link is two entities and a free-text note; richer taxonomy lives in the app's `note` payload.
- **No bidirectional dedup.** A→B and B→A are two distinct links.

**Deferred to v2:**
- **No link query index.** `links(at:)` is O(N links). App-side graph (§14) is the v1 mitigation.
- **No orphan-link GC.** Same stance as §3.4 orphan sidecars.

(Implementation order and smoke list: see §11 and §11.1.)

## 14. Future Performance Considerations

The package is intentionally disk-centric in v1. Every read goes to disk; every write is one atomic file operation. This keeps the package simple, makes correctness easy to reason about, and gives `NSFileVersion` a tight grip on conflict resolution. The cost is that operations like `links(at:)` scan all `.link` envelopes per call — O(N) on the link count.

For apps where read latency matters, the recommended pattern is an **app-side in-memory graph** that loads the full sidecar set at launch (`allKeys()` + `read(_:)` for each), serves reads from memory, and invalidates by re-reading changed envelopes after `reconcileSidecars()` returns. A personal address book's sidecar bytes fit in single-digit MB easily; the full hydration is fast.

This is intentionally an app concern, not a package concern. The package's job is "the disk is consistent and atomic"; the app's job is "the in-memory view is fast." Splitting it this way lets the package stay small and testable while leaving room for the app to choose its own caching strategy.

v2 of the package may grow opt-in caching primitives (e.g. an `InMemorySidecarCache` that wraps `SidecarStoreProtocol` and exposes change notifications) if the same caching code keeps getting written across apps.
