# GuessWho CLI + MCP — Implementation Plan

**Author:** `cli-mcp` (guesswho repo) · **Reviewers:** `allume-mcp-cli-helper`, `essentialmcp-helper`, `essential-mcp-research-helper`, Adam
**Status:** APPROVED by both reference agents; all refinements folded in. Distribution ANSWERED (App Store + TestFlight + Setapp; mirror Allume/Muse). Gathering Muse's concrete per-channel packaging mechanics from allume, then Phase 0 kicks off. · **Date:** 2026-07-16

Phases are executed **serially**. Each phase has explicit exit criteria and a review cycle. We do not start phase *N+1* until phase *N*'s criteria are met and reviewed.

---

## Architecture (agreed by all three reference agents)

Two-process **relay**. The running **Mac Catalyst app** is the HOST: it owns TCC grants (EventKit/Contacts), the single `GuessWhoSync`/`ContactsRepository` instance, the iCloud sidecar, and all human-confirmation UI. A thin **relay** binary (`guesswho`) — bundled at `GuessWho.app/Contents/MacOS/guesswho`, optionally symlinked to `/usr/local/bin` — is BOTH front doors:

- `guesswho run` → long-lived **MCP stdio server** (for Claude Desktop / Cursor / Claude Code).
- `guesswho contacts list …` (etc.) → one-shot **human CLI**.

Both send the same typed requests over **App-Group named pipes** to the app; the app runs the logic and answers. The relay **does not link `GuessWhoSync`** — only the shared wire module + transport package.

```
Claude Desktop / terminal
   │ MCP JSON-RPC over stdio   |  ArgumentParser CLI flags
   ▼
 guesswho (relay; bundled in .app; NOT linked against GuessWhoSync)
   │ newline-delimited JSON over named FIFOs (App Group container)
   ▼
 GuessWho.app (host — owns TCC, the single GuessWhoSync, the sidecar, confirm UI)
   │ direct calls into the SAME ContactsRepository/SyncService the UI uses
   ▼
 EventKit / Contacts + iCloud JSON sidecar
```

### Why relay, not a direct-to-Sync standalone CLI
1. **TCC ownership** — EventKit/Contacts auth is per-process and needs UI to grant; a client-spawned headless relay can't cleanly hold it. The running app already has it.
2. **Single writer** — `GuessWhoSync`'s per-key `NSLock` tables + contact-change watcher are per-process. Sidecar *files* are `NSFileCoordinator`-safe (no corruption), but two owners could still interleave read-modify-write and bypass the in-memory locks. One owner = correctness for free.

### v1 SCOPE STATEMENT (prevents scope creep — write this into the plan verbatim)
**v1 mutates GuessWho *sidecar* data only; system-store (EventKit / Contacts) *content* is READ-ONLY.** Reading system contacts/events is in; writing them is out of v1. Contact/event content writes are a *different coordination domain* (EventKit/Contacts, not the relay's single-writer sidecar guarantee), they need TCC *write* grants (a strictly harder grant than read with no clean mid-flight rollback), and they'd entangle the legitimate write path with the still-pending `com.apple.developer.contacts.notes` entitlement — so they get their own design pass, not a v1 phase.

### Load-bearing invariants (acceptance criteria, not conventions)
- **INV-1 Single writer by construction:** the relay target does NOT link `GuessWhoSync`. Enforced by the link line, verified in the build.
- **INV-2 Writes are visible everywhere:** every write tool routes through the SAME `ContactsRepository`/`SyncService` entry points the UI uses, so the change-watcher, iCloud push, and UI observation all fire. Test: an MCP-driven write is visible in the running app's UI and pushed to iCloud **without relaunch**.
- **INV-2b Host uses the LIVE app instance (read-side mirror of INV-1):** the host holds a reference to the app's existing `ContactsRepository`/`SyncService` (injected at app launch) and NEVER constructs its own store — so even *read* tools see the same in-memory state the UI sees (no stale second store). **Test (positive consequence — both reviewers preferred this over an `===` identity check):** a read tool reflects an in-memory, not-yet-persisted UI change — observable ONLY if the host shares the live instance, so it tests the consequence rather than the mechanism. ("Does not construct its own store" and the `===`-same-object check are architecture-review checklist items, not the unit gate.)
- **INV-3 Apple note NEVER crosses the wire (either direction):** the wire contact DTO has **no** `note`/`notes` field; the host mapper never reads `Contact.note` (Apple); no write tool accepts a note-shaped param; search never matches the Apple note. The **allowed** "note" on the wire is GuessWho's own sidecar `ContactNote` (via `notes(at:)`), a *different type*. Test (adversarial, structural): a fixture whose Apple `Contact.note` holds a unique **sentinel** — the sentinel appears in **zero** tool outputs (read/list/search/write-echo); assert the key is **absent** from the encoded JSON (not merely empty).
- **INV-4 Same app-group id in both targets:** derived from one xcconfig var; mismatch = silent FIFO failure. INV-4 is the *static* guarantee; **Phase 0 exit criterion 3 (app + CLI resolve the SAME container path at runtime) is its runtime verification** — named together on purpose.
- **INV-5 Mac (Catalyst) only for v1:** pipe/wire code gated Mac-only so iOS builds don't pull in FIFO code with no host. Concretely: the relay binary is built + Copy-Files-embedded ONLY on the Catalyst-capable config; **an iOS-only build simply OMITS the Copy Files phase** (it must NOT try to embed a macOS Mach-O into an iOS `.app` — that would fail to codesign). Make the iOS build's absence-of-relay explicit so nobody wonders where it went.

### Consent & safety model (NO per-call confirmation dialogs)
The MCP client is headless — the human is in Claude Desktop / Terminal, not staring at GuessWho — so an in-app modal on an MCP write is a dialog **nobody is watching** (it blocks/times-out the call or forces alt-tab per write). Therefore: **consent is the read-only toggle, granted once in Preferences** (`isMCPReadOnly` / `isCLIReadOnly` — writes OFF by default). Destructive ops are safe because GuessWho deletes are already **soft-delete/tombstone** (`deleteNote` sets `deletedAt`; `notes(at:)` filters live, `allNotes(at:)` recovers) — recoverable, so no hard-delete in v1 and no per-call prompt needed. This also removes the "longer interactive timeout" complexity (the default 10s holds). If Adam wants human-in-the-loop approval for agent writes, design it out-of-band (a notification the user acts on), NOT a modal blocking the tool call — flag as a product decision.

---

## Phase 0 — Catalyst packaging spike (the ONE real unknown) 🔴 GATE

**Goal:** prove a Mac Catalyst `.app` can embed + codesign + spawn a plain macOS CLI Mach-O that resolves the shared App-Group container. **No feature code.** Nothing else starts until this passes.

**Work:**
- New command-line-tool target `guesswho` (Mach-O executable, not an app). Trivial body: `--version` + a "probe" that resolves `containerURL(forSecurityApplicationGroupIdentifier:)` and prints the path.
- Its own minimal `.entitlements`: just `com.apple.security.application-groups = <same xcconfig var as app>`. No app-sandbox on the helper.
- App target: add helper as a target **dependency**; Copy Files build phase → `Contents/MacOS`.
- App side: a debug hook that creates the central FIFO in the group container and prints its path.

**Exit criteria (verify on a RELEASE / exported build with the build type GuessWho actually ships — see distribution question; NOT local Debug):**
1. Embedded CLI exists at `GuessWho.app/Contents/MacOS/guesswho`; `codesign -dvvv` (and `codesign -d --entitlements -`) on the **exported** app shows our team id + the matching app-group entitlement.
2. Running the embedded CLI directly by absolute path resolves the App-Group container dir **AND can actually read+write a temp file inside it at runtime** (a resolvable-but-unwritable path is a sandbox/entitlement mismatch that otherwise surfaces later disguised as an IPC bug).
3. The running app creates a FIFO in that container; the CLI resolves the **same** path. **If the two processes resolve DIFFERENT paths → STOP: group-id/entitlement mismatch; fix before anything else.**
4. An MCP client `.mcp.json` `command` = `.../Contents/MacOS/guesswho`, `args:["run"]` can exec it **past Gatekeeper from a QUARANTINED (exported/downloaded) copy** — a locally-built binary has no quarantine xattr and passes spuriously. Stub `run` that connects + exits is enough; no tools yet.
5. `/usr/local/bin` symlink install via `NSWorkspace.requestAuthorization(.createSymbolicLink)` + `FileManager(authorization:)` succeeds and resolves back to the running bundle **— IF the shipping build type permits it.** ⚠️ A **MAS-sandboxed** app generally **cannot** write to `/usr/local/bin` (outside the container, no entitlement covers it); in that case criterion 5 is replaced by "install UX = user manually adds the `Contents/MacOS/guesswho` path to their MCP client config" (or a separate Developer-ID CLI distribution). **This is decided in Phase 0, because it changes the install UX.**

**Distribution (ANSWERED by Adam 2026-07-16): App Store + TestFlight + Setapp.** Explicit direction: **mirror how Allume/Muse handles this** — Muse is a Mac Catalyst app on the same three channels and has already shipped this exact packaging + install-UX seam in production, so Phase 0 inherits Muse's proven approach rather than rediscovering it. The spike must target BOTH the MAS-sandboxed build AND the Setapp (Developer-ID / notarized) build, since the two differ on what the sandbox permits (notably the `/usr/local/bin` symlink and client-exec of `Contents/MacOS`). Concrete Muse mechanics requested from `allume-mcp-cli-helper` — fold in on reply: per-channel signing/entitlement matrix, whether the symlink install works on the MAS build or falls back to copy-path/manual-config, client-spawn behavior on the MAS-installed `.app`, and any App Store / Setapp review notes on the embedded CLI + named pipes.
**Fallback** if MAS bundling/spawn is restricted: match whatever Muse does per channel — likely symlink install on Setapp, copy-path/manual-config UX on MAS (both still exec the same bundled `Contents/MacOS/guesswho`).

**Debugging order (from allume) — check criterion 3 FIRST.** The moment Adam answers distribution and the spike runs on the real ship build type, verify criterion 3 (app + CLI resolve the SAME container path) before anything else. If it fails it is ALWAYS an entitlement / group-id mismatch, never a code bug — **do not debug IPC until it passes.** Everything else in Phase 0 is downstream of it.

**Review cycle** → then Phase 1.

---

## Phase 1 — Transport spine + read-only tools end-to-end

**Goal:** the full spine — relay ⇄ pipes ⇄ host dispatch ⇄ real data ⇄ wire DTO — proven with **read-only** tools. This is where INV-2/3/4 first get tests.

**Work:**
- Vendor `mcp-template`'s EasyMCP + EasyMacMCP (or the pieces we need) as a dependency. Respect the pipe gotchas: reader **keepalive FD** (avoid EOF busy-spin); shutdown ordering (cancel task → wake sentinel `\n` → await → close); persistent `AsyncLineSequence`; one request = one newline-delimited JSON line; helperId + messageId on every message.
- **TRANSPORT CHANGE — per-helper REQUEST pipe (locked in):** EasyMacMCP today uses ONE shared central request FIFO (many helpers → one host) and raw newline-JSON (NOT length-framed). On a shared FIFO, only writes ≤ **PIPE_BUF (512 bytes on Darwin — NOT 64KB; the 64KB figure was wrong)** are guaranteed atomic; above that, two concurrent helpers' writes can INTERLEAVE and tear the newline-framed stream. GuessWho requests can carry large notes/markdown (far over 512B), so the shared-pipe design is a latent tearing bug under concurrent clients. **Fix by mirroring the existing per-helper *response* pipe on the request side:** one request FIFO per `helperId` → exactly ONE writer per pipe → interleaving is structurally impossible at ANY size (a 500KB note writes in multiple non-atomic chunks nobody interleaves with; the line reader reassembles). Keeps newline-JSON framing UNCHANGED (no length-prefix parser on either side), symmetric with `[helperId: HostResponsePipe]` (add `[helperId: HostRequestPipe]`).
- **DISCOVERY (the one cost of per-helper request pipes — nail in Phase 1):** unlike the central request pipe (fixed path, app pre-opens it), the app must LEARN each new helper's request-pipe path. Design: a small **central announce channel** (fixed path) carries ONLY tiny `initialize(helperId:)` / `deinitialize(helperId:)` control messages — these are well under 512B so the shared-pipe atomicity ceiling is never a problem for them. On `initialize`, the app spins up that helper's dedicated request-reader + response-writer; on clean `deinitialize` it tears them down. This reuses the helperId routing key already present everywhere. Keep the per-helper RESPONSE pipe + messageId matching + the ENXIO-fast-fail open probe (O_WRONLY|O_NONBLOCK → ENXIO = "app not running", instant fail vs timeout hang) regardless — orthogonal to the request-side topology.
  - **DESIGN RULE — the announce channel keeps the 512B constraint forever:** it is still a many-writers→one-reader shared FIFO; it is safe ONLY because init/deinit are tiny. **No field of `initialize`/`deinitialize` may ever grow unboundedly** — do NOT add a "client capabilities/metadata" blob to `initialize` in a later version, or the tearing bug re-arms on the control channel. State this in the wire-module doc, not just as the Guard-1 assert.
- **DEAD-HELPER REAPING (Phase 1, NOT Phase 3 — the teardown code is written here):** a helper killed by SIGKILL / crash / client force-quit NEVER sends `deinitialize`. Two consequences, both worse under per-helper request pipes: (a) the host's per-helper request-reader Task lives forever, and (b) `request_pipe_<helperId>` + `response_pipe_<helperId>` FIFO files leak in the group container and accumulate across runs. **Critically, reader EOF is NOT a usable death signal:** `ReadPipe` deliberately holds its OWN `O_WRONLY` keepalive FD (the busy-spin fix — `ReadPipe.swift keepaliveWriterFD`) so an external writer detaching does NOT deliver EOF; a dead helper leaves the per-helper request reader parked, not EOF'd. So reaping MUST be explicit — pick a mechanism in Phase 1:
  - **Liveness** — a heartbeat/last-seen timestamp per helperId (bumped on any request or a periodic ping); the host reaps a helper whose last-seen exceeds a timeout (tears down both its pipes + reader Task).
  - **Launch-sweep** — on app launch, enumerate `request_pipe_*` / `response_pipe_*` in the group container and remove any with no live helper (a fresh app owns no helpers yet, so all pre-existing per-helper FIFOs are stale).
  - This shapes the discovery/teardown design, so decide it BEFORE writing the teardown code (retrofitting after discovery is built = churn). This looks fine in dev (Ctrl-C → deinit fires) and leaks in the field (clients `kill -9` helpers routinely).
  - **Guard 1 — channels strictly typed apart:** the announce channel carries ONLY init/deinit, NEVER a real request. Add a debug assertion that any frame written to the announce pipe is < PIPE_BUF (512B). The moment a real (large) request is routed through the announce channel "just once," the tearing bug returns on the control channel.
  - **Guard 2 — open-before-first-request ordering (a discovery-race that tears under load):** the helper must NOT write its first real request until the app has opened that helper's request-reader. **EasyMacMCP already solves this for free (source-traced):** `HostRequestPipe.startReading` dispatches `isInitialize`/`isDeinitialize` **INLINE** (`await requestHandler(request)`), while tool calls run in a child `Task {}`. The inline dispatch guarantees the per-helper pipes are stood up (in `handleRequest`→`setupResponsePipe`) BEFORE any tool call from that helper is processed. So keeping `initialize` on the announce channel + inline lifecycle dispatch preserves the ordering guarantee with no new code. (An explicit "ready" ack on the response pipe is the fallback if we ever move off the inline-dispatch model — not needed given the current design.)

- **IMPLEMENTATION ANCHORS (inherit, don't invent — source-traced by essentialmcp):**
  - Discovery is **message-driven off `initialize`**, NOT dir-watching (dir-watching is fragile: FSEvents latency, partial-create races, stale-FIFO cleanup). Templates: `EasyMCPHost.setupResponsePipe(for:)` (EasyMCPHost.swift:79) + `HostRequestPipe.startReading` (HostRequestPipe.swift:62).
  - The **only** new code vs today: keep the central `HostRequestPipe` as an **announce-only** reader (it only ever sees init/deinit, which already dispatch inline), and extend `setupResponsePipe` → `setupHelperPipes(for:)` to ALSO create a per-helper `HostRequestPipe` on `request_pipe_<helperId>` (opened + `startReading{ handleRequest }`), stored in `[helperId: HostRequestPipe]` alongside the existing `[helperId: HostResponsePipe]`. `teardownHelperPipes` closes BOTH — invoked on clean `deinitialize` OR by the reaper (see DEAD-HELPER REAPING; do NOT rely on reader EOF, the keepalive FD suppresses it). Helper side: init/deinit → announce FIFO; all tool calls → `request_pipe_<helperId>`.
  - **BUG TO FIX ON INHERIT:** EasyMacMCP's `WritePipe.write` doc comment claims "PIPE_BUF is 65536 on Darwin/Linux" — that's the **Linux** value; **Darwin is 512** (verified in `sys/syslimits.h`). Fix the comment. (This is also why per-helper request pipes are correctness, not just large-note support: even one contact JSON can exceed 512B and interleave on a shared pipe.)
  - **BUG NOT TO COPY:** the base `EasyMCPHost.stopListening` closes response pipes in **un-awaited detached `Task {}`s** — tolerable for write pipes, **WRONG for the deadlock-sensitive read pipes**. Our per-helper request READERS must have their `close()` (which runs cancel → `signalReaderWake` → await task → `readPipe.close()`, HostRequestPipe.swift:44/:95) **awaited individually** on teardown — do NOT fire-and-forget in a loop.
- **Shutdown bite:** the host now runs N request-reader tasks; each must follow cancel → `signalReaderWake` → await → close PER pipe, or the dispatch_io deadlock reappears N times. Keep a ≤PIPE_BUF **tripwire assert** on the announce channel only (control messages must stay tiny); per-helper data pipes need no size cap.
- **Shared wire module** (compiled into BOTH app + relay): `MCPRequest`/`MCPResponse` enums (one case per tool), note-**less** contact/event DTOs, `create(helperId:messageId:parameters:)` validation, pipe-path constants (from Info.plist / xcconfig).
- **Host** (`GuessWhoMCPHost: EasyMCPHost` in the app): `handleRequest` switch → per-tool handlers calling the SAME `ContactsRepository`/`SyncService` the UI uses. The host is **injected** with the app's live instance at launch and **never constructs its own store** (INV-2b). Dynamic, permission-gated `listTools` (a category appears only if its EventKit/Contacts auth is granted + the master toggle is on).
- **Relay CLI**: `run` (MCP stdio) + read-only subcommands.
- Read-only tools v1: `contacts.search`, `contacts.get`, `contacts.listNotes` (sidecar notes), `contacts.listTags`, `contacts.listLinks`, `contacts.listFavorites`, `events.list`, `events.get`, `guides.list`, `guides.get`, `places.list`.
- **Master toggles** in App-Group UserDefaults: `isMCPEnabled` / `isCLIEnabled` (OFF by default; user opts in via app Preferences) + `isMCPReadOnly` / `isCLIReadOnly` (server-side enforced).
- **Bounded reads from day one:** every list/search read takes a `limit` param (+ a cursor/offset for pagination) and enforces a max **response** size — decide truncate-and-flag vs typed error when exceeded. Retrofitting pagination after clients depend on unbounded lists is painful; cheap now, expensive later. (Request side is handled by the per-helper request pipe above; this is the response side.)

**Exit criteria:**
- End-to-end: an MCP client lists + calls a read tool against the running app and gets real data.
- **INV-3 test lands here (first tool):** sentinel-in-Apple-note round-trip proves the note never crosses; structural-absence assertion in encoded JSON.
- **INV-1 test (CI gate):** relay binary does not link `GuessWhoSync` (build/link-line check).
- **INV-2b test:** a read tool reflects an in-memory, not-yet-persisted UI change (observable only if the host shares the app's live instance).
- **INV-5 test (CI):** an iOS build of the app target compiles green with the relay + pipe/wire code excluded (catches the day someone `#if`s the gating wrong).
- **Transport test — concurrent large request (proves the headline fix):** a request carrying a >512B payload (e.g. a multi-KB markdown note body) round-trips intact, AND two concurrent helpers each sending >512B requests both arrive uncorrupted. Without this, the per-helper-request-pipe change is unverified — the tearing bug is silent, load-dependent, and passes casual testing.
- **Transport test — rapid teardown (proves the await-each-close fix):** rapid connect / disconnect / reconnect of a helper N times leaks no reader Tasks and never wedges (guards the un-awaited-detached-close bug we are NOT copying).
- Tools hidden when permission not granted or master toggle off.
- Plain-language schemas only (no "sidecar"/"link"/"EventKit"/"Calendar event" vocabulary — CLAUDE.md product principle).

**Review cycle** → then Phase 2.

---

## Phase 2 — Write tools (GuessWho sidecar data only)

**Goal:** mutations over GuessWho-owned data, routed through the app's real write paths. **No per-call confirmation dialogs** — consent is the read-only toggle (see model above); destructive ops are safe because GuessWho already soft-deletes (tombstones).

**Work:**
- Write tools over **GuessWho-owned sidecar** data only: add/edit/delete **sidecar note** (`ContactNote`), add/edit/delete **tag**, add/remove **link**, set/clear **favorite**, add/edit/delete **sidecar custom field** (a GuessWho sidecar field — NOT written back to the `CNContact`; naming it "sidecar custom field" removes any read as a contact-store write), guide/place create/reorder/delete. (Per v1 SCOPE STATEMENT, EventKit/Contacts *content* writes are OUT of v1 — their own design pass.)
- **Delete = soft-delete/tombstone only** (already how `deleteNote` etc. behave — sets `deletedAt`, recoverable via `allNotes`). No hard-delete in v1.
- **Read-only gate** (`isMCPReadOnly` / `isCLIReadOnly`) rejects writes server-side; writes OFF by default. This IS the consent gate — no modal.
- Standard response timeout holds (no interactive dialogs to wait on). Timeout stays **per-tool declarative** in tool metadata so a future interactive tool can opt into a longer window without a global change.

**Exit criteria:**
- **INV-2 test:** an MCP-driven note/tag write is visible in the running app's UI and pushed to iCloud **without relaunch**.
- **INV-3 write-direction test:** no write tool accepts a note-shaped param that could set/clear the Apple `Contact.note`.
- Writes rejected when `isMCPReadOnly`/`isCLIReadOnly` is on; a "deleted" item is recoverable (tombstone, not destroyed).

**Review cycle** → then Phase 3.

---

## Phase 3 — Preferences UI, install UX, docs, packaging polish

**Goal:** ship-ready.

**Work:**
- App **Preferences**: enable MCP / enable CLI toggles, read-only toggles, copy-helper-path button, install/repair `/usr/local/bin` symlink (auth panel), and guidance to remove it (`rm` — no authorized-delete API).
- Stale-symlink detection: resolve the symlink back to the running bundle; warn on mismatch (a prior install's symlink can point a NEW cli at an OLD app — our only wire-skew surface, so keep wire changes **additive-only**).
- **`.mcp.json` absolute-path repair:** the client config hardcodes `.../Contents/MacOS/guesswho`; a MAS in-place update or a user moving the app can invalidate it, and the relay then silently stops resolving (same skew surface as the symlink, but for the direct-path install). On app launch, verify the shipped helper path resolves; surface a repair hint in Preferences if a known client config points at a stale path.
- `docs/cli-mcp.md`: architecture, the two-process model, tool list, the Apple-note exclusion invariant, install steps, `.mcp.json` example.
- CI: build the helper target; run the wire round-trip + note-exclusion tests.

**Exit criteria:** a user can enable MCP from Preferences, wire up a client, and use read + GuessWho-owned-write tools, with the Apple note provably never exposed.

**Review cycle** → done (v1).

---

## Design notes carried from the planning session
- **Constants:** no second code-gen (EssentialMCP's BuildSettings.swift + assume-unchanged is a per-clone team papercut). Fold pipe/app-group/bundle-id constants into GuessWho's **existing xcconfig** pipeline → Info.plist → `Bundle.main.object(forInfoDictionaryKey:)`. App-group id from ONE xcconfig var in both targets (INV-4).
- **PIPE_BUF (512B on Darwin, not 64KB) → RESOLVED: per-helper request pipe + central announce channel for discovery** (see Phase 1 transport change). One writer per data pipe dissolves the atomicity ceiling entirely; the tiny control messages ride a shared announce channel and stay under 512B. Keeps newline-JSON framing.
- **Timeouts are per-tool + declarative** in tool metadata (read ~10s; a future human-interactive tool can opt into 120s+). No per-call confirmation dialogs in v1, so the default holds everywhere for now.
- **`executeWithErrorHandling`** is EssentialMCP's own app-side wrapper (pattern to replicate), not a library API.
- **swift-sdk:** official `modelcontextprotocol/swift-sdk` 0.12.1+ (Package.swift is truth; the mcp-template README is stale).
- **The app KEEPS `com.apple.developer.contacts.notes`** (its own note UI needs it), so "drop the entitlement" is NOT an available defense — the wire boundary is the only line, hence INV-3's adversarial test.
