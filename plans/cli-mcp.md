# GuessWho CLI + MCP — Implementation Plan

**Author:** `cli-mcp` (guesswho repo) · **Reviewers:** `allume-mcp-cli-helper`, `essentialmcp-helper`, `essential-mcp-research-helper`, Adam
**Status:** APPROVED by both reference agents; all refinements folded in. Distribution ANSWERED (App Store + TestFlight + Setapp; mirror Allume/Muse). All three MAS unknowns RESOLVED by Adam — Muse ships this seam in production (symlink works on MAS via the runtime auth API; client launches the helper which connects to the app; App Review clean). Phase 0 is now a confirmation, not a discovery. **ONE open item:** Adam's (a)-vs-(b) reconciliation of the symlink entitlement wording (blocks nothing structural). · **Date:** 2026-07-16

Phases are executed **serially**. Each phase has explicit exit criteria and a review cycle. We do not start phase *N+1* until phase *N*'s criteria are met and reviewed.

### Provenance map (what's proven vs ours vs open — for whoever executes Phase 0)
- **Verified from Muse's shipping source + inherited:** two-process relay; per-helper request pipe + announce-channel discovery; native-macOS-Mach-O helper embedded per-channel; per-channel app-group derived from ONE shared build var (never hardcoded); hardened runtime + sandbox + `get-task-allow` Debug-only; `Bundle.main.url(forAuxiliaryExecutable:)` as the single helper-path source; copy-path = pasteboard-set; 4-state symlink resolver (`destinationOfSymbolicLink` + `resolvingSymlinksInPath` both sides); symlink install via `NSWorkspace.requestAuthorization(.createSymbolicLink)`; `files.user-selected.read-write` on the app. MAS symlink + client-spawn + App-Review-clean are Adam-confirmed production facts.
- **Our improvements over Muse:** per-helper request pipe (Muse uses a central pipe; ours is needed because PIPE_BUF is 512B and we carry large payloads); INV-3 note-exclusion (more rigorous than Muse's note-handling); the concurrent-large-request test (proves the transport fix Muse never explicitly tested); awaited per-helper read-pipe teardown (avoids needing Muse's watchdog).
- **Held open — Adam only:** the (a)-vs-(b) symlink-entitlement wording. One tagged question, blocks nothing structural.

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
- **INV-4 App + helper derive the app-group id from ONE shared per-channel build var (never a hardcoded string):** ✓VERIFIED in Muse — the group id is team-prefixed AND channel-suffixed (`group.<TEAM>.<parent-bundle-id>`), so the *string differs per channel* (App Store vs Setapp). It works only because both targets expand it from the same build variable within a build. A hardcoded constant, or two vars that drift, = app + helper resolve to different containers = silent FIFO failure. INV-4 is the *static* guarantee; **Phase 0 exit criterion 3 (app + CLI resolve the SAME container path at runtime, on each channel's build) is its runtime verification** — named together on purpose.
- **INV-5 Mac (Catalyst) only for v1:** pipe/wire code gated Mac-only so iOS builds don't pull in FIFO code with no host. Concretely: the relay binary is built + Copy-Files-embedded ONLY on the Catalyst-capable config; **an iOS-only build simply OMITS the Copy Files phase** (it must NOT try to embed a macOS Mach-O into an iOS `.app` — that would fail to codesign). Make the iOS build's absence-of-relay explicit so nobody wonders where it went.

### Consent & safety model (NO per-call confirmation dialogs)
The MCP client is headless — the human is in Claude Desktop / Terminal, not staring at GuessWho — so an in-app modal on an MCP write is a dialog **nobody is watching** (it blocks/times-out the call or forces alt-tab per write). Therefore: **consent is the read-only toggle, granted once in Preferences** (`isMCPReadOnly` / `isCLIReadOnly` — writes OFF by default). Destructive ops are safe because GuessWho deletes are already **soft-delete/tombstone** (`deleteNote` sets `deletedAt`; `notes(at:)` filters live, `allNotes(at:)` recovers) — recoverable, so no hard-delete in v1 and no per-call prompt needed. This also removes the "longer interactive timeout" complexity (the default 10s holds). If Adam wants human-in-the-loop approval for agent writes, design it out-of-band (a notification the user acts on), NOT a modal blocking the tool call — flag as a product decision.

---

## Phase 0 — Catalyst packaging spike (CONFIRM we reproduce Muse's shipping setup) 🔴 GATE

**Goal:** reproduce Muse's proven packaging on GuessWho — a Mac Catalyst `.app` embedding + codesigning a native macOS CLI Mach-O that resolves the shared per-channel App-Group container, spawnable by an MCP client. Muse ships this exact seam on App Store + Setapp today (Adam-confirmed), so Phase 0 is a **confirmation that OUR build reproduces the working setup**, not a discovery of whether it's viable. The remaining GuessWho-specific risk is purely mechanical: getting the per-channel app-group derivation + the symlink entitlement wired identically. **No feature code.** Nothing else starts until this passes.

**Work (mirrors Muse — items marked ✓VERIFIED are read from Muse's source/build config by allume; treat as known-good):**
- New command-line-tool target `guesswho`. ✓VERIFIED Muse posture to copy: `SDKROOT = macosx` (a **native macOS Mach-O**, NOT a Catalyst binary), `ENABLE_HARDENED_RUNTIME = YES`, `app-sandbox = YES` on the helper. It notarizes as part of the app bundle — no separate notarization.
- Helper `.entitlements` ✓VERIFIED (Muse): `com.apple.security.app-sandbox = true`; `com.apple.security.application-groups = [group.$(DEVELOPMENT_TEAM).$(PARENT_BUNDLE_IDENTIFIER)]`; `files.user-selected.read-only = true`; and `get-task-allow` **Debug-only, stripped in Release — do NOT ship get-task-allow.** Group string is expanded per-channel at build time (`CODE_SIGN_ENTITLEMENTS_CONTENTS_TRANSFORMATION = expand-build-settings`).
- **⚠️ THE APP-GROUP ID IS NOT ONE STRING ACROSS CHANNELS ✓VERIFIED.** It is team-prefixed AND channel-suffixed — e.g. `group.T68Z94627S.com.…-appstore` vs `group.T68Z94627S.com.…-setapp`. It works in Muse ONLY because BOTH the app and its embedded helper derive the group from the SAME per-channel build variable, so within one build they always agree. **Do NOT hardcode one app-group string.** Derive it per-channel from one shared build var referenced by BOTH targets (see INV-4). A MAS build whose app + helper resolve to different containers = silent IPC failure — exactly what Phase-0 crit 3 catches. (Muse also keeps a shared non-suffixed `group.com.…` as a cross-channel fallback; Muse's pipe path uses the per-channel one, matching within a build.)
- Per-channel xcconfigs differ in `PRODUCT_BUNDLE_IDENTIFIER` + `PARENT_BUNDLE_IDENTIFIER` (App Store / Setapp variants). Shared: source, entitlements template, hardened-runtime + sandbox posture. GuessWho already has per-config xcconfigs (debug-suffixed ids) — extend that scheme to the three channels.
- App target: add helper as a target **dependency**; Copy Files build phase → `Contents/MacOS`.
- **Runtime helper location ✓VERIFIED (Muse):** ONE call — `Bundle.main.url(forAuxiliaryExecutable: "guesswho")?.path` (the arg is the helper's `PRODUCT_NAME`; `forAuxiliaryExecutable` resolves to `Contents/MacOS/<PRODUCT_NAME>`). **Never string-build the `Contents/MacOS/...` path.** Wrap it in ONE helper function called from every site (prefs pane, installer, symlink status). Muse uses this exact call in all three places.
- App side: a debug hook that creates the FIFO in the group container and prints its path.

**Exit criteria (verify on a RELEASE / exported build with the build type GuessWho actually ships — see distribution question; NOT local Debug):**
1. Embedded CLI exists at `GuessWho.app/Contents/MacOS/guesswho`; `codesign -dvvv` (and `codesign -d --entitlements -`) on the **exported** app shows our team id + the matching app-group entitlement.
2. Running the embedded CLI directly by absolute path resolves the App-Group container dir **AND can actually read+write a temp file inside it at runtime** (a resolvable-but-unwritable path is a sandbox/entitlement mismatch that otherwise surfaces later disguised as an IPC bug).
3. The running app creates a FIFO in that container; the CLI resolves the **same** path. **If the two processes resolve DIFFERENT paths → STOP: group-id/entitlement mismatch; fix before anything else.**
4. **Client-spawn (proven in Muse — confirm ours reproduces it):** an MCP client with `.mcp.json` `command` = `<pasted absolute path>` (either `.../Contents/MacOS/guesswho` or the `/usr/local/bin/guesswho` symlink), `args:["run"]`, launches the helper — **the AI agent launches it, the app never does** — and the helper connects to the running app over the pipes. Test past Gatekeeper from a **real MAS/TestFlight install** (Adam confirms this works for Muse in production). A locally-built binary has no quarantine xattr and passes spuriously — use the shipped artifact.
5. **`/usr/local/bin` symlink install WORKS on MAS (Adam-confirmed for Muse) via a RUNTIME auth API, not a static symlink entitlement** — install via `NSWorkspace().requestAuthorization(to: .createSymbolicLink)` + `FileManager(authorization: auth).createSymbolicLink(…)` (admin auth panel), then resolves back to the running bundle through the 4-state resolver. Carry `com.apple.security.files.user-selected.read-write` on the app (Muse does, all channels). Do NOT add a `/usr/local/bin` absolute-path exception — Muse has none. **[OPEN — confirm with Adam]** whether any profile-side entitlement beyond `files.user-selected.read-write` is also required. The symlink is a shipping option on ALL channels; copy-path remains the always-works fallback.

**Distribution (ANSWERED by Adam 2026-07-16): App Store + TestFlight + Setapp.** Explicit direction: **mirror how Allume/Muse handles this** — Muse is a Mac Catalyst app on the same three channels and has already shipped this exact packaging + install-UX seam in production, so Phase 0 inherits Muse's proven approach rather than rediscovering it. The spike must target BOTH the MAS-sandboxed build AND the Setapp (Developer-ID / notarized) build, since the two differ on what the sandbox permits (notably the `/usr/local/bin` symlink and client-exec of `Contents/MacOS`). Concrete Muse mechanics requested from `allume-mcp-cli-helper` — fold in on reply: per-channel signing/entitlement matrix, whether the symlink install works on the MAS build or falls back to copy-path/manual-config, client-spawn behavior on the MAS-installed `.app`, and any App Store / Setapp review notes on the embedded CLI + named pipes.
**Fallback** if MAS bundling/spawn is restricted: match whatever Muse does per channel — likely symlink install on Setapp, copy-path/manual-config UX on MAS (both still exec the same bundled `Contents/MacOS/guesswho`).

**✅ THE THREE MAS UNKNOWNS ARE RESOLVED — ANSWERED BY ADAM 2026-07-16 (Muse is LIVE in the App Store and working; this is production truth, not inference):**
1. **MAS symlink install WORKS.** ✓VERIFIED MECHANISM (allume read all six Muse channel `.entitlements`): it's a **RUNTIME AUTHORIZATION API, not a static symlink entitlement** — `NSWorkspace().requestAuthorization(to: .createSymbolicLink) { auth, _ in FileManager(authorization: auth).createSymbolicLink(…) }` pops the macOS admin auth panel; the returned `NSWorkspaceAuthorization` is a one-shot, user-granted, out-of-sandbox capability. The sandbox side rides on the standard **`com.apple.security.files.user-selected.read-write`** entitlement on the app (present in all Muse channels) + that runtime grant. **There is NO `com.apple.security.temporary-exception.files.absolute-path.read-write` / `/usr/local/bin` exception in Muse — do NOT add one.** ⚠️ Adam said "there's an entitlement to allow it"; allume could not find a bespoke symlink entitlement in the checked-in plists (only `files.user-selected.read-write`), so **[OPEN — confirm with Adam]** whether he means (a) `files.user-selected.read-write` + the runtime API loosely (most likely, matches the code), or (b) a profile-side/App-Store-Connect capability NOT in the local plist. Do NOT record an entitlement key until Adam confirms. The 4-state resolver + copy-path button ship as the robust baseline; the symlink is proven on MAS.
2. **MAS client-spawn WORKS — and note the correct direction:** **the app NEVER launches the helper.** The AI agent (Claude) launches the CLI MCP server, which then CONNECTS to the running app. Client-spawn of the bundled helper from a MAS-installed app is proven in production. (This is the relay model exactly — the earlier Phase 0 framing "app can spawn a CLI" was imprecise; the *client* spawns it, the helper connects to the app over the pipes.)
3. **App Review is HAPPY with it** — Apple cleared the embedded CLI helper + named-pipe IPC + MCP concept. Muse shipped it. GuessWho is designed to clear the same bar Muse already cleared.

**What this changes for Phase 0:** the packaging seam is no longer an open risk — it is **proven in production by Muse**, and GuessWho mirrors it. Phase 0 becomes a *confirmation that our build reproduces Muse's working setup* (esp. the per-channel app-group derivation + the symlink runtime-auth path), not a discovery of whether the approach is viable. The symlink can be the primary install on all channels; copy-path remains the always-works fallback. **Action:** the symlink MECHANISM is verified (runtime `requestAuthorization(.createSymbolicLink)` + `files.user-selected.read-write`, not a bespoke entitlement); the only OPEN item is Adam confirming whether a profile-side entitlement beyond `files.user-selected.read-write` is also needed (see criterion 5).

**Debugging order (from allume) — check criterion 3 FIRST.** When the spike runs on each real ship build type (App Store, Setapp), verify criterion 3 (app + CLI resolve the SAME container path) before anything else. If it fails it is ALWAYS an entitlement / group-id mismatch (almost certainly the per-channel app-group derivation), never a code bug — **do not debug IPC until it passes.** Everything else in Phase 0 is downstream of it.

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
- App **Preferences**: enable MCP / enable CLI toggles, read-only toggles, **copy-helper-path button** (PRIMARY install on every channel), install/repair `/usr/local/bin` symlink (auth panel, best-effort where the sandbox permits), and guidance to remove the symlink (`rm` — no authorized-delete API).
- **Copy-path is the whole "install" on copy-path channels ✓VERIFIED (Muse):** the button action is literally `UIPasteboard.general.string = helperPath` (from the single `Bundle.main.url(forAuxiliaryExecutable:)` helper). No generated `.mcp.json`, no writing to the client's config. The user pastes the absolute path into their client's `command` field; for us the config is `{"mcpServers":{"guesswho":{"command":"<pasted path>","args":["run"]}}}`.
- **Stale-symlink / resolve-back-to-bundle — the 4-state resolver ✓VERIFIED (Muse `CLISymlinkResolver`, ~60 lines, pure + unit-testable; copy near-verbatim):**
  - **Discriminator:** `try? FileManager.destinationOfSymbolicLink(atPath:)` is the AUTHORITATIVE is-symlink check — it succeeds even on a DANGLING link where `fileExists` lies. Do NOT use `attributesOfItem`/`fileExists` alone; they follow the link and can't tell the four states apart.
  - **Four states:** `notInstalled` (no symlink, no file) · `conflictingFile` (a REAL file/dir occupies the path — tell the user to `rm` it, don't clobber) · `dangling` (symlink whose destination is gone — offer "Reinstall to repair") · `installed` (symlink whose destination exists AND resolves to OUR bundle).
  - **Bundle-identity check (catches the multi-install / wrong-channel trap):** compare `URL(…).resolvingSymlinksInPath().path` of BOTH the symlink destination AND the expected bundle target before declaring `installed`. `resolvingSymlinksInPath` on **both** sides is load-bearing — Setapp/Sparkle bundle paths contain symlinks themselves, so a raw string compare false-negatives a legit install. If resolved-dest ≠ resolved-expected → a symlink pointing at a DIFFERENT (older/other-channel) bundle → treat as **conflict**, not installed. This is exactly why per-channel matters: a Setapp symlink pointing at the MAS bundle surfaces here as a conflict instead of silently talking to the wrong app. Keep wire changes **additive-only** (the only wire-skew surface).
- **`.mcp.json` absolute-path repair:** the client config hardcodes `.../Contents/MacOS/guesswho`; a MAS in-place update or a user moving the app can invalidate it, and the relay then silently stops resolving (same skew surface as the symlink, but for the direct-path install). On app launch, verify the shipped helper path resolves; surface a repair hint in Preferences if a known client config points at a stale path.
- `docs/cli-mcp.md`: architecture, the two-process model, tool list, the Apple-note exclusion invariant, install steps, `.mcp.json` example.
- CI: build the helper target; run the wire round-trip + note-exclusion tests.

**Exit criteria:** a user can enable MCP from Preferences, wire up a client, and use read + GuessWho-owned-write tools, with the Apple note provably never exposed.

**Review cycle** → done (v1).

---

## Design notes carried from the planning session
- **Constants:** no second code-gen (EssentialMCP's BuildSettings.swift + assume-unchanged is a per-clone team papercut). Fold pipe/app-group/bundle-id constants into GuessWho's **existing xcconfig** pipeline → Info.plist → `Bundle.main.object(forInfoDictionaryKey:)`. App-group id **per-channel-derived** from ONE shared build var referenced by both targets (NOT a hardcoded string — it differs App Store vs Setapp; INV-4). Muse expands it via `CODE_SIGN_ENTITLEMENTS_CONTENTS_TRANSFORMATION = expand-build-settings`.
- **PIPE_BUF (512B on Darwin, not 64KB) → RESOLVED: per-helper request pipe + central announce channel for discovery** (see Phase 1 transport change). One writer per data pipe dissolves the atomicity ceiling entirely; the tiny control messages ride a shared announce channel and stay under 512B. Keeps newline-JSON framing.
- **Timeouts are per-tool + declarative** in tool metadata (read ~10s; a future human-interactive tool can opt into 120s+). No per-call confirmation dialogs in v1, so the default holds everywhere for now.
- **`executeWithErrorHandling`** is EssentialMCP's own app-side wrapper (pattern to replicate), not a library API.
- **swift-sdk:** official `modelcontextprotocol/swift-sdk` 0.12.1+ (Package.swift is truth; the mcp-template README is stale).
- **The app KEEPS `com.apple.developer.contacts.notes`** (its own note UI needs it), so "drop the entitlement" is NOT an available defense — the wire boundary is the only line, hence INV-3's adversarial test.
