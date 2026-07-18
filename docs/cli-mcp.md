# CLI + MCP access

GuessWho ships a local, user-enabled agent interface: an MCP server that AI
assistants (Claude Desktop, Claude Code, Cursor, …) connect to, and a
terminal command, both backed by the running app. Everything is
device-local — no network transport, no server, and contact data never
leaves the machine. Each surface has ONE tri-state access setting — **off
→ read-only → read-write** — defaulting to **off**; the user opts in from
the app's Settings (⌘, on Mac). Read-write is what unlocks writes,
including full Contact Store contact-record edits (Revision 2).

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

Settings (⌘,) has one tri-state picker per surface — **AI Assistant
Access** and **Terminal Access**, each **Off / Read-only / Read-write**,
both defaulting to Off — stored in the CLI App-Group `UserDefaults`
(`MCPToggleKeys.mcpAccessMode` / `.cliAccessMode`; the pre-Revision-2
boolean pairs migrate once at launch). The app enforces the mode
**server-side per call** — hiding write tools from `tools/list` is UX, not
the gate — so a change applies to the very next request. Contacts/Calendar
permission gates apply on top: the agent only ever sees what the user has
granted the app. `contacts_delete` has an extra per-call bar: an in-app
confirmation alert naming the specific contact, which the user must
explicitly approve (see Tools).

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

**Read (16):** `contacts_search`, `contacts_get`, `contacts_list_notes`,
`contacts_list_custom_fields`, `contacts_list_linked_contacts`,
`contacts_list_linked_organizations`, `contacts_list_favorites`,
`contacts_list_groups`, `groups_list_members`, `events_list`,
`events_get`, `events_list_tags`, `guides_list`, `guides_get`,
`places_list`, `links_list`. (Plus `guesswho_status`, served by the relay
itself when the app is unreachable / to re-check.)

**Write (21):** the GuessWho-data writes — `contacts_add_note`,
`contacts_edit_note`, `contacts_delete_note`, `contacts_set_custom_field`,
`contacts_delete_custom_field`, `contacts_add_linked_contact`,
`contacts_add_linked_organization`, `contacts_remove_linked_contact`,
`contacts_set_favorite`, `events_add_tag`, `events_edit_tag`,
`events_delete_tag`, `guides_create`, `guides_delete`,
`guides_reorder_places`, `places_delete`, `links_create`, `links_remove`
— plus, since Revision 2, full Contact Store parity with the app's own
editor: **`contacts_create`**, **`contacts_update`** (PATCH semantics:
only passed fields change; list fields replace as whole lists), and
**`contacts_delete`**.

### Generic connections (`links_*`)

`links_list(id, kind)`, `links_create(fromId, fromKind, toId, toKind,
note?)`, and `links_remove(linkId)` expose the SAME connection surface the
app's detail views have, over the kind-agnostic engine primitive
(`addLink(from:to:note:)` / `links(at:)` / `removeLink(id:)` behind
`MCPLinkSource`, conformed by `SyncService`). Kinds on the wire are
`person`, `organization`, `event`, and `place`; each id is that kind's
ordinary wire id. Supported pairs mirror the app exactly:
contact↔contact, contact↔event, contact↔place, event↔event, and
event↔place. `place`+`place` is the one combination with no app
affordance and answers a typed `invalidParams`; guides aren't a
connection kind at all. Contact-involved creates route through the
identity-minting repository funnels (`addLink` / `addEventLink` /
`addPlaceLink`) with the same single-flight + post-mint-verify
protections as the `contacts_add_linked_*` tools; a system-calendar-only
event follows the tag rule (typed `requiresAppAction`, nothing minted).
Each `links_list` entry carries the connection's own id plus the FAR
endpoint's kind and id, so the agent can read the far record with the
matching read tool; rows whose far record no longer resolves are dropped.
`links_remove` soft-deletes and lands in Recently Deleted like the other
GuessWho-data deletes. The static permission domain is none (connection
storage is GuessWho's own); the dispatcher re-gates each call on the
system permission of every endpoint kind it references. The older
`contacts_add_linked_contact` / `contacts_add_linked_organization` /
`contacts_remove_linked_contact` / `contacts_list_linked_*` tools are
unchanged for backward compatibility.

Contact-record writes route through the SAME repository entry points the
app's contact editor uses (`editableContact`/`saveContact`/
`createContact`), so the editor's identity-URL carry-through merge and
change-watcher behavior apply identically; a wire-supplied web address
using the app's reserved internal form is rejected, and a note-shaped
argument is rejected with a pointer to `contacts_add_note`. Contact Store
saves can fail (the documented Cocoa 134092 store-rejection family,
revoked Contacts access, a record deleted elsewhere) — failures map to
typed codes (`writeFailed` / `permissionDenied` / `notFound`) via the same
`ContactEditModel.saveErrorCategory` the editor uses; never a crash, never
a silent success.

`contacts_delete` is uniquely destructive, so it carries an extra human
gate: the request returns out of band (fire-and-forget, correlated by
message id) while the app presents a confirmation alert naming the
specific contact on the frontmost active scene. Approve → the delete runs
and is audited; Cancel → a NORMAL non-error "the user declined" result (so
agents don't retry-loop); nothing to present on → a typed refusal. The
tool's declarative timeout is 300s (a human is thinking), and the app
re-checks elapsed time before performing an approved delete so a
timed-out call can never also have deleted.

Write safety machinery: per-call access-mode gate; a global per-host-run
write budget (confirmation requests count against it, and only one
confirmation can be on screen at a time); per-contact single-flight with
post-mint verification; idempotency-token replay dedup; GuessWho-data
deletes are soft — restorable from **Settings → Recently Deleted**; and
every agent write is appended to a device-local audit log (`MCPAuditLog`,
Application Support — deliberately never synced) that Settings renders as
the plain-language **Agent Activity** list.

### Ids

A contact's wire `id` IS its GuessWho UUID (Revision 2 — no per-session
tokens). A contact that has never been written to has no minted UUID yet,
so the wire hands out `Contact.deterministicGuessWhoID` — the exact UUID
the deterministic mint will assign on its first write — making the id
stable across the mint boundary. The id is a lookup key only; no write
tool can change it. Events ride their record UUID (or a derived `e-` id
for system-calendar-only rows, which keeps resolving after the user opens
the event in the app); groups ride a one-way `g-` digest of their system
identifier; notes/fields/tags/links/guides/places ride their own record
UUIDs. `WireRecordID` (GuessWhoMCPCore) is the whole scheme.

## The exclusion invariant

The wire carries the whole record the user sees EXCEPT four named fields
(Revision 2's focused-exclusion model, replacing the earlier positive
allowlist): the **Apple contact note**, **Apple local identifiers**, the
**`modifiedBy` device id**, and the **`guesswho://` URL form** (the
identity rides as the bare UUID id instead).

The Apple note is the hard line: `CNContact.note` is **never** readable,
writable, or searchable over this interface — the app keeps the
`com.apple.developer.contacts.notes` entitlement for its own UI, so the
**wire boundary is the only line**:

- No wire DTO has a note field, no write tool accepts a note-shaped
  argument (one is explicitly rejected), the update path carries the
  stored note through byte-identical, and `Contact`/`Event` model values
  are never serialized directly.
- Contact search matches only wire-visible fields; error messages never
  interpolate model values (even save-failure details are fixed strings).
- Enforced by tests that run under plain `swift test`: the targeted
  exclusion suite (a sentinel planted in EACH excluded field, asserted
  absent from every read output, write echo, and error — both
  directions), the adversarial note-exclusion suite (content AND
  match-presence), and the banned-vocabulary scan over every agent- and
  user-facing string.

The GuessWho notes exposed by `contacts_list_notes` / `contacts_add_note`
etc. are GuessWho's own per-contact dated notes, not the Apple note.

## Where things live

| Piece | Location |
|---|---|
| Wire types, tool inventory, DTOs, user-facing copy | `Sources/GuessWhoMCPWire/` |
| Dispatch core (per-tool handlers, mappers, id scheme, audit log, Recently Deleted service, symlink resolver) | `Sources/GuessWhoMCPCore/` |
| FIFO transport (host + relay ends, reconnect, reaping) | `Sources/GuessWhoMCPTransport/` |
| Relay entry point | `App/guesswho-cli/` |
| Relay build + embed (own xcodeproj; the app's "Build and Embed guesswho-cli" Run Script nested-builds it into an isolated derived-data path, copies the binary to `Contents/MacOS`, and codesigns it with the expanded App Group — the Muse pattern that keeps the Catalyst app and the native-macOS helper out of one xcodebuild invocation, which otherwise fails `archive` with "Multiple commands produce …/UninstalledProducts/macosx/…") | `App/guesswho-cli.xcodeproj` + the Run Script in `App/GuessWho.xcodeproj` |
| App host + gates + delete-confirmation presenter | `App/GuessWho/Support/MCPHostController.swift` |
| Helper locator (the ONE place the path is derived) | `App/GuessWho/Support/CLIHelper.swift` |
| Settings sheet (toggles, install, activity, Recently Deleted) | `App/GuessWho/MCPPreferencesView.swift` |
| Admin-auth symlink creation | `App/GuessWhoAppKitBridge/` |

Package-level tests (wire round-trip, the exclusion suite, framing
injection, note exclusion, contact-record writes + confirmation flow,
banned vocabulary, resolver, formatter) run with `swift test`; the
app-hosted integration legs (INV-2 live-instance writes, access-mode
gating against the real host) live in the `GuessWhoTests` bundle. App-Review positioning and the privacy-label answers are in
`docs/cli-mcp-app-review.md`.
