# Contacts unified fetch key audit (batch 2 / B2-1)

`CNContactStoreAdapter.fetchAll()` is the authoritative unified-contact load
for `ContactsRepository`. This audit traces every property mapped by
`CNContactStoreAdapter.toContact(_:)` through the package, app, and CLI/MCP
projections. The rule is conservative: an optional Contacts key stays if any
consumer reads it, if editing must round-trip it, or if it participates in
identity/reconciliation.

## Result

The explicit request lost one descriptor:

- **Removed from `keys`: `CNContactIdentifierKey`.** The Contacts SDK declares
  it under “Properties that are always fetched.” `toContact(_:)` still reads
  `CNContact.identifier`, and `Contact.localID` / `ContactID` / repository
  reconciliation remain unchanged. This removes a redundant request
  descriptor, not the identifier value.

No optional property key was safe to remove. The current set is therefore the
minimum complete set for the current `Contact` read model. In particular,
`CNContactNoteKey` remains: the app detail and editor surfaces read and write
the Apple contact note. The CLI/MCP mapper intentionally excludes that value
from `WireContact`; excluding it from the wire does not make it unused by the
app.

Full-size and thumbnail image bytes remain absent from the bulk key set. They
already use the on-demand `imageKeys` / `thumbnailKeys` paths; the bulk fetch
requests only `CNContactImageDataAvailableKey` so photo UI can choose the
correct path.

## Kept optional keys and consumers

| Keys | Why they stay |
| --- | --- |
| `CNContactTypeKey` | People/organization list partitioning, organization association logic, detail/debug UI, and `WireContact.kind`. |
| Prefix, given, middle, family, previous-family, suffix, nickname | `Contact.displayName`, list sorting/sectioning, search, detail/editor fields, LinkedIn matching/apply, and the full CLI/MCP card. |
| Phonetic given, middle, and family names | App phonetic-name editor, package search, and CLI/MCP read/write fields. |
| Job title, department, organization, phonetic organization | List subtitles, detail rows, organization/department navigation and edits, search/LinkedIn matching, and CLI/MCP projections. |
| `CNContactNoteKey` | App detail and contact editor. Deliberately never projected by CLI/MCP. |
| Phone numbers | Detail actions, editor, search, LinkedIn apply, and CLI/MCP projections and entry-level writes. |
| Email addresses | Detail actions, repository email index/matching, editor, LinkedIn apply, Maps contact matching, and CLI/MCP projections and writes. |
| Postal addresses | Detail/Maps actions, editor, and CLI/MCP projections and writes. |
| URL addresses | User-visible web rows, LinkedIn matching, editor, CLI/MCP user-visible URLs, and—critically—the internal `guesswho://contact/…` identity/reconciliation contract. |
| Gregorian birthday | Detail/editor and CLI/MCP projection/write. |
| Non-Gregorian birthday | App detail rendering and lossless contact-card editing. |
| Other dates | App detail/editor and CLI/MCP projection and entry-level writes. |
| Social profiles | App detail/editor, LinkedIn matching/apply, and CLI/MCP projection and entry-level writes. |
| Instant-message addresses | App detail/editor and CLI/MCP projection and entry-level writes. |
| Contact relations | App related-name rows and best-effort contact navigation, repository reverse-relation queries, editor, and CLI/MCP projection and entry-level writes. |
| `CNContactImageDataAvailableKey` | Detail/list photo loading decisions; bytes themselves stay on demand. |

## Completeness and write-roundtrip constraint

`Contact` is not merely a list-row DTO. The repository hands the same value to
the detail view and `ContactEditModel`, and `CNContactStoreAdapter.apply(_:to:)`
writes its fields back to a mutable Contacts record. Dropping an optional key
would therefore do more than hide a row: an unrelated edit could replace an
unfetched property with `Contact`'s empty default. Keeping every optional key
listed above preserves both read completeness and lossless read-modify-write
behavior.

`CNContactStoreAdapterTests.roundTripPreservesEveryField` covers the complete
CN-to-model-to-CN mapping. `trimmedFetchKeysCoverEveryMappedConsumerField`
asserts the exact optional-key contract, including the note key and the absence
of bulk image bytes and the redundant always-fetched identifier descriptor.
