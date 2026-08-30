# Catalyst cold-start CPU after batch 1 — first 30 s (Release, 2026-08-29)

> **Status: superseded — batch 2 is done.** §5 ("Re-ranked remaining
> opportunities (batch 2)") and §7 were the batch-2 plan; all five items were
> then implemented, reviewed clean, and re-measured in
> [`catalyst-startup-cpu-after-batch2.md`](catalyst-startup-cpu-after-batch2.md)
> (window CPU 7.8 s → 3.3 s). Two code claims below drifted after batch 2: the
> place-corpus cache invalidation is no longer unconditional — it is now scoped
> to place/guide (and unknown-scope) deliveries (batch-2 item B2-4); and the
> Contacts `fetchAll` is now single-flighted (B2-1). Read §5 as executed, not
> planned; treat the after-batch2 report as the current state.

Re-profile of the first 30 seconds of a cold Mac Catalyst **Release** launch,
recorded headless with xctrace on the developer machine (macOS 26.5.2,
xctrace 26.0/17C519), **after** the four batch-1 CPU optimizations landed.
Investigation only — no app code was changed. The pre-optimization baseline,
method, and theme definitions are in
[`catalyst-startup-cpu-baseline.md`](catalyst-startup-cpu-baseline.md)[^base];
this document uses the same build configuration, recording templates, and
analysis pipeline so the numbers compare directly.

**TL;DR.** Batch 1 works. Total sampled CPU in the 30 s window fell from
**≈19.2 s to ≈7.8 s (−59 %)**, and the process now goes **idle at ~21 s**
instead of re-walking the whole sidecar corpus past the end of the window
[^tp][^base]. Three of the four fixes verify unambiguously: ISO-8601/ICU
date-parse CPU collapsed 4.2 s → **7 ms** (libicucore self weight 2.7 s →
25 ms), the `allPlaces()` walk fell 3.9 s → **0.9 s**, and the per-file
`NSFileVersion` conflict scan fell 2.1 s → **~1 ms** — and because the
incremental scan falls back to a full scan whenever the metadata flag is
missing, the storm's disappearance **proves
`NSMetadataUbiquitousItemHasUnresolvedConflictsKey` IS populated** on real
watcher deliveries[^scope]. The watcher debounce (fix 1) removed the
baseline's second full corpus round entirely. What remains: the Contacts
unified fetch is now the largest single operation (1.5 s / 19.2 %), sidecar
read coordination overhead is the largest theme (1.7 s / 22.3 %), and
EventKit window fetches re-run several times (0.9 s / 11.6 %)[^tp].

---

## 1. Method and verification

### Build

```sh
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData build
```

Outcome: **BUILD SUCCEEDED** (log kept at `.build/xcodebuild-release.log`
during the session), product at
`.build/DerivedData/Build/Products/Release-maccatalyst/GuessWho.app`,
bundle id `com.milestonemade.guesswho`. The build is this branch
(`agent/agent-2ec9b328`, forked from `agent/performance`), which contains all
four batch-1 fixes — verified in source before profiling: the watcher
quiet-period debounce[^f1src], the fixed-layout ISO-8601 parser[^f2src], the
`PlaceCorpusCache` generation cache[^f3src], and the metadata-flag-gated
conflict scan[^f4src].

### LaunchServices substitution: hit again, caught again

Exactly as the baseline documented, `xctrace --launch` resolves the `.app`
through LaunchServices by bundle id. The procedure (kill by bundle id →
`prune-lsregister.py --apply` keeping our build → `lsregister -u
/Applications/GuessWho.app` → `lsregister -f <worktree app>`) was run before
**every** launch, and the launched binary path was verified with `pgrep -fl`
**during** every recording:

1. **First App Launch attempt launched the wrong binary.** Mid-run `pgrep`
   showed `/Applications/GuessWho.app/Contents/MacOS/GuessWho` despite the
   prune + unregister + force-register having just run. The recording was
   killed, the trace deleted, and the installed instances killed.
2. **Remedy that worked:** run `lsregister -u /Applications/GuessWho.app` a
   second time immediately before `xctrace record` (launching the installed
   copy had re-registered it). On the retry, `lsregister -u` returned
   `-10814` ("not found") — proof the installed copy was out of the LS
   database — and all three kept recordings then launched the worktree
   binary, confirmed by `pgrep -fl` at the start and middle of each window.
3. The installed app's registration was **restored** afterwards with
   `lsregister -f /Applications/GuessWho.app`.

### Recordings

```sh
xcrun xctrace record --template "App Launch"    --launch <app> --time-limit 30s --output .build/traces/launch-after-1.trace
xcrun xctrace record --template "Time Profiler" --launch <app> --time-limit 30s --output .build/traces/timeprofiler-after-1.trace
xcrun xctrace record --template "App Launch"    --launch <app> --time-limit 30s --output .build/traces/launch-after-2.trace
```

All three exited 54 (the time-limit success code) and finalized
(`UI_state_metadata.bin` present in each bundle). The Time Profiler trace's
thread rows carry pid 96336, matching the mid-run `pgrep` of the worktree
binary — the profiled process is our build[^tp].

### Analysis pipeline

Same as the baseline: `phases.py` (xctrace skill) on the App Launch traces;
the Time Profiler trace's **pre-symbolicated** `time-profile` table exported
to XML and aggregated with the baseline's committed scripts plus a new
substring-matching theme script,
[`theme_report.py`](catalyst-startup-cpu-after-batch1.assets/theme_report.py)
(the baseline's `burst_report.py` matches frame names exactly, so
"static "/"closure #1 in "-prefixed frames — the ISO-8601 parse, `fetchAll` —
show 0 there; the theme script substring-matches and reproduces the
baseline's theme definitions). Generated tables are committed in
[`catalyst-startup-cpu-after-batch1.assets/`](catalyst-startup-cpu-after-batch1.assets/)
so the numbers survive trace-bundle cleanup. `hotspots.py` on the second App
Launch trace cross-checks the shape (coordinated sidecar reads are again the
dominant app-side stacks; its atos pass cannot resolve dyld-shared-cache
system frames — expected headless limitation)[^hs].

### Environment caveats (separate from findings)

- **Headless Catalyst never fires `Foreground`** (window never clicked);
  "Initial Frame Rendering" is the interactivity proxy, as in the baseline.
- Cache-warm cold launches (the app ran minutes earlier), matching the
  baseline's conditions.
- The wrong-binary first attempt ran the **installed** build against the
  same user data container for ~40 s before being killed. That may have
  changed saved UI state: unlike the baseline, this window shows **no**
  `EKEventStoreAdapter.eventsWithAttendee` scan and **no** MapKit/GeoServices
  burst — the baseline attributed both to the state-restored contact card
  and guide places. Treat those two themes as *not measured this run*, not
  as batch-1 wins.
- The first App Launch trace has an anomalous 1.32 s Process Creation phase
  (system-side, pre-app; likely cleanup load from the just-killed wrong-binary
  attempt). The second trace is clean and is used as the representative
  timeline.

---

## 2. Phase timeline (clean App Launch trace)

From `launch-after-2.trace`[^ph2]:

| Start | Duration | Phase |
|-------|----------|-------|
| 00:00.000 | 281.98 ms | Initializing — Process Creation |
| 00:00.281 | ~77 ms | Initializing — System Interface Initialization (two overlapping spans) |
| 00:00.307 | 26.48 ms | Initializing — Static Runtime Initialization |
| 00:00.394 | 56.09 ms | Launching — UIKit Initialization |
| 00:00.451 | 5.97 ms | Launching — UIKit Scene Creation |
| 00:00.456 | 4.43 ms | Launching — didFinishLaunchingWithOptions() |
| 00:00.461 | 35.13 ms | Launching — UIKit Scene Creation |
| 00:00.496 | ~33 ms | Launching — AppKit Init + AppKit Scene Creation |
| 00:00.529 | 12.73 ms | Launching — AppKit Scene Creation (cont.) |
| 00:00.542 | 22.84 ms | Launching — sceneWillConnectTo() |
| 00:00.565 | 50.79 µs | Launching — sceneWillEnterForeground() |
| 00:00.565 | 190.60 ms | Launching — Initial Frame Rendering |

**Process start → first frame ≈ 0.76 s** (baseline: ≈ 1.13 s)[^ph2][^base].
Same shape, every phase equal or faster; the first-frame gain is plausible
but both figures are single runs, so treat the phase-level delta as
indicative, not precise. The anomalous first trace
(`launch-after-1.trace`[^ph1]) shows the identical phase shape after its
slow Process Creation (first frame at 2.04 s, of which 1.32 s is Process
Creation — pre-app, system-side).

`Foreground` never fired (headless caveat). `didFinishLaunching` is still
~4.4 ms — the heavy work stays deferred, so the 30-second story is again the
background window below.

---

## 3. Where the CPU went (Time Profiler, 30 s window)

Totals from the symbolicated `time-profile` aggregation[^tp][^tpr]:

- **Total sampled CPU: ≈7 814 ms** across all threads (baseline: ≈19 182 ms
  → **−59.3 %**).
- **Main thread: 1 055 ms (13.5 %)** (baseline: 1 876 ms → −44 %). No hangs;
  top main-thread leaves are diffuse objc/CF/dyld launch work; GuessWhoSync
  self weight on main is 4 ms.

### The cycle now terminates

CPU by 5 s bucket, all threads (baseline had ≥1.2 s per 2 s bucket still
running at 28–30 s)[^tp][^base]:

| Window | After (ms) | Note |
|---|---|---|
| 0–5 s | 3 279 | launch + first full load + Contacts fetch |
| 5–10 s | 2 056 | settling passes |
| 10–15 s | 1 315 | settling passes |
| 15–20 s | 1 060 | tail of settling |
| 20–25 s | 104 | **idle from ~21 s** |
| 25–30 s | ~0 | idle |

The baseline's signature — the full corpus cycle running 2–14 s, pausing,
then **re-running 22–30 s past the window's end** — is gone. Passes still
repeat during the first ~20 s while iCloud metadata churn settles (sidecar
reads appear in every 2 s bucket from 2–20 s[^theme]), but each pass is far
cheaper (no ICU, no conflict storm, cached place walks), and the pipeline
reaches quiescence inside the window.

### Before/after by theme (all threads, stack presence)

Themes overlap (a sample counts toward every theme its stack touches), so
columns do not sum to 100 %. Before numbers are the baseline doc's theme
table; after numbers are the same definitions computed by
`theme_report.py`[^base][^tp][^theme]:

| Theme | Before ms (% of 19.2 s) | After ms (% of 7.8 s) | Δ |
|---|---|---|---|
| Sidecar coordinated read + decode | 5 100 (26.5 %) | 1 743 (22.3 %) | **−3 357 (−66 %)** |
| ISO-8601 date parse presence | 4 200 (21.8 %) | 7 (0.1 %) | **−4 193 (−99.8 %)** |
| — libicucore self weight | 2 693 (14.0 %) | 25 (0.3 %) | **−2 668 (−99.1 %)** |
| `allPlaces()` corpus walk | 3 900 (20.2 %) | 912 (11.7 %) | **−2 988 (−77 %)** |
| Conflict scan (NSFileVersion) | 2 100 (11.0 %) | ~1 (0.0 %) | **−2 099 (−~100 %)** |
| Contacts unified fetch | 1 900 (10.0 %) | 1 502 (19.2 %) | −398 (−21 %) |
| EventKit attendee scan | 1 400 (7.5 %) | 0 | *not measured this run*[^caveat] |
| EventKit window fetch | 1 300 (6.8 %) | 907 (11.6 %) | −393 (−30 %) |
| Link counts | 1 200 (6.2 %) | 343 (4.4 %) | **−857 (−71 %)** |
| MapKit/Geo resolution (self) | ~450 | 0 | *not measured this run*[^caveat] |
| **TOTAL sampled CPU** | **19 182** | **7 814** | **−11 368 (−59.3 %)** |
| Main thread | 1 876 | 1 055 | −821 (−44 %) |

### The kernel metadata storm

Top kernel leaves, all threads[^base][^tp][^theme]:

| Leaf | Before ms | After ms | Δ |
|---|---|---|---|
| `__getattrlist` | 977 | 317 | −68 % |
| `__open` | 572 | 421 | −26 % |
| `mach_msg2_trap` | 441 | 244 | −45 % |
| `getattrlistbulk` | 226 | 144 | −36 % |
| `stat` | 186 | 67 | −64 % |
| `getxattr` | 122 | not in top 15 (<10) | ~gone |

Of the remaining 317 ms of `__getattrlist`, 256 ms sits inside the
coordinated-read theme (NSFileCoordinator probes on each sidecar read; the
corpus walks read through the same path) and effectively none under conflict
scanning[^theme] — the storm's source has shifted entirely from
`NSFileVersion` enumeration to per-read coordination (opportunity #5).

---

## 4. Verdicts on the four fixes

### Fix 1 — watcher quiet-period debounce + delta-scoped refreshes: WORKED (biggest structural change)

The baseline's second full corpus round (22–30 s, still running at the
window's end) no longer exists; the process is idle from ~21 s (104 ms total
CPU in 20–25 s, ~0 after)[^tp][^base]. The whole-window total fell 59 %,
which is more than the sum of the per-theme decode/scan savings — i.e.
redundant rounds were eliminated, not just cheapened. Residual: passes still
repeat through ~2–20 s while iCloud churn settles; see the re-ranked list.

### Fix 2 — fixed-layout ISO-8601 parser: WORKED (near-total elimination)

`SidecarISO8601.date(from:)` stack presence fell 4 200 ms → 7 ms, and
libicucore self weight fell 2 693 ms → 25 ms (#2 binary in the baseline →
#20 now)[^tp][^base]. The fast path's own leaves are visible and tiny
(`fixedLayoutDate` 5 ms, `decimal` 3 ms, `gregorianDaysSince1970` 2 ms)[^tpr]
— the parser is doing the work without ICU[^f2src]. On its own this fix
removed ≈22 % of the baseline window.

### Fix 3 — `allPlaces()` generation cache + single-flight: WORKED (−77 %)

The walk fell 3 900 ms → 912 ms[^tp][^base]. The remaining cost is real
walks, not cache overhead: during the 2–20 s churn window every watcher
delivery posts `.guessWhoSidecarsDidChange`, and `GuessWhoSync` invalidates
the place corpus on **every** such post regardless of what changed[^inv], so
the generation keeps ticking and walks re-run — exactly the behavior the
cache's own comment predicts under sustained churn[^f3src]. Once churn stops
(~20 s), walks stop entirely. A concrete follow-up exists (below).

### Fix 4 — metadata-flag-gated conflict scan: WORKED, and the flag IS populated

The critical open question is answered: **the metadata conflict flag is
populated.** `conflictScanScope(for:)` falls back to a full per-file
`NSFileVersion` scan (`.all`) if even one delivered metadata item lacks
`NSMetadataUbiquitousItemHasUnresolvedConflictsKey`[^scope]. The after-trace
shows the conflict-scan theme at ~1 ms (baseline 2 100 ms), no
`unresolvedConflictVersions` presence, and the per-file getattrlist storm
collapsed (−68 % `__getattrlist`, −64 % `stat`, `getxattr` gone)[^tp][^theme].
If the flag had come back `nil` on real deliveries, every pass would still
run the full storm — so its absence is positive evidence the flag was
present (evidently `false`/no conflicts) on the live iCloud deliveries.

---

## 5. Re-ranked remaining opportunities (batch 2)

Percentages are of the new 7.8 s window; themes overlap.

### 1. Contacts unified fetch — now the largest discrete op (was #6)

1 502 ms / 19.2 % (baseline 1 900 ms / 10 % — batch 1 barely touched it, so
its share doubled)[^tp][^base]. Concentrated at 2–8 s (617 + 609 + 270 ms
per 2 s bucket), consistent with more than one full fetch during launch
settling[^theme]; 111 ms of it is `mach_msg2_trap` (XPC to contactsd).
Baseline directions stand: count the in-window fetches via breadcrumbs,
enforce single-flight per settling window, audit the fetched key set.

### 2. Per-read coordination overhead + `allKeys()` enumeration (was #5)

The sidecar read theme is now the biggest at 1 743 ms / 22.3 %. Decode is no
longer the bulk of it: `SidecarEnvelope.init(from:)` presence is 771 ms
(within it `SidecarCell.init` 634 ms, `JSONValue.init` 536 ms), leaving
roughly 1 s of coordination/I/O scaffolding — kernel leaves inside the theme:
`__getattrlist` 256 ms, `__open` 77 ms, `read` 69 ms, `stat` 59 ms,
`__mac_syscall` 46 ms[^tpr][^theme]. Separately, directory enumeration
`FileSystemSidecarStore.allKeys()` shows 572 ms / 7.3 % presence[^tpr].
Directions unchanged from the baseline: coordinate once per corpus pass
instead of per file, reuse a `JSONDecoder`, skip coordination when the root
is local-only — plus cache/share the `allKeys()` listing per pass.

### 3. EventKit window fetch re-runs (sibling of old #7)

`eventsWindow(from:to:includeEventKit:)` 907 ms / 11.6 %, of which
`EKEventStoreAdapter.fetchEvents(in:)` is 746 ms; it burst four times
(2–4, 8–10, 10–12, 16–18 s)[^tpr][^theme]. Each settling pass appears to
re-fetch the EventKit window. Cache the EK window per
`EKEventStoreChanged`-generation, or let the events repository's delta path
skip the EK re-fetch when only sidecar keys changed.

### 4. `allPlaces()` residual — scope the notification invalidation

912 ms / 11.7 %. Local writes already invalidate only for `.place`/`.guide`
keys, but the `.guessWhoSidecarsDidChange` observer invalidates
unconditionally[^inv], so every watcher delivery during churn defeats the
cache. The watcher already computes delta key sets[^f1src]; carrying the
changed kinds into the notification (or checking them in the observer) would
let contact/event-only churn keep the cache warm and collapse most of the
remaining walks.

### 5. Fold `linkCounts` and `allContactTimestamps` into the reload pass (was #8, + new)

`linkCounts(ofKind:)` shrank to 343 ms / 4.4 % (−71 %, mostly from running
less often), and a theme the baseline didn't call out is now visible at the
same altitude: `GuessWhoSync.allContactTimestamps()` at 434 ms / 5.6 %
presence[^tpr] — another whole-corpus sidecar walk per contacts reload.
Both re-read link/contact sidecars the repository pass already touches; fold
them into that pass or maintain the counts incrementally.

### 6. Restored-card EventKit attendee scan (old #7) — re-measure first

Absent from this window (0 ms; baseline 1 400 ms / 7.5 %). Nothing in batch 1
targets it, and the likely cause is a state-restoration difference (see
caveats), not a fix. Before investing, re-profile with a restored contact
card and confirm it still costs ~1.4 s; the baseline's directions (defer,
cache per contact, narrow the window) remain sensible.

Not worth ranking now: MapKit/Geo (absent this run, was ~2–3 %),
dyld/static-init (~launch phases already lean), main-thread first layout
(diffuse, −44 % vs. baseline).

---

## 6. Artifacts

Trace bundles (large, **not** committed; delete when done):

- `.build/traces/launch-after-1.trace` — App Launch, anomalous Process
  Creation (kept as evidence; phase shape agrees post-creation).
- `.build/traces/launch-after-2.trace` — clean App Launch trace (primary
  timeline).
- `.build/traces/timeprofiler-after-1.trace` — 30 s Time Profiler trace
  (primary CPU source).
- `.build/traces/tp-after.xml` — the exported `time-profile` table (7.6 MB;
  the baseline's equivalent export was ~2.5× larger — the CPU drop is
  visible even in export size).

Committed analysis assets in
[`catalyst-startup-cpu-after-batch1.assets/`](catalyst-startup-cpu-after-batch1.assets/):
`theme_report.py` (new substring theme aggregation),
`tp-after-report.md` (full `time_profile_report.py` output),
`theme-after.md` (theme/bucket/kernel tables), `phases-launch-after-1.md`,
`phases-launch-after-2.md`, and `hotspots-launch2.md` (cross-check). To
re-derive from the trace: export the `time-profile` table with
`xcrun xctrace export --input <trace> --xpath
'/trace-toc/run/data/table[@schema="time-profile"]' --output tp.xml` and run
the scripts on `tp.xml`.

## 7. Limitations / next steps

- One Time Profiler run (the CPU-theme ranking is robust to run noise; exact
  ms are ±). Two App Launch runs; phase timings are single-run indicative.
- The attendee-scan and MapKit themes were not exercised this run
  (state-restoration difference) — re-measure before acting on old #7.
- Cache-warm, headless, no `Foreground`/TTI (unchanged from baseline).
- Pass counts during the 2–20 s settling window weren't counted; the
  watcher's log breadcrumbs can quantify them before batch-2 item 4.

[^base]: [Pre-optimization baseline doc — method, phase table, theme table, ranked opportunities](catalyst-startup-cpu-baseline.md)
[^tp]: [Time Profiler trace, time-profile table aggregation](../../.build/traces/timeprofiler-after-1.trace)
[^tpr]: [Committed full aggregation output](catalyst-startup-cpu-after-batch1.assets/tp-after-report.md)
[^theme]: [Committed theme/bucket/kernel tables](catalyst-startup-cpu-after-batch1.assets/theme-after.md)
[^ph1]: [Phase table, first App Launch trace](catalyst-startup-cpu-after-batch1.assets/phases-launch-after-1.md)
[^ph2]: [Phase table, second (clean) App Launch trace](catalyst-startup-cpu-after-batch1.assets/phases-launch-after-2.md)
[^hs]: [hotspots.py cross-check on the second App Launch trace](catalyst-startup-cpu-after-batch1.assets/hotspots-launch2.md)
[^scope]: [Missing flag ⇒ full-scan fallback](../../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.conflictScanScope(for:emptyItemsAreComplete:))
[^f1src]: [Watcher quiet-period debounce + delta key mapping](../../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.quietPeriodElapsed())
[^f2src]: [Fixed-layout parser tried before ICU](../../Sources/GuessWhoSync/SidecarISO8601.swift:SidecarISO8601.date(from:))
[^f3src]: [Generation cache and its churn caveat](../../Sources/GuessWhoSync/GuessWhoSync+Guides.swift:PlaceCorpusCache)
[^f4src]: [Conflict-flag projection from NSMetadataItem](../../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.metadataConflictItem(from:))
[^inv]: [Unconditional invalidation, called from the `.guessWhoSidecarsDidChange` observer registered in `GuessWhoSync.init`](../../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.invalidatePlaceCorpus())
[^caveat]: [Environment caveats §1 — restored-state difference this run](#1-method-and-verification)
