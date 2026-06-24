# Plan: cache-by-default contact reads + incremental store refresh

## Problem

GuessWho has ~1500 contacts. Every "give me contacts" path bottoms out in
`SyncService.fetchAll()` → `CNContactStoreAdapter.fetchAll()` →
`CNContactStore.enumerateContacts` over **all** contacts with the full key set.
That full enumeration is the slow path the user is feeling. Two distinct
problems compound it:

1. **No cache/store distinction.** Consumers that only need "the contacts we
   already have" still re-enumerate the whole store. `ContactsRepository.contacts`
   is already an in-memory, `@Observable` cache — but most consumers bypass it
   and call `service.fetchAll()` directly.

2. **Full reload on every change.** `.CNContactStoreDidChange` fires on *any*
   store mutation — including the app's *own* writes — carrying no payload about
   what changed. The only response with today's primitives is a full
   re-enumeration. Worse, our own `save`/`delete` trip it, so each user edit
   reloads all ~1500 contacts *twice* (once from the explicit post-save
   `repository.reload()`, once from the observer reacting to our own write).

## Guiding principle

**Read the cache by default; touch `CNContactStore` only deliberately.**

Two clearly-named verbs:
- **Cache read** — `ContactsRepository.contacts` (already populated, zero I/O).
  The default for almost every consumer.
- **Store refresh** — re-read `CNContactStore`. Only at launch, on a real
  external change, or right after our own write — and even then, ideally only
  the *delta* (see Workstream D).

After this work, the **only** callers of the full-store `fetchAll()` are the
repository's `reload()` and internal reconcile.

---

## Current full-store `fetchAll()` call sites (the inventory)

Verified at planning time (line numbers may drift during implementation —
re-grep `fetchAll` before editing):

| # | Site | Today | Needs | Target |
|---|------|-------|-------|--------|
| 1 | `ContactsRepository.reload()` :45 | full enumerate | full refresh | **keep** (this IS the refresh) |
| 2 | `ContactDetailView.loadContact` :1059 | `fetchAll().first{id}` (cache-miss fallback) | one record | `service.fetch(localID:)` |
| 3 | `ContactDetailView.refreshContactMap` :962 | full enumerate → uuid→contact map | all contacts | **cache** (`repository.contacts`) |
| 4 | `ConnectionsSection.loadEligibleContacts` :243 | full enumerate → picker list | all contacts | **cache** |
| 5 | `ConnectionsSection.save` :272 | `fetchAll().first{id}` AFTER reconcile write | one *fresh* record | `service.fetch(localID:)` |
| 6 | `EventDetailView.reload` :472 | full enumerate → uuid+email maps | all contacts | **cache** |
| 7 | `EventDetailView` (sub-view) :774 | `.task { contacts = fetchAll() }` | all contacts | **cache** (verify what it feeds) |
| 8 | `FavoritesListViewController` :199 | full enumerate → favorites list | all contacts | **cache** |
| 9 | `SyncService.reconcileIfNeeded` :531 | `fetchAll().first{id}` AFTER reconcile | one *fresh* record | adapter `fetch(localID:)` |
| 10| `SyncService` :638 | internal reconcile path | (verify) | likely **keep** |

Rule of thumb for each site: result used as `.first{ $0.localID == X }` → single
fetch; result iterated into a map/array → cache read; immediately after a write
to that contact → single *store* fetch (cache is stale for that record).

---

## Workstreams

### A — single-record reads (app-only)

Add to `SyncService` (next to `fetchAll()`, matching its guard/catch/lastError
style):

```swift
/// Fetches one contact by localID without enumerating the whole store.
/// Returns nil when the contact does not exist or access is not granted.
/// Use instead of `fetchAll().first { $0.localID == ... }` — routes through
/// `unifiedContact(withIdentifier:)`, O(1) against the store.
func fetch(localID: String) async -> Contact? {
    guard contactsAuthorization == .authorized else { return nil }
    do { return try await contactsAdapter.fetch(localID: localID) }
    catch { lastError = "fetch failed: \(error.localizedDescription)"; return nil }
}
```

The adapter's `fetch(localID:)` already exists (CNContactStoreAdapter:100,
InMemoryContactStore:32) and is in `ContactStoreProtocol`. Do **not** remove the
existing throwing `fetchContactForEditing` — the editor relies on its shape.

Convert sites to single fetch. #2 and #9 are post-write so they MUST hit the
store (`service.fetch`), not the cache:
- **#2** `ContactDetailView.loadContact` cache-miss fallback → `service.fetch(localID:)`.
- **#9** `SyncService.reconcileIfNeeded` :531 `fetchAll().first{id}` → adapter
  `fetch(localID:)` (in-package single fetch).
- **#5** `ConnectionsSection.save` :272 does reconcile-then-`fetchAll().first{id}`
  — this DUPLICATES `SyncService.reconcileIfNeeded` (review finding). Collapse it:
  replace the manual `reconcile` + `fetchAll().first` + `guessWhoUUID` dance with
  a single `try await service.reconcileIfNeeded(contact:)` call (which, after #9,
  internally uses `fetch(localID:)`). Net: one fewer full enumeration AND less
  duplicated logic.
- **#10** `SyncService.contact(forGuessWhoUUID:)` :636 is **DEAD CODE** —
  verified zero callers across App/Sources/Tests. It hides a full `fetchAll()`.
  **Delete the method** rather than convert it.

### A′ — cache reads (app-only)

Point the map-builders (#3, #4, #6, #7, #8) at `repository.contacts` instead of
`service.fetchAll()`. **Injection is mandatory, not optional** (both reviewers):
these views read `repository` from the SwiftUI environment, so a view that starts
using `repository` without it being injected **crashes/won't compile** — there is
no graceful-empty fallback. Verified wiring (GuessWhoSceneDelegate.swift):
- `ContactDetailView` already declares `@Environment(ContactsRepository.self) private var repository`
  and the SceneDelegate injects it on the `ContactDetailView` hosting controllers.
  So **#3** (`refreshContactMap`) is a direct swap to `repository.contacts`.
- `ConnectionsSection` is a subview of `ContactDetailView`, so it inherits the
  same environment — but confirm it actually has `@Environment(ContactsRepository.self)`;
  add the declaration if missing. **#4** then reads `repository.contacts`.
- `EventDetailView` (**#6**, **#7**) is hosted by the SceneDelegate WITHOUT a
  `ContactsRepository` in its environment today. Add
  `@Environment(ContactsRepository.self)` to `EventDetailView` AND inject
  `.environment(appDelegate.contactsRepository)` at ALL THREE construction sites
  in GuessWhoSceneDelegate.swift — miss one and that entry point crashes:
  1. `showEventDetail` :195 — Catalyst secondary-column replace.
  2. `pushCatalystEventDetail` :234 — Catalyst in-detail drill-down push.
  3. the iPhone push path ~:466 — `injectIPhonePushHandlers` event detail.
  (Each currently injects `.environment(service)` + `.environment(favoritesStore)`
  only; add `.environment(appDelegate.contactsRepository)` alongside, matching the
  three `ContactDetailView` sites that already do so, e.g. :220.)
- `FavoritesListViewController` (**#8**) is a UIKit VC constructed
  `init(store:service:)` (SceneDelegate :137/:378) — it does NOT use the SwiftUI
  environment. Add a `repository:` parameter to its initializer and pass
  `appDelegate.contactsRepository` at both construction sites; its :199 builder
  reads `repository.contacts`.

Do NOT construct a second `ContactsRepository` — there is ONE app-owned instance
(`appDelegate.contactsRepository`). Thread that exact instance through.
**GuessWhoSceneDelegate.swift is in scope for this workstream** (the injection
edits) — note its overlap with the manager-owned integration is nil (manager
only edits the AppDelegate observer, not the SceneDelegate).

Cold cache: the cache is populated on launch and kept fresh by reloads + D's
delta; the staleness window for these map-builders is small and acceptable. An
empty cache renders an empty map (no crash) — the crash risk is the MISSING
injection above, which this workstream fixes.

### B — in-place repository patch (app-only)

Add to `ContactsRepository`. To let workstream D's `applyExternalChanges` apply
many changes under a SINGLE post (no snapshot storm), split each op into a
non-posting mutator + a public post-once wrapper:

```swift
// Non-posting cache mutators — caller decides when to post.
private func applyRefresh(localID: String) async { ... }  // fetch ONE → replace/insert
private func applyRemove(localID: String) { ... }         // drop from array

/// Refresh one contact from the store and notify list controllers. For our own
/// save of a known localID — re-reads ONE record, not all ~1500.
func refreshContact(localID: String) async {
    await applyRefresh(localID: localID)
    postDidReload()
}

/// Remove one contact from the cache and notify. For our own delete. No store I/O.
func removeContact(localID: String) {
    applyRemove(localID: localID)
    postDidReload()
}
```

`postDidReload()` is the single shared post helper (`@MainActor`, posts
`.contactsRepositoryDidReload`). `applyExternalChanges` (D) calls the private
`applyRefresh`/`applyRemove` in order for the whole delta, then `postDidReload()`
ONCE. The public single-shot wrappers post once each (fine for a lone edit).

All posts run on the main actor exactly as `reload()` does, so the diffable list
controllers re-apply a snapshot on the main thread. The `reconfigureItems` diff
added in commit 6dbb90c then repaints exactly the changed rows. `applyRefresh`
hits the STORE for one record (the cache is stale for the just-changed contact);
`applyRemove` is pure in-memory.

Rewire post-save / post-delete paths to call these instead of full `reload()`:
- `ContactDetailView` inline-save path(s) (~:425, :445, :457, :1139) — after a
  save of a known localID, `await repository.refreshContact(localID:)`; after a
  delete, `repository.removeContact(localID:)`.
- Keep `await repository.reload()` ONLY where the set of changed contacts is
  unknown (genuine external change with no delta — handled by D's fallback).

Caution: the reconcile path (#9-adjacent, ContactDetailView:1139) reloads so the
cache reflects a freshly-stamped GuessWho URL. `refreshContact(localID:)` covers
that — it re-reads that one contact, which is exactly what changed.

### C — exclude our own writes from the delta (via transactionAuthor)

**Revised after review.** The original counter/debounce idea is race-prone:
`.CNContactStoreDidChange` is async + coalesced, so a real EXTERNAL change can
land in the same window as a self-write and be wrongly dropped, and a self-write
notification can arrive after the token is cleared (redundant reload) or never
(stuck counter). Both reviewers flagged this.

The correct mechanism is built into Contacts: **tag our writes with a
`transactionAuthor`, then exclude that author when reading change history.**
- `CNContactStoreAdapter.save`/`delete` set `saveRequest.transactionAuthor` to a
  constant app identifier (e.g. the bundle id) before `store.execute`.
- `CNChangeHistoryFetchRequest.excludedTransactionAuthors = [ourAuthor]` so the
  delta read in D simply never reports our own edits.

This makes D's delta the single correctness path and **dissolves the separate
C+D integration seam** — there is no race-prone self-suppression counter and no
special-casing in the observer. Our own edits are handled by B (in-place patch)
and are invisible to the change-history read by construction; external edits flow
through D. The observer just calls `applyExternalChanges()`.

Note: `transactionAuthor` is itself meaningful only at write time; it is NOT
persisted state. The author string is a compile-time constant, not stored.

### D — incremental external sync (PACKAGE + app wiring)

Replace "full reload on external change" with a change-history delta read.

**Package changes** (Sources/GuessWhoSync + GuessWhoSyncTesting):

1. New value type(s) describing a change set, e.g.:
   ```swift
   public enum ContactChange: Sendable, Equatable {
       case updated(localID: String)   // covers add + update
       case deleted(localID: String)
   }
   public struct ContactChangeSet: Sendable {
       /// Ordered as the history reported them — apply IN ORDER. Do NOT
       /// bucket into updated-then-deleted: a delete followed by a re-add of
       /// the same localID (unify/unlink) must apply delete then update.
       public var changes: [ContactChange]
       public var newToken: Data        // opaque cursor to persist after apply
       public var requiresFullReload: Bool  // DropEverything / first run
   }
   ```
2. New `ContactStoreProtocol` method:
   ```swift
   func changes(since token: Data?) async throws -> ContactChangeSet
   ```
3. `CNContactStoreAdapter.changes(since:)` — implement with
   `CNChangeHistoryFetchRequest`:
   - Set `request.startingToken` to the decoded prior token (nil ⇒ from the
     beginning; we then also return `requiresFullReload: true` to baseline).
   - Set `request.excludedTransactionAuthors = [Self.transactionAuthor]` so our
     own writes (tagged in `save`/`delete`, workstream C) never surface.
   - Enumerate via the **`CNChangeHistoryEventVisitor` protocol** (NOT `is/as`
     class casts — the reviewer-correct, Apple-documented path). Implement a
     small visitor that appends `.updated`/`.deleted` in the order visited:
     `visitAddContactEvent` → `.updated`, `visitUpdateContactEvent` → `.updated`,
     `visitDeleteContactEvent` → `.deleted`, others → no-op.
   - **`visitDropEverythingEvent` ⇒ `requiresFullReload = true`** and clear any
     accumulated partial changes. Per TN3149, token invalidation / first-run /
     history-truncation is delivered AS A DROP-EVERYTHING EVENT in the stream —
     it is NOT a thrown error. (Original plan was wrong here.)
   - Read `result.currentHistoryToken` for `newToken`.
   - Run on the existing `workQueue` (same priority-inversion bridge as
     `fetchAll`). Genuine thrown errors (I/O, auth) still propagate via `throws`;
     the caller falls back to a full `reload()` on throw too.
4. `CNSaveRequest` author tagging (workstream C, in this same adapter):
   **EVERY** `CNSaveRequest` this adapter executes must carry
   `transactionAuthor = Self.transactionAuthor` (a constant, e.g. the bundle id)
   — not just `save`/`delete`. The adapter has 7 write sites:
   `save` (:117), `delete` (:141), `createGroup` (:190), `renameGroup` (:209),
   `deleteGroup` (:223), `addMember` (:282), `removeMember` (:295). Group and
   membership writes can emit `visitUpdateContactEvent` for the affected
   contact, so an untagged one would surface as a phantom self-write in the
   delta. Centralize via a single chokepoint — a private
   `makeSaveRequest() -> CNSaveRequest` (or `execute(_:)` helper) that stamps the
   author once — so no future write site can forget the tag. The group/membership
   APIs have zero app callers today (latent), but tagging them all upholds the
   absolute "our writes never appear in the delta" guarantee with no cost.
   Additionally set `request.includeGroupChanges = false` on the
   `CNChangeHistoryFetchRequest` so group-only churn never enters the contact
   delta.
5. `InMemoryContactStore.changes(since:)` — real op-log implementation so D is
   unit-testable: record an ordered op log (`updated`/`deleted` with a
   monotonic per-op token), honor `excludedTransactionAuthors` (track the author
   passed to a test save), return ordered changes since the given token, and
   emit `requiresFullReload` on a nil token or a token older than the retained
   log. Add a test-only `setTransactionAuthor`/save-with-author hook as needed.
6. Package tests in `Tests/GuessWhoSyncTests` covering: nil token → baseline +
   `requiresFullReload`; add/update/delete deltas in order; a delete-then-readd
   of the same localID preserves order; excluded-author writes are NOT reported;
   drop-everything ⇒ `requiresFullReload`.

**Token persistence:** the change-history token is meaningful, device-local sync
state — it must NOT live in `UserDefaults` (no meaningful data state in
UserDefaults), and it must NOT live in the iCloud-synced sidecar root either: a
`CNContactStore` history token from device A is meaningless on device B (each
device has its own contact-store history), so a synced token would cause the
wrong device to think it is "caught up" and silently miss external edits.

Persist it as a small **device-local** file in Application Support, OUTSIDE the
sidecar directory and excluded from iCloud backup/sync. Concretely:
- A tiny `ContactSyncCursorStore` (in `GuessWhoSync`) that reads/writes an opaque
  `Data` blob to `…/Application Support/<bundle>/contacts-change-cursor` (or a
  caller-provided device-local `URL`), with `URLResourceValues.isExcludedFromBackup`
  set so it never rides iCloud. It is a cursor/cache, safe to lose — loss just
  forces one full reload (`requiresFullReload`).
- The store URL is injected (constructor takes a `URL`) so it is testable and so
  the package never hard-codes an app-specific path. The app passes a device-local
  Application Support URL; tests pass a temp dir.
- A `nil`/missing cursor file ⇒ first run ⇒ baseline token + `requiresFullReload`.

(Open for review: exact filename and whether the cursor store is its own type vs
a method on the sidecar store using a device-local sibling directory. Default:
its own small type with an injected device-local URL, so iCloud-synced and
device-local state stay physically separated.)

**App wiring** (integrated by manager — see Integration):
- `SyncService.contactChanges(since:)` passthrough + cursor load/save via the
  device-local `ContactSyncCursorStore` (NOT UserDefaults, NOT the synced sidecar).
- `ContactsRepository.applyExternalChanges()` — fetch delta and apply with these
  REQUIRED properties (both reviewers):
  1. **Batch the post.** Mutate the cached `contacts` array for ALL changes
     first, then post `.contactsRepositoryDidReload` EXACTLY ONCE — no
     per-change post, or the diffable lists get a snapshot storm.
     `refreshContact`/`removeContact` (workstream B) therefore need a
     non-posting internal variant (e.g. private `applyOne(...)`) so the batch
     can post a single time; the public single-shot versions still post once.
  2. **Honor change order.** Apply `changeSet.changes` IN ORDER (delete-then-
     readd of the same localID must not be reordered into updated-then-deleted
     buckets). For `requiresFullReload`, call `reload()` instead.
  3. **Persist the cursor only AFTER a successful apply, on BOTH branches**
     (delta apply succeeded → save `newToken`; full `reload()` succeeded → save
     the fresh baseline `newToken`). Never persist before applying — a crash
     mid-apply must re-process, not skip.
  4. **Empty delta → no post.** Because our own saves still fire
     `.CNContactStoreDidChange` (the notification is not author-filtered — only
     the change-history READ is), the observer will frequently read a delta of
     ZERO changes (all ours, excluded). When `changes` is empty AND not
     `requiresFullReload`, skip the snapshot post entirely (still persist the
     advanced `newToken` — the cursor moved even though nothing user-visible
     changed). This avoids a no-op snapshot apply on every self-write.
  5. **Idempotent + serialized.** `applyRefresh` (replace/insert by localID) and
     `applyRemove` (drop by localID) are idempotent, so re-processing a delta
     after a crash (cursor not yet advanced) is safe. Overlapping invocations:
     guard with a simple in-flight flag / serialize on the main actor so two
     near-simultaneous `.CNContactStoreDidChange` notifications don't interleave
     a half-applied delta; the second either coalesces or runs after the first
     with the advanced cursor. Document the chosen guard inline.
- AppDelegate `.CNContactStoreDidChange` observer calls
  `applyExternalChanges()` instead of `reload()`, AND still calls
  `eventsRepository.reload()` (see Integration — do NOT drop it).

### Integration (manager-owned, after subagents land)

With C reimplemented via `transactionAuthor`/`excludedTransactionAuthors`, there
is **no race-prone self-suppression in the observer** — our own writes are
invisible to the change-history read by construction, and are already reflected
in the cache by B. The observer is therefore simple, but it MUST preserve the
existing events refresh (the current observer at GuessWhoAppDelegate:95-107 kicks
BOTH `contactsRepository.reload()` and `eventsRepository.reload()`; the rewrite
keeps the events call):

```
on .CNContactStoreDidChange (MainActor):
    Task { @MainActor in
        await contactsRepository.applyExternalChanges()  // D: delta, or reload() on requiresFullReload/throw
        await eventsRepository.reload()                   // PRESERVED from today's observer
    }
```

`.EKEventStoreChanged` observer is unchanged (events-only). The manager owns this
file (`GuessWhoAppDelegate.swift`) plus `SyncService` cursor helpers and
`ContactsRepository.applyExternalChanges()`, assembled after Agents 1–3 land.

---

## Parallelization

- **Agent 1 — package (D core + C author tag):** `ContactStoreProtocol.changes(since:)`,
  `ContactChange`/`ContactChangeSet`, `CNContactStoreAdapter` (visitor-based
  `changes(since:)` + `transactionAuthor`/`excludedTransactionAuthors` on
  save/delete), `InMemoryContactStore` op-log impl, `ContactSyncCursorStore`
  (device-local, injected URL, `isExcludedFromBackup`), package tests. **Zero
  app-file overlap.** Largest / riskiest; start first.
- **Agent 2 — app reads (A + A′):** add `SyncService.fetch`; convert #2/#9 to
  single fetch and collapse #5 into `reconcileIfNeeded`; DELETE dead #10
  `contact(forGuessWhoUUID:)`; convert map-builders #3/#4/#6/#7/#8 to
  `repository.contacts`; **inject the repository** into `EventDetailView` (env)
  and `FavoritesListViewController` (init param), editing
  **GuessWhoSceneDelegate.swift** at every `EventDetailView`/`FavoritesListViewController`
  construction site.
- **Agent 3 — app writes (B):** `ContactsRepository` non-posting mutators +
  `refreshContact`/`removeContact`/`postDidReload`; rewire `ContactDetailView`
  post-save → `refreshContact`, post-delete → `removeContact`, reconcile reload →
  `refreshContact`.
- **Manager — integration (C+D wiring):** `SyncService.contactChanges(since:)` +
  cursor load/save, `ContactsRepository.applyExternalChanges()` (batched,
  ordered, cursor-after-success), the rewritten AppDelegate `.CNContactStoreDidChange`
  observer that ALSO preserves `eventsRepository.reload()`.

Conflict management: Agent 1 (package) is conflict-free with all app agents.
Agent 2 owns GuessWhoSceneDelegate.swift; the manager does NOT touch it (manager
edits only GuessWhoAppDelegate.swift), so no overlap there. Agent 2 & Agent 3
both touch `SyncService.swift` (Agent 2 adds `fetch`, deletes #10; Agent 3 none —
B is repository-only) and `ContactDetailView.swift` (Agent 2: `loadContact`
fallback + `refreshContactMap`; Agent 3: save/delete/reconcile paths) — different
functions, git auto-merges non-adjacent hunks. `ContactsRepository.swift` is
Agent 3 (B mutators) + manager (`applyExternalChanges`) — sequence manager after
Agent 3. Merge order: Agent 1 → Agent 2 → Agent 3 → manager integration.

Note: with C folded into Agent 1 (author tag) + the manager observer, there is no
standalone "C agent" — the race-prone counter is gone entirely.

---

## Risks & edge cases

- **Empty/cold cache:** A′ consumers reached before first `reload()` see an empty
  list. Acceptable (matches today's pre-permission behavior) but each site must
  not crash on empty.
- **Stale cache for post-write reads:** #2/#5/#9 read immediately after a write —
  they MUST use `service.fetch`/adapter `fetch` (store), never the cache. Likewise
  B's `applyRefresh` re-reads the one changed contact from the store.
- **Self-writes via `transactionAuthor` (C), not a counter:** our `save`/`delete`
  tag `transactionAuthor`; the change-history read sets `excludedTransactionAuthors`
  so our own edits never appear in the delta — no async/coalescing race, no stuck
  counter. Our edits are reflected in the cache by B; external edits by D. The
  earlier counter design is REMOVED.
- **Change-history "DropEverything" (D):** token invalidation / first-run /
  history truncation arrives as a `visitDropEverythingEvent` callback (TN3149),
  NOT a thrown error → set `requiresFullReload` and fall back to full `reload()`.
  Genuine thrown errors (I/O, auth) also fall back to `reload()`.
- **Token must stay device-local (D):** the cursor is per-device contact-store
  state. It must NOT be in UserDefaults (no meaningful state there) and must NOT
  ride iCloud via the sidecar root — a synced token would make device B skip real
  edits. Persist device-local in Application Support, `isExcludedFromBackup`. Loss
  is safe: one full reload re-baselines it.
- **Unified contacts / event ordering (D):** change-history events are keyed on
  contact identifiers; a unify/unlink in Contacts.app can surface as delete+add of
  the same id. The delta-apply MUST process events IN HISTORY ORDER (not bucketed
  updated-then-deleted), so a delete-then-readd ends with the contact present.
  Covered by a package test (delete-then-readd preserves order).
- **Single app-owned repository:** never construct a second `ContactsRepository`.
  Thread the AppDelegate's instance through; injecting it into the SwiftUI views
  is part of A′.
- **Product principle:** none of this surfaces "sidecar"/"link"/"EventKit"
  vocabulary in UI. All changes are internal data-flow; no user-facing strings.

## Out of scope

- Converting lists to UIKit (already done) and the reconfigure-rows diff
  (commit 6dbb90c, pending its own review).
- Image/thumbnail loading paths (already on-demand).
- Event (EKEventStore) reload optimization — parallel but separate; this plan is
  contacts-only. The `.CNContactStoreDidChange` observer rewrite MUST preserve the
  existing `eventsRepository.reload()` call (a contact change can affect event
  invitee/attendee rendering) — this is a requirement of the integration, not an
  optional carry-over.

## Success criteria

1. The only full-store `fetchAll()` callers left are `repository.reload()` and
   internal reconcile.
2. Map-builders read `repository.contacts` (cache); single-record lookups use
   `service.fetch(localID:)`.
3. A user edit patches one row (no full reload); EVERY adapter write (save,
   delete, group + membership) is tagged with `transactionAuthor` and excluded
   from the change-history delta, so a self-write triggers no second reload and an
   all-ours delta posts nothing.
4. External Contacts.app edits apply as an ordered delta (only the changed
   contacts), under a single batched snapshot post, with a full-reload fallback on
   DropEverything/throw; the cursor persists only after a successful apply.
5. Package gains `changes(since:)` on the protocol + both store impls, the
   device-local `ContactSyncCursorStore`, and the `transactionAuthor` tagging,
   all with tests.
6. Dead code `SyncService.contact(forGuessWhoUUID:)` removed; #5 collapsed into
   `reconcileIfNeeded`.
7. `EventDetailView` + `FavoritesListViewController` receive the single app-owned
   `ContactsRepository` (env / init) at every SceneDelegate construction site.
8. The `.CNContactStoreDidChange` observer still refreshes `eventsRepository`.
9. Mac Catalyst build succeeds; package tests pass.
10. No user-facing string regresses the product principle.
