# Sidecar forward-compatibility contract

The sidecar is JSON-in-iCloud (see the storage/sync decision). Peers on
**different app versions** read, merge, and write the **same** synced
envelopes. This document states the guarantee that makes that safe — and the
rules a future change must keep — so that adding a new field `type` (or any
other additive schema change) never destroys data on a peer that does not yet
understand it.

Read this before you touch `SidecarCell`, `SidecarEnvelope`, `SidecarMerge`,
`SidecarField`, `SidecarFieldType`, or the store's read-modify-write.

## The guarantee

> A peer that cannot decode a cell **preserves it verbatim**. It does not show
> the field, but it keeps the bytes and syncs them back unchanged. The field
> reappears intact on any peer new enough to decode it. No data is lost.

Concretely: a `url`-typed custom field written by a newer build is invisible on
an older build that predates the `url` type, but the older build stores it,
merges it, and writes it back. When the envelope reaches an up-to-date build
again, the field is exactly as written.

"Unknown to this build" is always a **display** state, never a **storage**
state.

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
- **Keep changes additive.** Add a new `SidecarFieldType` case; do not
  repurpose or remove an existing raw value, and do not change an existing
  type's stored payload shape. A removed/renamed raw value turns existing
  stored cells into "unknown" on the very build that wrote them.
- **Do not bump `schemaVersion` for an additive change.** Merge refuses a
  version mismatch (`SidecarMerge.swift`), which would *stop* peers from
  converging — the opposite of what forward-compatibility needs. `schemaVersion`
  is reserved for a genuinely breaking envelope-shape change, which needs its
  own migration design and is out of scope here.

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

## Regression coverage

`Tests/GuessWhoSyncTests/SidecarForwardCompatTests.swift` proves the guarantee
directly: a cell with a `type` string this build does not know survives a full
load → mutate-a-neighbor → save → reload cycle, and survives a merge, with its
bytes intact — while `fields(at:)` omits it from the decoded list. If you break
a leg of the contract, that test fails.
