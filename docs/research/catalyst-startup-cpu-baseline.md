# Catalyst cold-start CPU baseline — first 30 s (Release, 2026-08-29)

> **Status: historical baseline — superseded.** This is the pre-optimization
> measurement. Its §6 "Ranked CPU optimization opportunities" was the plan; it
> is now ~90% executed. Batch 1 landed and was re-measured in
> [`catalyst-startup-cpu-after-batch1.md`](catalyst-startup-cpu-after-batch1.md)
> and batch 2 in
> [`catalyst-startup-cpu-after-batch2.md`](catalyst-startup-cpu-after-batch2.md)
> (window CPU 19.2 s → 7.8 s → 3.3 s). Only the attendee-scan (#7) and MapKit
> (#9) items remain un-measured/open. Read this only for the original baseline
> numbers; treat the after-reports as the current state.

Instruments/xctrace profile of the first 30 seconds of a cold launch of the
Mac Catalyst **Release** build, recorded headless on the developer machine
(`MacBook Pro`, macOS 26.5.2, xctrace 26.0/17C519). Investigation only — no
app code was changed.

**TL;DR.** Launch-to-first-frame is healthy: the first frame renders **~1.1 s**
after process start, and the main thread burns only **1.9 s of CPU across the
whole 30 s**[^1]. The real cost is off the main thread: the process consumed
**≈19.2 s of CPU in the 30 s window** (multi-core), and almost all of it is the
sidecar/iCloud subsystem re-walking the entire sidecar corpus **repeatedly** —
the same read+decode+conflict-scan cycle runs continuously from ~2–14 s and
then again from ~22–30 s[^2]. The top themes: coordinated sidecar file reads
(26.5 % of all CPU), ISO-8601 date parsing via ICU inside sidecar decode
(21.8 %), the `allPlaces()` corpus walk (20.2 %), per-file `NSFileVersion`
conflict scans (11 %), the Contacts unified fetch (~9 %), and EventKit
attendee/window scans (~14 % combined)[^2].

---

## 1. Method and verification

### Build

```sh
xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho \
  -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/DerivedData build
```

Outcome: **BUILD SUCCEEDED**, signed (Team `T68Z94627S`), universal
x86_64+arm64, product at
`.build/DerivedData/Build/Products/Release-maccatalyst/GuessWho.app`,
bundle id `com.milestonemade.guesswho` (Debug and Release share the
production id[^3]). Release numbers are representative — no Debug caveat
applies.

### The LaunchServices substitution hazard is real in this repo

`xctrace --launch <path>` resolves `.app` bundles through LaunchServices by
bundle id. This machine had **234 registrations** for
`com.milestonemade.guesswho` (204 of them stale agent-worktree DerivedData
builds, plus the installed `/Applications/GuessWho.app`). Two recordings
launched the **wrong binary** before the procedure below made it stick, and
mid-run `ps` verification caught both:

1. First App Launch attempt: LS launched `/Applications/GuessWho.app` even
   after the 204-entry prune and `lsregister -f` on our build. Fix:
   temporarily `lsregister -u /Applications/GuessWho.app` (re-registered
   after profiling).
2. First Time Profiler attempt: LaunchServices **re-discovered**
   `/Applications/GuessWho.app` within ~4 minutes of the unregister and
   substituted it again. The trace was discarded and re-recorded after a
   second unregister immediately before launch.

Procedure that worked, before **every** launch: kill any instance by bundle
id, run `prune-lsregister.py … --apply`, `lsregister -u` the installed copy,
`lsregister -f` the worktree build, launch, then verify the running binary
path with `ps`/`pgrep` **during** the recording. The installed
`/Applications/GuessWho.app` registration was restored afterwards with
`lsregister -f /Applications/GuessWho.app`.

### Recordings

```sh
xcrun xctrace record --template "App Launch"    --launch <app> --time-limit 30s --output .build/traces/launch-release-2.trace
xcrun xctrace record --template "Time Profiler" --launch <app> --time-limit 30s --output .build/traces/timeprofiler-release.trace
```

All kept traces finalized (`UI_state_metadata.bin` present); xctrace exits 54
on time-limit success, so the bundle was checked, not the exit code. A first
App Launch trace (`launch-release.trace`) is also kept but its first ~10 s
overlapped with a stale instance of the installed build that was being killed
off — it was used only as a cross-check; its phase timeline agrees with the
clean trace.

### Analysis pipeline

- Phases: `phases.py` (xctrace skill) on the App Launch traces.
- Hotspots: the Time Profiler trace's `time-profile` table was exported to
  XML — it is **fully symbolicated by xctrace** (every frame carries symbol +
  binary, including dyld-shared-cache system frameworks) — and aggregated
  with the two scripts preserved in
  [`catalyst-startup-cpu-baseline.assets/`](catalyst-startup-cpu-baseline.assets/)
  (leaf self-weight, stack presence, per-binary roll-ups, time buckets).
  Sampling interval 1 ms, one 1 ms weight per sampled running thread; only
  running threads are recorded, so "CPU ms" ≈ on-core time.
- `hotspots.py` on the App Launch traces cross-checks the main-thread
  picture; its atos pass cannot resolve dyld-shared-cache system frames
  (expected headless limitation), which the `time-profile` export sidesteps.
- One unnamed hot frame (`0x1086826c7`, present in 79.5 % of samples) was
  resolved via `atos` against the build's dSYM: it is a linker
  `<deduplicated_symbol>` thunk, i.e. a pass-through shared by many
  GuessWhoSync functions, not a real hotspot.

### Environment caveats (separate from findings)

- **Headless Catalyst never fires the `Foreground` phase** — documented
  xctrace-skill behavior; the window was never clicked. "Initial Frame
  Rendering" is used as the interactivity proxy.
- These are process-cold but **cache-warm** launches (the app had run
  minutes earlier). True disk-cold numbers would be somewhat larger in the
  dyld/static-init phases.
- State restoration reopened the last-viewed contact detail, so the trace
  includes that card's work (notably the EventKit "Recent Events" scan[^4]).
  That is the realistic relaunch path for this user profile, but a
  first-ever launch would not include it.
- The profiled process was verified mid-run as the worktree Release build;
  the trace's TOC records the profiled pid and its SIGKILL at cleanup.
- `xctrace --launch` transiently shows two app processes for a few seconds;
  the sibling exits after hand-off and the trace follows the surviving,
  launchd-parented instance (return-exit-status in the TOC confirms it).

---

## 2. Phase timeline (clean App Launch trace)

From `launch-release-2.trace`[^1]:

| Start | Duration | Phase |
|-------|----------|-------|
| 00:00.000 | 312.09 ms | Initializing — Process Creation |
| 00:00.312 | 131.53 ms | Initializing — System Interface Initialization (two overlapping spans) |
| 00:00.398 | 45.86 ms | Initializing — Static Runtime Initialization |
| 00:00.491 | 87.89 ms | Launching — UIKit Initialization |
| 00:00.579 | 5.61 ms | Launching — UIKit Scene Creation |
| 00:00.585 | 4.90 ms | Launching — didFinishLaunchingWithOptions() |
| 00:00.590 | 138.89 ms | Launching — UIKit Scene Creation |
| 00:00.729 | ~83 ms | Launching — AppKit Init + AppKit Scene Creation |
| 00:00.811 | 21.53 ms | Launching — AppKit Scene Creation (cont.) |
| 00:00.833 | 51.99 ms | Launching — sceneWillConnectTo() |
| 00:00.885 | ~1 ms | Launching — sceneWillEnterForeground() |
| 00:00.886 | 247.51 ms | Launching — Initial Frame Rendering |

**Process start → first frame ≈ 1.13 s.** `Foreground` never fired (headless
Catalyst caveat above). The contaminated first trace shows the same shape
with a slower Process Creation (1.33 s), consistent with the concurrent
stale instance.

The launch phases themselves offer little to optimize: `didFinishLaunching`
is 4.9 ms because the app defers its heavy work into `Task { }` blocks and
watchers[^5] — which is exactly where the 30-second CPU story moves next.

---

## 3. Where the CPU went (Time Profiler, 30 s window)

Totals from the symbolicated `time-profile` aggregation[^2]:

- **Total sampled CPU: ≈19 182 ms** across all threads in 30.7 s of trace.
- **Main thread: 1 876 ms (9.8 %)** — the rest is background queues: the top
  four worker threads alone account for 7.4 s.

### Self weight by binary (all threads, top 12)

| CPU ms | % | Binary |
|---|---|---|
| 3 338 | 17.4 % | libsystem_kernel.dylib (syscalls — see getattrlist below) |
| 2 693 | 14.0 % | libicucore.A.dylib (ICU — date parsing) |
| 2 494 | 13.0 % | CoreFoundation |
| 2 071 | 10.8 % | libobjc.A.dylib |
| 1 625 | 8.5 % | libswiftCore.dylib |
| 1 374 | 7.2 % | Foundation |
| 1 345 | 7.0 % | libsystem_malloc.dylib |
| 1 093 | 5.7 % | libsystem_platform.dylib |
| 481 | 2.5 % | libsystem_pthread.dylib |
| 315 | 1.6 % | VectorKit (MapKit rendering/geo) |
| 309 | 1.6 % | EventKit |
| 261 | 1.4 % | dyld |

Top kernel leaves: `__getattrlist` **977 ms**, `__open` 572 ms,
`mach_msg2_trap` 441 ms, `getattrlistbulk` 226 ms, `stat` 186 ms,
`getxattr` 122 ms — a file-metadata storm, not data I/O[^2].

### The work is periodic, not one-shot

CPU by 2 s bucket for marker functions (ms, all threads)[^2]:

| window (s) | sidecar read | allPlaces | reconcile | ek attendees | eventsWindow | linkCounts | VectorKit/Geo | TOTAL |
|---|---|---|---|---|---|---|---|---|
| 0–2 | 41 | 57 | 0 | 0 | 0 | 0 | 0 | 961 |
| 2–4 | 290 | 376 | 290 | 0 | 0 | 0 | 0 | 1 241 |
| 4–6 | 433 | 249 | 309 | 0 | 737 | 189 | 0 | 2 559 |
| 6–8 | 496 | 335 | 326 | 0 | 0 | 119 | 0 | 1 865 |
| 8–10 | 591 | 403 | 7 | 0 | 141 | 139 | 0 | 1 735 |
| 10–12 | 564 | 310 | 0 | 0 | 0 | 188 | 0 | 1 095 |
| 12–14 | 272 | 108 | 0 | 95 | 0 | 78 | 722 | 1 938 |
| 14–16 | 0 | 0 | 0 | 685 | 0 | 0 | 9 | 729 |
| 16–18 | 115 | 170 | 0 | 601 | 0 | 0 | 0 | 946 |
| 18–20 | 297 | 375 | 0 | 0 | 0 | 0 | 0 | 482* |
| 20–22 | 1 | 0 | 289 | 0 | 0 | 0 | 0 | 365 |
| 22–24 | 277 | 192 | 336 | 0 | 134 | 60 | 0 | 1 022 |
| 24–26 | 463 | 394 | 335 | 0 | 139 | 93 | 0 | 1 442 |
| 26–28 | 490 | 338 | 226 | 0 | 68 | 113 | 0 | 1 261 |
| 28–30 | 570 | 450 | 0 | 0 | 73 | 123 | 0 | 1 226 |

\* markers overlap across threads, so a bucket's marker columns can exceed
its TOTAL-attributable share; TOTAL is all sampled CPU in the bucket.

The sidecar read + `allPlaces` + reconcile cycle runs essentially
continuously from ~2–14 s, pauses, and **runs again in full from ~22 s to
past the end of the window**. The corpus-wide work is repeating, not a
single launch cost.

Mechanism (code-verified): the sidecar file watcher's `NSMetadataQuery` over
the whole iCloud sidecar root fires `DidFinishGathering`/`DidUpdate`; every
delivery runs `reconcileSidecars()` (a conflict scan of **every** sidecar
file) and then posts `.guessWhoSidecarsDidChange`[^6]; the repositories
subscribe and re-fetch their full corpus (e.g. the guides repository
re-fetches every guide and place)[^7]. The watcher coalesces passes while
one is running but has **no quiet period** of its own[^8], and the
repositories' 300 ms reload debounce[^7] is too short to absorb sustained
iCloud metadata churn (plausibly including attribute updates caused by the
app's own reads/downloads) — so the corpus-wide cycle restarts
back-to-back. (The `NSMetadataQuery` does set
`notificationBatchingInterval = 1.0`[^8], so deliveries are rate-limited to
~1/s during churn — that is upstream delivery batching, not a quiet period
on the reconcile pass, and it still delivers during sustained churn, so a
full corpus pass can run about once a second.)

---

## 4. Main-thread hotspots

Main thread total: 1 876 ms of CPU in 30 s — no hangs observed, first frame
at 1.13 s. Top leaf symbols (self weight, base = 1 876 ms)[^2]:

| CPU ms | % | Leaf symbol | Binary |
|---|---|---|---|
| 113 | 6.0 % | objc_msgSend | libobjc |
| 42 | 2.2 % | _platform_memmove | libsystem_platform |
| 35 | 1.9 % | mach_msg2_trap | libsystem_kernel |
| 31 | 1.7 % | __getattrlist | libsystem_kernel |
| 30 | 1.6 % | swift_bridgeObjectRetain | libswiftCore |
| 29 | 1.5 % | _CFRelease | CoreFoundation |
| 27 | 1.4 % | getMethodFromRelativeList | libobjc |
| 27 | 1.4 % | swift_retain | libswiftCore |
| 26 | 1.4 % | _CFStringGetCStringPtrInternal | CoreFoundation |
| 24 | 1.3 % | getMethodNoSuper_nolock | libobjc |
| 23 | 1.2 % | CFStringFindWithOptionsAndLocale | CoreFoundation |
| 22 | 1.2 % | swift_bridgeObjectRelease | libswiftCore |
| 19 | 1.0 % | _xzm_free | libsystem_malloc |
| 18 | 1.0 % | __CF_IS_OBJC | CoreFoundation |
| 18 | 1.0 % | swift_release | libswiftCore |
| 13 | 0.7 % | initializeWithCopy for Contact | GuessWhoSync |

By stack presence, the main thread's busy time divides into: run-loop event
servicing scaffolding (~63 %), CoreAnimation commit + UIKit layout
(`CA::Transaction::commit()` 28 %, `-[UIView layoutSublayersOfLayer:]`
26.6 %), main-queue dispatch drain (21.9 %), and Swift-concurrency task
completion on the main actor (29.9 %)[^2]. By self weight per binary the
main thread is: libobjc 17.3 %, CoreFoundation 16.2 %, libswiftCore 15.1 %,
UIKitCore 8.0 %, kernel 7.2 %, GuessWhoSync 3.1 %[^2] — i.e. diffuse
first-layout + list-population work, no single dominating app function. No
main-thread opportunity here comes close to the background themes below.

---

## 5. Themes (all threads)

Stack-presence weights overlap (a sample counts toward every theme its stack
touches), so these do not sum to 100 %[^2]:

| Theme | CPU (of 19.2 s) | Anchors |
|---|---|---|
| Sidecar coordinated read + JSON decode | 5.1 s / 26.5 % | `FileSystemSidecarStore.read(_:)`[^9], `SidecarEnvelope.init(from:)`, `SidecarCell.init(from:)` |
| — of which ISO-8601 date parse (ICU) | 4.2 s / 21.8 % | `SidecarISO8601.date(from:)`[^10]; libicucore self weight 2.7 s |
| Places corpus walk | 3.9 s / 20.2 % | `GuessWhoSync.allPlaces()`[^11] |
| Conflict scan (NSFileVersion per file) | 2.1 s / 11.0 % | `reconcileSidecars()` → `keysWithUnresolvedConflicts()`[^12], `ProductionUbiquityProvider.unresolvedConflictVersions(at:)` 1.6 s[^13] |
| Contacts unified fetch | 1.9 s / 10.0 % | `CNContactStoreAdapter.runOnWorkQueue` / `fetchAll()` 1.7 s |
| EventKit attendee scan ("Recent Events") | 1.4 s / 7.5 % | `EKEventStoreAdapter.eventsWithAttendee(...)`, triggered from the restored contact card[^4] |
| EventKit window fetch | 1.3 s / 6.8 % | `GuessWhoSync.eventsWindow(from:to:includeEventKit:)` |
| Link counts | 1.2 s / 6.2 % | `GuessWhoSync.linkCounts(ofKind:)`, called from the contacts repository reload[^14] |
| MapKit/Geo resolution | ~0.45 s self | VectorKit + GeoServices self weight (12–14 s bucket) |
| dyld + static init | ~0.3 s | launch phases + `findClosestSymbol` samples (unattributed, minor) |

---

## 6. Ranked CPU optimization opportunities

Ranked by expected effect on the 30 s window. Percentages are of the 19.2 s
total sampled CPU; themes overlap, and item 1 **multiplies** items 2–5. No
changes were made — directions are suggestions for follow-up work.

### 1. Debounce and delta-scope the sidecar watcher pipeline (biggest lever)

- **Hotspot:** the repeat cycle itself — sidecar read/decode + `allPlaces` +
  reconcile running 2–14 s and again 22–30 s[^2].
- **Where:** `SidecarFileWatcher.scheduleChangeProcessing` /
  `processSidecarChanges`[^8][^6] and each repository's
  `.guessWhoSidecarsDidChange` handler[^7].
- **Share:** the second full round is roughly a third of the window's
  sidecar CPU; eliminating redundant rounds plausibly saves **~4–6 s of the
  19.2 s (20–30 %)**, more on iCloud-churny days.
- **Direction:** add a quiet-period debounce to the watcher pass itself (the
  repositories' 300 ms reload debounce exists but cannot absorb sustained
  metadata churn); scope passes to the keys the `NSMetadataQuery` update
  actually named (added/changed paths are available in the notification)
  instead of corpus-wide reconcile + corpus-wide repository refreshes;
  consider ignoring metadata churn caused by the app's own in-flight
  reads/writes.

### 2. Cheapen sidecar envelope decode — ISO-8601 dates first

- **Hotspot:** `SidecarISO8601.date(from:)` inside every `SidecarCell`
  decode — 4.2 s presence, and ICU (`libicucore`) is 2.7 s of raw self
  weight, #2 of all binaries[^2][^10].
- **Where:** `Sources/GuessWhoSync/SidecarISO8601.swift` (parse), reached
  from `SidecarEnvelope.init(from:)`/`SidecarCell.init(from:)`.
- **Share:** up to **~20 %** of window CPU (fully overlapped with theme 1;
  independent win even if item 1 lands, since first-pass decode remains).
- **Direction:** the two `ISO8601DateFormatter`s are cached, but each
  `date(from:)` is an ICU round-trip, and the permissive fallback
  double-parses every non-fractional string. Options: try a cheap
  fixed-layout parser first (the format is self-inflicted and regular:
  `yyyy-MM-ddTHH:mm:ss[.SSS]Z`) with the formatter kept as fallback;
  choose fractional-vs-not by scanning for `.` before parsing; or cache
  parse results keyed by string for the many identical timestamps.
  A fresh `JSONDecoder()` per file read is also avoidable[^9], though it is
  second-order next to the date parse.

### 3. Cache/share the `allPlaces()` corpus walk

- **Hotspot:** `GuessWhoSync.allPlaces()` — 3.9 s / 20.2 %[^2][^11].
- **Where:** `GuessWhoSync+Guides.swift`; app-side callers in
  `SyncService.allPlaces()` (used twice via `async let` fan-outs) and the
  guides repository refresh[^7].
- **Share:** most of its 20 % overlaps themes 1–2, but the walk repeats per
  caller per refresh — memoizing one walk per change-generation and sharing
  in-flight results across concurrent callers should collapse several walks
  into one, saving a **low-single-digit-seconds** slice.
- **Direction:** generation-token cache invalidated by
  `.guessWhoSidecarsDidChange`; coalesce concurrent callers onto one task;
  longer-term, keep a places index instead of re-reading every place
  envelope to answer counts.

### 4. Make conflict scanning incremental (kill the getattrlist storm)

- **Hotspot:** `reconcileSidecars()` → `keysWithUnresolvedConflicts()` →
  `NSFileVersion.unresolvedConflictVersionsOfItem` per file — 2.1 s / 11 %,
  and the kernel-side `__getattrlist`/`getattrlistbulk`/`stat`/`getxattr`
  storm (~1.5 s combined leaves) is largely this plus coordinated-read
  probes[^2][^12][^13].
- **Where:** `FileSystemSidecarStore.keysWithUnresolvedConflicts()`,
  `SidecarUbiquityProvider.swift`.
- **Share:** **~11 %** of window CPU, repeated every watcher pass.
- **Direction:** scan only keys named by the triggering metadata update; or
  read `NSMetadataUbiquitousItemHasUnresolvedConflictsKey` straight from the
  `NSMetadataQuery` results the watcher already holds, reserving per-file
  `NSFileVersion` work for items actually flagged.

### 5. Trim per-read coordination overhead

- **Hotspot:** `FileSystemSidecarStore.read(_:)` scaffolding around the
  decode: a fresh `NSFileCoordinator` per file, a `fileExists` probe (a
  second probe runs only when the materialized file is absent — the hot path
  with the file present does one), `__open` 572 ms, plus
  `__iopolicysys`/`__mac_syscall` — the read path is 5.1 s total with
  decode[^2][^9].
- **Share:** perhaps **3–5 %** net of decode (bounded by the syscall
  leaves).
- **Direction:** batch coordination for corpus walks (coordinate the
  directory once per pass instead of per file), skip coordination when the
  store root is local-only, and reuse a single `JSONDecoder` instead of
  allocating one per read.

### 6. Contacts unified fetch — verify single-flight per window

- **Hotspot:** `CNContactStoreAdapter.fetchAll()` on its work queue —
  1.9 s / 10 %[^2].
- **Where:** `Sources/GuessWhoSync/CNContactStoreAdapter.swift`, driven by
  `ContactsRepository.reload()` from `didFinishLaunching`[^5] and
  change-notification refreshes.
- **Share:** **~10 %**, likely 1–2 full fetches in-window.
- **Direction:** confirm how many full fetches ran (breadcrumbs exist);
  ensure watcher-driven refreshes cannot stack a second full fetch during
  launch settling; audit the fetch key set for keys the lists don't render.

### 7. Defer/cap the restored contact card's EventKit work

- **Hotspot:** `EKEventStoreAdapter.eventsWithAttendee(...)` — 1.4 s /
  7.5 %, running 13–18 s in[^2], triggered by the state-restored
  `ContactDetailView`'s Recent Events section[^4]; plus
  `-[EKObjectID isEqual:]` and EventKit self weight 0.3 s.
- **Share:** **~7.5 %**.
- **Direction:** run the scan at lower priority after launch settles, cache
  results per contact with an `EKEventStoreChanged` invalidation, or narrow
  the query window/calendar set on cold start.

### 8. `linkCounts(ofKind:)` per reload

- **Hotspot:** 1.2 s / 6.2 %, re-walking link sidecars on each contacts
  reload[^2][^14].
- **Direction:** fold link counting into the same pass that already reads
  the link sidecars for the repository, or maintain counts incrementally.

### 9. MapKit/VectorKit resolution burst

- **Hotspot:** VectorKit 315 ms + GeoServices 134 ms self weight,
  concentrated at 12–14 s[^2] — Maps place-ID resolution for guide places.
- **Share:** **~2–3 %**.
- **Direction:** defer resolution until the Guides/Places UI is shown, or
  rate-limit it behind the launch window.

Not worth ranking: dyld/static-init (~0.3 s once, phases already lean),
main-thread first layout (§4 — diffuse and small), logging (no `dladdr`
found in the logging stack; the dyld `findClosestSymbol` samples, 89 ms,
remain unattributed and minor).

---

## 7. Artifacts

Trace bundles (large, **not** committed; delete when done):

- `.build/traces/launch-release-2.trace` — clean 30 s App Launch trace (primary).
- `.build/traces/timeprofiler-release.trace` — 30 s Time Profiler trace (primary CPU source).
- `.build/traces/launch-release.trace` — first App Launch trace; first ~10 s
  contaminated by a concurrent stale instance; cross-check only.

Analysis scripts (committed):
[`catalyst-startup-cpu-baseline.assets/time_profile_report.py`](catalyst-startup-cpu-baseline.assets/time_profile_report.py)
(hotspot/roll-up aggregation over the exported `time-profile` XML) and
[`catalyst-startup-cpu-baseline.assets/burst_report.py`](catalyst-startup-cpu-baseline.assets/burst_report.py)
(per-2 s marker buckets; note its marker match is exact-name, so
"static "/"closure #1 in "-prefixed frames — ISO-8601 parse, `fetchAll` —
show 0 there; use the main aggregation for those totals).

To re-derive the numbers: export the table
(`xcrun xctrace export --input <trace> --xpath
'/trace-toc/run/data/table[@schema="time-profile"]' --output tp.xml`), then
run the scripts on `tp.xml`.

## 8. Limitations / next steps

- Single run per template (skill guidance is ≥3 runs + median for launch
  *timing*; the CPU-theme ranking is robust to run noise, the phase table
  less so).
- Cache-warm cold launch; no true disk-cold numbers.
- `Foreground`/TTI not measurable headless on Catalyst; an in-app signpost
  would give a real TTI number.
- The exact number of watcher-triggered passes wasn't counted; the
  `sidecar files changed` / `sidecar metadata query gathered` log
  breadcrumbs[^6] can quantify pass counts and per-pass triggers before
  starting item 1.

[^1]: [App Launch trace, life-cycle-period table via phases.py](../../.build/traces/launch-release-2.trace)
[^2]: [Time Profiler trace, time-profile table aggregation](../../.build/traces/timeprofiler-release.trace)
[^3]: [Debug xcconfig — production bundle id in Debug](../../App/Config/GuessWho-Debug.xcconfig)
[^4]: [Recent Events fetch on the contact card](../../App/GuessWho/ContactDetailView.swift:reloadRecentEvents(for:))
[^5]: [Launch kickoff of repository reloads and watchers](../../App/GuessWho/GuessWhoAppDelegate.swift:application(_:didFinishLaunchingWithOptions:))
[^6]: [Watcher pass: reconcile then post](../../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.processSidecarChanges(added:changed:removed:))
[^7]: [Guides repository re-fetch on sidecar change, 300 ms debounce](../../App/GuessWho/Support/GuidesRepository.swift:GuidesRepository.scheduleDebouncedReload())
[^8]: [Coalescing loop, no debounce](../../Sources/GuessWhoSync/SidecarFileWatcher.swift:SidecarFileWatcher.scheduleChangeProcessing(added:changed:removed:))
[^9]: [Coordinated read + per-read JSONDecoder](../../Sources/GuessWhoSync/FileSystemSidecarStore.swift:FileSystemSidecarStore.read(_:))
[^10]: [ISO-8601 parse with permissive double-formatter fallback](../../Sources/GuessWhoSync/SidecarISO8601.swift:SidecarISO8601.date(from:))
[^11]: [Corpus walk over every place sidecar](../../Sources/GuessWhoSync/GuessWhoSync+Guides.swift:GuessWhoSync.allPlaces())
[^12]: [Conflict-key scan entry point](../../Sources/GuessWhoSync/GuessWhoSync.swift:GuessWhoSync.reconcileSidecars())
[^13]: [Per-file NSFileVersion conflict probe](../../Sources/GuessWhoSync/SidecarUbiquityProvider.swift:ProductionUbiquityProvider.unresolvedConflictVersions(at:))
[^14]: [Link counts during contacts reload](../../Sources/GuessWhoSync/ContactsRepository.swift:ContactsRepository)
