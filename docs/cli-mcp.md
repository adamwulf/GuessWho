# CLI + MCP access

GuessWho ships a local, user-enabled agent interface: an MCP server that AI
assistants (Claude Desktop, Claude Code, Cursor, …) connect to, and a
terminal command, both backed by the running app. Everything is
device-local — no network transport, no server, and contact data never
leaves the machine. Both surfaces are **OFF by default** and **read-only by
default**; the user opts in from the app's Settings (⌘, on Mac).

The build plan (design rationale, invariants, review history) is
`plans/cli-mcp.md`. This doc describes what shipped.

## The two-process model

```
MCP client (Claude, Cursor…)          GuessWho.app (Mac Catalyst)
        │ stdio (MCP protocol)                 │
        ▼                                      ▼
guesswho-cli relay  ◀── FIFOs in the ──▶  MCPHostController
(embedded helper)       shared container      └─ ToolDispatcher → live
                                                 ContactsRepository/SyncService
```

- **`guesswho-cli`** is a small relay embedded at
  `GuessWho.app/Contents/MacOS/guesswho-cli` (never named `guesswho` —
  case-insensitive APFS would collide with the app executable `GuessWho`).
  `guesswho-cli run` hosts the MCP stdio server; `guesswho-cli probe` is a
  packaging diagnostic. The relay holds **no data access of its own**: it
  links only the wire + transport modules (INV-1 — never `GuessWhoSync`),
  so every answer must come from the app.
- **The app** is the only process that touches Contacts/Calendar or the
  user's storage. `MCPHostController` (Catalyst-only; iOS has no host)
  runs the channel while either master toggle is on and injects the SAME
  live repository/service instances the UI uses (INV-2), so agent reads
  see exactly what the user sees and agent writes appear in the open UI
  without a relaunch.
- **Transport:** newline-JSON over FIFOs in the CLI App-Group container —
  one central announce channel (control messages only, kept under Darwin's
  512-byte atomic-write ceiling) plus one request + one response FIFO per
  helper, each with a single writer so interleaving is structurally
  impossible. Helper ids are unguessable 128-bit random tokens. If the app
  is closed, the relay serves a single `guesswho_status` tool whose
  description tells the agent to ask the user to open the app; it
  re-probes on call and emits `tools/list_changed` once the app is back.
- **Per-channel container:** both sides resolve the App-Group id from the
  `GuessWhoCLIAppGroup` Info.plist key, expanded from one shared build
  variable per channel (Debug ids are `.debug`-suffixed), so an app and a
  helper from different channels can never cross-talk (INV-4).

## Enabling and gating

Settings (⌘,) has four toggles, stored in the CLI App-Group
`UserDefaults` (`MCPToggleKeys`): **AI assistant access** / **Terminal
access** (both OFF by default) and a **read-only** toggle per surface (ON
by default). The app enforces them **server-side per call** — hiding write
tools from `tools/list` is UX, not the gate — so a flip applies to the
very next request. Contacts/Calendar permission gates apply on top: the
agent only ever sees what the user has granted the app.

## Install

**Copy-path is the primary install on every channel.** Settings shows the
helper's absolute path with a Copy Path button (`UIPasteboard` only — the
app never generates or edits a client's config file). The user pastes it
into their client's config, e.g. `.mcp.json`:

```json
{
  "mcpServers": {
    "guesswho": {
      "command": "/Applications/GuessWho.app/Contents/MacOS/guesswho-cli",
      "args": ["run"]
    }
  }
}
```

(`/usr/local/bin/guesswho` works as the `command` too, once installed.)

**Terminal install** creates the symlink `/usr/local/bin/guesswho →
…/Contents/MacOS/guesswho-cli` through the system admin-authorization
panel (`NSWorkspace.requestAuthorization(to: .createSymbolicLink)` +
`FileManager(authorization:)`, driven from the AppKit bridge bundle — a
runtime auth API, no bespoke entitlement; the Muse-shipped mechanism).
`CLISymlinkResolver` (GuessWhoMCPCore, unit-tested) classifies the path
into four states before offering anything:

| State | Meaning | Settings offers |
|---|---|---|
| `notInstalled` | nothing at the path | Install |
| `installed` | symlink resolves to OUR bundle's helper | — |
| `dangling` | symlink whose destination is gone (app moved/updated) | Reinstall + copyable removal command |
| `conflictingFile` | a real file, or a symlink to a DIFFERENT bundle (older install, other channel) | Show in Finder + copyable removal command |

The discriminator is `FileManager.destinationOfSymbolicLink(atPath:)`
(authoritative even on a dangling link, where `fileExists` lies), and the
bundle-identity check compares `resolvingSymlinksInPath()` of **both** the
link destination and the expected bundle target — Setapp/Sparkle-style
bundle paths contain symlinks themselves, so a raw string compare would
false-negative a legit install, and a wrong-channel link must surface as a
conflict, not `installed`.

**Uninstall is never a hand-typed path:** there is no authorized-delete
API, so Settings offers a Copy Removal Command button that puts the exact
shell-escaped `rm` line on the pasteboard.

**Stale-path repair:** a MAS in-place update or moving the app invalidates
any pasted absolute path (and the symlink → the `dangling` state). The app
stamps the last copied/installed helper path in the group defaults; at
launch and in Settings it compares that to the current path and shows a
plain repair hint ("GuessWho has moved…") when they differ. Sandbox limits
mean the app cannot read a client's config directly — the stamp is the
signal.

## Tools

Names use underscores (MCP clients restrict tool names to
`[a-zA-Z0-9_-]`). The authoritative inventory — names, agent-facing
descriptions, schemas, permission domain, read/write class, timeouts — is
`MCPTool` in `Sources/GuessWhoMCPWire/MCPTool.swift`.

**Read (15):** `contacts_search`, `contacts_get`, `contacts_list_notes`,
`contacts_list_custom_fields`, `contacts_list_linked_contacts`,
`contacts_list_linked_organizations`, `contacts_list_favorites`,
`contacts_list_groups`, `groups_list_members`, `events_list`,
`events_get`, `events_list_tags`, `guides_list`, `guides_get`,
`places_list`. (Plus `guesswho_status`, served by the relay itself when
the app is unreachable / to re-check.)

**Write (16, all GuessWho-owned data only — never system contact or
calendar content):** `contacts_add_note`, `contacts_edit_note`,
`contacts_delete_note`, `contacts_set_custom_field`,
`contacts_delete_custom_field`, `contacts_add_linked_contact`,
`contacts_add_linked_organization`, `contacts_remove_linked_contact`,
`contacts_set_favorite`, `events_add_tag`, `events_edit_tag`,
`events_delete_tag`, `guides_create`, `guides_delete`,
`guides_reorder_places`, `places_delete`.

Write safety machinery (Phase 2): per-call read-only gate; a global
per-host-run write budget; per-contact single-flight with post-mint
verification (no duplicate identity mints); idempotency-token replay
dedup; deletes are soft — restorable from **Settings → Recently Deleted**;
and every agent write is appended to a device-local audit log
(`MCPAuditLog`, Application Support — deliberately never synced) that
Settings renders as the plain-language **Agent Activity** list.

## The Apple-note exclusion invariant

`CNContact.note` is **never** readable, writable, or searchable over this
interface — the app keeps the `com.apple.developer.contacts.notes`
entitlement for its own UI, so the **wire boundary is the only line**:

- Wire DTOs are a positive per-field **allowlist** (`WireDTOs.swift`);
  there is no note field to forget to strip, and `Contact`/`Event` model
  values are never serialized directly (INV-3/INV-3b).
- Contact search matches only allowlisted fields; error messages never
  interpolate model values.
- Enforced by tests that run under plain `swift test`: DTO-allowlist
  round-trips, the adversarial note-exclusion suite (a note-bearing
  contact goes through every read tool and search path; the note text
  must appear nowhere in any encoded response), and the banned-vocabulary
  scan over every agent- and user-facing string.

The GuessWho notes exposed by `contacts_list_notes` / `contacts_add_note`
etc. are GuessWho's own per-contact dated notes, not the Apple note.

## Where things live

| Piece | Location |
|---|---|
| Wire types, tool inventory, DTO allowlist, user-facing copy | `Sources/GuessWhoMCPWire/` |
| Dispatch core (per-tool handlers, mappers, audit log, Recently Deleted service, symlink resolver) | `Sources/GuessWhoMCPCore/` |
| FIFO transport (host + relay ends, reconnect, reaping) | `Sources/GuessWhoMCPTransport/` |
| Relay entry point | `App/guesswho-cli/` |
| App host + gates | `App/GuessWho/Support/MCPHostController.swift` |
| Helper locator (the ONE place the path is derived) | `App/GuessWho/Support/CLIHelper.swift` |
| Settings sheet (toggles, install, activity, Recently Deleted) | `App/GuessWho/MCPPreferencesView.swift` |
| Admin-auth symlink creation | `App/GuessWhoAppKitBridge/` |

Package-level tests (wire round-trip, DTO allowlist, framing-injection,
note exclusion, banned vocabulary, resolver, formatter) run with
`swift test`; the app-hosted integration legs (INV-2 live-instance writes,
read-only gating against the real host) live in the `GuessWhoTests`
bundle. App-Review positioning and the privacy-label answers are in
`docs/cli-mcp-app-review.md`.
