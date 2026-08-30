# Catalyst cold-start CPU after batch 2 — first 30 s (Release, 2026-08-29)

Re-profile of the first 30 seconds of a cold Mac Catalyst **Release** launch,
recorded headless with xctrace on the developer machine (macOS 26.5.2,
xctrace 26.0/17C519), **after** the five batch-2 CPU optimizations landed on
top of batch 1. Investigation only — no app code was changed. The
pre-optimization baseline is
[`catalyst-startup-cpu-baseline.md`](catalyst-startup-cpu-baseline.md)[^base];
the after-batch-1 report (whose re-ranked list batch 2 implemented) is
[`catalyst-startup-cpu-after-batch1.md`](catalyst-startup-cpu-after-batch1.md)[^b1].
Build configuration, recording templates, and analysis pipeline are identical
to both, so the numbers compare directly.

**TL;DR.** Batch 2 works, and the launch window is now close to the floor.
Total sampled CPU in the 30 s window fell from the baseline's **≈19.2 s** to
**≈7.8 s** after batch 1 to **≈3.3 s** now (**−58 % vs. batch 1, −83 % vs.
baseline**), and the process goes **idle at ~8 s** (batch 1: ~21 s; baseline:
still churning at 30 s)[^tp][^theme][^b1][^base]. All five batch-2 fixes
verify, four of them with direct breadcrumb evidence: exactly **one** full
Contacts fetch per launch (log-proven single-flight), exactly **one**
underlying EventKit window fetch per launch with every later request a cache
hit (bursts: 4 → 1), the sidecar read theme fell 1 743 → **233 ms** under
bulk coordination, `allPlaces()` fell 912 → **190 ms** (one initial walk,
zero churn re-walks), and the `linkCounts`/`allContactTimestamps` duplicate
corpus walks (777 ms combined) are **gone**, replaced by a fused projection
pass measuring 15 ms[^tp][^theme][^mk][^log]. What remains is dominated by
the intrinsic cost of the single Contacts unified fetch (1 214 ms — now
36.8 % of a much smaller window) plus diffuse first-launch framework work;
further optimization is into diminishing returns (§6).

---

## 1. Method and verification

### Build

```sh
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData build
```

Outcome: **BUILD SUCCEEDED** (log kept at `.build/xcodebuild-release-b2.log`
during the session), product at
`.build/DerivedData/Build/Products/Release-maccatalyst/GuessWho.app`,
bundle id `com.milestonemade.guesswho`. The build is this branch
(`agent/agent-0638a25a`, forked from `agent/performance`), which contains
batch 1 **and** all five batch-2 fixes — verified in history and source
before profiling: single-flight `fetchAll` (`c4b9424` + invalidation
`14bafbd`)[^sf1], the fused contacts-reload projection (`5dbbec7`)[^sf5],
bulk corpus-read coordination (`6f551b5` + provenance/budget follow-ups
`51660fd`…`164ff39`)[^sf2], EventKit window-fetch coalescing with
breadcrumbs (`8d42458`, `07c6027`)[^sf3], and scoped place-cache
invalidation (`25c73e7`)[^sf4].

### LaunchServices procedure (no substitution this time)

Same hazard and same procedure as both prior sessions[^base][^b1]: before
**every** launch — kill any instance by binary path (`pkill -9 -f
"GuessWho.app/Contents/MacOS/GuessWho"`), `prune-lsregister.py … --apply`
keeping the worktree build (first run removed 7 stale agent-worktree
registrations), `lsregister -f <worktree app>`, and `lsregister -u
/Applications/GuessWho.app` immediately before `xctrace record` (run twice
before the first launch). Before the second and third launches that
pre-launch unregister returned `-10814` ("not found") — the installed copy
was confirmed still out of the LS database. The launched binary path was verified with
`pgrep -fl` **during** every recording window (twice per window); all three
recordings ran
`…/agent-0638a25a/repo/.build/DerivedData/Build/Products/Release-maccatalyst/GuessWho.app/Contents/MacOS/GuessWho`.
The Time Profiler trace's thread rows carry pid 48450, matching the mid-run
`pgrep` — the profiled process is our build[^tpr]. The installed app's
registration was **restored** afterwards with `lsregister -f
/Applications/GuessWho.app`.

### Recordings

```sh
xcrun xctrace record --template "App Launch"    --launch <app> --time-limit 30s --output .build/traces/launch-after-b2-1.trace
xcrun xctrace record --template "Time Profiler" --launch <app> --time-limit 30s --output .build/traces/timeprofiler-after-b2.trace
xcrun xctrace record --template "App Launch"    --launch <app> --time-limit 30s --output .build/traces/launch-after-b2-2.trace
```

All three exited 54 (the time-limit success code) and finalized
(`UI_state_metadata.bin` present in each bundle). No recording was discarded
— unlike both prior sessions, LaunchServices never substituted the wrong
binary.

### Analysis pipeline

Same as both prior reports: `phases.py` (xctrace skill) on the App Launch
traces[^ph1][^ph2]; the Time Profiler trace's **pre-symbolicated**
`time-profile` table exported to XML (`tp-after-b2.xml`, 4.6 MB — batch 1's
was 7.6 MB, the baseline's ~19 MB; the CPU drop is visible in export size
alone) and aggregated with the baseline's `time_profile_report.py`[^tpr] and
batch 1's substring `theme_report.py`[^theme], plus a new
[`extra_markers.py`](catalyst-startup-cpu-after-batch2.assets/extra_markers.py)
pass for the batch-2-specific symbols (`contactReloadProjection`,
`allContactTimestamps`, `walkCorpus`, `EventWindowFetchCoordinator`,
…)[^mk]. `hotspots.py` on the clean App Launch trace cross-checks the shape
(its atos pass cannot resolve dyld-shared-cache system frames — expected
headless limitation)[^hs]. The one unnamed hot GuessWhoSync frame
(`0x10683092f`, 62 % stack presence) was resolved via `atos` against the
build's dSYM: it is again a linker `<deduplicated_symbol>` pass-through
thunk (load addr `0x106700000` + `0x130930`), the same phenomenon the
baseline documented — not a real hotspot[^tpr][^base].

**New this run:** the batch-2 breadcrumbs give direct, non-statistical
evidence. The app's file log for the recorded windows (excerpt committed[^log])
carries `sync.contact-fetch` start/finish lines with fetch ids, caller
counts, and durations[^sf1], and `sync.eventkit-fetch`
started/finished/cache-hit/invalidated lines[^sf3]. Log timestamps are UTC:
01:45:04 / 01:47:14 / 01:48:20 correspond to the three recordings
(20:45 / 20:47 / 20:48 CDT).

### Environment caveats (separate from findings)

- **Headless Catalyst never fires `Foreground`** (window never clicked);
  "Initial Frame Rendering" is the interactivity proxy, as in both priors.
- Cache-warm cold launches (the app ran minutes earlier), matching both
  priors' conditions.
- The EventKit **attendee scan** and **MapKit/Geo** themes are again absent
  (0 ms). They were absent after batch 1 too, attributed to a
  state-restoration difference — nothing in batch 1 or 2 targets them, so
  they remain *not measured*, not fixed[^b1][^theme].
- One Time Profiler run (per-theme ms are ±run noise; the structural
  signals — pass counts, burst counts, idle point — are breadcrumb- and
  bucket-backed). Two App Launch runs.
- The first App Launch trace has an anomalous 775 ms Process Creation phase
  (system-side, pre-app — first launch immediately after the build; batch 1's
  first trace showed the same artifact at 1.32 s). Its phase shape after
  creation matches the clean trace, which is used as the representative
  timeline[^ph1][^ph2].

---

## 2. Phase timeline (clean App Launch trace)

From `launch-after-b2-2.trace`[^ph2]:

| Start | Duration | Phase |
|-------|----------|-------|
| 00:00.000 | 279.97 ms | Initializing — Process Creation |
| 00:00.279 | ~55 ms | Initializing — System Interface Initialization (two overlapping spans) |
| 00:00.305 | 30.26 ms | Initializing — Static Runtime Initialization |
| 00:00.384 | 74.25 ms | Launching — UIKit Initialization |
| 00:00.458 | 3.67 ms | Launching — UIKit Scene Creation |
| 00:00.462 | 4.27 ms | Launching — didFinishLaunchingWithOptions() |
| 00:00.466 | 42.84 ms | Launching — UIKit Scene Creation |
| 00:00.509 | ~29 ms | Launching — AppKit Init + AppKit Scene Creation |
| 00:00.538 | 13.82 ms | Launching — AppKit Scene Creation (cont.) |
| 00:00.552 | 24.31 ms | Launching — sceneWillConnectTo() |
| 00:00.577 | 63.17 µs | Launching — sceneWillEnterForeground() |
| 00:00.577 | 194.35 ms | Launching — Initial Frame Rendering |

**Process start → first frame ≈ 0.77 s** — statistically unchanged from
batch 1 (≈ 0.76 s; baseline ≈ 1.13 s)[^ph2][^b1][^base]. Expected: batch 2
targets the background settling window, not the first frame, and
`didFinishLaunching` remains ~4 ms because the heavy work is deferred. The
anomalous first trace shows the identical shape after its slow Process
Creation (first frame at 1.70 s, of which 775 ms is Process Creation)[^ph1].

---

## 3. Where the CPU went (Time Profiler, 30 s window)

Totals from the symbolicated `time-profile` aggregation[^tpr]:

- **Total sampled CPU: ≈3 301 ms** across all threads (batch 1: ≈7 814 ms →
  **−57.8 %**; baseline: ≈19 182 ms → **−82.8 %**).
- **Main thread: 854 ms (25.9 %)** (batch 1: 1 055 ms; baseline: 1 876 ms).
  No hangs; top main-thread leaves are diffuse objc/CF/dyld launch work;
  GuessWhoSync self weight on main is 4 ms.

### The window now goes idle at ~8 s

CPU by 2 s bucket, all threads (batch 1 idled at ~21 s; the baseline was
still re-walking the corpus at 30 s)[^theme][^b1][^base]:

| Window | CPU ms | Note |
|---|---|---|
| 0–2 s | 920 | process launch + first frame (themes ~15 ms of it) |
| 2–4 s | 1 658 | first full load: contacts fetch + EK fetch + corpus walk |
| 4–6 s | 567 | contacts fetch continues (558 ms of it) |
| 6–8 s | 138 | contacts fetch tail |
| 8–30 s | ~18 total | **idle from ~8 s** (1/2/1/0/14/0… ms per bucket) |

The breadcrumb log agrees: in the Time Profiler window, after the initial
gather (1 281 metadata results) and **one** full watcher pass at ~4 s, no
further watcher pass fired at all; in the two App Launch windows the full
pass is followed only by a handful of tiny **delta** passes (changed=1–3
keys each, the app's own settling churn), the last ~12 s in — each costing
too little to register in the buckets[^log][^theme].

### Three-way theme table (all threads, stack presence)

Themes overlap (a sample counts toward every theme its stack touches), so
columns do not sum to 100 %. Baseline and batch-1 columns are those reports'
theme tables; batch-2 numbers are the same definitions computed by the same
`theme_report.py`[^base][^b1][^theme][^mk]:

| Theme | Baseline ms (% of 19.2 s) | After b1 ms (% of 7.8 s) | After b2 ms (% of 3.3 s) | Δ b2 vs b1 |
|---|---|---|---|---|
| Contacts unified fetch | 1 900 (10.0 %) | 1 502 (19.2 %) | 1 214 (36.8 %) | −288 (−19 %) |
| Sidecar coordinated read + decode | 5 100 (26.5 %) | 1 743 (22.3 %) | 233 (7.1 %) | **−1 510 (−87 %)** |
| — `allKeys()` enumeration | (inside read theme) | 572 (7.3 %) | 100 (3.0 %) | **−472 (−83 %)** |
| EventKit window fetch | 1 300 (6.8 %) | 907 (11.6 %) | 316 (9.6 %) | **−591 (−65 %)** |
| `allPlaces()` corpus walk | 3 900 (20.2 %) | 912 (11.7 %) | 190 (5.8 %) | **−722 (−79 %)** |
| `linkCounts` | 1 200 (6.2 %) | 343 (4.4 %) | 0 | **−343 (−100 %)** |
| `allContactTimestamps` | (not broken out) | 434 (5.6 %) | 0 | **−434 (−100 %)** |
| ISO-8601 date parse | 4 200 (21.8 %) | 7 (0.1 %) | 4 (0.1 %) | held (batch-1 win) |
| Conflict scan (NSFileVersion) | 2 100 (11.0 %) | ~1 (0.0 %) | 0 | held (batch-1 win) |
| EventKit attendee scan | 1 400 (7.5 %) | 0 | 0 | *not measured either run*[^b1] |
| MapKit/Geo resolution (self) | ~450 | 0 | 0 | *not measured either run*[^b1] |
| **TOTAL sampled CPU** | **19 182** | **7 814** | **3 301** | **−4 513 (−57.8 %)** |
| Main thread | 1 876 | 1 055 | 854 | −201 (−19 %) |

### The kernel metadata storm is over

Top kernel leaves, all threads[^base][^b1][^theme]:

| Leaf | Baseline ms | After b1 ms | After b2 ms |
|---|---|---|---|
| `__getattrlist` | 977 | 317 | 94 |
| `__open` | 572 | 421 | 71 |
| `mach_msg2_trap` | 441 | 244 | 134 |
| `getattrlistbulk` | 226 | 144 | 24 |
| `stat` | 186 | 67 | 32 |
| `getxattr` | 122 | <10 | <6 (not in top 15) |

The remaining `mach_msg2_trap` is mostly XPC to contactsd inside the
Contacts fetch (69 ms) and EventKit (38 ms) — IPC intrinsic to those
fetches, not file-metadata churn[^theme].

---

## 4. Verdicts on the five batch-2 fixes

### B2-1 — Contacts fetchAll single-flight: WORKING AS DESIGNED; CPU −19 % (now the dominant remaining op)

The breadcrumbs answer the baseline's open question directly: each of the
three recorded launches ran **exactly one** full unified fetch —
`full contact fetch started fetchID=1` … `finished callers=1 contacts=1662
durationMs=4433/4192/4379` — and no second fetch ever started in any 30 s
window[^log][^sf1]. There is no stacked duplicate fetch left to eliminate.
The theme's CPU fell 1 502 → 1 214 ms (−19 %); what remains is the
*intrinsic* cost of one full fetch of 1 662 unified contacts with 27
requested optional keys (`enumerateAllContacts` presence is 1 184 ms of the
1 214, spread 2–8 s, ~4.3 s wall on the Contacts work queue)[^tpr][^theme].
`callers=1` also means no concurrent caller even attempted to join
in-window — the batch-1 delta-scoping had already removed most re-triggers,
and the single-flight now guarantees it. Further gains here mean cheapening
the *one* fetch (key-set audit, deferral of non-list keys), not preventing
extra ones.

### B2-2 — bulk-coordinated corpus reads: WORKED (read theme −87 %)

The sidecar read theme fell 1 743 → 233 ms, and its composition changed
shape: the per-file `NSFileCoordinator` scaffolding is gone, replaced by the
new bulk machinery visible in the stacks — `walkCorpus` 438 ms total across
all corpus users, within it `coordinatedCorpusRead` 213 ms (one directory
claim per walk via `ProductionSidecarFileCoordinator.coordinateReading`,
223 ms) and `visitCapturedCorpus` 227 ms[^tpr][^mk][^sf2]. `allKeys()`
enumeration fell 572 → 100 ms. Decode also shrank with fewer passes and the
reused decoder: `SidecarEnvelope.init(from:)` 771 → 232 ms, `JSONValue.init`
536 → 179 ms[^b1][^tpr]. Kernel-side, the coordination probe storm collapsed
(vs. batch 1: `__getattrlist` −70 %, `__open` −83 %, `getattrlistbulk`
−83 %)[^theme].

### B2-3 — EventKit window-fetch coalescing: WORKED (bursts 4 → 1, theme −65 %)

Batch 1 saw `eventsWindow`/`fetchEvents` burst **four** times (2–4, 8–10,
10–12, 16–18 s)[^b1]. Now there is **one** burst (2–4 s bucket only), and
the new `sync.eventkit-fetch` breadcrumbs prove the topology: per launch,
exactly one `EventKit window fetch started` (574–694 ms wall, 1 569 events)
followed by only `cache hit` lines (5, 1, and 5 across the three launches;
the sole invalidation is the launch-time `calendar-access-request`, before
the first fetch)[^log][^sf3]. Theme CPU fell 907 → 316 ms;
`EKEventStoreAdapter.fetchEvents(in:)` 746 → 254 ms, now routed through
`EventWindowFetchCoordinator.fetch` (254 ms presence — the coordinator's own
overhead is negligible)[^tpr][^mk].

### B2-4 — scoped `allPlaces` cache invalidation: WORKED (−79 %, zero churn re-walks)

`allPlaces()` fell 912 → 190 ms, all of it in the 2–4 s bucket — i.e. the
**initial** corpus load (plus the full watcher pass's refresh, coalesced by
the batch-1 single-flight cache), once, with zero walks afterwards[^theme].
After batch 1 the cache was defeated by every watcher delivery
(unconditional invalidation on `.guessWhoSidecarsDidChange`); the observer
now invalidates only when the delivery requires a full refresh or its
changed keys name a place/guide[^sf4], so the contact/event-scoped delta
passes seen in the App Launch windows[^log] no longer tick the generation —
and the measured window shows exactly the predicted collapse of the batch-1
residual: one walk burst, then nothing.

### B2-5 — fused contacts-reload corpus pass: WORKED (duplicate walks eliminated)

The two whole-corpus walks the contacts reload used to add are at **zero**:
`linkCounts(ofKind:)` 343 → 0 ms, `allContactTimestamps()` 434 → 0 ms (and
`linkedEndpoints` 0)[^b1][^mk]. In their place, the fused
`contactReloadProjection()` — one pass over contact/link sidecars feeding
counts, timestamps, and endpoints together[^sf5] — shows just 15 ms of
direct stack presence; the walk it performs rides the shared
bulk-coordinated corpus machinery counted in B2-2's 233 ms read theme (async
queue hops detach the projection frame from the per-file work, so 15 ms is
its attributable floor, and the whole read theme is its ceiling). Either
way: 777 ms of duplicated walking became a share of a 233 ms theme, ≥−70 %
and plausibly ~−98 %.

---

## 5. Cross-checks

- **Second App Launch run (same template as batch 1's cross-check):**
  in-window samples fell 19 790 → 3 788 (−81 %) against batch 1's
  `hotspots-launch2.md`, with the dominant app-side stacks now the Contacts
  fetch (~22 % of samples, Contacts/ContactsPersistence/CoreData frames) and
  the same GuessWhoSync `<deduplicated_symbol>` thunk — consistent with the
  Time Profiler picture on an independent run[^hs][^b1].
- **The profiled pid** in the Time Profiler trace (48450) matches the
  mid-run `pgrep` of the worktree binary[^tpr].
- **Log topology matches trace buckets:** the contacts fetch's 4.2–4.4 s
  wall span (log) matches the theme's 2–8 s bucket spread (trace); the EK
  fetch's ~0.65 s wall (log) matches its single 2–4 s burst
  (trace)[^log][^theme].

---

## 6. What's left, and is batch 3 worth it?

Of the 3 301 ms window (themes overlap)[^tpr][^theme][^mk]:

1. **Contacts unified fetch — 1 214 ms / 36.8 %.** One fetch, intrinsic
   cost. The only remaining lever of real size, and it's bounded: audit the
   27 requested optional keys against what the lists/detail actually render
   at launch, or move to change-history-driven incremental fetches. It runs
   on a background queue and completes by ~7 s, so the user-visible payoff
   is energy/CPU, not responsiveness.
2. **Main-thread launch work — 854 ms.** Diffuse framework-side first-layout
   and event-servicing (GuessWhoSync self weight on main: 4 ms). No single
   app function to attack; this is close to the platform floor for this UI.
3. **EventKit window fetch — 316 ms**, of which the one EKEventStore fetch
   is 254 ms for 1 569 events — intrinsic unless the launch window narrows.
4. **Sidecar corpus machinery — 233 ms** read theme (438 ms `walkCorpus`
   scaffolding presence across all users) — already bulk-coordinated; a
   persistent index could shave it further but the absolute stakes are small.
5. **`allPlaces` — 190 ms** — one initial walk; a places index would remove
   it (same small stakes).

**Assessment: diminishing returns.** The sidecar/iCloud subsystem that was
~80 % of the baseline window is now ~7 %, the settling storm is structurally
gone (idle at 8 s), and the biggest remaining line is a single OS-mediated
Contacts fetch whose cost is mostly XPC + CoreData on Apple's side of the
boundary. A batch 3 targeting the fetch key set is defensible if launch
energy matters; nothing else clears the bar. The two *unmeasured* themes
(restored-card attendee scan, MapKit place resolution) should be re-measured
with a contact card in restored state before any work on them[^b1].

---

## 7. Artifacts

Trace bundles (large, **not** committed; delete when done):

- `.build/traces/launch-after-b2-1.trace` — App Launch, anomalous 775 ms
  Process Creation (kept as evidence; phase shape agrees post-creation).
- `.build/traces/launch-after-b2-2.trace` — clean App Launch trace (primary
  timeline + hotspots cross-check).
- `.build/traces/timeprofiler-after-b2.trace` — 30 s Time Profiler trace
  (primary CPU source).
- `.build/traces/tp-after-b2.xml` — the exported `time-profile` table (4.6 MB).

Committed analysis assets in
[`catalyst-startup-cpu-after-batch2.assets/`](catalyst-startup-cpu-after-batch2.assets/):
`tp-after-b2-report.md` (full `time_profile_report.py` output),
`theme-after-b2.md` (theme/bucket/kernel tables), `extra_markers.py` +
`extra-markers-b2.md` (batch-2 symbol presence), `phases-launch-after-b2-1.md`,
`phases-launch-after-b2-2.md`, `hotspots-launch-b2-2.md` (cross-check), and
`breadcrumbs-launch-log-b2.log` (the app-log excerpt covering all three
recorded launches; timestamps UTC). To re-derive from the trace: export the
`time-profile` table with `xcrun xctrace export --input <trace> --xpath
'/trace-toc/run/data/table[@schema="time-profile"]' --output tp.xml` and run
the scripts on `tp.xml`.

[^base]: [Pre-optimization baseline — method, theme definitions, ranked list](catalyst-startup-cpu-baseline.md)
[^b1]: [After-batch-1 report — the numbers batch 2 is measured against, and the re-ranked list it implemented](catalyst-startup-cpu-after-batch1.md)
[^tp]: [Time Profiler trace bundle](../../.build/traces/timeprofiler-after-b2.trace)
[^tpr]: [Committed full aggregation output](catalyst-startup-cpu-after-batch2.assets/tp-after-b2-report.md)
[^theme]: [Committed theme/bucket/kernel tables](catalyst-startup-cpu-after-batch2.assets/theme-after-b2.md)
[^mk]: [Committed batch-2 marker presence table](catalyst-startup-cpu-after-batch2.assets/extra-markers-b2.md)
[^ph1]: [Phase table, first App Launch trace](catalyst-startup-cpu-after-batch2.assets/phases-launch-after-b2-1.md)
[^ph2]: [Phase table, second (clean) App Launch trace](catalyst-startup-cpu-after-batch2.assets/phases-launch-after-b2-2.md)
[^hs]: [hotspots.py cross-check on the clean App Launch trace](catalyst-startup-cpu-after-batch2.assets/hotspots-launch-b2-2.md)
[^log]: [App-log breadcrumb excerpt for the three recorded launches (UTC timestamps)](catalyst-startup-cpu-after-batch2.assets/breadcrumbs-launch-log-b2.log)
[^sf1]: [Single-flight full fetch with start/finish breadcrumbs](../../Sources/GuessWhoSync/CNContactStoreAdapter.swift:CNContactStoreAdapter.fetchAll())
[^sf2]: [One directory-coordination claim per corpus walk](../../Sources/GuessWhoSync/FileSystemSidecarStore.swift:FileSystemSidecarStore.coordinatedCorpusRead(_:))
[^sf3]: [Window-fetch coalescing coordinator + `sync.eventkit-fetch` breadcrumbs](../../Sources/GuessWhoSync/EKEventStoreAdapter.swift:EventWindowFetchCoordinator)
[^sf4]: [Place-cache invalidation, now called from the `.guessWhoSidecarsDidChange` observer in `GuessWhoSync.init` only when the delivery requires a full refresh or its changed keys name a place/guide](../../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.invalidatePlaceCorpus())
[^sf5]: [Fused contact-reload projection (counts + timestamps + endpoints in one pass)](../../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.contactReloadProjection())
