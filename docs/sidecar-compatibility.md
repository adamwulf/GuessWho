# Sidecar forward-compatibility contract

The sidecar is JSON-in-iCloud (see the storage/sync decision). Peers on
**different app versions** read, merge, and write the **same** synced
envelopes. This document states the guarantee that makes that safe — and the
rules a future change must keep — so that adding a new field `type` never
destroys data on a peer that does not yet understand it.

Read this before you touch `SidecarCell`, `SidecarEnvelope`, `SidecarMerge`,
`SidecarField`, `SidecarFieldType`, or the store's read-modify-write.

## The guarantee

> A field whose `type` a build does not understand is **hidden, not deleted**.
> The build keeps the cell, merges it, and writes it back; the field reappears
> on any peer new enough to decode it. The field is not lost (with one numeric
> caveat spelled out below).

Concretely: a `url`-typed custom field written by a newer build is invisible on
an older build that predates the `url` type, but the older build stores it,
merges it, and writes it back. When the envelope reaches an up-to-date build
again, the field is there with the same `type`, `field` name, value, and dates.

"Unknown to this build" is a **display** state, never a **storage** state — for
the things this guarantee covers. It covers exactly what rides *inside* a
cell's opaque inner value object; the boundary below says what that is and,
just as importantly, what it is not.

## What is and is not preserved

The unit that round-trips is the raw `SidecarCell` — its `value` (an opaque
`JSONValue`) plus the `modifiedAt` / `modifiedBy` / `deletedAt` stamps. A
cell's `type`, `field` name, payload, `createdAt`, and any *other keys a newer
build adds inside that value object* all live within the opaque `value`, so
their structure is carried through even when this build cannot interpret them —
with the one numeric caveat below.

**Preserved** (safe to add in a newer build):

- A new `SidecarFieldType` raw value (a new field `type`) — the case this
  guarantee exists for.
- A new key **inside** a cell's inner value object — it sits within the opaque
  `value` and round-trips. String and boolean values are exact; a *number*
  value is subject to the numeric caveat below.

**NOT preserved** — do not rely on these surviving an older build:

- A new key at the **`SidecarCell`** level (a sibling of `value` /
  `modifiedAt`) or at the **`SidecarEnvelope`** level. Both decode with fixed
  `CodingKeys`, so an unknown key there is dropped on re-encode.
- A cell that is malformed at the **cell** level (e.g. a bad `modifiedAt`, or a
  `value` that is not decodable) — the envelope decoder skips it by design and
  counts it in `cellsDroppedOnDecode`. Only an unknown **inner `type`** is
  preserved; a structurally broken cell is not.
- **Exact numeric values outside `Double`'s range.** `JSONValue` decodes every
  number as `Double`, so an inner-value *number* is round-tripped through a
  `Double`. Integers with magnitude ≤ 2^53 (and values a `Double` represents
  exactly) survive unchanged; an integer beyond 2^53 (e.g.
  `9007199254740993` → `9007199254740992`) or a high-precision float is
  silently rounded — real value loss, not just a different byte spelling.
  Today's sidecar values are strings, booleans, and small numbers (a `.blob`
  pointer's `byteCount`, well under 2^53), so this bites nothing shipping; a
  future writer must not stash a large-magnitude number inside a value object
  and expect an older peer to return it exactly.

The first two NOT-preserved items are genuine schema changes that need their own
migration (see the `schemaVersion` rule below); the third is a limit on what
kind of *value* you may safely add inside a cell.

## Why it holds — three legs

The guarantee is not incidental; it stands on three independent properties.
All three must remain true.

1. **Cells are opaque at the storage layer.** A `SidecarCell` decodes its
   `value` as an opaque `JSONValue` plus timestamps[^1]. The field's `type`,
   `field` name, and payload all live *inside* that value object; the cell
   layer never inspects them. So a cell with an unknown inner `type` decodes as
   a `SidecarCell` just like any other, and `SidecarEnvelope` keeps it in its
   `[String: SidecarCell]` map[^2].

2. **Merge is whole-cell, keyed by UUID.** `merge` walks the raw cell maps and
   applies last-writer-wins per UUID on the whole cell (`value` + stamps +
   `deletedAt` move together)[^3]. It never looks at the inner `type`. An
   unknown cell is kept when the peer lacks it and LWW'd whole when both hold
   it.

3. **The store's read-modify-write copies the raw cell map.** `addField`,
   `setField`, and `deleteField` each read the whole envelope's
   `[String: SidecarCell]`, change or add the **one** cell being written, and
   write the whole map back[^4]. Cells this build cannot decode ride along
   untouched. Nothing is ever rebuilt from the decoded field list.

`SidecarField.decode` returning nil for an unknown `type`[^5], and
`GuessWhoSync.fields(at:)` skipping such cells[^6], act **only** on the decoded
list a caller sees. They remove the field from view, never from the envelope.

[^1]: [SidecarCell.init(from:) decodes value as JSONValue](../Sources/GuessWhoSync/SidecarCell.swift:SidecarCell)
[^2]: [SidecarEnvelope holds fields as a raw cell map](../Sources/GuessWhoSync/SidecarEnvelope.swift:SidecarEnvelope)
[^3]: [merge — whole-cell LWW by UUID](../Sources/GuessWhoSync/SidecarMerge.swift:merge)
[^4]: [Field-instance mutations read-modify-write the raw map](../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.addField)
[^5]: [SidecarField.decode returns nil for an unknown type](../Sources/GuessWhoSync/SidecarField.swift:SidecarField.decode)
[^6]: [GuessWhoSync.fields(at:) omits unknown cells from the list only](../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.fields)

## The contract — rules future changes MUST keep

- **Never rebuild an envelope from decoded fields.** Persisting must copy the
  raw `[String: SidecarCell]` map (read-modify-write of one cell), so unknown
  cells survive. A "re-encode everything we parsed" save path would silently
  drop every newer-typed cell an older build touches. This is the single most
  important rule.
- **Never delete a cell just because it will not decode.** `decode` returning
  nil, or `type(of:)` returning nil, is not permission to remove the cell.
- **Keep merge operating on raw cells.** Do not decode-then-remerge; do not
  merge field-by-decoded-field. Whole-cell LWW by UUID is what carries unknown
  cells through.
- **Keep additions inside the cell value.** The safe additions are a new
  `SidecarFieldType` case and a new key **inside** a cell's inner value object
  (see the boundary above). Do not repurpose or remove an existing raw value,
  and do not change an existing type's stored payload shape — a removed/renamed
  raw value turns existing stored cells into "unknown" on the very build that
  wrote them. Adding a key at the `SidecarCell` or `SidecarEnvelope` level is
  NOT forward-compatible; older builds drop it. That is a `schemaVersion`
  migration, not this guarantee.
- **Do not bump `schemaVersion` for an in-cell additive change.** Merge refuses
  a version mismatch[^3], which would *stop* peers from converging — the
  opposite of what forward-compatibility needs. `schemaVersion` is reserved for
  a genuinely breaking envelope-shape change (a new cell/envelope-level key you
  need older peers to preserve, a payload-shape change), which needs its own
  migration design and is out of scope here.

## Adding a new field `type` (worked example)

1. Add the `case` to `SidecarFieldType`. Let the compiler enumerate the
   exhaustive `switch`es to update (validation, wire mapping, payload, UI).
2. Validate the payload shape in `SidecarField.validate` — follow `.date`,
   which additionally checks the string's format.
3. Map it across the wire (`WireMapping.wireFieldType` /
   `ToolDispatcher.wireWritableFieldType`), the CLI `--type`, and the MCP tool
   schema. These string-keyed sites are NOT compiler-checked — update them by
   hand.
4. Render it in the app's custom-field row.
5. Do **not** add a version gate or a "drop if unknown" path. The three legs
   above already make older peers safe: they preserve and round-trip the new
   cell and simply do not display it.

## Adding a new KIND (a new directory)

The guarantee above is about cells inside an envelope a build already reads. A
new `SidecarKind` is a different question: it adds a **directory** older builds
have never heard of, and cell-level forward compatibility says nothing about
whether they leave that directory alone. They do, and it rests on one property:

> Every store operation reaches a kind's directory through
> `SidecarKind.directoryName`, iterating `SidecarKind.allCases`[^7][^8]. A
> directory a build has no kind for is never listed — so it is never read,
> merged, rewritten, prefetched, or removed by that build.

The file watcher maps such a path back through the same mapping and finds no
kind[^9], which makes that batch globally unknown: each repository does one
debounced, **read-only** reload. Because nothing on that path writes, nothing
echoes back through the watcher, so an older build pays one reload per burst of
newer-kind writes and nothing more.

Rules for the next new kind:

- Add the `case` and its `directoryName`; the compiler enumerates the
  exhaustive `switch`es. Do not add a hand-written list of kinds anywhere — the
  listing, the scoped listing, and the prefetch derive from `allCases`.
- Add the kind's line to the frozen `shippedDirectoryNames` table in
  `SidecarStoreCompatibilityTests`. A directory name is a synced on-disk
  contract: once a build ships it, never rename it.
- Keep any new subscriber refresh path read-only, or prove — with a test that
  counts writes across the echo — that its writes settle. The one existing
  exception is `ContactsRepository`'s group-identity resolution[^10].
- If the kind has cells whose loss would be destructive (a deletion marker, a
  parent assignment), treat an envelope that decoded with dropped cells as
  untrustworthy rather than as "those cells are absent". See
  [`group-folders.md`](group-folders.md#untrustworthy-data).

`SidecarStoreCompatibilityTests` proves the property on the current build with
a directory name **no** build knows (`future-kind`), which is the same code path
an older build takes for a directory a newer build introduced — and keeps
protecting the next new kind after this one ships. It asserts, against a digest
of every file under the root, that read-only operations change nothing and that
each mutation changes exactly the one file it names.

[^7]: [The one kind-to-directory mapping](../Sources/GuessWhoSync/SidecarKind.swift:SidecarKind.directoryName)
[^8]: [Enumeration lists known kinds only](../Sources/GuessWhoSync/FileSystemSidecarStore.swift:FileSystemSidecarStore.allKeys)
[^9]: [Watcher directory-name mapping](../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.sidecarKind)
[^10]: [The watcher path's one bounded write exception](../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository.refreshFromSidecarChange)

## Regression coverage

`Tests/GuessWhoSyncTests/SidecarForwardCompatTests.swift` proves the guarantee
directly. A cell with a `type` string this build does not know:

- survives the store's read-modify-write (adding a neighbor field leaves it
  untouched) and a whole-cell merge, in-memory; and
- survives a real `JSONEncoder`/`JSONDecoder` round-trip of the envelope —
  including an extra unknown key placed *inside* its value object — proving the
  serialization leg, not just the in-memory objects;

while `fields(at:)` omits it from the decoded list throughout. If you break a
leg of the contract, one of these tests fails.
