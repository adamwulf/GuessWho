# Contact-detail load baseline — Catalyst, driven A→B navigation (2026-08-29)

Profile + diagnosis of what happens between clicking a contact row and the
detail page being fully settled, on Mac Catalyst, after the batch-1/batch-2
startup CPU work landed. Recorded with a deterministic in-app DEBUG driver
(no UI scripting): launch → 15 s idle → open contact A → contact B →
an organization → an event → a phantom organization. Investigation +
instrumentation only — no production detail-load logic was changed. The
os_signpost regions and the DEBUG `--nav-benchmark` driver added here are the
measurement infrastructure for this phase and are intended to be kept.

**TL;DR.** A contact-detail open is a **strictly sequential chain of
per-open, uncached scans**; the wall time to a fully-settled card was
**4.85 s for contact A and 2.67 s for contact B** (Debug build; see the
build-config caveat). The dominant step is the "Recent Events" EventKit
attendee scan — a full 11-year `events(matching:)` walk of every calendar
event on every open (**3.64 s on A, 1.54 s on B**, 45 % / 21 % of the
window's total CPU) — B is faster *only* because EventKit's daemon caches are
warm, not because the app caches anything. Behind it: **two** full
link-corpus walks per open (~0.83 s combined), a Contacts group-membership +
account-sources XPC sweep (~0.3 s), and a `stampViewed` sidecar write whose
iCloud watcher echo re-triggers **events-window reloads** (each a full
event-sidecar walk + 1 287-event projection) 2–3× per open — even the
"idle" phantom-org window carries ~1.1 s of residual walk CPU from this
churn. Opening an organization also paid **996 ms** in `stampViewed` because
the open **minted** the org's GuessWho UUID (Case-A reconcile + CNContact
save on the open path). The phantom-organization page — pure cache render,
no loads — opens instantly, which is the existence proof for how fast the
others could feel. The top opportunity, worth ~75 % of A's wall, is to stop
rescanning EventKit per open (index once per launch + invalidate on change);
next are fusing/indexing the link walks, running the independent load steps
concurrently instead of sequentially, and breaking the self-write → watcher
→ events-reload echo.

---

## 1. Method

### Driver: DEBUG launch-argument benchmark (option b)

There is no `guesswho://contact/<uuid>` deep-link route — the scene delegate
handles only the `guesswho-linkedin[-debug]://` wake scheme (LinkedIn handoff
+ guide import), and the `guesswho://` identity URL is deliberately not a
navigation surface. Rather than AppleScript accessibility clicking (brittle,
and headless Catalyst never foregrounds its window), a **DEBUG-only,
launch-argument-gated driver** was added to `GuessWhoSceneDelegate`
(authorized by Adam via the manager): launching with `--nav-benchmark` arms a
task that waits 15 s for startup to idle, then drives the exact
`showContactDetail` / `showEventDetail` / `showPhantomOrganizationDetail`
calls a list-row click makes (each REPLACES the secondary column), dropping a
`nav_open` signpost marker before each step:

- **contact A, contact B** — the first two people, alphabetically, that carry
  ≥1 email address (so the recent-events attendee scan actually runs; it
  early-returns for a contact with no email and no street address). 8 s dwell.
- **organization** — first organization alphabetically. 6 s dwell.
- **event** — last event in the loaded window with attendees. 6 s dwell.
- **phantom organization** — first phantom projection. 5 s dwell.

The whole extension is `#if DEBUG && targetEnvironment(macCatalyst)`; without
the argument it never runs. Picks are deterministic given the same data.

### Instrumentation: `DetailLoadSignpost`

New `.pointsOfInterest` signpost regions (subsystem
`com.milestonemade.guesswho`, `App/GuessWho/Support/DetailLoadSignposts.swift`),
kept in Release:

- `ContactDetailView`: `contact_detail_load` (overall) around
  `performInitialLoad`, with sub-regions `contact_resolve`,
  `contact_sidecar_stores`, `contact_event_links`, `contact_sources`,
  `contact_refresh_linked_events`, `contact_recent_events`, `contact_groups`,
  `contact_address_guides`, `contact_stamp_viewed`, `contact_header_photo`.
- `EventDetailView`: `event_detail_load` around `reload()`, with
  `event_adopt`, `event_refresh`, `event_read`, `event_links`,
  `event_notes_tags`, `event_location_guides`.

### Recording

Debug Catalyst build into the worktree's `.build/DerivedData`
(`BUILD SUCCEEDED`; product bundle id `com.milestonemade.guesswho` — Debug
now shares the production bundle id, App Group, and iCloud container; only
the display name and wake scheme differ). LaunchServices procedure as in the
startup reports: `prune-lsregister.py --apply` (removed 1 stale agent-worktree
Release registration), `lsregister -f` the worktree build, `lsregister -u
/Applications/GuessWho.app` (second run returned −10814 — already out),
restore `lsregister -f /Applications/GuessWho.app` afterwards.

```sh
xcrun xctrace record --template "Time Profiler" --instrument "os_signpost" \
  --time-limit 60s --output .build/traces/detail-nav-1.trace \
  --launch -- <worktree>/.build/DerivedData/Build/Products/Debug-maccatalyst/GuessWho.app \
  --nav-benchmark
```

Exit 54 (time-limit success), bundle finalized (`UI_state_metadata.bin`
present). The launched binary path **and** the `--nav-benchmark` argument
were verified via `pgrep -fl` twice mid-run — the profiled process is the
worktree Debug build. App-log breadcrumbs (`app.nav-benchmark`) confirm all
five navigations fired on schedule; the log excerpt for the window is
committed[^log].

### Analysis pipeline

`xctrace export` of the `os-signpost` and `time-profile` tables;
[`nav_windows.py`](contact-detail-load-baseline.assets/nav_windows.py)
(per-navigation signpost windows split at the `nav_open` markers)[^nw];
[`window_profile.py`](contact-detail-load-baseline.assets/window_profile.py)
(the baseline `time_profile_report.py` aggregation restricted to each
navigation's time window — per-window totals, main-thread leaves, app-binary
stack presence)[^wp]; the xctrace skill's `aggregate-signposts.py` as a
global cross-check[^agg].

**Recording quirk:** every **app-subsystem** signpost row appears exactly
**twice** in the exported table — the Time Profiler template's Points of
Interest track and the explicitly-added os_signpost instrument each record
our `.pointsOfInterest` events (system-subsystem signposts appear once;
xctrace also warned about backdated signpost timestamps). Duplicated pairs
carry identical timestamps — in the committed `nav-windows-1.md` and
`aggregate-signposts-1.md`, our regions' counts are 2× with doubled totals
and the **Max column is the true single-occurrence value**; the tables below
use the de-duplicated numbers.

### Caveats

- **Debug build.** The `#if DEBUG` driver requires it. Framework-bound steps
  are directly comparable to the Release startup reports (this run's launch
  contacts fetch: 4 067 ms vs 4 192–4 433 ms in Release; EventKit window
  fetch 678 ms vs 574–694 ms), but **our own Swift code — especially the
  sidecar JSON decode paths — is inflated** (no optimization), so treat
  walk/decode CPU as an upper bound and the *structure* (what runs, how many
  times, in what order) as the finding. A Release re-run needs either a
  Release-gated driver flag or scripted clicking.
- Real data, real writes: each open stamps `lastViewed` (the org open minted
  its GuessWho UUID; the event open adopted a sidecar) — identical side
  effects to a user opening the same records.
- One run per page (n=1); the per-step ORDER and repeat-costs are
  structural, the exact ms are ±noise.
- Windows include the dwell after each open, so per-window CPU also captures
  the settling churn that open caused (deliberately — it is attributable
  to the navigation).

---

## 2. The load-step map (static)

### Contact detail (`ContactDetailView`) — what one open runs

Row click → `showContactDetail` builds a **fresh** `UIHostingController` +
`ContactDetailView` and replaces the secondary column (`setViewController(_:
for: .secondary)`) — no state survives navigation; every open starts cold.
The view's `.task` runs `performInitialLoad()` → `loadContact()`, a
**strictly sequential** await chain (total = sum of steps; confirmed by the
signpost numbers):

| # | Step | What it does | Where | Cached? | Repeats for 2nd contact? |
|---|---|---|---|---|---|
| 1 | `contact_resolve` | `repository.contact(id:)` dictionary hit | main | in-memory cache | ~0 ms |
| 2 | `contact_sidecar_stores` | `NotesStore`/`FieldsStore` init — **synchronous single-envelope sidecar reads on the main actor** — then `ContactLinksStore.reload()` → `links(for:)` → **full link-corpus walk** (every link file: coordinated read + JSON decode) | walk on bg queue | no | yes, full cost |
| 3 | `contact_event_links` | `repository.eventLinks(for:)` → **a second full link-corpus walk** (same files, different far-endpoint filter) | bg | no | yes, full cost |
| — | *publish* | `contact = loaded` — first paint of the card | main | | |
| 4 | `contact_sources` | `contactSources()` (containers XPC) + when >1 account `sources(for:)` — **per container, a whole-address-book unified id fetch** | bg (XPC) | no | yes |
| 5 | `contact_refresh_linked_events` | per linked event, coordinated sidecar read + EK lookup (+ write-back) — 0 here (no event links on A/B) | bg | debounced 1 h/key | n/a |
| 6 | `contact_recent_events` | `SyncService.recentEvents` → `EKEventStoreAdapter.eventsWithAttendee` — **full `events(matching:)` scan of a −10y…+1y window** (3 × ≤4-year predicate chunks), matching attendee emails / street lines per event | bg | **no** — not routed through `EventWindowFetchCoordinator` | yes, full rescan |
| 7 | `contact_groups` | `fetchGroupMemberships` — fetch **all** groups, then a `predicateForContactsInGroup` unified fetch per group | bg (XPC) | no | yes |
| 8 | `contact_address_guides` | `guides(containingAddresses:)` — `allGuides()` walk (uncached) + `allPlaces()` (PlaceCorpusCache, warm) | bg | places yes, guides no | yes (guides walk) |
| 9 | `contact_stamp_viewed` | `repository.stampViewed` — resolve-or-mint (**reconcile + CNContact save if unminted** — STAMP-ALWAYS by design) + **synchronous coordinated sidecar write on the main actor** + `postDidReload(contactDataChanged: false)` | main | n/a (write) | yes |
| 10 | `contact_header_photo` (parallel `.task(id:)`) | `contactPhotoData` store fetch + decode | bg | per-contact NSCache — cold for each new contact | yes |

Render-side, each body evaluation (≈8+ per open as the steps land) also runs
synchronous main-thread scans over the 1 662-contact cache:
`contactsReferencing(contact:)` (O(N × relations) with per-contact
trim+lowercase), `organizationContact(named:)` (O(N)), and for organizations
`contactsAssociated(with:)` + `departments(in:)` (O(N) + sort). Each
**address row** starts a `CLGeocoder` network geocode (uncached) and, once
resolved, renders a **live MapKit `Map`** as a 96×72 static preview — the
trace shows the full MapKit layer/Metal pipeline behind those thumbnails
(`LayerDataRequest` 102 intervals ≈9.8 s wall summed across threads,
`LoadAllLayers` 722 ms)[^agg].

Downstream of step 9, every open also triggers:
`.contactsRepositoryDidReload` → both contact list VCs re-run
`peopleSectionIDs`/`organizationsSections` (filter + sort of all contacts,
localized compares), an O(N) `Contact` equality diff, and a snapshot
re-apply (`ReconfigureCell` fired 750× across this 50 s run)[^agg]; and the
sidecar write's **iCloud watcher echo** (§4.3).

### Organization detail

Same `ContactDetailView`, same chain. Differences: the org-only sections
(`contactsAssociated`, `departments`) add O(N) render scans;
`recent_events` still runs (matches by street lines when no email); and on
this run the open **minted** the org's GuessWho UUID inside `stampViewed`
(Case-A reconcile → strip/mint → **CNContact save**, `Saving Contacts`
297 ms inside a 996 ms stamp)[^agg][^log].

### Event detail (`EventDetailView.reload()`)

Sequential: adopt-on-load (mint a sidecar for an EventKit-only row —
happened here, 656 ms) → `refreshEvent` (coordinated read + EK lookup +
cache-cell write-back) → `event(uuid:)` sync envelope read (main) →
`links(at:)` **full link-corpus walk** → notes + tags sync envelope reads
(main) → parallel `.task`: `guides(matchingLocation:)` (`allGuides` walk +
places cache). Render: per-attendee email→contact index hits (O(1)) but
`organizationContact(named:)` O(N) per person per body eval;
DataDetectors scans the text fields (~108 ms main).

### Phantom organization (`PhantomOrganizationDetailView`)

Pure synchronous render off the repository cache (`phantomOrganization(key:)`,
`contactsAssociated(withOrganizationNamed:)`, `departments`) — **no async
loads, no sidecar reads, no stamps**. The control case.

---

## 3. Measured: A vs B (and org / event / phantom)

### Per-step wall time (signpost regions, Debug)[^nw]

| Region | contact A | contact B | organization | event |
|---|---|---|---|---|
| **overall detail_load** | **4 846 ms** | **2 672 ms** | **2 902 ms** | **1 470 ms** |
| recent_events (EK attendee scan) | 3 639 | 1 536 | 1 568 | — |
| sidecar_stores (notes/fields + **link walk #1**) | 470 | 437 | 0 | — |
| event_links (**link walk #2**) | 394 | 391 | 0 | — |
| sources (accounts) | 211 | 152 | 140 | — |
| groups (memberships) | 104 | 111 | 101 | — |
| stamp_viewed | 28 | 45 | **996** (mint + CNContact save) | — |
| address_guides | 0.1 | 0.1 | 96 | — |
| header_photo (parallel task) | 92 | 87 | 183 ×2 | — |
| event_adopt | — | — | — | 656 |
| event_links (link walk) | — | — | — | 476 |
| event_location_guides | — | — | — | 404 |
| event_refresh / read / notes+tags | — | — | — | 5 / 3 / 11 |
| **phantom-org: no regions at all** | | | | |

The overall region equals the sum of its steps — the chain is fully
sequential. The org's `header_photo` ran twice: the mint changed the
contact's `ContactID` (guessWhoID nil → minted), re-firing the
`.task(id: contact?.contactID)`.

### Per-window CPU (time-profile, Debug)[^wp]

| Window | Total CPU | Main thread | Dominant app-stack presence |
|---|---|---|---|
| launch (0–17.9 s) | 5 350 ms | 1 195 ms | contacts fetchAll (1 153 ms), corpus walk (1 037 ms) |
| contact A (8.1 s) | 3 177 ms | 364 ms | **eventsWithAttendee 1 439 ms (45 %)**, walkCorpus 411 ms, decode 388 ms |
| contact B (8.0 s) | 2 934 ms | 474 ms | **walkCorpus 773 ms (26 %)**, eventsWithAttendee 627 ms (21 %) |
| organization (6.0 s) | 2 481 ms | 674 ms | eventsWithAttendee 644 ms (26 %), CNContactStoreAdapter.save 194 ms |
| event (6.1 s) | 1 937 ms | 552 ms | walkCorpus 533 ms (27 %), DataDetectors ~108 ms (main) |
| phantom-org (5.1 s) | 1 121 ms | 217 ms | walkCorpus 337 ms (30 %) — **all residual churn; the page itself loads nothing** |

Main-thread CPU per open is modest (0.36–0.67 s Debug) — **navigation
latency is serialized background I/O, not main-thread compute**. The main
thread spends 59–83 % of each window idle in the run loop waiting.

### Is B faster from warm caches?

B settled in 2.67 s vs A's 4.85 s — but the only warm thing was **EventKit's
daemon** (attendee scan 3 639 → 1 536 ms; `EKPredicateSearch` system
signposts shrink identically[^agg]). Every app-side step repeated at full
cost (link walks 864 → 828 ms; groups/sources/photo ≈unchanged). **The app
caches nothing between contact opens.** Meanwhile B's window carries *more*
corpus-walk CPU than A's (773 vs 411 ms) — that is A's write-echo churn
(§4.3) landing during B's window.

---

## 4. Diagnosis — where the time actually goes

### 4.1 The EventKit attendee scan is the single dominant cost

`recentEvents` builds a **−10y…+1y** interval and walks EventKit's
`events(matching:)` (3 chunked predicates) over **every calendar event**,
checking every attendee email / location needle — per open, uncached,
bypassing the `EventWindowFetchCoordinator` cache that batch 2 added for the
events *list*. 3.6 s cold / ~1.5 s warm per open (framework-bound: the
comparable Release window fetch differs <20 %). 45 % / 21 % / 26 % of the
A / B / org windows' entire CPU. The `sync.eventkit-fetch` breadcrumbs (which
already log this scan) agree with the signposts to the millisecond[^log].

### 4.2 Two full link-corpus walks per contact open, a third on event opens

`links(for:)` (people/org connections) and `eventLinks(for:)` each call
`sync.links(at:)`, which **reads and decodes every link sidecar on disk**
(`O(N links)`) and then filters by far-endpoint kind — the same files walked
twice back-to-back (~830 ms combined, Debug-inflated but structurally
2× redundant). The batch-2 fused `contactReloadProjection` solved exactly
this shape for the *list* (endpoints + counts in one pass); the *detail*
still walks per open, twice.

### 4.3 The `stampViewed` write-echo: opening a contact reloads the events list

Every open writes one `lastViewed` cell (STAMP-ALWAYS, by design). The write
itself is cheap (28–45 ms) — **its consequences are not**:

1. The iCloud watcher sees the changed file (multiple metadata updates as
   upload state advances) and the app's repositories react: the log shows
   the **events window reload** running 2–3× per contact open (generations
   7→9 during A, 10→13 during B), each a full event-sidecar corpus read +
   1 287-event projection + snapshot apply (~200 ms publish each,
   `walkCorpus` CPU in every window — 337 ms even under the load-free
   phantom page)[^log]. `EventsRepository.scheduleDebouncedReload` is
   *supposed* to drop deliveries whose changed keys name no event/link kind —
   a contact-stamp delivery should never reach it. Either these deliveries
   arrive with **nil (unknown) scope** (one unmappable path in the batch —
   e.g. a directory or root-level support file — makes the whole delivery
   full-scope) or an event/link file is being touched unexpectedly.
   **Pinpointing which needs one breadcrumb** (log the unmapped path /
   changed keys at the drop decision) — a cheap, high-value follow-up.
2. `postDidReload` (even with `contactDataChanged: false`) makes both
   contact lists re-sort + O(N)-diff + re-apply snapshots per open.
3. On a never-stamped record the stamp **reconciles + mints inside the open
   path**: the org open paid 996 ms for reconcile + CNContact save, and the
   mint re-keys the `ContactID` (re-firing the photo task). Case-A minting
   also fires a `CNContactStoreDidChange` → `GuessWhoContactsDidChange`
   cascade a few seconds later[^log].

### 4.4 Sequential chain: latency = Σ steps

Steps 4–8 (§2) are mutually independent, and none needs to precede the
others; today they run one-after-another on the awaited chain, so the
attendee scan *delays* groups/guides, and everything delays settling. The
signpost totals literally sum to the overall region.

### 4.5 Smaller per-open costs

- **Contacts XPC sweep per open** — groups (all groups + per-group
  membership predicate fetch) + sources (containers + per-container
  whole-book id fetch when >1 account): ~0.25–0.3 s per open; 130 `Fetching
  Contacts` XPC intervals in the 50 s run[^agg].
- **Live `Map` + `CLGeocoder` per address row** — a network geocode per open
  (uncached) and a full MapKit render pipeline for a static 96×72 thumbnail.
- **Render-side O(N) scans per body eval** — backrefs / org-by-name /
  associated-people over 1 662 contacts on the main thread, re-run on every
  state change (≈8+ evals per open). Small each; structural waste.
- **Event detail** — adoption mint 656 ms (first open only, by design),
  the link walk 476 ms, DataDetectors ~108 ms main.

---

## 5. Ranked optimization opportunities

1. **Stop rescanning EventKit per open** (`recentEvents` / `eventsWithAttendee`)
   — ~75 % of A's wall, ~1.5 s even warm. Options, roughly in order of
   leverage: (a) build a per-launch **attendee-email → events index** in one
   scan (the launch already fetches 1 570 events for the list window; widen
   once, index, then O(1) per open), invalidated by `.EKEventStoreChanged`;
   (b) serve the detail from the **cached coordinator window** immediately
   and only backfill the deep 10-year scan lazily/async; (c) narrow the
   window. Any of these turns the dominant step into a lookup.
2. **Run the independent load steps concurrently** (`async let` /
   task group for recent-events, groups, sources, address-guides, event-links)
   — collapses wall from Σ(steps) to max(step); combined with #1 the open
   settles in the time of the link walk. Zero behavior change, pure
   structure. (Keep the pre-paint set — stores + event links — as-is if the
   single-paint contract matters, or paint after the cheap envelope reads.)
3. **Fuse, then index, the link reads** — immediate: one `links(at:)` walk
   per open, split by far-endpoint kind in the repository (halves the walk).
   Real fix: a per-endpoint **link index** maintained like the batch-2
   fused projection / place cache (build once, invalidate on link-scoped
   watcher deliveries) — detail opens then read links with zero corpus I/O.
   Also serves `EventDetailView` (its third walk).
4. **Break the self-write → watcher → events-reload echo** — first add the
   one-line breadcrumb at `scheduleDebouncedReload`'s drop decision (log the
   changed keys / unmapped path when scope is nil), then fix the scoping so a
   contact-stamp delivery can never full-refresh the events repo. Also stops
   the phantom/idle-window walk churn. Cheap investigation, sizable win
   (2–3 events-window walks + snapshot applies per open today).
5. **Make `stampViewed` non-blocking and quieter** — fire-and-forget off the
   open chain (it gates nothing the UI shows), skip or coalesce the
   `postDidReload` for presentation-only stamps unless a time-ordered sort is
   actually live, and consider deferring the mint-on-open (org paid ~1 s +
   a CNContact save mid-open) — though STAMP-ALWAYS minting is a product
   decision (memory: deliberate), so scope any change with Adam.
6. **Cache the Contacts group/source lookups** — repository-level caches of
   the group list + membership map and the per-record sources footer,
   invalidated by `CNContactStoreDidChange` (the store barely changes
   mid-session); removes ~0.3 s XPC per open.
7. **Snapshot the address-map previews** — `MKMapSnapshotter` image (or at
   least geocode-result cache keyed by address) instead of a live `Map` per
   row per open.
8. **Precompute the render-side name indexes** — normalized-org-name → record
   and display-name → back-references maps maintained by the repository
   alongside its existing indexes, so body evals do dictionary hits instead
   of O(N) string scans.
9. **Event detail**: ride #3's index for `links(at:)`; consider deferring
   DataDetectors styling off first paint.

Not worth chasing now: header photo (~90 ms, parallel, cached per contact),
`contact_resolve` (~0), notes/fields envelope reads (fast even in Debug,
though they are synchronous main-actor disk reads and would ride along if
the stores ever go async), phantom-org page (already instant).

## 6. `plans/contact-reload-optimization.md` — status of the overlap

That plan (cache-by-default contact reads + incremental store refresh) is
**essentially executed** on this branch: no `service.fetchAll()` call sites
remain in any view (grep-clean), detail views resolve via
`repository.contact(id:)` / `editableContact(id:)`, the change-history delta
with `transactionAuthor` self-exclusion + device-local cursor landed
(`SyncService.init(contactCursorURL:)` is live in the launch log). Its still
relevant, unexecuted ideas for *this* phase: it explicitly declared **“Event
(EKEventStore) reload optimization” out of scope** — that deferred work is
precisely opportunities #1 and #4 above — and its index+delta philosophy
(read caches by default, touch stores deliberately, refresh by delta) is the
pattern opportunities #3, #6, and #8 apply to links, groups/sources, and the
name indexes.

## 7. Artifacts

Trace + exports (large, **not** committed; delete when done):
`.build/traces/detail-nav-1.trace` (60 s Time Profiler + os_signpost),
`.build/traces/signposts-1.xml`, `.build/traces/tp-1.xml`,
`.build/traces/record-1.log`, build log `.build/xcodebuild-debug-detail.log`.

Committed in [`contact-detail-load-baseline.assets/`](contact-detail-load-baseline.assets/):
[`nav_windows.py`](contact-detail-load-baseline.assets/nav_windows.py) +
[`nav-windows-1.md`](contact-detail-load-baseline.assets/nav-windows-1.md)
(per-navigation signpost tables; duplicated-row caveat in §1),
[`window_profile.py`](contact-detail-load-baseline.assets/window_profile.py) +
[`window-profile-1.md`](contact-detail-load-baseline.assets/window-profile-1.md)
(per-window CPU + hotspots),
[`aggregate-signposts-1.md`](contact-detail-load-baseline.assets/aggregate-signposts-1.md)
(global signpost cross-check incl. system signposts),
[`breadcrumbs-nav-benchmark.log`](contact-detail-load-baseline.assets/breadcrumbs-nav-benchmark.log)
(app-log slice for the benchmark window; timestamps UTC).

To reproduce: build Debug Catalyst, run the LS procedure, record with the
command in §1, then `nav_windows.py` on the signpost export and
`window_profile.py` on the time-profile export with the `nav_open` marker
times as window bounds.

[^nw]: [Per-navigation signpost windows (counts 2×, Max = true value)](contact-detail-load-baseline.assets/nav-windows-1.md)
[^wp]: [Per-window time-profile aggregation](contact-detail-load-baseline.assets/window-profile-1.md)
[^agg]: [Global signpost aggregation cross-check](contact-detail-load-baseline.assets/aggregate-signposts-1.md)
[^log]: [App-log breadcrumbs for the benchmark window (UTC)](contact-detail-load-baseline.assets/breadcrumbs-nav-benchmark.log)
