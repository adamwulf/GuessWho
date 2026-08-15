# CLI command parity — full `guesswho` CLI ↔ MCP tool parity, with a testable core

**Author:** researcher agent `cli-parity-research` · **Date:** 2026-08-14 ·
**Status:** research/plan — no production code changed. Product decisions
folded in 2026-08-14 (per-field flags default over `--json`; one shared
core for CLI + MCP; declined-delete exit 10; favorite flags; note-body
input) — see §6 for the resolved list.
All `file:line` anchors below were read at commit `ba7ac6e` ("Merge agent
agent-6db0f73e work"); symbol names are given alongside so anchors survive
line drift. Verification baseline on this tree: `swift test` exits 0 —
311 XCTest + 863 swift-testing tests, 0 failures (run 2026-08-14).

---

## 1. Goal & scope

**Goal:** every MCP tool has an equivalent terminal command, and every
terminal tool-command maps to an MCP tool — full 63-tool parity — with the
per-command request-building and response-rendering logic living in a
package module where `swift test` exercises the PRODUCTION code path (no
duplicated logic in tests, no live app needed).

Current gap: the MCP surface exposes **63 tools (22 read + 41 write)** —
pinned by both the enum (`MCPTool`,
`Sources/GuessWhoMCPWire/MCPTool.swift:20-102`) and the inventory test
(`WireRequestCreateTests.testToolInventoryCountAndReadWriteSplit`,
`Tests/GuessWhoMCPWireTests/WireFramingTests.swift:435-441`). The CLI
exposes **three** tool commands — `contacts search`, `contacts get-photo`,
`contacts set-photo` (`ContactsCommand`,
`App/guesswho-cli/ContactsCommand.swift:7-13`; photo commands added in
commit `9106c51`) — plus the non-tool `run` and `probe` subcommands
(`GuessWhoCLI`, `App/guesswho-cli/GuessWhoCLI.swift:17-24`). So **60
commands are missing**.

**IN scope**

- A CLI command for **all 63** MCP tools, including the
  confirmation-gated `contacts_delete` (see §4 and §6 — the CLI sends the
  request and waits on the app-side dialog; the deferred answer rides the
  normal response pipe, `MCPPipeHost` out-of-band delivery,
  `Sources/GuessWhoMCPTransport/MCPPipeHost.swift:72`, wired at
  `App/GuessWho/Support/MCPHostController.swift:172`).
- Moving the per-command logic into a new package target
  (`GuessWhoCLICore`) so `swift test` reaches it (§3).
- A **parity guard test** that fails whenever an `MCPTool` case exists
  without a registered CLI command, or vice-versa (§3.4).
- A banned-vocabulary scan over all CLI help text (the product principle:
  no "sidecar / unlink / EventKit / link-to-existing" in user-facing copy
  — same mechanism as `BannedVocabularyTests`,
  `Tests/GuessWhoMCPCoreTests/BannedVocabularyTests.swift:14-27`).
- Updating the "Terminal contact commands" section of `docs/cli-mcp.md`
  (currently documents only the three commands, `docs/cli-mcp.md:121-144`).

**OUT of scope**

- Any MCP-side change: no new tools, no schema changes, no dispatcher
  changes. The app host is untouched.
- Apple `CNContact.note` exposure — **never**. The CLI inherits the wire
  exclusion for free because it can only send `WireRequest`s and the wire
  has no note field in any DTO or request (`WireDTOs.swift:3-28`;
  note-shaped args rejected at `WireRequest.swift:953-958`). No CLI flag
  or command may add one.
- Human-friendly table/interactive output formats (JSON-first, §4; a
  `--format` option is a possible follow-on, §6).
- The test-suite follow-ons identified by the audit (§3.1) that are not
  needed for CLI parity (e.g. an engine-backed event/guide source for the
  MCP tests) — inventoried, not scheduled here.

**Access + safety model carried over unchanged:** every CLI command rides
`RequestOrigin.cli` helper ids (`ContactsCommand.swift:138`), so the app's
per-call tri-state gate (`cliAccessMode`, enforced server-side —
`WireEnvironment.swift:115-128`, `MCPDataSources.swift:224-237`) governs
reads and writes exactly as it does today; write budget, idempotency
replay, single-flight, and audit all live app-side and apply to CLI
traffic with zero new code.

---

## 2. Command inventory — all 63 tools

**Derivation rule (also the parity-guard rule):** the CLI command path is
derived mechanically from the tool name — the text before the first
underscore is the noun group; the rest becomes the hyphenated verb
(`contacts_list_custom_fields` → `guesswho contacts list-custom-fields`).
The three shipped commands already match this rule exactly
(`contacts_search` → `contacts search`, `contacts_get_photo` →
`contacts get-photo`, `contacts_set_photo` → `contacts set-photo`), and a
pure function of `MCPTool.rawValue` can compute the expected path — which
is what makes the parity test one loop (§3.4).

**Argument rules (uniform):**

- Required scalar arguments → **positionals**, in the tool schema's
  `required` order (ids first — the shipped precedent:
  `ContactsGetPhoto.contactId` is positional,
  `ContactsCommand.swift:50-51`).
- Optional scalars → `--kebab-case` flags named after the wire argument
  (`limit` → `--limit`, `idempotencyToken` → `--idempotency-token` —
  shipped precedent `ContactsCommand.swift:104-105`).
- Arrays of ids → variadic positionals (`groups add-members <group-id>
  <contact-id> ...`).
- Booleans → a required **`--flag` / `--no-flag` pair** (an error when
  neither is given — the wire is desired-state, not a toggle). The three
  favorite commands use `--favorite` / `--no-favorite`
  (`ArgumentParser` `@Flag(inversion: .prefixedNo)`; decided 2026-08-14,
  §6 #6).
- **Structured objects → per-field flags by DEFAULT** — one `--kebab-case`
  flag per wire field; an omitted flag = omitted (the wire's PATCH rule,
  `WireContactScalarFields`; empty string clears). `--json` is an
  OPTIONAL alternative on `contacts create` and on the structured
  add/delete tools, and the PRIMARY path for the three structured *edit*
  tools (which must supply two full objects — 18 per-field flags is why).
  Both paths build the SAME `[String: Value]` bag and funnel through
  `WireRequest.create`, so there is no logic fork (decided 2026-08-14, §6
  #3; see the input-convention note below the table).
- **Large text / JSON inputs** (a note `--body`, any `--json`) accept an
  inline value, `-` for stdin, or a `--<field>-file <path>` companion
  flag. At most one input reads stdin per call. This mirrors the shipped
  photo commands' `<file | ->` handling (`ContactsCommand.swift:53`,
  `:101`) and removes the shell-quoting hazard of an inline JSON string.
- Every write command gets `--idempotency-token`.
- Every paged read gets `--limit` / `--cursor`.

Output shapes: **JSON** = the payload encoded by the wire's one agent
encoder (stable sorted keys, `WireResponse.agentJSONEncoder`,
`Sources/GuessWhoMCPWire/WireResponse.swift:267-271`) + trailing newline
on stdout; **bytes** = raw photo bytes on stdout; **ack** = the fixed
`WireAckMessage` text on stdout. Errors always go to stderr (§4).

### contacts (30 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `contacts_search` | `contacts search` ✅ shipped | `<query>` | `--limit --cursor` | args | JSON page of contact summaries |
| `contacts_list` | `contacts list` | — | `--kind --favorites-only --group-id --limit --cursor` | args | JSON page of contact summaries |
| `contacts_get` | `contacts get` | `<contact-id>` | — | args | JSON contact card |
| `contacts_get_photo` | `contacts get-photo` ✅ shipped | `<contact-id>` | `-o/--output <file\|->` | args | bytes → stdout or file |
| `contacts_list_notes` | `contacts list-notes` | `<contact-id>` | `--limit --cursor` | args | JSON page of notes |
| `contacts_list_custom_fields` | `contacts list-custom-fields` | `<contact-id>` | `--limit --cursor` | args | JSON page of fields |
| `contacts_list_groups` | `contacts list-groups` | — | `--limit --cursor` | args | JSON page of groups |
| `contacts_create` | `contacts create` | — | `--kind` + one flag per scalar field (`--given-name`, `--family-name`, `--organization`, `--job-title`, `--birthday`, …) + `--json`/`--json-file` for the list fields + `--idempotency-token` | flags (+ optional `--json` for lists) | JSON contact card (echo) |
| `contacts_update` | `contacts update` | `<contact-id>` | `--kind` + the same scalar flags (scalars-only by wire construction — `WireContactScalarFields`, `WireDTOs.swift:315-336`) + `--idempotency-token` | args | JSON contact card (echo) |
| `contacts_delete` | `contacts delete` | `<contact-id>` | `--idempotency-token` | args | waits on the in-app confirmation, up to the tool's 300 s timeout (`MCPTool.timeout`, `MCPTool.swift:200-205`); approved → ack `contactDeleted` on stdout, exit 0; declined → stderr note, **exit 10** (§4, §6 #1) |
| `contacts_set_photo` | `contacts set-photo` ✅ shipped | `<contact-id>` | `-i/--input <file\|->` `--idempotency-token` | bytes ← stdin or file | ack (`photoSet`) |
| `contacts_delete_photo` | `contacts delete-photo` | `<contact-id>` | `--idempotency-token` | args | ack (`photoDeleted`) |
| `contacts_add_value` | `contacts add-value` | `<contact-id> <field> <value>` (`field` ∈ `phone email url related_name date` — `WireContactListField`, `WireRequest.swift:7-13`) | `--label --idempotency-token` | args | JSON contact card (echo) |
| `contacts_delete_value` | `contacts delete-value` | `<contact-id> <field> <value>` | `--idempotency-token` | args | JSON contact card (echo) |
| `contacts_edit_value` | `contacts edit-value` | `<contact-id> <field> <current-value> <new-value>` | `--new-label --idempotency-token` | args | JSON contact card (echo) |
| `contacts_add_postal_address` | `contacts add-postal-address` | `<contact-id>` | postal field flags (§2 note) `--idempotency-token` — or `--json`/`--json-file` | flags (or `--json`) | JSON contact card (echo) |
| `contacts_edit_postal_address` | `contacts edit-postal-address` | `<contact-id>` | `--json`/`--json-file` = `{"currentAddress":…,"newAddress":…}` `--idempotency-token` — or `--current-*`/`--new-*` flags | `--json` primary (18 per-field flags otherwise) | JSON contact card (echo) |
| `contacts_delete_postal_address` | `contacts delete-postal-address` | `<contact-id>` | postal field flags (full match) `--idempotency-token` — or `--json` | flags (or `--json`) | JSON contact card (echo) |
| `contacts_add_social_profile` | `contacts add-social-profile` | `<contact-id>` | `--label --service --username --url` `--idempotency-token` — or `--json` | flags (or `--json`) | JSON contact card (echo) |
| `contacts_edit_social_profile` | `contacts edit-social-profile` | `<contact-id>` | `--json`/`--json-file` = `{"currentProfile":…,"newProfile":…}` `--idempotency-token` — or `--current-*`/`--new-*` flags | `--json` primary | JSON contact card (echo) |
| `contacts_delete_social_profile` | `contacts delete-social-profile` | `<contact-id>` | `--label --service --username --url` (full match) `--idempotency-token` — or `--json` | flags (or `--json`) | JSON contact card (echo) |
| `contacts_add_instant_message` | `contacts add-instant-message` | `<contact-id>` | `--label --service --username` `--idempotency-token` — or `--json` | flags (or `--json`) | JSON contact card (echo) |
| `contacts_edit_instant_message` | `contacts edit-instant-message` | `<contact-id>` | `--json`/`--json-file` = `{"currentInstantMessage":…,"newInstantMessage":…}` `--idempotency-token` — or `--current-*`/`--new-*` flags | `--json` primary | JSON contact card (echo) |
| `contacts_delete_instant_message` | `contacts delete-instant-message` | `<contact-id>` | `--label --service --username` (full match) `--idempotency-token` — or `--json` | flags (or `--json`) | JSON contact card (echo) |
| `contacts_add_note` | `contacts add-note` | `<contact-id>` | `--body` (inline / `-` stdin / `--body-file`) `--idempotency-token` | flag / stdin / file (§2 note, §6 #4) | JSON note (echo) |
| `contacts_edit_note` | `contacts edit-note` | `<contact-id> <note-id>` | `--body` (inline / `-` stdin / `--body-file`) `--idempotency-token` | flag / stdin / file | JSON note (echo) |
| `contacts_delete_note` | `contacts delete-note` | `<contact-id> <note-id>` | `--idempotency-token` | args | ack (`noteDeleted`) |
| `contacts_set_custom_field` | `contacts set-custom-field` | `<contact-id> <name> <value>` | `--type (text\|multilineNote\|date\|checkbox) --idempotency-token` | args | JSON custom field (echo) |
| `contacts_delete_custom_field` | `contacts delete-custom-field` | `<contact-id> <field-id>` | `--idempotency-token` | args | ack (`fieldDeleted`) |
| `contacts_set_favorite` | `contacts set-favorite` | `<contact-id>` | `--favorite`/`--no-favorite` (required) `--idempotency-token` | args | ack (`favoriteSet`/`favoriteCleared`) |

### organizations (4 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `organizations_list_members` | `organizations list-members` | `<organization-id>` | `--limit --cursor` | args | JSON page of contact summaries |
| `organizations_list_departments` | `organizations list-departments` | `<organization-id>` | `--limit --cursor` | args | JSON page of department names |
| `organizations_list_department_members` | `organizations list-department-members` | `<organization-id> <department>` | `--limit --cursor` | args | JSON page of contact summaries |
| `organizations_rename_department` | `organizations rename-department` | `<organization-id> <old-name> <new-name>` | `--idempotency-token` | args | JSON `{affectedCount}` (`WireDepartmentRenameResult`, `WireDTOs.swift:45-51`) |

### groups (7 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `groups_list_for_contact` | `groups list-for-contact` | `<contact-id>` | `--limit --cursor` | args | JSON page of groups |
| `groups_create` | `groups create` | `<name>` | `--idempotency-token` | args | JSON group (echo) |
| `groups_rename` | `groups rename` | `<group-id> <name>` | `--idempotency-token` | args | JSON group (echo) |
| `groups_delete` | `groups delete` | `<group-id>` | `--idempotency-token` | args | ack (`groupDeleted`) |
| `groups_add_members` | `groups add-members` | `<group-id> <contact-id> ...` (1–200, variadic) | `--idempotency-token` | args | JSON membership result (`WireGroupMembershipResult`, `WireDTOs.swift:582-598`) |
| `groups_remove_members` | `groups remove-members` | `<group-id> <contact-id> ...` | `--idempotency-token` | args | JSON membership result |
| `groups_set_favorite` | `groups set-favorite` | `<group-id>` | `--favorite`/`--no-favorite` (required) `--idempotency-token` | args | JSON group (echo) |

### events (6 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `events_list` | `events list` | `<start-date> <end-date>` (ISO 8601, ≤ 1-year window) | `--limit --cursor` | args | JSON page of event summaries |
| `events_get` | `events get` | `<event-id>` | — | args | JSON event |
| `events_list_tags` | `events list-tags` | `<event-id>` | `--limit --cursor` | args | JSON page of tags |
| `events_add_tag` | `events add-tag` | `<event-id> <text>` | `--idempotency-token` | args | JSON tag (echo) |
| `events_edit_tag` | `events edit-tag` | `<event-id> <tag-id> <text>` | `--idempotency-token` | args | JSON tag (echo) |
| `events_delete_tag` | `events delete-tag` | `<event-id> <tag-id>` | `--idempotency-token` | args | ack (`tagDeleted`) |

### guides (6 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `guides_list` | `guides list` | — | `--limit --cursor` | args | JSON page of guides |
| `guides_get` | `guides get` | `<guide-id>` | — | args | JSON guide |
| `guides_list_for_place` | `guides list-for-place` | `<place-id>` | `--limit --cursor` | args | JSON page of guides |
| `guides_create` | `guides create` | `<name>` | `--json` (the `places` array) `--idempotency-token` | args / `--json` | JSON guide (echo) |
| `guides_delete` | `guides delete` | `<guide-id>` | `--idempotency-token` | args | ack (`guideDeleted`) |
| `guides_reorder_places` | `guides reorder-places` | `<guide-id> <place-id> ...` (variadic, every place) | `--idempotency-token` | args | ack (`placesReordered`) |

### places (4 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `places_list` | `places list` | — | `--guide-id --limit --cursor` | args | JSON page of places |
| `places_search` | `places search` | `<query>` | `--limit --cursor` | args | JSON page of places |
| `places_get` | `places get` | `<place-id>` | — | args | JSON place |
| `places_delete` | `places delete` | `<place-id>` | `--idempotency-token` | args | ack (`placeDeleted`) |

### links (3 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `links_list` | `links list` | `<id> <kind>` (`kind` ∈ `person organization event place`) | `--limit --cursor` | args | JSON page of connections |
| `links_create` | `links create` | `<from-id> <from-kind> <to-id> <to-kind>` | `--note --idempotency-token` | args | JSON connection (echo) |
| `links_delete` | `links delete` | `<link-id>` | `--idempotency-token` | args | ack (`linkRemoved`) |

### favorites (3 tools)

| MCP tool | CLI command | Positionals | Options | Input | Output |
|---|---|---|---|---|---|
| `favorites_list` | `favorites list` | — | `--limit --cursor` | args | JSON page of favorites |
| `favorites_set` | `favorites set` | `<kind> <id>` (`kind` ∈ `contact event group guide place`) | `--favorite`/`--no-favorite` (required) `--idempotency-token` | args | ack (`genericFavoriteSet`/`genericFavoriteCleared`) |
| `favorites_reorder` | `favorites reorder` | — | `--json`/`--json-file` (the complete `favorites` array of `{kind,id}`) `--idempotency-token` | `--json` (inline / `-` stdin / file) | ack (`favoritesReordered`) |

**Non-tool commands (exempt from the parity guard):** `run` (MCP stdio
relay), `probe` (packaging diagnostic) — both exist today
(`GuessWhoCLI.swift:66-161`). The relay-only `guesswho_status`
pseudo-tool (`RelayMCPServer.statusToolName`,
`Sources/GuessWhoMCPTransport/RelayMCPServer.swift:24`) is not an
`MCPTool` case and gets no command; `probe` is its terminal counterpart.

### Per-field flags (default) and the `--json` escape hatch

**Decision (Adam, 2026-08-14): per-field flags are the default; `--json`
is an optional path, not the primary one.** Per-field flags are the more
reliable interface for an AI agent that shells out — no nested
shell-quoting of a JSON blob (the top cause of malformed agent shell
commands), and `--help` enumerates every field so the schema is
discoverable rather than guessed. The replace-vs-merge ambiguity of a
whole-object `--json` on a PATCH is also removed: an omitted flag = key
absent = unchanged; an explicit empty string clears (the wire's
`WireContactScalarFields` PATCH rule).

**The front-end choice costs nothing in shared logic.** Per-field flags
and a `--json` payload BOTH assemble the same `[String: Value]` argument
bag, and BOTH funnel through the SAME production builder —
`WireRequest.create(helperId:messageId:parameters:)`
(`Sources/GuessWhoMCPWire/WireRequest.swift:409-784`) — so required
fields, closed field sets (`additionalProperties: false`,
`MCPTool.closedSchema`, `MCPTool.swift:244-252`), the note-argument
rejection (`WireRequest.swift:953-958`), and the exact error messages are
the shared, already-tested production path (`WireRequestCreateTests`,
`WireFramingTests.swift:235-960`). Per-field flags for a structured
object write into that object's nested keys in the bag
(e.g. `--street` → `["address": .object(["street": .string(...)])]`).

Where `--json` is offered (and why):

1. **`contacts create`** — the list fields (phones/emails/…) are arrays;
   `--json`/`--json-file` is the compact way to seed a brand-new card.
   Scalars stay per-field flags.
2. **Structured *edit* (`edit-postal-address` / `-social-profile` /
   `-instant-message`)** — an edit must supply BOTH a full current object
   (the exact match) AND a full new object. As per-field flags that is
   `--current-street … --new-street …`, ~18 flags; `--json`/`--json-file`
   (`{"currentAddress":…,"newAddress":…}`) is the primary path, and the
   canonical object is exactly what `guesswho contacts get` prints, so the
   user copies it out of one command into the next
   (`docs/cli-mcp.md:510-519`). Per-field `--current-*`/`--new-*` stay
   available.
3. **Structured *add*/*delete* and `favorites reorder`** — per-field flags
   (add/delete) or a small array (`reorder`); `--json` is the optional
   alternative for copy-paste from `contacts get`.

`--json` accepts an inline value, `-` for stdin, or `--json-file <path>`;
the stdin/file forms compose with `jq` and heredocs and carry no
shell-quoting hazard. Supplying a key BOTH via a flag and via `--json` is
a usage error, never a silent merge.

**Structured-entry field flags (once, referenced by the table):**

- **postal** (`WirePostalAddress`, `WireDTOs.swift`): `--label --street
  --sub-locality --city --sub-administrative-area --state --postal-code
  --country --iso-country-code`. The five non-optional wire strings
  (`street`, `city`, `state`, `postalCode`, `country`) default to the
  empty string when their flag is omitted, so the server's "at least one
  component non-empty" rule (not the CLI) is the gate.
- **social** (`WireSocialProfile`): `--label --service --username --url`
  (at least one of the latter three non-empty, server-enforced).
- **instant message** (`WireInstantMessage`): `--label --service
  --username` (`username` required, non-empty).

Delete matches the complete canonical representation, so delete takes the
full flag set (or `--json`) exactly like add.

---

## 3. Testability

### 3.1 Audit — where today's MCP tests ride production vs. reimplemented logic

**The split, as designed.** The suite has two fixtures:

- **`MCPProductionFixture`** wires the REAL production stack: the real
  `ToolDispatcher`, the real `ContactsRepository`, the real `GuessWhoSync`
  engine over a real on-disk `FileSystemSidecarStore`, and the real
  on-disk `FavoritesStore` — with exactly ONE substituted boundary, the
  OS Contacts store (`RecordingContactStore` wrapping
  `InMemoryContactStore`; headless `swift test` has no CNContactStore/TCC)
  (`Tests/GuessWhoMCPCoreTests/MCPProductionHarness.swift:15-36` and
  `:436-482`). The recording store "implements NO repository rules"
  (`MCPProductionHarness.swift:48-68`) — it delegates, records, and
  injects one-shot faults. The favorite surface is a one-line-per-method
  delegation to the real store (`MCPFavoriteStoreAdapter`,
  `MCPProductionHarness.swift:307-334`). The only other test-only
  substitution is the keychain blob-crypto seam
  (`MCPProductionHarness.swift:2-10`).
- **`Fixture` (Fakes.swift)** uses scripted sources, and — importantly —
  polices its own limits: any test that accidentally leans on a
  production semantic the legacy source doesn't model hits an `XCTFail`
  tripwire (`unexpectedLegacySemanticPath`,
  `Tests/GuessWhoMCPCoreTests/Fakes.swift:44-69`; applied to
  organization matching/departments/photo/membership/renameDepartment at
  `Fakes.swift:248-280`, `:316-327`, `:566-569`, `:619-624`, and to
  favorite set/reorder CAS at `Fakes.swift:838-858`).

**What genuinely rides production even under the scripted fixture.** The
assertion targets of most scripted-fixture tests are dispatcher/mapper
logic, which is production code in `GuessWhoMCPCore`:

- contacts_list's deterministic sort + filters
  (`ToolDispatcher.contactsList`,
  `Sources/GuessWhoMCPCore/ToolDispatcher.swift:495-550`), search
  matching via the production `Contact.matches(searchQuery:)` with the
  identity-URL pre-filter (`ToolDispatcher.contactsSearch`,
  `ToolDispatcher.swift:458-470`), pagination/caps
  (`ToolDispatcher.swift:4823` MARK), gates/budgets/idempotency/
  single-flight (`ToolDispatcher.swift:60-97`, `:1457` MARK), and the
  single-entry match rules (0-match `notFound` / multi-match `ambiguous`,
  canonical date matching — `ToolDispatcher.swift:2700-2829`).
- DTO mapping is production `WireMapping`, which re-drops tombstones and
  `.blob` fields defensively even if a source leaks them
  (`WireMapping.customField`,
  `Sources/GuessWhoMCPCore/WireMapping.swift:154-171`).
- Link tests run a REAL engine over a real temp-directory store even
  inside the scripted fixture (`EngineLinkSource`, `Fakes.swift:861-887`;
  `Fixture.makeLinkEngine`, `Fakes.swift:974-985`; stated as the point of
  the suite, `Tests/GuessWhoMCPCoreTests/LinkToolTests.swift:6-15`).

**Suites pinned to the production fixture** (their headers say so, and the
fixture calls confirm it): photos
(`ContactPhotoToolTests.swift:7-15`), organizations
(`OrganizationToolTests.swift:7-15`), groups (`GroupToolTests.swift:10-17`),
favorites storage semantics (`FavoritesToolTests.swift:8-16`),
structured-entry mutations (`StructuredContactEntryToolTests.swift:9-19`),
and the harness smoke tests (`MCPProductionHarnessTests.swift:7-16`),
including a CLI-origin write that proves engine+repository share one
contact store (`MCPProductionHarnessTests.swift:81-117`).

**Residual mirror risk — the inventory.** These are places where a fake
REIMPLEMENTS a production rule and at least one test asserts on the
fake's behavior. Per the task instruction this is an inventory, not a
rewrite proposal; none of these blocks CLI parity.

| # | Mirrored rule | Where the mirror lives | Where a test asserts on it | Risk |
|---|---|---|---|---|
| 1 | Note/field CRUD semantics: soft-delete tombstones, edit-undeletes, type-replace upsert | `LegacyScriptedContactSource.addNote…deleteField`, `Fakes.swift:334-433` | `WriteToolTests.testAddEditDeleteNoteRoundTrip` asserts "delete must tombstone, not remove" against the fake's own `notesByEffectiveID` map (`WriteToolTests.swift:122-128`) | **Medium.** The MCP-layer test stays green if only the fake tombstones. Mitigant: the real engine's tombstone rules are covered by `GuessWhoSyncTests`, and the dispatcher's own guardrails (reserved names, `.blob` rejection) are production asserts in the same file (`WriteToolTests.swift:149-186`). |
| 2 | Resolve-or-mint + identity-URL stamp (LWW, deterministic mint) | `LegacyScriptedContactSource.effectiveWriteID`/`stamp`, `Fakes.swift:126-167` | The dispatcher race tests (losing-mint retry, `simulateLosingMintOnce`) and pre-mint-id tests | **Low, by design.** This mirror exists precisely to script races the recording store cannot express (`Fakes.swift:71-79` says so); the mint VALUE comes from the production `Contact.deterministicGuessWhoID` (`Fakes.swift:144-146`), and the same identity flow is proven against production in `MCPProductionHarnessTests.swift:81-117`. Keep, clearly labeled (it is). |
| 3 | Favorite-key derivation (guessWhoID-else-localID) | `LegacyScriptedContactSource.effectiveID`, `Fakes.swift:121-125` | scripted-fixture `favoritesOnly` filtering / `isFavorite` reads | **Low.** Real canonicalization/CAS is production-pinned in `FavoritesToolTests` via the real `FavoritesStore` (`FavoritesToolTests.swift:8-16`); the scripted uses are data plumbing. |
| 4 | Event-tag storage semantics (tags as `.note`-typed `"tag"` field cells, tombstones) | `FakeEventSource`, `Fakes.swift:662-740` | every `events_*_tag` test — the fake is the event source in BOTH fixtures (`MCPProductionHarness.swift:471`) | **Medium — the widest genuine gap.** The production conformer is app-target `SyncService`, which is a one-line delegation to package-resident engine calls (`SyncService.eventTags/addEventTag/editEventTag/deleteEventTag`, `App/GuessWho/Support/SyncService.swift:414-448`), so package tests could ride the real engine via an `EngineEventSource` adapter exactly like `EngineLinkSource`. Recommended follow-on, not CLI-parity work. |
| 5 | Guide import/reorder/delete | `FakeGuideSource`, `Fakes.swift:742-804` | guide/place read+write tests | **Medium, same shape as #4.** `SyncService`'s guide methods likewise delegate to the engine (`SyncService.swift:600-622`); the address matcher is already the real one (`GuideAddressMatcher`, `Fakes.swift:764-769`). Same follow-on as #4. |
| 6 | In-memory link soft-delete/undelete fallback | `Fakes.swift:493-517`, canned links seeded at `Fakes.swift:1034-1051` | only pre-existing read-tool/sentinel tests that don't set `linkEngine` | **Low.** All `links_*` behavior tests set the real engine (`LinkToolTests.swift:6-15`). |
| 7 | Contact-record store behavior (create re-issues identity, one-shot store errors) | `LegacyScriptedContactSource.createContact/saveContact…`, `Fakes.swift:529-624` | `ContactStoreWriteTests` runs on the scripted fixture (`ContactStoreWriteTests.swift:26-33`) | **Low-medium.** The asserted logic (field application, PATCH semantics, validation, idempotency) is dispatcher production code; the mirror is only the store's identity re-issue. `MCPProductionFixture` could carry this suite; worthwhile only if it's ever touched anyway. |

**Conclusion of the audit:** the split is real and mostly clean — the
production harness substitutes exactly one OS boundary, the scripted
fixture fails loudly when leaned on for semantics it doesn't model, and
the mapper re-enforces the exclusion rules defensively. The two
substantive mirrors worth eventually closing are the event-tag and guide
sources (#4, #5), both closable with thin engine adapters in the test
target, mirroring `EngineLinkSource` — no production change required.

### 3.2 Audit — the CLI has NO tests, and what is stranded

Confirmed three ways:

1. `App/guesswho-cli.xcodeproj` contains exactly one target (the tool)
   and no test target (`project.pbxproj:135-137` — `targets` lists only
   `guesswho-cli`).
2. No test anywhere references the CLI's types: `grep -rn
   "ContactsCommand\|CLICommandClient\|CLICommandOutput\|CLIPhotoInput\|GuessWhoCLI"
   Tests/` returns nothing (run 2026-08-14 on `ba7ac6e`); the only
   references in the tree are the two CLI source files themselves.
3. The package test suite cannot reach it structurally: the logic lives
   in app-target sources compiled only by `App/guesswho-cli.xcodeproj`,
   outside every SwiftPM test target (`Package.swift:152-166` lists the
   test targets; none can see `App/`).

**Stranded (untestable today) logic, by site:**

- **Request building:** each command's arg → `WireRequest` construction
  (`ContactsSearch.run`, `ContactsCommand.swift:30-41`;
  `ContactsSetPhoto.run`, `:107-130`).
- **Response rendering + validation:** error unwrap
  (`CLICommandOutput.throwIfError`, `:161-166`), JSON emission with the
  agent encoder + newline (`CLICommandOutput.writeJSON`, `:168-182`),
  photo-response integrity checks — base64 decode, non-empty,
  `data.count == photo.byteCount` (`ContactsGetPhoto.run`, `:64-73`) —
  and the stdout-bytes vs `-o` file split (`:75-88`).
- **Input handling:** stdin/file bounded read in 64 KiB chunks capped at
  `maxContactPhotoBytes + 1` (`CLIPhotoInput.readBounded`, `:200-217`),
  empty/oversize rejection and byte-based media sniffing (`:108-117` —
  the sniffing itself IS shared production code,
  `WireContactPhotoMedia.mediaType(for:)`,
  `Sources/GuessWhoMCPWire/WireContactPhotoMedia.swift:11-34`, tested in
  `WireContactPhotoMediaTests`).
- **Transport client:** helper-id mint, connection lifecycle,
  `RelayConnectionError` → user message (`CLICommandClient.send`,
  `:133-159`).
- **Environment resolution:** Info.plist App-Group read + container
  resolution (`CLIEnvironment`, `GuessWhoCLI.swift:43-64`).
- **Error → exit-code mapping — currently degenerate:** every failure is
  thrown as ArgumentParser's `ValidationError` (transport failures
  included, `ContactsCommand.swift:153-155`), and ArgumentParser exits
  `EX_USAGE` (64) for validation errors on macOS
  (swift-argument-parser `Platform.exitCodeValidationFailure`,
  `.build/checkouts/swift-argument-parser/Sources/ArgumentParser/Utilities/Platform.swift:154-163`).
  So today "GuessWho isn't open" and "that contact has no photo" exit 64
  with a usage footer, indistinguishable from a typo'd flag. §4 fixes
  this.

By contrast, the pieces the CLI *shares* are already production-tested
under `swift test`: the transport it calls (`RelayConnection.send`,
`Sources/GuessWhoMCPTransport/RelayConnection.swift:191`, exercised
end-to-end over real FIFOs in
`Tests/GuessWhoMCPTransportTests/PipeTransportTests.swift:89-224`), the
wire types and the argument-bag builder
(`WireRequestCreateTests`), and the app-side dispatch of CLI-origin
requests (`MCPProductionHarnessTests.swift:81-117`). **The untested band
is exactly the CLI's own layer — and for 60 more commands written the
current way, it would be 60× more untested inline logic.**

### 3.3 Recommended architecture — a package-resident CLI core

**The two surfaces already share one core; the CLI just needs to join it
(Adam's Q, 2026-08-14).** The actual tool logic lives in NEITHER wrapper —
it runs app-side in `ToolDispatcher` (`GuessWhoMCPCore`), across the FIFO,
because only the app touches Contacts/Calendar/storage; the relay and CLI
link wire + transport only, never `GuessWhoSync` (INV-1). So neither
wrapper reimplements logic today. The shared *client-side* funnel is three
calls, and the MCP relay already runs exactly them
(`RelayMCPServer.handleCallTool`,
`Sources/GuessWhoMCPTransport/RelayMCPServer.swift:134-151`):

```
build:  WireRequest.create(parameters:)      // GuessWhoMCPWire — shared
send:   connection.send(request, timeout)    // GuessWhoMCPTransport — shared
render: response.asCallToolResult()          // GuessWhoMCPWire — shared
```

The CLI must call the SAME three. Each wrapper adds only its own *protocol
adapter*: the relay parses MCP JSON-RPC (`RelayMCPServer`), the CLI parses
argv (`GuessWhoCLICore`). Those adapters are different jobs, so the relay
must **not** link `GuessWhoCLICore` or ArgumentParser — it has no argv.
`GuessWhoCLICore` is therefore the argv adapter ONLY; the deep shared core
stays the existing wire + transport packages plus the app-side dispatcher.

**Decision: create a new SwiftPM target + static product
`GuessWhoCLICore` holding the entire ArgumentParser command tree, and
shrink the app-target `guesswho-cli` to a `@main` shim.** This is the
same pattern the codebase already uses twice: the MCP side's thin host
over a package-tested core (`ToolDispatcher` in `GuessWhoMCPCore`,
host adapter at `MCPHostController.swift:167`), and the wire module's
package-resident request builder (`WireRequest.create`) that the MCP
relay funnels through.

**Module layout**

- `GuessWhoCLICore` (new target, new static product):
  - depends on `GuessWhoMCPWire`, `GuessWhoMCPTransport`, and
    `ArgumentParser` (swift-argument-parser becomes a direct
    `Package.swift` dependency; it is already in the resolved graph via
    mcp-template — `Package.swift:80-87` — and the CLI xcodeproj already
    pins `>= 1.5.0`, `App/guesswho-cli.xcodeproj/project.pbxproj:214-223`).
  - **MUST NOT depend on `GuessWhoSync`** — INV-1 carries over verbatim
    (`Package.swift:48-53`); and the APP must never link this product
    (same rule as the standalone wire/transport products, same file).
    ArgumentParser must NOT be added to `GuessWhoMCPWire` itself — the
    wire rides inside the app's dynamic `GuessWhoSync` product
    (`Package.swift:33-41`) and the app has no business linking
    ArgumentParser.
  - contents: the root command + all noun groups; `run` and `probe`;
    and three small seams —
    1. `CLIRuntime` — injected environment: `containerURL()`, a
       transport factory, and an output sink. The live values come from
       the `@main` shim; tests install fakes. (ArgumentParser commands
       are value types materialized by `parse`, so the runtime is a
       settable static — the standard ArgumentParser testing pattern.)
    2. `CLITransport` protocol — one requirement,
       `send(_ request: WireRequest, timeout: TimeInterval) async throws
       -> WireResponse`; the live conformance wraps `RelayConnection`
       (today's `CLICommandClient`, generalized).
    3. `CLIOutput` protocol — `writeData(_ : Data)` /
       `writeLine(_ : String)` / `writeError(_ : String)`; live = stdout
       bytes + stderr; tests capture buffers.
- `App/guesswho-cli/` keeps only: `@main` + logging bootstrap
  (stderr-only — `GuessWhoCLI.main`, `GuessWhoCLI.swift:29-36`), the
  Info.plist environment read (`CLIEnvironment`), and the live
  `CLIRuntime` wiring. Nothing else. The nested-xcodebuild embed is
  unchanged — the helper's isolated build links every package product
  statically (the archive-fix design, `plans/cli-mcp.md:8`), so one more
  static product costs nothing structurally.
- `GuessWhoCLICoreTests` (new test target): depends on `GuessWhoCLICore`
  only.

**Per-command shape — declarative, one production funnel.** Each tool
command declares:

```swift
struct ContactsListNotes: CLIToolCommand {
    static let tool: MCPTool = .contactsListNotes          // parity key
    @Argument var contactId: String
    @Option var limit: Int?
    @Option var cursor: String?
    func argumentBag() throws -> [String: Value] { … }     // pure flags → bag
}
```

and a protocol extension supplies the one shared `run()`:
`argumentBag()` → **`WireRequest.create(helperId:messageId:parameters:)`**
(the production, already-tested builder — validation, closed field sets,
enum checks, note rejection all shared with MCP) → `CLITransport.send`
with `tool.timeout` (which automatically gives `contacts delete` its
300 s human window, `MCPTool.swift:200-205`) → **shared renderer**.

**The renderer reuses the wire's own rendering.** For every non-binary
payload, CLI output should be byte-identical to the MCP agent surface:
render via `WireResponse.asCallToolResult()`
(`Sources/GuessWhoMCPWire/WireResponse.swift:189-247`) — data payloads
become the same sorted-keys JSON text, acks the same fixed strings,
errors the same plain messages — written to stdout (+`\n`), with
`isError` routing to stderr + a nonzero exit. This kills the current
duplicate JSON-emission path (`CLICommandOutput.writeJSON` re-encodes
what `asCallToolResult` already produces) and means the INV-3/banned-
vocabulary guarantees that are already tested against the MCP rendering
(`WireResponse.agentVisibleText` scans, `SecurityInvariantTests`) apply
to CLI output for free. Only two commands need bespoke rendering, both
already specified by the shipped code: `get-photo` (decode + integrity
check + bytes to stdout/file) and `set-photo` (input side). Their logic
moves into `GuessWhoCLICore` as small pure helpers
(`CLIPhotoInput`/`CLIPhotoOutput`) unit-tested directly.

**What `swift test` then covers, with real values and no live app:**

1. **Parse tests** — `try ContactsListNotes.parse(["<id>", "--limit",
   "5"])`: real ArgumentParser parsing of the real declarations (flag
   names, positional order, enum values, help text).
2. **Request-build tests** — parsed command → `argumentBag()` →
   `WireRequest.create` → compare against the expected `WireRequest`
   case via the wire's own `JSONEncoder` bytes (the framing tests'
   technique, `WireFramingTests.swift:17-30`). Malformed `--json`
   payloads assert the exact shared error messages.
3. **Render tests** — feed canned `WireResponse` values (every case:
   pages, records, acks, `departmentRename`, `groupMembership`, every
   `WireErrorCode`) through the shared renderer with a capturing
   `CLIOutput`; assert stdout bytes, stderr text, and exit code.
4. **Byte-path tests** — `CLIPhotoInput` bounds/sniffing over in-memory
   handles; `get-photo` integrity failures (byteCount mismatch, bad
   base64, `present: false`).
5. **Transport-error mapping** — a throwing fake `CLITransport`
   asserting `RelayConnectionError` → message + exit code (the live
   transport itself stays covered by `PipeTransportTests`).
6. **Vocabulary** — walk the command tree's abstracts/discussions/help
   with the same banned list as `BannedVocabularyTests.swift:14-27`.

The end-to-end legs that genuinely need the built binary + running app
(spawn, Info.plist, FIFO permissions) remain `[app]`/`[human]`, exactly
as the MCP side already classifies them (`plans/cli-mcp.md:90`).

**Alternative considered and rejected:** keeping ArgumentParser in the
app target and extracting only a pure mapping layer. It tests the bag
building but strands the 60 commands' parsing declarations (flag names,
positional order, help copy) untested in the app target — for zero
dependency savings, since ArgumentParser is already in the CLI's link
line. Also rejected: subprocess-driving the built binary from tests
(needs the built bundle; not runnable under plain sandboxed
`swift test`).

### 3.4 The parity guard

One test in `GuessWhoCLICoreTests`, two assertions, kept green forever:

```swift
func testEveryMCPToolHasACLICommandAndViceVersa() {
    let registered = CLICommandRegistry.allToolCommands   // walks the real command tree
    // 1. tool → command: fails the moment a 64th MCPTool case lands without a CLI command.
    for tool in MCPTool.allCases where !Self.pending.contains(tool) {
        XCTAssertNotNil(registered[tool], "\(tool.rawValue) has no CLI command")
        XCTAssertEqual(registered[tool]?.commandPath,
                       Self.expectedPath(for: tool))       // the §2 derivation rule, as code
    }
    // 2. command → tool: every registered tool-command names a real MCPTool
    //    (guaranteed by the `static let tool: MCPTool` requirement) and no
    //    two commands claim one tool.
    XCTAssertEqual(registered.count, MCPTool.allCases.count - Self.pending.count)
}
```

`pending` is an explicit `Set<MCPTool>` of not-yet-implemented tools that
lands in Phase 1 with 60 entries and must shrink to empty by Phase 5 —
so the guard exerts pressure during the build-out AND catches future
drift (a new tool without a command, a command without a tool, a
non-derived name). `run`/`probe` don't conform to `CLIToolCommand`, so
they're structurally exempt.

**Field-level parity (added because the CLI now uses per-field flags).**
Per-field flags and the `MCPTool` JSON schema (`MCPTool.swift`) declare
the same field sets twice, so they can drift. A second assertion in the
same guard checks that every non-object property of a tool's schema is
reachable as a positional or flag on its command (name-matched via the §2
derivation), and that every scalar flag/positional names a real schema
property. Object-valued schema keys (`address`, `profile`, the
current/new pairs) are satisfied by EITHER the per-field flag group OR the
`--json` path, so they're checked as "covered by one of the two", not
flag-by-flag. This keeps a schema change (a new required field on
`contacts_create`, say) from silently landing without a CLI flag —
without duplicating the schema, since the schema stays the single source
and the test reads it.

---

## 4. Conventions

- **Naming:** noun group + hyphenated verb, derived mechanically from the
  tool name (§2). Verbs therefore stay aligned with the MCP verb set
  (`add`/`edit`/`delete`/`set`/`list`/`get`/`create`/`rename`/
  `reorder`/`search`) — the consolidation naming already settled on the
  MCP side (delete not remove, etc.).
- **Ids, limits, cursors:** ids are opaque strings passed through
  verbatim, always positional. `--limit` (server default 50, max 200 —
  documented in `MCPTool.limitDoc`, `MCPTool.swift:216-217`) and
  `--cursor` on every paged read; the CLI does NOT validate or interpret
  either — the server's typed errors are the single source of truth.
- **stdout is data, stderr is everything else.** Data payloads (JSON,
  photo bytes) and ack lines go to stdout; every diagnostic, error, and
  progress message goes to stderr so redirected/piped output stays clean
  — the shipped get-photo precedent, already documented
  (`docs/cli-mcp.md:143-144`). The `contacts delete` wait note
  ("GuessWho is asking for your approval — check the app.") is stderr.
  Logging is bootstrapped to stderr already (`GuessWhoCLI.swift:29-36`).
- **Exit codes** (replacing today's everything-is-64):
  - `0` — success, including "no data" successes the wire defines as
    normal results (`present: false` handling stays a get-photo error
    only because bytes were requested).
  - `1` — the app answered with a typed error (`WireResponse.error` —
    message printed to stderr verbatim; codes never printed, matching
    `BannedVocabularyTests.testErrorCodeNamesStayOutOfAgentText`,
    `BannedVocabularyTests.swift:127-135`).
  - `10` — **the user declined the delete confirmation** (decided
    2026-08-14, §6 #1). Not an app error and not a data result, so it gets
    a distinct non-zero code a script can branch on; the declined message
    (`WireAckMessage.contactDeleteDeclined`) prints to stderr, stdout stays
    empty. MCP still reports the same outcome as a NORMAL result so agents
    don't retry-loop — the CLI's non-zero code is a terminal-ergonomics
    choice layered on top, not a wire change.
  - `69` (`EX_UNAVAILABLE`) — transport-level failure: app not running /
    not ready / timed out (`RelayConnectionError`), so scripts can
    distinguish "open the app" from a real tool error.
  - `64` (`EX_USAGE`) — genuine usage errors only (ArgumentParser
    validation, malformed `--json`, a key supplied both by flag and
    `--json`, more than one stdin-reading input).
  Implemented as a small typed `CLIExitCode` in `GuessWhoCLICore`,
  unit-tested; commands stop wrapping runtime failures in
  `ValidationError`.
- **Booleans are flags, not toggles** (decided 2026-08-14, §6 #6): the
  three favorite commands take a required `--favorite` / `--no-favorite`
  pair and error when neither is given — matching the wire's
  desired-state (not toggle) semantics.
- **Text / JSON inputs** (a note `--body`, any `--json`) take an inline
  value, `-` for stdin, or a `--<field>-file <path>` companion (decided
  2026-08-14, §6 #4). At most one input per call reads stdin. Per-field
  flags are the default for structured objects; `--json` is the optional
  path (§2 note).
- **Writes:** `--idempotency-token` on every write (shipped precedent,
  `ContactsCommand.swift:104-105`); no client-side retry logic — retry
  identity is the caller's choice, dedup is the app's
  (`ToolDispatcher.swift:79-84`).
- **Gating messages:** read-only / off states surface as the server's
  own fixed strings (`WireErrorMessage.readOnly` / `.disabled`,
  `Sources/GuessWhoMCPWire/WireError.swift:58-65`) on stderr with exit 1
  — the CLI adds no wording of its own, keeping the banned-vocabulary
  surface enumerable.
- **Help copy:** plain-language only; nouns are "contact", "event",
  "guide", "place", "group", "connection", "favorite". The §3.3
  vocabulary test enforces it.

---

## 5. Phasing

Serial phases, each with its own test deliverable and review cycle
(per [[feedback_always_review]] — no skipped reviews). Counts:
3 shipped + 20 + 17 + 22 + 1 = 63.

**Phase 1 — Testable core (no new commands).**
Create `GuessWhoCLICore` + `GuessWhoCLICoreTests`; add the direct
swift-argument-parser dependency; **re-resolve and commit BOTH
`Package.resolved` lockfiles** (repo rule, `CLAUDE.md`); move
`run`/`probe`/the three contacts commands into the core; introduce
`CLIRuntime`/`CLITransport`/`CLIOutput`, the shared `run()` funnel
through `WireRequest.create`, the `asCallToolResult`-based renderer, and
`CLIExitCode`; shrink the app target to the shim.
*Tests:* parse/request-build/render/byte-path/exit-code suites for the
three shipped commands; the parity guard with a 60-entry `pending` set;
the CLI vocabulary scan.
*Exit:* `swift test` green; Catalyst app builds + embeds unchanged
(nested build still links statically); `guesswho contacts search`
behavior byte-identical (the renderer change may only alter failure exit
codes, called out in the review).

**Phase 2 — The 20 remaining read commands.**
`contacts list/get/list-notes/list-custom-fields/list-groups`,
`organizations list-*` (3), `groups list-for-contact`, `events
list/get/list-tags`, `guides list/get/list-for-place`, `places
list/search/get`, `links list`, `favorites list`.
*Tests:* per-command parse + request-build cases; render cases for every
newly-exercised `WireResponse` payload case; `pending` shrinks by 20.

**Phase 3 — GuessWho-data writes (17).**
Notes (3), custom fields (2), `contacts set-favorite`, `favorites
set/reorder`, event tags (3), `guides create/delete/reorder-places`,
`places delete`, `links create/delete`. First use of `--json`
(`favorites reorder`, `guides create`) — lands with the shared JSON→
`Value` ingestion + its malformed-payload tests.
*Tests:* as Phase 2, plus `--json` stdin/inline/conflict cases;
`pending` −17.

**Phase 4 — Contact Store writes minus delete (22).**
`contacts create/update/delete-photo`, value edits (3), structured
entries (9), `organizations rename-department`, groups writes (6).
The per-field scalar-flag surface for create/update, the per-field
structured add/delete flags, and the `--json` path for the structured
*edit* trio are the bulk of the work; every validation behavior
(scalars-only update, closed structured objects, note rejection) is
asserted through the shared funnel, i.e. against production
`WireRequest.create` behavior — flags and `--json` share it.
*Tests:* as before, plus per-field→bag assembly and flag/`--json`
conflict cases; `pending` −22.

**Phase 5 — `contacts delete` + closure.**
The confirmation-gated delete (300 s wait, stderr wait-note, ack/declined
handling); `pending` becomes empty and the guard goes strict; rewrite
`docs/cli-mcp.md`'s terminal section to document the full command set;
final review cycle + a manual `[human]` end-to-end pass against the
running app (per-command E2E is not automatable under `swift test`).

Slow is smooth; smooth is fast — each phase is independently shippable
and the guard names exactly what remains.

---

## 6. Decisions (resolved 2026-08-14) & remaining open items

**RESOLVED by Adam, 2026-08-14:**

1. **Declined delete exit code → distinct non-zero.** Deleted → exit `0`;
   user declined → exit `10`, message on stderr (§4). Scripts can branch;
   the wire result is unchanged (MCP keeps declined as a normal result).
3. **Structured input → per-field flags by default, `--json` optional.**
   Per-field is the clearer, quote-safe interface for an agent; `--json`
   (inline / `-` stdin / `--json-file`) stays as the escape hatch — on
   `contacts create` (list fields) and as the primary path for the three
   structured *edit* tools (§2 note, §3.3). Both build the same bag and
   funnel through `WireRequest.create`, so no logic fork.
4. **Note body as an input param → yes.** `contacts add-note`/`edit-note`
   take `--body` inline, `--body -` (stdin), or `--body-file` — same
   convention as `--json`.
5. **`links list` argument order → id-first** (`<id> <kind>`), mechanical
   and consistent with every id-leading command. (Adam: no preference.)
6. **Favorite value → flag, not toggle.** `--favorite` / `--no-favorite`,
   required, on the three favorite commands (§4).

**Unchanged recommendations (not challenged):**

2. **No tool is deliberately CLI-less.** All 63 get a command, including
   `contacts delete` (headless-safe — the human gate is the app dialog,
   not the terminal). Revisit only if Adam wants no terminal delete.
   *(was §6.3)* **Output format default** stays JSON-for-data /
   fixed-text-for-acks, byte-identical to the MCP agent surface; a
   human-readable `--format table` is a possible later addition that would
   fork the tested render path, so it is out of scope now.

**Still open — one item, test-only:**

7. **Test-suite follow-ons from the audit (§3.1 #4/#5):** engine-backed
   `EngineEventSource`/`EngineGuideSource` test adapters to retire the
   event-tag and guide mirrors in `Fakes.swift`. Zero production change,
   test-only; schedule independently of CLI parity?

---

## Appendix — verification record

- `swift test` (package root, this worktree, 2026-08-14): **exit 0**;
  XCTest side "Executed 311 tests, with 0 failures"; swift-testing side
  "Test run with 863 tests in 81 suites passed". No app-target
  (`xcodebuild`) build was attempted for this research; the plan's
  packaging claims rest on the committed project files and
  `plans/cli-mcp.md`'s archive-fix record, both cited inline.
- Tool count cross-check: 22 read cases + 41 write cases counted in
  `MCPTool.swift:21-102`; pinned by
  `WireFramingTests.swift:435-441`; prose count at `docs/cli-mcp.md:153`.
- CLI link line: `ArgumentParser`, `GuessWhoMCPWire`,
  `GuessWhoMCPTransport` and nothing else
  (`App/guesswho-cli.xcodeproj/project.pbxproj:94-98`) — INV-1 holds.
