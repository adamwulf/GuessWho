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

Convert sites #2, #5, #9 to single fetch. #5 and #9 are post-write so they MUST
hit the store (`service.fetch`), not the cache.

### A′ — cache reads (app-only)

Point the map-builders (#3, #4, #6, #7, #8) at `repository.contacts` instead of
`service.fetchAll()`. Open design question per site: the SwiftUI views
(`ContactDetailView`, `ConnectionsSection`, `EventDetailView`) and
`FavoritesListViewController` must have `ContactsRepository` available.
- `ContactDetailView` already holds `repository` (it calls `repository.reload()`
  / `repository.contact(localID:)`), so #3 is a direct swap.
- `ConnectionsSection`, `EventDetailView`, `FavoritesListViewController`: confirm
  whether `repository` is already injected; if not, inject it. Do NOT construct a
  second `ContactsRepository` — there is ONE app-owned instance (AppDelegate).
  Thread the existing one through.

If a consumer can be reached before the repository's first `reload()` completes
(empty cache), it must tolerate an empty list gracefully (it already does today
for the "access not yet granted" case). The cache is refreshed on launch and on
every change, so staleness window is small; acceptable for these map-builders.

### B — in-place repository patch (app-only)

Add to `ContactsRepository`:

```swift
/// Refresh a single contact from the store and splice it into the cache,
/// then notify list controllers. Cheap alternative to a full reload() when
/// exactly one contact changed (our own save) — re-reads ONE record, not all.
func refreshContact(localID: String) async { ... }   // fetch → replace/insert → post

/// Remove a contact from the cache (our own delete) and notify. No store I/O.
func removeContact(localID: String) { ... }           // drop from array → post
```

Both post `.contactsRepositoryDidReload` exactly as `reload()` does, so the
diffable list controllers re-apply a snapshot. The `reconfigureItems` diff added
in commit 6dbb90c then repaints exactly the changed row.

Rewire post-save / post-delete paths to call these instead of full `reload()`:
- `ContactDetailView` inline-save path(s) (~:425, :445, :457, :1139) — after a
  save of a known localID, `await repository.refreshContact(localID:)`; after a
  delete, `repository.removeContact(localID:)`.
- Keep `await repository.reload()` ONLY where the set of changed contacts is
  unknown (genuine external change with no delta — handled by D's fallback).

Caution: the reconcile path (#9-adjacent, ContactDetailView:1139) reloads so the
cache reflects a freshly-stamped GuessWho URL. `refreshContact(localID:)` covers
that — it re-reads that one contact, which is exactly what changed.

### C — suppress self-inflicted reload (app-only)

The AppDelegate `.CNContactStoreDidChange` observer (GuessWhoAppDelegate:95-107)
currently full-reloads on every store change, including our own writes. Add a
suppression token: when the app performs a `save`/`delete` (and patches the cache
via B), set a flag/generation so the next `.CNContactStoreDidChange` that
corresponds to our own write is ignored (or downgraded to "already handled").

Design note: `.CNContactStoreDidChange` is coalesced and async — a naive boolean
can race (the notification can arrive after the flag is cleared, or batch several
writes). Prefer a small "expected self-change" counter or a short
debounce/coalesce window, and document the chosen approach inline. This
interacts with D (the observer is the same code site), so **C's observer change
is integrated together with D's wiring** — see Integration.

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
       public var changes: [ContactChange]
       public var newToken: Data        // opaque cursor to persist
       public var requiresFullReload: Bool  // true on token-invalid / first run
   }
   ```
2. New `ContactStoreProtocol` method:
   ```swift
   func changes(since token: Data?) async throws -> ContactChangeSet
   ```
3. `CNContactStoreAdapter.changes(since:)` — implement with
   `CNChangeHistoryFetchRequest` (set `startingToken`; `currentHistoryToken`
   when nil). Enumerate `CNChangeHistoryEvent` subclasses
   (`CNChangeHistoryAddContactEvent`, `...UpdateContactEvent`,
   `...DeleteContactEvent`; treat others as no-ops). On a thrown
   token-invalid / unsupported error, return `requiresFullReload: true` with a
   fresh `currentHistoryToken`. Run on the existing `workQueue` (same
   priority-inversion bridge as `fetchAll`).
4. `InMemoryContactStore.changes(since:)` — a test-friendly implementation:
   track a monotonic op log so tests can assert delta behavior, OR return
   `requiresFullReload: true` always (document which; a real op log is preferred
   so D can be unit-tested).
5. Package tests in `Tests/GuessWhoSyncTests` covering: first call (nil token →
   full-reload or baseline), add/update/delete deltas, and token-invalid →
   `requiresFullReload`.

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
- `ContactsRepository.applyExternalChanges()` — fetch delta; if
  `requiresFullReload`, call `reload()`; else for each `updated` localID
  `refreshContact`, each `deleted` `removeContact`; persist `newToken`.
- AppDelegate `.CNContactStoreDidChange` observer calls
  `applyExternalChanges()` instead of `reload()`.

### Integration (manager-owned, after subagents land)

The AppDelegate observer + repository delta-apply is where **C** and **D**
collide (same observer, same repository). The manager assembles this last so the
self-suppression (C) and the change-history delta (D) are designed as one
coherent observer:

```
on .CNContactStoreDidChange:
    if this change was caused by our own recent write (C): consume the token, skip
    else: await repository.applyExternalChanges()   // D: delta or full-reload fallback
```

---

## Parallelization

- **Agent 1 — package (D core):** ContactStoreProtocol, CNContactStoreAdapter,
  InMemoryContactStore, package tests. **Zero app-file overlap.** Largest /
  riskiest; start first.
- **Agent 2 — app reads (A + A′):** `SyncService.fetch`, convert single-record
  lookups (#2,#5,#9-app-side), convert map-builders to `repository.contacts`
  (#3,#4,#6,#7,#8), inject repository where missing.
- **Agent 3 — app writes (B):** `ContactsRepository.refreshContact/removeContact`,
  rewire post-save/delete paths to patch-in-place.
- **Manager — integration (C + D wiring):** SyncService passthrough + token
  persistence, `applyExternalChanges`, the unified AppDelegate observer.

Conflict management: Agents 1 & 2 are conflict-free. Agent 3 overlaps Agent 2 on
`SyncService.swift` / `ContactDetailView.swift` but in different functions (git
auto-merges non-adjacent hunks). The AppDelegate observer is touched only by the
manager. Merge order: Agent 1, then Agent 2, then Agent 3, then manager
integration.

---

## Risks & edge cases

- **Empty/cold cache:** A′ consumers reached before first `reload()` see an empty
  list. Acceptable (matches today's pre-permission behavior) but each site must
  not crash on empty.
- **Stale cache for post-write reads:** #5/#9 read immediately after a reconcile
  write — they MUST use `service.fetch` (store), never the cache.
- **`.CNContactStoreDidChange` coalescing/races (C):** notification is async and
  batched; the self-suppression must not drop a real external change that arrives
  in the same window. Favor a counter/coalesce over a bare boolean; document.
- **Change-history token invalidation (D):** OS can invalidate the token (store
  reset, OS migration). Must detect and fall back to full `reload()` —
  `requiresFullReload`.
- **Token must stay device-local (D):** the cursor is per-device contact-store
  state. It must NOT be in UserDefaults (no meaningful state there) and must NOT
  ride iCloud via the sidecar root — a synced token would make device B skip real
  edits. Persist device-local in Application Support, `isExcludedFromBackup`. Loss
  is safe: one full reload re-baselines it.
- **Unified contacts (D):** change-history events are keyed on contact
  identifiers; a unify/unlink in Contacts.app can surface as delete+add. The
  delta-apply (remove then refresh) handles this; verify in the adapter.
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
  contacts-only. (Note `.CNContactStoreDidChange` observer also kicks
  `eventsRepository.reload()` today; leave that behavior unless it falls out of
  the observer rewrite — if so, preserve it.)

## Success criteria

1. The only full-store `fetchAll()` callers left are `repository.reload()` and
   internal reconcile.
2. Map-builders read `repository.contacts` (cache); single-record lookups use
   `service.fetch(localID:)`.
3. A user edit patches one row (no full reload) and does not trigger a second
   full reload from the self-change observer.
4. External Contacts.app edits apply as a delta (add/update/delete of only the
   changed contacts), with a full-reload fallback on token invalidation.
5. Package gains `changes(since:)` on the protocol + both store impls, with tests.
6. Mac Catalyst build succeeds; package tests pass.
7. No user-facing string regresses the product principle.
