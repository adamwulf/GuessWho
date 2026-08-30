# Contact-detail load after DL-1…DL-4 — Catalyst re-profile (2026-08-30)

Re-run of the [detail-load baseline](contact-detail-load-baseline.md) on the
same machine, data, method, and Debug build config, after the four DL
optimizations landed on this branch: **DL-1** parallel load chain
(`555e9e1`), **DL-2** attendee/location index behind `eventsWithAttendee` +
post-launch warm-up (`741e516`, `94c6b76`), **DL-3** fused + indexed link
reads (`076240a`, `1f594f2`), **DL-4** deferred viewed stamp + kind-scoped
sidecar deliveries (`fa8df97`, `313fc74`, `7b4fd46`). Investigation only —
no app code changed in this pass.

**TL;DR.** The wall time to a fully-settled contact card dropped
**~12× on contacts and ~9× on the organization**: contact A **4 846 → 381
ms**, contact B **2 672 → 210 ms**, organization **2 902 → 322 ms**, event
**1 470 → 373 ms** (Debug, n=1)[^nw2]. Every targeted step now costs what
the fixes predicted: `recent_events` is a **0.1–43 ms index lookup**
(was a 1.5–3.6 s EventKit walk; the one 11-year walk now runs once at
launch idle, 15 996 events)[^log2], the link corpus is read **once per open
in ~70 μs** off the DL-3 index (was two ~400 ms walks)[^agg2], and the
viewed stamp runs **after** the publish with **zero** sidecar-triggered
events reloads per contact open (was 2–3) — the phantom-org control window's
CPU fell from 1 121 to **118 ms** because the echo churn is gone[^wp2]. The
critical path of a contact open is now the **Contacts XPC pair
(`sources` 202–378 ms + `groups` 141–315 ms)**, and of the org/event opens
the **uncached guides walk** (315/334 ms). **Verdict on DL-5 progressive
rendering: not needed.** The single paint lands in 0.2–0.4 s even in Debug;
the cheaper follow-ups (cache groups/sources per `CNContactStoreDidChange`,
index the guides corpus) bound the slowest branch below ~150 ms with no
layout shift.

---

## 1. Method

Identical to the baseline §1 — same `--nav-benchmark` DEBUG driver (15 s
idle, then contact A → contact B → organization → event → phantom org, same
deterministic picks), same `DetailLoadSignpost` regions, same recording
command. Differences worth stating:

- Build: Debug Catalyst from this worktree into `.build/DerivedData`
  (`BUILD SUCCEEDED`, bundle id `com.milestonemade.guesswho`).
- LaunchServices: `prune-lsregister.py --apply` removed 5 stale sibling-
  worktree registrations; `lsregister -u /Applications/GuessWho.app`;
  `lsregister -f` this build; installed app re-registered after the run.
  The launched binary path + `--nav-benchmark` argument were verified via
  `pgrep -fl` twice mid-run — the profiled process is this worktree's build.
- Recording: `xctrace record --template "Time Profiler" --instrument
  "os_signpost" --time-limit 60s` → `.build/traces/detail-nav-2.trace`,
  exit 54, bundle finalized. Same duplicated-signpost quirk as the baseline:
  app-subsystem rows appear 2×; **Max ms is the true single-occurrence
  value** in every table below.
- Same caveats: Debug build (our Swift inflated; XPC/EventKit framework work
  comparable to Release), one run per page (n=1), real writes (each open
  stamps `lastViewed`). Two data-state differences from the baseline run,
  called out in §3: the organization's GuessWho UUID and the event's sidecar
  were **already minted/adopted by the baseline run**, so this run does not
  pay (or measure) mint-on-stamp or adopt-on-load.
- The EventKit daemon was warm (four benchmark launches earlier the same
  day). That discounts the launch-time index *build*, not the per-open
  lookups the fixes are judged on.

Analysis: the baseline's committed
[`nav_windows.py`](contact-detail-load-baseline.assets/nav_windows.py) /
[`window_profile.py`](contact-detail-load-baseline.assets/window_profile.py)
scripts re-run against this trace's exports[^nw2][^wp2], the xctrace skill's
`aggregate-signposts.py` as the global cross-check[^agg2], and the app-log
slice for the run window (07:19:32–07:20:23 UTC)[^log2].

## 2. Overall: wall time and window CPU vs. baseline

Overall `contact_detail_load` / `event_detail_load` region (Max ms, Debug)
— baseline numbers from the baseline §3 table[^base]:

| Window | Baseline | Now | Δ |
|---|---|---|---|
| contact A | 4 846 | **381** | **−92 %** (12.7×) |
| contact B | 2 672 | **210** | **−92 %** (12.7×) |
| organization | 2 902 | **322** | **−89 %** (9.0×) |
| event | 1 470 | **373** | **−75 %** (3.9×; −54 % vs the 814 ms non-adopt remainder) |
| phantom-org | no regions (instant) | no regions (instant) | — |

Per-window sampled CPU (all threads / main thread, ms)[^wp2]:

| Window | Baseline CPU | Now CPU | Baseline main | Now main |
|---|---|---|---|---|
| launch (0→first open) | 5 350 | **9 438** | 1 195 | 1 385 |
| contact A | 3 177 | **880** | 364 | 380 |
| contact B | 2 934 | **751** | 474 | 345 |
| organization | 2 481 | **1 595** | 674 | 587 |
| event | 1 937 | **951** | 552 | 515 |
| phantom-org | 1 121 | **118** | 217 | 108 |

The launch window grew by ~4.1 s of background CPU — that is the DL-2 trade
made explicit: the 11-year attendee walk now runs once per launch at
`.background` priority during idle (`EKPredicateSearch` totals 4.30 s in
this trace, nearly all pre-open)[^agg2], plus run-to-run variance in the
contacts `fetchAll` (5 990 ms this run vs 4 067 baseline)[^log2]. Every
navigation window shrank; the phantom window's −89 % is pure echo removal
(the page itself loads nothing in either run).

## 3. Per-region breakdown (Max ms, baseline → now)[^nw2]

| Region | contact A | contact B | organization | event |
|---|---|---|---|---|
| **overall detail_load** | **4 846 → 381** | **2 672 → 210** | **2 902 → 322** | **1 470 → 373** |
| recent_events (DL-2) | 3 639 → 10.1 | 1 536 → 7.6 | 1 568 → 42.9 | — |
| sidecar_stores (DL-3: envelope reads only now) | 470 → 9.8 | 437 → 7.5 | 0 → 8.9 | — |
| event_links (DL-3: the ONE fused link read) | 394 → 0.08 | 391 → 0.06 | 0 → 0.07 | — |
| sources | 211 → 378 | 152 → 202 | 140 → 207 | — |
| groups | 104 → 315 | 111 → 142 | 101 → 141 | — |
| stamp_viewed (DL-4: now after publish) | 28 → 17.8 | 45 → 16.7 | 996 → 22.7 † | — |
| address_guides | 0.1 → 0.0 | 0.1 → 0.0 | 96 → **315** | — |
| header_photo (parallel task) | 92 → 145 | 87 → 32 | 183 ×2 → 38 ×1 | — |
| event_adopt | — | — | — | 656 → — ‡ |
| event_links (link read) | — | — | — | 476 → 5.6 |
| event_location_guides | — | — | — | 404 → **334** |
| event_refresh / read / notes+tags | — | — | — | 5/3/11 → 5.6/4.5/6.3 |

† The baseline org open **minted** the org's UUID inside the stamp
(reconcile + CNContact save). This run stamps an already-minted record, so
the 996 → 23 ms is mostly a data-state difference, not a DL-4 measurement.
DL-4 still moves whatever the stamp costs off the visible path (it now runs
after `contact_detail_load` ends), and the org's photo task no longer
re-fires (no mint → no `ContactID` re-key).

‡ Same event as the baseline run, whose open adopted the sidecar; adoption
is first-open-only by design, so this run has no adopt step.

**DL-1 is visible in the shape**: contact A's load branches sum to ~713 ms
(sources 378 + groups 315 + recent 10 + stores 10) inside a 381 ms wall —
the overall region now equals the *longest* branch (`sources`, 378 ms), not
the sum, with the ~145 ms photo task overlapping as well. Same on B (210 ≈
sources 202) and org (322 ≈ address_guides 315, over ~714 ms of branches).

**`sources`/`groups` read higher than baseline** (378/315 vs 211/104 on A).
They are now concurrent with each other and with the photo fetch, so the
Contacts XPC daemon serves them under contention, and n=1 Debug noise is
±100 ms; either way they are the contact critical path now.

## 4. Breadcrumb evidence[^log2]

**DL-2 — recent_events is a cached lookup.** One `EventKit attendee index
built` line per launch: 15 996 events, −10y…+1y, built at launch+12.7 s
(3.2 s before the first open; the warm-up task from `94c6b76`). The
per-open fetches then report `durationMs=0.141` (A, 1 email),
`0.131` (B, 3 emails), and `42.7` (org, 1 location needle — email lookups
hit the index's per-email dictionary; location needles scan its
located-events slice). All three return the same result set the
baseline's full scans returned (`events=0` for these records, identical
needle counts), so the index changed the cost, not the answer[^blog].

**DL-4 — zero sidecar-triggered events reloads per contact open.** Each
contact open's stamp write produces 5 watcher deliveries as the iCloud
upload state advances; **every one is dropped**: `events sidecar delivery
dropped changedKinds=contact` ×5 (A), ×5 (B), ×5 (org), with
`changedKeys=nil/coarse-scope` resolved by the DL-4 directory-kind scoping
(`313fc74`) and `exact/1` for the settled file. Zero `events window reload`
lines in any contact window (baseline: 2–3 full reloads per open), and the
phantom window has **no deliveries and no reloads at all**. The two launch
reloads (gen 1 `app-launch`, gen 2 initial full-scope gather) are expected.

**Remaining echo — event opens only.** Opening the event writes its event
sidecar, and those deliveries *correctly* name `changedKinds=event`, so
they are accepted: 5 accepted deliveries → 4 observed events-window reloads
(generations 3–6) inside the event dwell, one fresh EventKit window fetch
(190 ms) + 3 window-cache hits. Correctly scoped, but a self-write
suppression/coalescing pass for event stamps would remove ~4 reloads ×
~150–190 ms of background churn per event open.

**DL-3 — one link read per open, off the index.** `contact_event_links`
(the single fused `contactDetailLinks` read) costs 56–76 **μs** per open —
six occurrences in the whole trace totalling 409 μs[^agg2] — and
`contact_sidecar_stores` (7.5–9.8 ms) is now only the notes/fields envelope
reads. The event detail's `event_links` fell 476 → 5.6 ms. The remaining
~160–260 ms of `walkCorpus` stack presence in the contact/org windows[^wp2]
is the *contacts* repository's post-stamp refresh (contact-kind deliveries)
plus the org's `allGuides()` walk — background work after the publish, not
the open path.

## 5. Per-fix verdict

| Fix | Verdict | Evidence |
|---|---|---|
| DL-1 parallel chain | **Works.** Wall = longest branch, not Σ. | A: 858 ms of branches in a 381 ms wall (§3). |
| DL-2 attendee index | **Works; the biggest single win.** 3 639 → 10 ms on A. | One index build per launch during idle; 0.13–43 ms per open; same results as the full scan (§4). |
| DL-3 link index + fuse | **Works.** 2 × ~400 ms walks → 1 × ~70 μs read. | `contact_event_links` 409 μs total across the run; event `links` 476 → 5.6 ms (§3, §4). |
| DL-4 deferred stamp + tiered scope | **Works for contacts.** 0 events reloads per contact open (was 2–3); stamp off the visible path; phantom CPU −89 %. | §4 drop lines; §2 CPU table. Event opens still self-echo 4 reloads (correctly scoped; follow-up). |

## 6. Remaining hotspots, ranked

1. **`contact_sources` (202–378 ms) + `contact_groups` (141–315 ms)** — the
   contact-open critical path now; both are per-open Contacts XPC sweeps
   (containers + per-container whole-book fetch; all groups + per-group
   membership fetch). The baseline's opportunity #6 (repository-level cache
   invalidated by `CNContactStoreDidChange`) bounds the slowest branch to
   the photo/recent level (<150 ms).
2. **Guides corpus walk per open** — `contact_address_guides` 315 ms (org),
   `event_location_guides` 334 ms (event; `GuideAddressMatcher` +
   `eventsWindow` dominate its window[^wp2]). An `allGuides()` index/cache
   (the places side is already cached) is the same shape as DL-3.
3. **Event-open self-echo** — 4 accepted event-kind reloads per event open
   (§4); suppress or coalesce deliveries for the app's own event stamp.
4. **`contact_header_photo`** 145 ms on A (parallel, per-contact NSCache
   cold) — minor.
5. Unchanged from baseline §4.5: render-side O(N) name scans per body eval,
   live MapKit thumbnails + per-open geocodes, post-stamp contact-list
   re-sort/diff (`ReconfigureCell` 428× this run vs 750× baseline[^agg2]).

## 7. Is DL-5 progressive rendering still needed? **No.**

The question was whether the user still visibly waits before the core card
appears. Time-to-core — the single coherent paint after the slowest branch
— is now **210–381 ms** on contact/org opens and **373 ms** on the event
(Debug; Release framework costs are comparable, our Swift slice smaller).
That is at or under the threshold where a skeleton/streaming UI would be
perceptible as an improvement, and far from the baseline's 2.7–4.8 s stall
that motivated DL-5. Streaming the slow sections would save at most the gap
between the envelope reads (~10 ms) and the XPC branches (~380 ms worst
case) while introducing layout shift and a second render pass.

The better spend is hotspot #1: caching groups + sources makes the slowest
branch ~photo-sized and pulls the whole open under ~150 ms with the
single-paint contract intact. Revisit DL-5 only if a future branch (e.g. a
cold first open ~13 s after launch, before the warm-up index finishes — the
one case where `recent_events` still joins the in-flight index build)
proves user-visible in practice.

## 8. Artifacts

Trace + exports (large, **not** committed; delete when done):
`.build/traces/detail-nav-2.trace` (60 s Time Profiler + os_signpost),
`.build/traces/signposts-2.xml`, `.build/traces/tp-2.xml`,
`.build/traces/record-2.log`, build log `.build/xcodebuild-debug-after.log`.

Committed in [`contact-detail-load-after.assets/`](contact-detail-load-after.assets/):
per-navigation signpost tables, per-window CPU aggregation, global signpost
cross-check, and the app-log slice for the run window. To reproduce, follow
baseline §1 with the §1 notes above; window bounds for `window_profile.py`
came from this run's `nav_open` markers (18.553 / 26.858 / 35.366 / 41.391 /
47.468 s, complete at 52.619 s).

[^nw2]: [Per-navigation signpost windows, this run (counts 2×, Max = true value)](contact-detail-load-after.assets/nav-windows-2.md)
[^wp2]: [Per-window time-profile aggregation, this run](contact-detail-load-after.assets/window-profile-2.md)
[^agg2]: [Global signpost aggregation cross-check, this run](contact-detail-load-after.assets/aggregate-signposts-2.md)
[^log2]: [App-log breadcrumbs for the run window (UTC)](contact-detail-load-after.assets/breadcrumbs-2.log)
[^base]: [Baseline report §3 tables](contact-detail-load-baseline.md)
[^blog]: [Baseline app-log breadcrumbs — attendee scans, same needles, events=0](contact-detail-load-baseline.assets/breadcrumbs-nav-benchmark.log)
