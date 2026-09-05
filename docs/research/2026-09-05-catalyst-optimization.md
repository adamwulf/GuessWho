# Mac Catalyst optimization baseline — fresh Instruments captures (2026-09-05)

Fresh Time Profiler + os_signpost captures of the Mac Catalyst app to guide
optimization. Two questions drive the work: **time to a populated contacts
list** (cache *publication*, not the first empty frame) and **per-navigation
detail-load cost**, plus where CPU goes on the main thread vs. all threads.

This report is **supporting evidence**; each claim is tagged **[measured]**
(sampled/logged in a verified capture) or **[hypothesis]** (plausible from a
hot path but not A/B-measured). Prior related work:
[startup CPU after batch 2](catalyst-startup-cpu-after-batch2.md),
[detail-load after DL-1…4](contact-detail-load-after.md).

> No personal data: only aggregate counts, durations, and symbol names appear —
> no contact/event names, emails, or record identifiers.

## TL;DR

- **Biggest cost is the EventKit attendee-index warm-up** (`buildAttendeeIndex`
  → `toEvent` over the **entire 15760-occurrence corpus**): **~44–50 % of all
  sampled CPU** and **~99 s wall** at `.background` priority in Debug. It ran
  long enough to abort the first navigation run at the old 90 s readiness gate
  **[measured]**.
- **Time-to-populated-list is gated by the Contacts fetch** (~11–15 s in Debug
  for 1685 contacts) → cache publication; the first painted frame is the
  **empty** list, well before **[measured]**.
- **Per-open detail loads (Debug, warm index): Contact A 743 ms, Contact B
  424 ms, Organization 1009 ms** (log-derived wall); **organization is the
  heaviest open** by CPU too (1.7 s all-thread) **[measured]**. The event open's
  distinctive cost is `GuideAddressMatcher` (Maps-guide address matching,
  ~260 ms) **[measured]**.
- Main-thread CPU is ~framework/runtime (objc/CoreFoundation/Swift/UIKit); the
  app's own main-thread code is only ~2–4 % **[measured]**.
- Candidate directions (unmeasured gains): narrow the attendee-index projection
  + hydrate only matches; a partial contacts-list projection for a faster
  populated list **[hypothesis]**.

## 1. Environment & configuration [measured]

| Item | Value |
|---|---|
| Host | Apple Silicon MacBook Pro (kernel `t6000`), macOS 26.5.2 (25F84) |
| Xcode / xctrace | 26.3 (17C519) / 26.0 (17C519) |
| SDK / target | MacOSX26.2, `arm64-apple-ios17.0-macabi` (Mac Catalyst) |
| DerivedData / traces | `.build/DerivedData` / `.build/profiling` (worktree-local) |
| Branch / final harness | `agent/agent-edc537f7` @ `ecdd424` |
| Date | 2026-09-05, US Central |

### Build commands & outcomes (all `** BUILD SUCCEEDED **`)

```sh
# Debug Catalyst (the profiled configuration)
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData -configuration Debug build

# Release Catalyst (compile-only; validates DEBUG-only harness exclusion, §6)
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData -configuration Release build
```

Debug was rebuilt at each harness commit (`a420e04` → `ba9b95c` → `ecdd424`).
The Debug scheme compiles **with coverage instrumentation**
(`-profile-generate` / `-profile-coverage-mapping` present on 69 compile
invocations) — this inflates **absolute** CPU (see §7).

### Permissions & data — representativeness confirmed [measured]

| Store | Authorization | Count | Source |
|---|---|---|---|
| Contacts | granted (`status=ready`) | **1685** | `startup cache load finished cache=contacts`[^log] |
| Calendar | granted | **1517** (visible window); **15760** (attendee corpus) | `sync.eventkit-fetch` breadcrumbs[^log] |

No TCC prompt blocked any run. The startup **events** task logs
`status=superseded, items=0` — an **expected** invocation outcome (a later
notification-driven reload wins), not a defect; the representative event count
comes from the `sync.eventkit-fetch` breadcrumb.

## 2. Launched-binary verification & the LaunchServices hazard [measured]

The Debug build and the user's installed `/Applications/GuessWho.app` **share
the bundle id `com.milestonemade.guesswho`** (the Debug build carries no
`.debug` suffix — from the built `Info.plist`). `xctrace --launch` routes
through LaunchServices even for the inner executable path, and LaunchServices
ranks the installed `/Applications` copy above a DerivedData dev build. **Early
`xctrace --launch` runs therefore profiled the installed Release app, not this
tree** — until `/Applications` was temporarily unregistered.

Verification used a Python Mach-O `LC_UUID` parser
([`nav_slice.py`'s sibling `machouuid`](2026-09-05-catalyst-optimization.assets/README.md);
`dwarfdump`/`otool`/`lipo`/`codesign`/`ps` are not in the sandbox allow-list),
compared to the per-image `*.symbolsarchive` filenames in each trace's
`symbols/stores/` (named by loaded-image UUID). The completed nav trace's
process metadata independently confirms attribution:
`path=.../Debug-maccatalyst/GuessWho.app`, `arguments="--nav-benchmark"`,
pid 5804, `exit(0)`.

| Binary | UUID | Used by |
|---|---|---|
| Debug `GuessWho.debug.dylib` (`ecdd424`) | `85EADC20-93D5-3E8B-ACFC-7BE491B4D701` | **`debug-nav-2` (completed nav, primary)** |
| Debug `GuessWho.debug.dylib` (`ba9b95c`) | `2E41162C-47D6-371F-9F64-B29B58C42B34` | `debug-nav-1` (aborted nav) |
| Debug `GuessWho.debug.dylib` (`a420e04`) | `86DE3F5E-20B5-3731-A8F6-DDD515A50E18` | `debug-verify2` (startup) |
| Debug stub `GuessWho` | `38A28841-9F6C-31FA-BC06-C950C9DCBAB3` | all Debug traces |
| Installed `/Applications` (arm64, v169) | `C7B114CE-2333-37B6-AD2A-645B28D84E7A` | `debug-launch-tp-1` (installed reference) |

**Retraction:** any startup measurement attributed to "this tree" *before*
`/Applications` was unregistered was actually the substituted installed Release
app (its UUID `C7B114CE` appears in those traces; this tree's UUIDs do not).

### Launch procedure (authorized, reversible) & registration restoration

`lsregister -f` alone could not beat the pile of registered copies (~25 sibling
agent-worktree DerivedData builds + `/Applications`). Per capture:

1. `prune-lsregister.py com.milestonemade.guesswho --keep <Debug .app> --apply`
   — registry-only unregister of 25 stale **DerivedData** copies; never touches
   `/Applications`/Setapp/TestFlight; keeps this build.
2. `lsregister -u /Applications/GuessWho.app` (temporary).
3. `lsregister -f <Debug .app>`.
4. `xctrace record … --launch -- <Debug exec path> --nav-benchmark`.
5. **`lsregister -f /Applications/GuessWho.app`** afterward, on success or abort.

**Registration RESTORED and verified:** `/Applications/GuessWho.app` is
registered again (present in `lsregister -dump`) and is front-ranked (last
`-f`); the installed process (pid 84763) was never killed. The only lasting
change is the pruned sibling DerivedData registrations, which re-register on
their next build. A `GUESSWHO_NAV_BENCHMARK=1` env trigger (`ba9b95c`) also
exists, but `xctrace --env` stalled the launch in two attempts (unexplained
observation); the `--nav-benchmark` **argv** launch is what this report used.

## 3. Reference: installed Release v169 (NOT this tree) [measured]

`debug-launch-tp-1.trace` (Time Profiler, 30 s, pid 54398, `C7B114CE`) profiled
the **installed Release** app. Useful as a shipped-config anchor, but not this
tree, and it includes **state restoration** (reopens the last-viewed contact).

- Launch phases: process start → **Foreground 7.14 s** (first frame = **empty**
  list); Initial Frame → Foreground 326 ms.
- Sampled CPU 8024 ms / 30 s; main 2121 ms (26 %); two **background** threads
  (2700 + 1956 ms) dominate. Main by binary is framework: libobjc 17.5 %,
  CoreFoundation 12.7 %, UIKitCore 10.6 %, libswiftCore 9.8 %; app code ~2.3 %
  (Release frames stripped). CPU-by-5 s peaks at 5–10 s = 2761 ms (Contacts).
- Signpost wall (not additive across overlapping spans): `startup_contacts_cache`
  ≈ 14.4 s, `startup_events_cache` ≈ 2.6 s, `EKPredicateSearch` up to 14.4 s.

## 4. This tree's Debug startup (no navigation) [measured]

`debug-verify2.trace` (30 s, pid 97887, `86DE3F5E`) — startup only, with state
restoration; this tree's app symbols resolve.

- Sampled CPU 10409 ms / 30 s; main 2541 ms (24 %); two background threads
  (3333 + 2593 ms) dominate.
- **App-attributed hot paths (stack presence, all threads, `GuessWhoSync`):**
  `EKEventStoreAdapter.fetchEventsDirectly` 3553 ms (34 %),
  `eventsWithAttendee` 3099 ms (30 %), `buildAttendeeIndex` 3098 ms (30 %),
  `CNContactStoreAdapter.runOnWorkQueue` 2836 ms (27 %),
  `EKEventStoreAdapter.toEvent` (converting ~15760 occurrences) 2560 ms (25 %).
  App **leaf** self-weight is tiny — CPU is inside the EventKit/Contacts
  framework calls the app makes, on background threads.
- Main-thread self-CPU by binary: libobjc 17.2 %, libswiftCore 14.0 %,
  CoreFoundation 11.6 %, UIKitCore 10.8 %; app's own main-thread code ~3.7 %.
- Supporting log: full contact fetch 14834 ms / 1685; state-restored detail load
  7419 ms (its cold attendee window fetch alone 7411 ms).

## 5. Navigation (per-open cost) — this tree

Two runs, both UUID-verified this build:

- **`debug-nav-1`** (`2E41162C`, 135 s, 90 s deadline): **aborted** —
  `startup cache wait timed out`. Contacts (1685) + events (1243) were ready,
  but the **attendee-index warm-up finished at ~99 s** (`attendee index built
  events=15760`), 9 s past the gate, so `attendees` never reached ready. **No
  `nav_open` ran.** Over the window the warm-up is ~44–50 % of all sampled CPU
  (`fetchEventsDirectly` 5555 ms / 49.6 %; `prepareEventsWithAttendeeIndex` /
  `WindowSingleFlightCache.value` 4933 ms / 44.1 %), spread **thinly** across
  the 15–90 s buckets (~100–400 ms per 5 s) — consistent with the
  `.background` priority the source declares for the warm-up task. **[measured]**
- **`debug-nav-2`** (`85EADC20`, 240 s, 180 s deadline after `ecdd424`):
  **completed** — `startup caches ready attendees=ready contacts=1685
  events=1242`, then A → B → organization → event → phantom → `complete`.

### Per-navigation detail-load wall time — LOG-derived [measured]

From `app.contact-load` breadcrumbs (**not** signpost-derived — see limitation).
"core ready" = first card paint; "finished" = full detail completion:

| Open | core ready | full load finished | attendee lookup |
|---|---|---|---|
| Contact A | 37 ms | **743 ms** | 0.2 ms (warm-index hit) |
| Contact B | 28 ms | **424 ms** | 0.2 ms |
| Organization | 27 ms | **1009 ms** | 62 ms (location match) |
| Event | — | **unmeasured** (no trustworthy load-finished breadcrumb) | — |
| Phantom org | — | **unmeasured** (control; no async load) | — |

The once-cold attendee fetch (~7 s cold in §4) is now a **0.2–62 ms warm-index
lookup** — the launch-time warm-up pays off for opens.

### Per-navigation CPU — trace-sliced by log→trace clock alignment [measured]

Recording start `2026-09-05T15:01:18.355-05:00`; each `opening …` log time
(same system clock) maps to a trace offset. **Alignment uncertainty ≈ ±0.5 s.**
Sampled weight (ms) per window
([`nav_slice.py`](2026-09-05-catalyst-optimization.assets/nav_slice.py)):

| Window | wall s | all-thread CPU ms | main-thread CPU ms |
|---|---|---|---|
| readiness + attendee warm-up (arm→A) | 53.9 | **10924** | 1885 |
| Contact A (full) | 8.55 | 691 | 451 |
| Contact B (full) | 8.56 | 489 | 337 |
| **Organization (full)** | 6.42 | **1717** | **831** |
| Event (full) | 6.31 | 974 | 680 |
| Phantom (full, control) | 5.38 | 373 | 261 |
| Contact A (load sub-window 0.95 s) | — | 606 | 385 |
| Contact B (load sub-window 0.51 s) | — | 403 | 271 |
| Organization (load sub-window 1.14 s) | — | 907 | 490 |

Full windows include the 5–8 s idle settle after each open; load sub-windows
(log core-ready→finished) isolate the work.

**Per-open app-attributed hot paths** (stack presence in `GuessWho*`, minus the
always-present `$main`/runloop entry frame):

- **Contact A / B:** `CNContactStoreAdapter.runOnWorkQueue` +
  `CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)` — Contacts XPC
  group-membership fetch dominates a person open.
- **Organization (heaviest):** the same Contacts work +
  `FileSystemSidecarStore.runWithBusyHandling` (sidecar reads).
- **Event:** `GuideAddressMatcher.matches(guides:places:)` /
  `guides(appearingIn:…)` ≈ 260 ms — matching the event's location to Maps
  guides — the distinctive event-open cost.
- **Phantom (control):** only a `ProductionSidecarFileCoordinator.coordinateReading`
  sidecar read; lowest CPU, as expected.

### Material limitation — custom signposts missing from the final trace

The app's `DetailLoadSignpost` / `StartupLoadSignpost` intervals and the
`nav_open` markers were **absent from `debug-nav-2`'s exported `os-signpost`
table** (only Apple-subsystem signposts came through). They **do fire** —
`DetailLoadSignpost.measure` appears in the time-profile stacks, and the same
intervals were captured in the installed-v169 trace — so this is an xctrace
capture gap, not missing instrumentation. Consequently, per-navigation **wall**
is **log-derived** and per-navigation **CPU** is **clock-aligned slice** (±0.5 s)
with verified process attribution; **neither is signpost-derived for this run.**

## 6. Release exclusion validation [measured]

The DEBUG-Catalyst-only harness additions (`benchmark*LoadStatus`,
`EventsRepository.benchmarkLoadSucceeded`, `lastReloadOutcome` usage, and the
`#if DEBUG && targetEnvironment(macCatalyst)` driver) are correctly excluded:
the **Release Catalyst build succeeded** with no reference to them.

## 7. Caveats

- **Debug + coverage.** `-Onone` plus coverage instrumentation inflate
  **absolute** CPU; use Debug numbers for *where time goes* / relative ordering.
  §3 (Release) anchors absolutes.
- **Fresh process, warm filesystem caches** — not cold; no reboot/`purge`, and
  xctrace launched repeatedly (binaries + Contacts/Calendar daemons warm).
- **Coexistence confound.** The installed app (pid 84763) ran throughout and is
  itself active (an `EKEventStoreChanged` window refetch ~every 12 s). Single-
  process traces do not sample its CPU, so cross-process contention is a
  **[hypothesis]**, not measured.
- **State restoration** inflates §3/§4 "startup" (reopens a detail); §5 uses the
  deterministic driver instead.
- **Population marker ≠ first frame.** `startup_contacts_cache` end = cache
  **publication**; painted rows follow (snapshot apply + render), and the first
  painted frame is the **empty** list.
- **Headless symbolication.** Raw `time-sample` addresses don't map (empty
  `dyld-library-load`); the aggregated **`time-profile`** schema resolves
  framework + this tree's Debug app symbols (installed Release frames stripped).
  The **App Launch template** produced a 7.5 GB `trace-data.atrc` that never
  finalized → **Time Profiler** used throughout (it still carries life-cycle
  phases).
- **Benchmark side effect.** Opening the event adopts a sidecar (documented
  adopt-on-open), writing to the shared iCloud container and starting a brief
  events-reload churn — inherent to the harness.

## 8. Prioritized directions

Tags: **[measured]** hot path in a verified trace; **[hypothesis]** gain not
A/B-measured.

1. **EventKit attendee-index warm-up — the dominant cost.** **[measured]**
   `EKEventStoreAdapter.buildAttendeeIndex` runs the full fetch and
   `EKEventStoreAdapter.toEvent` hydrates notes, title, calendar name/color,
   `createdAt`, and attendees for the **entire ~15760-occurrence corpus**
   (44–50 % of sampled CPU; ~99 s `.background` wall; it aborted a nav run).
   **Experiment [hypothesis]:** index a **minimal projection** and hydrate only
   matched results; cache per-calendar color conversion. Also weigh the warm-up
   **priority/scheduling** (today `.background`) against the detail-open latency
   it protects. *Validate with a before/after capture.*
2. **Contacts fetch gates the populated list.** **[measured]**
   `CNContactStoreAdapter` `fetchAll` ≈ 11–15 s (Debug) is the critical path to
   cache publication; `fetchGroupMemberships` also recurs per contact open. Per
   the [key audit](contacts-unified-fetch-key-audit.md), **no fetched key is
   safely removable** (edit round-trip erases unfetched fields), so a faster
   populated list needs an explicit **partial list projection + hydration/
   completeness contract**, not key deletion. **[hypothesis]**
3. **Organization opens are the heaviest detail load** (1.7 s all-thread /
   0.83 s main; 1009 ms wall). **[measured]** Worth a dedicated per-section
   profile (associated-contacts + department scans + sidecar reads).
4. **Event opens: Maps-guide address matching** (`GuideAddressMatcher`,
   ~260 ms). **[measured]** Candidate: index guide/place addresses once rather
   than scanning per open. **[hypothesis]**
5. **Main-thread framework/runtime overhead** (objc/CF/Swift/UIKit; app code
   ~2–4 %; recurring `CUIStructuredThemeStore lookupAssetForKey:` and
   `CA::Transaction::commit()`). **[measured]** Low leverage vs. the background
   EventKit/Contacts work.

### Suggested next captures (for the manager's synthesis)

- A **contention-controlled** run (installed app quit) to test whether the
  attendee warm-up wall drops materially — currently **[hypothesis]**.
- A **Release** navigation capture (needs the harness in a Release-adjacent
  build or an instrumented internal build) for absolute per-open numbers.
- Fix the **os-signpost capture gap** (or record with the Logging template) so
  per-open `contact_detail_load`/`event_detail_load` sub-regions are directly
  measured rather than clock-aligned.

## 9. Preserved evidence

- **Traces (bulky, in `.build/profiling/`, not committed):** `debug-nav-2.trace`
  (`85EADC20`, completed nav), `debug-nav-1.trace` (`2E41162C`, aborted),
  `debug-verify2.trace` (`86DE3F5E`, startup), `debug-launch-tp-1.trace`
  (`C7B114CE`, installed v169).
- **Committed sanitized assets:**
  [`2026-09-05-catalyst-optimization.assets/`](2026-09-05-catalyst-optimization.assets/) —
  `nav_slice.py` (per-window slicer), the aggregated `time-profile` summaries
  per trace, and `README.md` (exact commands, UUIDs, log excerpts, restoration).

[^log]: App log (FellerBuncher), `~/Library/Group Containers/T68Z94627S.com.milestonemade.guesswho/Logs/app-2026-09-05.log`, 2026-09-05: `msg="startup cache load finished" cache=contacts items=1685 status=ready`; `msg="EventKit window fetch finished" events=1517`; `msg="EventKit attendee index built" events=15760`. Emitters: [`GuessWhoAppDelegate`](../../App/GuessWho/GuessWhoAppDelegate.swift:GuessWhoAppDelegate), [`EKEventStoreAdapter`](../../Sources/GuessWhoSync/EKEventStoreAdapter.swift:EKEventStoreAdapter). Navigation driver: [`GuessWhoSceneDelegate.runNavBenchmark`](../../App/GuessWho/GuessWhoSceneDelegate.swift:GuessWhoSceneDelegate); signpost defs: [`DetailLoadSignpost`/`StartupLoadSignpost`](../../App/GuessWho/Support/DetailLoadSignposts.swift:DetailLoadSignpost).
