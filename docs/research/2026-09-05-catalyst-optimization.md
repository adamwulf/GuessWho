# Mac Catalyst optimization findings — Instruments, 2026-09-05

The strongest leads are the work required to publish the contacts cache and the
large EventKit attendee-index build. The completed navigation run also identifies
organization loading and event-to-guide matching as useful follow-up targets.
No production optimization or measured speedup is claimed here.

The worker captured and analyzed the runs; the manager merged its report and
corrected the interpretation against the committed computation outputs and
handoff. **[measured]** means worker-observed sampling or logging, not an
independently repeated measurement. Wall-clock results and launch setup are
worker-reported where the original log/XML is not in the committed bundle.
**[hypothesis]** means a proposed explanation or optimization with no A/B result.
Raw-trace availability after worker closure is unverified; see §9.

## Main findings

- **Attendee preparation is a substantial CPU target.** In the aborted
  135-second run, its preparation frame appears in **4,933 ms / 44.1%** of
  sampled weight. The broader EventKit fetch frame appears in **49.6%**;
  these overlap and must not be added or presented as independent estimates.
  The worker reported about **99 seconds wall time** for a 15,760-occurrence
  warm-up, exceeding the original benchmark timeout.[^1][^4]
- **Contacts loading is the main lead for faster useful content.** The worker
  reported roughly **11–15 seconds** for full-contact loading/publication with
  **1,685 contacts**. Cache publication, logical detail readiness, and a
  populated frame on screen are different boundaries; this session does not
  establish time to the first populated frame.[^4]
- **Warm detail completion was 743 ms, 424 ms, and 1,009 ms** for contact A,
  contact B, and the organization, respectively, according to app breadcrumbs.
  The organization's full navigation window has the largest sampled CPU
  among the five driven windows: **1,717 ms all-thread / 831 ms main**.
  The event window includes about **260 ms** of guide-address-matching stack
  presence. Window attribution is approximate and includes background work.[^3][^4]
- **Framework-heavy samples are still optimization opportunities.** The Debug
  startup capture has about **3.7% main-thread leaf self-weight** in app
  binaries, while the completed run has **5,042 ms main-thread sampled weight**
  in total. The app can trigger expensive framework work; low app leaf weight
  does not prove UI work is unavoidable or inexpensive.[^2][^5]

Start with an optimized, repeatable baseline, then investigate contacts
publication for perceived startup speed and attendee projection/scheduling for
CPU and early-detail latency. Section 8 gives concrete experiments and success
criteria.

## 1. Environment & configuration (worker-recorded)

The worker recorded the following setup and build results. Full build logs and
tool-version output were not committed; the retained record is the evidence
README and worker handoff.[^4][^6]

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
invocations, worker-verified). The overhead was not quantified; Debug and
coverage can change both absolute costs and relative rankings (see §7).

### Data availability (worker-reported)

| Store | Authorization | Count | Source |
|---|---|---|---|
| Contacts | populated read succeeded; access scope not measured | **1685** | Contacts publication breadcrumb[^4] |
| Calendar | populated EventKit read reported | **1517** in an earlier visible window; **1242** at completed-nav readiness; **15760** in attendee corpus | Worker handoff / evidence record[^4][^6] |

The worker reported no blocking TCC prompt. Populated reads establish data
availability, not unrestricted authorization or comparability across runs.
One startup **events** task logged
`status=superseded, items=0` — an **expected** invocation outcome (a later
notification-driven reload wins), not a defect; the representative event count
comes from a successful fetch/publication instead.[^4][^6]

## 2. Launched-binary verification & the LaunchServices hazard [measured]

According to the worker's built-plist and UUID checks, the Debug build and the
user's installed `/Applications/GuessWho.app` **share
the bundle id `com.milestonemade.guesswho`** (the Debug build carries no
`.debug` suffix — from the built `Info.plist`). `xctrace --launch` routes
through LaunchServices even for the inner executable path, and LaunchServices
selected the installed `/Applications` copy despite the requested path in this
session. This is an observed outcome, not a universal ranking rule. **Early
`xctrace --launch` runs therefore profiled the installed Release app, not this
tree** — until `/Applications` was temporarily unregistered.[^4][^6]

Verification used a Python Mach-O `LC_UUID` parser
([`machouuid.py`](2026-09-05-catalyst-optimization.assets/machouuid.py);
`dwarfdump`/`otool`/`lipo`/`codesign`/`ps` are not in the sandbox allow-list),
compared to the per-image `*.symbolsarchive` filenames in each trace's
`symbols/stores/` (named by loaded-image UUID). The completed nav trace's
process metadata independently confirms attribution:
`path=.../Debug-maccatalyst/GuessWho.app`, `arguments="--nav-benchmark"`,
pid 5804, `exit(0)`. The table records those worker-verified identities; raw
process metadata and UUID command output were not committed.[^4][^6]

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
registered again (present in `lsregister -dump`, per the worker). This verifies
registration presence, not future launch precedence; the installed process
(pid 84763) was not killed by the profiling worker. Stale DerivedData
registrations were removed; future launches/builds may register them again.
The navigation flow can also make its normal data changes (§7), so registration
cleanup is not a claim that all application state remained unchanged.[^4][^6]
A `GUESSWHO_NAV_BENCHMARK=1` env trigger (`ba9b95c`) also
exists, but `xctrace --env` stalled the launch in two attempts (unexplained
observation); the `--nav-benchmark` **argv** launch is what this report used.

## 3. Reference: installed Release v169 (NOT this tree) [measured]

`debug-launch-tp-1.trace` (Time Profiler, 30 s, pid 54398, `C7B114CE`) profiled
the **installed Release** app, a different binary from this tree. The worker
reported **state restoration** (a contact detail opened).
Use it as a separately labeled observation, not a controlled baseline or a
conversion factor for Debug costs.[^4][^7]

- The worker reported process start → **Foreground 7.14 s**, and Initial Frame
  → Foreground 326 ms. The phase export is not in the bundle. Foreground is not
  a measurement of populated rows or readiness for interaction; no first-frame
  content claim is made here.[^4]
- Sampled CPU 8024 ms in the nominal 30-second recording (the export has a
  30–35 s tail); main 2121 ms (26 %); two **non-main** threads
  (2700 + 1956 ms) dominate. Main by binary is framework: libobjc 17.5 %,
  CoreFoundation 12.7 %, UIKitCore 10.6 %, libswiftCore 9.8 %; app-binary leaf self-weight ~2.3 %
  (many Release frames unresolved). CPU-by-5 s peaks at 5–10 s = 2761 ms;
  this bucket alone does not identify its cause.[^7]
- Signpost wall (not additive across overlapping spans): `startup_contacts_cache`
  ≈ 14.4 s, `startup_events_cache` ≈ 2.6 s, `EKPredicateSearch` up to 14.4 s,
  as reported by the worker. Raw signpost export is not committed, so these
  remain reported observations rather than independently rechecked values.[^4]

## 4. This tree's Debug startup (no navigation) [measured]

`debug-verify2.trace` (nominal 30 s, pid 97887, `86DE3F5E`) — startup with a
worker-reported restored detail; this tree's app symbols resolve. The retained
export includes a small 30–35 s tail, so its totals describe the exported
capture rather than a mathematically exact 30-second cutoff.[^5]

- Sampled CPU 10409 ms in this export; main 2541 ms (24 %); two non-main threads
  (3333 + 2593 ms) dominate.
- **App-attributed hot paths (stack presence, all threads, `GuessWhoSync`):**
  `EKEventStoreAdapter.fetchEventsDirectly` 3553 ms (34 %),
  `eventsWithAttendee` 3099 ms (30 %), `buildAttendeeIndex` 3098 ms (30 %),
  `CNContactStoreAdapter.runOnWorkQueue` 2836 ms (27 %),
  `EKEventStoreAdapter.toEvent` (converting ~15760 occurrences) 2560 ms (25 %).
  App **leaf** self-weight is tiny — CPU is inside the EventKit/Contacts
  framework/runtime calls the app makes, predominantly off the main thread.
  These are overlapping inclusive frames, not additive costs.[^5]
- Main-thread self-CPU by binary: libobjc 17.2 %, libswiftCore 14.0 %,
  CoreFoundation 11.6 %, UIKitCore 10.8 %; app-binary leaf self-weight ~3.7%.
  This attribution does not include framework work caused by app code.[^5]
- Supporting log: full contact fetch 14834 ms / 1685, worker-reported.
  The full timestamped log lines were not preserved in the committed bundle.[^4]

## 5. Navigation (per-open cost) — this tree

Two runs, both UUID-verified this build:

- **`debug-nav-1`** (`2E41162C`, 135 s, 90 s deadline): **aborted** —
  `startup cache wait timed out`. Contacts (1685) + events (1243) were ready,
  but the **attendee-index warm-up finished at ~99 s** (`attendee index built
  events=15760`), after the driver had timed out; `attendees` had not reached
  ready before that timeout. **No
  `nav_open` ran.** The attendee-preparation frame has 4933 ms / 44.1% of
  sampled weight. The broader `fetchEventsDirectly` frame has 5555 ms / 49.6%;
  it can also include other event fetches and overlaps preparation. The
  process's 15–90 s buckets range from 46 to 790 ms of sampled weight per
  five seconds. Those buckets show intermittent work, not 99 seconds of
  continuously occupied CPU. Source-declared background priority, scheduling,
  IPC/I/O waits, and coexistence are possible contributors; this capture does
  not isolate their causal shares.[^1][^4]
- **`debug-nav-2`** (`85EADC20`, 240 s, 180 s deadline after `ecdd424`):
  **completed** — `startup caches ready attendees=ready contacts=1685
  events=1242`, then A → B → organization → event → phantom → `complete`.
  In this run preparation has 3920 ms / 22.3% of total sampled weight, and
  all caches reached readiness about 49 seconds after the worker-reported
  armed timestamp. The earlier 99-second warm-up is not a stable per-launch
  constant; the two runs are not an optimization A/B comparison.[^2][^4]

### Per-navigation detail-load wall time — LOG-derived [measured]

From worker-transcribed `app.contact-load` breadcrumbs (**not** signpost-derived).
"core ready" is a logical loading milestone; "finished" is the loader's
completion breadcrumb. Neither directly measures a painted frame or completion
of all asynchronous UI work. Original timestamped lines were not committed.[^4]

| Open | core ready | full load finished | attendee lookup |
|---|---|---|---|
| Contact A | 37 ms | **743 ms** | 0.2 ms (warm-index hit) |
| Contact B | 28 ms | **424 ms** | 0.2 ms |
| Organization | 27 ms | **1009 ms** | 62 ms (location match) |
| Event | — | **unmeasured** (no trustworthy load-finished breadcrumb) | — |
| Phantom org | — | **unmeasured** (no trustworthy completion boundary) | — |

The reported **0.2–62 ms warm-index lookups** are consistent with avoiding a
fresh index build on these opens. The contacts and query shapes differ from
any restored-detail observation; this is not a same-query measured speedup
ratio.[^4]

### Per-navigation CPU — trace-sliced by log→trace clock alignment [measured]

Recording start `2026-09-05T15:01:18.355-05:00`; each `opening …` log time
(same system clock) was mapped to a trace offset by the worker. The proposed
**±0.5 s uncertainty was not calibrated** against a shared trace/log marker.
Treat these as exploratory window associations; there is no validated error
bound or repeated-run variance estimate.[^3][^9]
Sampled weight (ms) per window
([`nav_slice.py`](2026-09-05-catalyst-optimization.assets/nav_slice.py)):

| Window | wall s | all-thread CPU ms | main-thread CPU ms |
|---|---|---|---|
| trace start → A (includes launch and warm-up) | 53.9 | **10924** | 1885 |
| Contact A (full) | 8.55 | 691 | 451 |
| Contact B (full) | 8.56 | 489 | 337 |
| **Organization (full)** | 6.42 | **1717** | **831** |
| Event (full) | 6.31 | 974 | 680 |
| Phantom (full comparison window) | 5.38 | 373 | 261 |

Full windows run from one opening breadcrumb to the next (or benchmark
completion). They include the driver's settling delay and unrelated background
work; they are not CPU spent exclusively loading that card. The original
subsecond slices are retained in the evidence output as provisional diagnostics
but omitted here: their boundaries run from opening to loader completion, not
core-ready to completion, and the uncalibrated alignment can materially change
their totals.[^3][^9]

**Per-open app-attributed hot paths** (stack presence in `GuessWho*`, minus the
always-present `$main`/runloop entry frame):

- **Contact A / B:** `CNContactStoreAdapter.runOnWorkQueue` +
  `CNContactStoreAdapter.fetchGroupMemberships(contactLocalID:)` — Contacts XPC
  group-membership fetch is visible (70 ms for A, 64 ms for B), but this does
  not establish dominance of the whole person open.[^3]
- **Organization (heaviest):** the same Contacts work +
  `FileSystemSidecarStore.runWithBusyHandling` (sidecar reads).[^3]
- **Event:** `GuideAddressMatcher.matches(guides:places:)` /
  `guides(appearingIn:…)` ≈ 260 ms — matching the event's location to Maps
  guides — a distinctive frame in this event window.[^3]
- **Phantom (comparison window):** a
  `ProductionSidecarFileCoordinator.coordinateReading` frame has 51 ms of
  stack presence. It has the lowest full-window sampled CPU here, but is not
  an empty or controlled rendering baseline.[^3]

### Material limitation — custom signposts missing from the final trace

The app's `DetailLoadSignpost` / `StartupLoadSignpost` intervals and the
`nav_open` markers were **absent from `debug-nav-2`'s exported `os-signpost`
table**, according to the worker. `DetailLoadSignpost.measure` is present in
sampled stacks, which proves that code path ran but does not prove signpost
emission or collection. The cause of the missing markers is unresolved.
Consequently, per-navigation **wall** is worker-transcribed from logs and
per-navigation **CPU** uses approximate clock-aligned slices of the verified
process; **neither is signpost-derived for this run.** The shared app log also
lacks retained per-line PID evidence, so UUID verification of the sampled
process does not independently prove ownership of every ordinary log line.[^3][^4]

## 6. Release exclusion validation [measured]

The DEBUG-Catalyst-only harness additions (`benchmark*LoadStatus`,
`EventsRepository.benchmarkLoadSucceeded`, `lastReloadOutcome` usage, and the
`#if DEBUG && targetEnvironment(macCatalyst)` driver) are correctly excluded:
the worker reported **Release Catalyst build success at `a420e04`**. Later
commits changed the DEBUG driver trigger, comments, and timeout; they received
Debug builds, but no later Release rebuild is claimed. Manager corrections
after merge only change research documentation and analysis labels.[^4][^6]

## 7. Caveats

- **Debug + coverage.** Optimization and instrumentation differ from shipping
  behavior, and overhead was not measured. Neither absolute costs nor relative
  rankings are guaranteed to carry over. The installed Release run (§3) is a
  different binary and workload, not a calibration factor.
- **Fresh process, warm filesystem caches** — not cold; no reboot/`purge`, and
  xctrace launched repeatedly (binaries + Contacts/Calendar daemons warm).
- **Coexistence confound.** The installed app (pid 84763) ran throughout and is
  itself active (an `EKEventStoreChanged` window refetch ~every 12 s). Single-
  process traces do not sample its CPU, so cross-process contention is a
  **[hypothesis]**, not measured.
- **State restoration** adds detail work to §3/§4 "startup"; §5 uses the
  deterministic driver. These are different workloads, not directly comparable
  startup trials.
- **Population marker ≠ first frame.** A successful `startup_contacts_cache`
  end follows repository publication; a superseded invocation is not a winning
  publication marker. Painted rows require UI work after data becomes available.
  First-frame contents and first-populated-frame timing were not established.
- **Headless symbolication.** Raw `time-sample` addresses don't map (empty
  `dyld-library-load`); the aggregated **`time-profile`** schema resolves
  framework + this tree's Debug app symbols (installed Release frames stripped).
  The **App Launch template** produced a 7.5 GB `trace-data.atrc` that never
  finalized → **Time Profiler** used throughout (it still carries life-cycle
  phases).
- **Benchmark side effect.** Event opening may adopt a sidecar through normal
  app behavior. The worker observed sidecar/reload activity near the event open;
  its causal attribution is uncertain with shared logs and a coexisting app.
  The dataset/restoration state may therefore differ on a repeat run.

## 8. Prioritized next steps

These are proposed experiments, not measured speedups. Prioritize by the outcome
we want: Contacts loading for time to useful content; attendee indexing for
background work and the first detail opened before warm-up completes.

| Priority | Work | Why it is worth doing | Acceptance evidence |
| -------- | ---- | --------------------- | ------------------- |
| 1 — establish the baseline | Repeat the same flow in an optimized internal build without coverage, with controlled restoration, dataset, and other app activity. Measure cache publication and the first populated frame separately. | Current timings are instrumented Debug observations, and only one full navigation run completed. | At least three comparable runs; median and range for contacts publication, populated-frame time, attendee readiness, full detail completion, all-thread CPU, and main-thread CPU. |
| 2 — reduce attendee-index work | Prototype a minimal attendee/location/occurrence projection, hydrating full event details only for selected matches. Separately test warm-up scheduling. | The aborted run contains 4,933 ms of attendee-preparation stack presence (44.1% of sampled weight); the completed run contains 3,920 ms (22.3% over a longer, different workload).[^1][^2] | Same match results and occurrence ordering, no extra repeated window fetches, lower build CPU and wall time; no regression to contact-list readiness or early detail opens. |
| 3 — reduce contacts publication latency | First split fetch, conversion, repository projection, and UI publication timings. Then prototype an explicit partial list model with on-demand full hydration if fetch cost dominates. | Worker-reported full-contact fetches took roughly 11–15 seconds for 1,685 contacts. The existing key audit explains why deleting keys from the complete editable model is unsafe.[^4][^8] | Faster first populated list with stable identity, correct sorting/search, and lossless edits; measure deferred work too so cost is not merely moved into the first interaction. |
| 4 — improve navigation | Start with the organization window and event guide matching; inspect framework descendants and repeated invalidations, then cache or index only demonstrated repeated work. | Organization: 1,717 ms all-thread / 831 ms main in its full window. Event guide-matching frames: about 260 ms of stack presence. These are approximate window attributions.[^3] | Lower per-open CPU and completion latency in repeated opens, correct invalidation after contact/calendar/guide edits, and bounded memory growth. |

For attendee indexing, retain recurrence-occurrence deduplication, latest-matching
occurrence selection, email/location matching, and invalidation behavior. A
per-calendar metadata/color cache is a small candidate only if a focused profile
shows repeated conversion matters. Raising task priority may shorten elapsed
time without reducing CPU and may compete with loading the contacts list; test
those tradeoffs independently.

For navigation, group-membership queries are visible on both person opens
(70 and 64 ms of stack presence), but those figures do **not** establish that
they dominate the whole interaction.[^3] Inspect repeated calls and invalidation
before adding a cache. The event window's guide-matching frames are another
concrete place to test a precomputed address index.

### Measurement improvements before broad optimization

- Restore reliable app signpost capture or add timestamped, process-tagged
  completion breadcrumbs. Check interval IDs and pair begin/end across async
  hops; a helper's presence in a sampled stack does not prove its signposts were
  recorded.
- Tie each navigation boundary to trace time with a verified synchronization
  marker. The current subsecond slices have no validated error bound and should
  not drive a speedup claim.
- Measure an early contact open while the attendee index is still building as
  well as the warm-index flow. Waiting for all caches deliberately excludes the
  interaction most exposed to a long warm-up.
- Control the installed app's activity in a separate run to test contention.
  Its coexistence is recorded; its causal contribution to these delays is not.
- Do not discard main-thread opportunities because app binaries have little
  leaf self-weight. The app can trigger expensive layout, asset lookup,
  text detection, and rendering in frameworks. Follow those stacks back to the
  responsible view updates.
- No comparison run of Apple Contacts was captured. A claim about how much faster
  Contacts is requires a comparable, separately measured workflow.

## 9. Evidence and retention

The merged bundle preserves the worker's numerical aggregation outputs, window
slicer, Mach-O UUID parser, setup record, and selected original handoff messages.
The manager checked the report's CPU figures against these transferred outputs,
corrected inconsistent labels and overclaims, and did not rerun Instruments.

The original trace bundles, XML exports, full shared app log, and matching build
products were **not committed or copied into this worktree**. Their last reported
location was:

```text
/Users/adamwulf/Developer/swift/GuessWho/.ittybitty/agents/agent-edc537f7/repo/.build/profiling/
```

Trace names: `debug-nav-2.trace` (completed), `debug-nav-1.trace` (aborted),
`debug-verify2.trace` (Debug startup), and `debug-launch-tp-1.trace` (installed
Release). After the worker was closed by the authorized merge, path isolation
prevented checking that location or archive retention. **Availability of raw
traces and matching symbols is unverified.** The committed outputs are retained
evidence, but are insufficient to re-export or recalibrate the original traces.

The README contains reconstructed setup/log notes, explicitly distinguished
from verbatim application logs. The handoff file preserves original worker
statements so reported wall times and corrected timestamp provenance remain
auditable. Neither substitutes for a raw process-tagged log export.

### Sources

[^1]: [Original aggregation output — aborted navigation run, CPU weights and buckets](2026-09-05-catalyst-optimization.assets/timeprofile-nav-aborted.md)
[^2]: [Original aggregation output — completed navigation run, CPU weights and buckets](2026-09-05-catalyst-optimization.assets/timeprofile-nav-completed.md)
[^3]: [Original per-navigation slicer output, with manager-added interpretation notes](2026-09-05-catalyst-optimization.assets/per-navigation-cpu.md)
[^4]: [Original worker handoff excerpts — reported wall times, run outcomes, build and registration checks](2026-09-05-catalyst-optimization.assets/worker-handoff.txt)
[^5]: [Original aggregation output — Debug startup, CPU weights and buckets](2026-09-05-catalyst-optimization.assets/timeprofile-debug-startup.md)
[^6]: [Worker-recorded capture metadata and reconstructed command/log notes](2026-09-05-catalyst-optimization.assets/README.md)
[^7]: [Original aggregation output — installed Release v169, CPU weights and buckets](2026-09-05-catalyst-optimization.assets/timeprofile-installed-v169.md)
[^8]: [Contacts fetch-key audit — complete-model and lossless editing constraints](contacts-unified-fetch-key-audit.md)
[^9]: [Window slicer — fixed trace-relative offsets and sampled-weight calculation](2026-09-05-catalyst-optimization.assets/nav_slice.py)
