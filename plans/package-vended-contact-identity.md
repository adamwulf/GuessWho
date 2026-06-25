# Plan: package-vended `Contact` + opaque `ContactID`

## Status (2026-06-24)

- **Stage 1 — vend `ContactID`: DONE** (commits `79337de`, `ed57ae4`).
- **Stage 2 — package permission API: DONE** (commits `fa79533`, `13851e0`;
  integration fix `6a7fba9`).
- **Permission-status refinements (beyond original plan): DONE** — the app's
  `ContactsAuthorization`/`EventsAuthorization` enums were deleted; the UI binds
  to the package's `StoreAuthorizationStatus` directly (commits `6b463c2`,
  `fad00f1`). `init` no longer reads system status; the properties default to
  `.notDetermined` and the launch-time `await request…IfNeeded()` populates them
  (commit `ff18113`).
- **Stage 1.5 (O(1) contact index in the repository): DONE** (`557b8d7`,
  `f4b4031`). `contact(id:)`/`contact(localID:)`/`contactIDs(matchingEmail:)` are
  O(1) synchronous reads over private `contactsByEffectiveID`/`contactsByLocalID`/
  `contactsByEmail` indexes; all `contacts` mutations funnel through one
  `setContacts(_:)`; the delta path rebuilds once per batch. Lets Stages 3–4
  delete the five hand-rolled UI-layer contact maps.
- **Stage 3 (list VCs): DONE** (`d3f1a83`, `97c0cb8`, NIT `a2d6bb0`). First
  attempt relied on undocumented diffable `==`-reconfigure + had an `appendItems`
  crash and was rejected in review; the shipped redesign makes `ContactID`
  identity-only and the VCs drive reconfigure explicitly (a `[ContactID: Contact]`
  last-rendered map) with the snapshot deduped by `effectiveID`. `contactsByLocalID`
  is gone from both VCs. 428 tests + Catalyst + iPhone-sim builds green.
- **Stage 4 (navigation/detail/connections/favorites): DONE** (`fc50b7e`,
  `4496320`). `ContactReference` carries a `ContactID` (not a `localID`);
  `ContactDetailView`'s identity is a `ContactID` with `localID` confined to a
  `boundaryLocalID`/`resolvedLocalID` token threaded only into SyncService/
  repository methods (stable across a reconcile re-key). The three hand-rolled
  maps (`uuidToContact` in ContactDetailView / EventDetailView /
  FavoritesListViewController, plus `emailToContact`) are DELETED; resolution
  goes through `repository.contact(id:)` / `contactIDs(matchingEmail:)` and a
  small new package accessor `contact(guessWhoID:)` (bare link-endpoint /
  favorite UUID → Contact, O(1), guessWhoID-confirmed) alongside
  `contactID(for:)` (the only sanctioned way for the app to mint a navigation
  token from a Contact, since `ContactID.init` is `package`). Connections,
  attendee/linked-contact taps, and favorites resolve on demand;
  `service.guessWhoUUID(in:)` survives only for the OPENED contact's own UUID
  (favorites/notes/links binding) and the debug section — Stage 5 owns its
  removal. 430 tests + Catalyst + iPhone-sim builds green.
- **Stage 5 (visibility tighten): DONE (5.5 assessed, NOT implemented).**
- **Stage 6 (ContactID-keyed contact sidecar API; internalize reconcile):
  IN PROGRESS — 6a + 6b DONE.** Split into sub-phases 6a
  (foundation: wire engine into repository + reconcile-on-write) → 6b (vend the
  ContactID-keyed API) → 6b2 (one `Contact` cache `contactsByLocalID` + a
  `guessWhoIDToLocalID` pointer index — no duplicate `Contact` copies — so
  `contact(id:)` survives a reconcile re-key and `ContactDetailView.resolvedLocalID`
  can be deleted) → 6c (`prepareContactForDetail`) → 6d (migrate app
  consumers) → 6e (audit). 6a wires the engine + favorites store into the
  repository. Concurrency: accept double-mint (a practical non-event;
  single-device = harmless orphan, multi-device = Case-D heals).
  Favoriting an unreconciled contact becomes allowed (package reconciles then
  saves). Debug reconcile/sidecar readout dropped (no new retained package state).
- **Stage 7 (EventID + event-identity boundary): DEFERRED** — the events analogue
  of Stages 1–6; the `EventsRepository`-into-package migration given a stage
  number. Not started; scope TBD after Stage 6 lands.
  The VIEW no longer calls `service.guessWhoUUID(in:)`: a new package accessor
  `ContactsRepository.guessWhoID(in: Contact) -> String?` (a PURE function of the
  passed contact returning `ContactID(contact:).guessWhoID` — nil when
  un-reconciled, never the localID fallback) backs `contactUUID`, the debug
  section, and the post-load UUID read. It reads off the LOADED `contact` (tracked
  via the stable `resolvedLocalID`), NOT the nav `id`, because `id` does not
  re-key when an on-open Case-A reconcile mints the UUID — keying on `id` would
  null the binding right after reconcile. `SyncService.guessWhoUUID(in:)` is now
  `private` (SyncService doesn't retain a repository, so its own sidecar/reconcile
  seams keep using it). Static `localID` audit: every app `localID` is a
  boundary token, the empty new-contact seed, the debug display, or a comment —
  no identity/dict-key/nav use remains. **Stage 5.5** (`Contact.localID`
  `public → package`) was ASSESSED ONLY, not implemented: app sites still READ
  `Contact.localID` (debug display, edit-save boundary, boundary-token capture,
  and SyncService's reconcile seams), so a blind flip would break them. See the
  Stage 5.5 assessment for the package additions a clean flip would require.
  432 tests + Catalyst + iPhone-sim builds green.

Two design decisions taken during Stages 1–2 changed the shape below from the
original draft — they are folded into the sections that follow:

1. **`ContactID` carries BOTH an OPTIONAL `guessWhoID` and the `localID`;
   identity = `guessWhoID ?? localID`.** A not-yet-reconciled contact (no
   `guesswho://` URL) is identified by its `localID` and still appears in the
   list — it is NOT dropped. The original draft's "materialize only after
   reconciliation, identity is the GuessWho UUID only" is superseded.
2. **The reconciliation transition (`localID`-keyed → `guessWhoID`-keyed) is an
   accepted diffable delete+insert**, rare (once per contact) and symmetric with
   how events adopt a sidecar (`Event.stableID(forEventKitID:)`). No alias map.
3. **`ContactID` is a FULLY OPAQUE, IDENTITY-ONLY token** — its only stored
   properties are `guessWhoID`/`localID`, both `package` (zero public), and `==`
   AND `hash` both key on `effectiveID` only (consistent `Hashable`). The app
   holds/compares/fetches-with it but cannot read any field, so it can't be a
   "contact-light". It carries NO display fields: an earlier draft did, betting
   diffable `apply()` would reconfigure on `==`-difference, but Apple's docs say
   it won't (you must call `reconfigureItems` explicitly), so the fields earned
   nothing and made `Hashable` inconsistent. Content repaint is the VC's explicit
   reconfigure pass; rows render from the `Contact` fetched via the synchronous
   O(1) `repository.contact(id:)`.

## Why

Today the app keys its entire contact UI on `localID` (Apple's
`CNContact.identifier`) and runs its own `CNContactStore`/`EKEventStore`. Both
break the project's stated boundaries:

- `localID` is supposed to be a transient lookup token, never persisted,
  compared, or keyed-on as GuessWho identity (`CLAUDE.md`,
  `docs/contact-identity.md`). The app instead uses it as the durable identity
  for diffable-data-source rows, navigation references, and identity
  comparisons.
- The UI should never load or run `CNContactStore` on its own. `SyncService`
  instantiates a second `CNContactStore` (for the main-actor `requestAccess`
  call) and owns the `EKEventStore`.

This plan fixes both with one change to the package's vended model: the package
hands the app a `Contact` that carries an **opaque `ContactID`** wrapping both
the GuessWho UUID and the (internal) `localID`, plus the handful of bare display
fields the UI needs for change detection. The app keys everything on `ContactID`
and never sees `localID`. A small package-vended permission API removes the
app's need to own a `CNContactStore`.

This supersedes the deleted `contacts-repository-package-api.md`. That plan
relied on a session-scoped loser→canonical alias map, an explicit
`bootstrapIdentityBaseline()` write-sweep distinct from `reload()`, and parallel
`ID↔localID` index dictionaries threaded through every incremental mutation.
This plan does **not** introduce those. Identity lives inside the `ContactID`
value itself, so there is no separate index to keep coherent and no alias map to
grow.

## Core idea

`ContactID` is a FULLY OPAQUE, IDENTITY-ONLY token. EVERY stored property is
`package`, ZERO public, and there are only two — the identity, nothing else. The
app holds it, compares it, and hands it back to fetch the real `Contact`; it
CANNOT read any field off it, so the token can't be misused as a "contact-light".
The conformances are public so the app can put it in a diffable snapshot / `Set`;
the data is sealed.

```swift
public struct ContactID: Hashable, Sendable {
    // The ONLY two stored properties — both package, both identity:
    package let guessWhoID: String?   // canonical bare UUID, nil until reconciled
    package let localID: String       // CNContact.identifier, always present

    var effectiveID: String { guessWhoID ?? localID }   // the single identity

    /// NON-failing — `localID` is always available, so a row can be vended
    /// before reconciliation. `guessWhoID` is nil when there's no valid URL.
    package init(contact: Contact) { /* sets guessWhoID via SidecarKey, localID */ }

    // CONSISTENT Hashable: == and hash BOTH key on effectiveID, nothing else.
    public static func == (lhs: ContactID, rhs: ContactID) -> Bool {
        lhs.effectiveID == rhs.effectiveID
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(effectiveID)
    }
}
```

### Why identity-only (and NOT "== carries display fields for free diffing")

An earlier draft put the display fields on `ContactID` and made `==` compare
them while `hash` stayed identity-only, betting that
`UITableViewDiffableDataSource.apply()` would re-check `==` on a same-identity
row and auto-reconfigure it. **It does not.** Apple's docs (the `reconfigureItems`
discussion) are explicit: `apply()` identifies items by their `Hashable`
identifier ONLY; to repaint an existing row's CONTENTS you must EXPLICITLY call
`reconfigureItems`/`reloadItems`. A `==`/`hash` that disagree is also a
`Hashable`-contract smell, and two contacts sharing a `guessWhoID` in the
transient pre-reconcile window produced two EQUAL `ContactID`s → `appendItems`
trap (crash). So:

- `ContactID` is identity-only (consistent `Hashable`).
- The list VCs do their OWN explicit `reconfigureItems` pass: keep a
  `[ContactID: Contact]` map of what each row last rendered, and on each snapshot
  reconfigure the rows whose `Contact` (fetched via `repository.contact(id:)`)
  differs from the last-rendered one. Identity stays stable (no flicker); only
  changed contents reload. This is documented behavior, in the layer Apple says
  owns it.
- The snapshot is DE-DUPED by `effectiveID` so the transient duplicate-guessWhoID
  window can't trap `appendItems`.

This still deletes the app's `contactsByLocalID` side-dictionary (rows key on
`ContactID`, content fetched O(1) via `repository.contact(id:)`); it just keeps
the content-change detection explicit in the VC instead of (incorrectly) leaning
on diffable internals.

The snapshot becomes `NSDiffableDataSourceSnapshot<Section, ContactID>`. Because
`ContactID` is identity-only and sealed, the cell provider fetches the full
`Contact` via `repository.contact(id:)` to render the row (the existing cells
already take a `Contact` — `ContactCell.configure(with: Contact)` — so this costs
nothing). Content-change repaint is driven by the VC's explicit `reconfigureItems`
pass (above), comparing the fetched `Contact` against the last rendered one.

### No display fields on `ContactID` (DECIDED)

`ContactID` carries NO display data — only its identity (`guessWhoID` /
`localID`). An earlier draft carried the row's raw components for "free" diffing;
that was removed because `apply()` does not reconfigure on `==`-difference (see
above), so the fields earned nothing and made `Hashable` inconsistent. Row
content always comes from the `Contact` fetched via `repository.contact(id:)`.

## What the app stops doing

Direct consequences once `ContactID` lands and the app migrates to it:

- **No `contactsByLocalID` dictionaries.** `ContactsListViewController` and
  `OrganizationsListViewController` snapshot `ContactID` directly; the cell
  provider fetches the row's `Contact` via `repository.contact(id:)` (a cache
  hit) — no app-maintained side dictionary.
- **An EXPLICIT `reconfigureItems` pass stays** (keyed on `ContactID` now, not
  `localID`): the VC compares each row's fetched `Contact` against the last
  rendered one and reconfigures the changed rows. `ContactID` identity keeps the
  row in place; this pass repaints its contents. (Not "for free" via `==` — see
  "Why identity-only" above.)
- **No `localID` in navigation.** `ContactReference` (`NavigationReferences.swift`)
  is re-keyed on `ContactID` (carry the whole value, or just `guessWhoID`).
- **No `localID` identity comparisons.** `ContactDetailView.swift:654` and
  `ConnectionsSection.swift:266` compare `ContactID`s (i.e. effective identity),
  not raw `localID`.
- **No app-built GuessWho-UUID maps.** The 3 duplicated
  `for c in repository.contacts { map[guessWhoUUID(in: c)] = c }` builders
  (`EventDetailView:482`, `FavoritesListViewController:213`,
  `ContactDetailView`) are replaced by `repository.contact(id:)`.
- **No `SyncService.guessWhoUUID(in:)` in the app.** Identity is already on the
  vended value.
- **No app-owned `CNContactStore`.** See the permission section below.

## Identity construction (where the UUID comes from)

When a contact carries a valid GuessWho URL, `ContactID.guessWhoID` is the
canonical lowercase bare UUID produced by the existing single
validator/canonicalizer in `SidecarKey` (`parseGuessWhoContactURL` /
`forContact`) — never a parallel parser. When it carries no URL (not yet
reconciled), `guessWhoID` is nil and identity falls back to `localID`; the
`ContactID` still materializes, so the row appears in the list immediately
(`reload()` does NOT reconcile — see Non-goals).

Once reconciliation mints a URL (or a Case-D collapse settles the canonical
UUID), the contact's `ContactID` gains/changes its `guessWhoID`, so its
effective identity changes. The diffable apply renders that as a delete of the
old-identity row + insert of the new-identity row — correct, rare (once per
contact), and requiring no alias map. A navigation reference or favorite holding
a retired UUID resolves through the repository; if it cannot resolve it returns
nil → a non-crashing "unavailable" state. (Actively mapping a known-retired
Case-D UUID to its canonical record from the durable on-disk link-rewrite record
the reconciler already writes is a clean follow-up, not a blocker for v1.)

## Permission API (removes the app's `CNContactStore`) — DONE

`SyncService` formerly constructed a second `CNContactStore` (for the main-actor
`requestAccess`) and owned the `EKEventStore`. Both are gone. As shipped:

- The package vends two neutral types (`Sources/GuessWhoSync/StoreAuthorizationStatus.swift`):
  - `StoreAuthorizationStatus { notDetermined, authorized, denied, restricted }`
    — the adapters collapse platform statuses into it (Contacts `.limited` →
    `.authorized`; Events `.fullAccess`/pre-17 `.authorized` → `.authorized`,
    `.writeOnly` → `.denied`).
  - `StoreAccessResult { status, failureDescription? }` — `failureDescription`
    is non-nil ONLY when the request threw, so `SyncService` restores the same
    `lastError` write the pre-adapter code made on a thrown request.
- `ContactStoreProtocol` gained `contactsAuthorizationStatus()` /
  `requestContactsAccess() -> StoreAccessResult`; `EventStoreProtocol` gained the
  event equivalents. The adapters own the one true store and run the request
  there. The `EKEventStoreAdapter` constructs its own store via a defaulted
  `init()`; `SyncService` owns zero Apple stores.
- **The app's `ContactsAuthorization`/`EventsAuthorization` enums were deleted.**
  They were isomorphic to `StoreAuthorizationStatus` (only `.notRequested` vs
  `.notDetermined` differed), so the mapping carried no information. The UI binds
  to `StoreAuthorizationStatus` directly; `PermissionGateViewController` /
  `EventsListViewController` switch on `.notDetermined` etc.
- `SyncService.contactsAuthorization` / `eventsAuthorization` default to
  `.notDetermined`; `init` does NOT read system status (an init can't `await`).
  `GuessWhoAppDelegate` awaits `requestContactsAccessIfNeeded()` /
  `requestEventsAccessIfNeeded()` right after construction, which populates the
  real status before first interaction. Tradeoff accepted: an already-authorized
  user may see the "Requesting…" gate for one frame at launch.

Result: `grep` finds zero `CNContactStore(` / `EKEventStore(` in the app target.

## Non-goals / explicitly out of scope

- No session-scoped loser→canonical alias map. (The deleted plan's mechanism.)
- No `bootstrapIdentityBaseline()` that makes `reload()` a write-sweep. Keep the
  existing reconcile triggers; do not silently turn every reload into a write.
- No parallel APP-SIDE contact maps surviving the migration, and no
  session-scoped loser→canonical alias index. (A repository-INTERNAL
  `[effectiveID: Contact]` performance index IS wanted — see Stage 1.5 — but it
  is a private cache rebuilt from the snapshot, not an alias map and not exposed
  to the app. The only `localID` carrier the app sees is the sealed field inside
  `ContactID`.)
- No change to how relationships vs links work, and no new
  pick-from-existing-contact UI. (Honors `CLAUDE.md`.)
- Not bundled here: moving `EventsRepository` into the package, the
  Organizations/Contacts list-VC de-duplication, and the `EventLinkSheet`
  "pick existing calendar event" product-principle question. Those are tracked
  separately; this plan is scoped to contact identity + permissions.

## Implementation stages

Each stage ends green (`swift test` + Catalyst build) before the next begins.

### Stage 1 — Vend `ContactID` from the package — DONE (`79337de`, `ed57ae4`)

1. Add `ContactID` (above) to `Sources/GuessWhoSync/`. `localID` is `package`
   visibility (or `internal`), never `public`.
2. Give `ContactsRepository` methods that return contacts addressed by
   `ContactID`:
   - `contact(id: ContactID) -> Contact?`
   - the existing section/search accessors vend `ContactID` rows (or expose a
     parallel `*IDs` accessor) so list VCs can snapshot them.
   - `contacts(matchingEmail:)`, `contacts(named:)`, `contactsReferencing(id:)`
     return results keyed by `ContactID`. `contacts(named:)` returns ALL matches
     (no silent last-writer pick); the UI owns disambiguation.
3. `ContactID` is built via a NON-failing `init(contact:)`: `guessWhoID` comes
   only via `SidecarKey.forContact` (nil when no valid URL); `localID` is always
   set. Section accessors `.map` (not `.compactMap`) so no contact is dropped.
4. Package tests: identity equality across display-field changes; hash stability
   across a field edit; `==` inequality on a name/job/org/photo change;
   `contact(id:)` round-trip; duplicate display-name returns all matches;
   `contactsReferencing` self-exclusion by `guessWhoID`.

Acceptance: package vends `ContactID`-addressed reads; `localID` is not public;
no query enumerates `CNContactStore` (cache reads only).

### Stage 1.5 — O(1) contact index inside the repository — DONE (`557b8d7`, `f4b4031`)

**Goal:** make `contact(id:)` (and `contact(localID:)`) O(1) so the app can get
a `Contact` back from a `ContactID` immediately, and so the five hand-rolled
UI-layer maps (below) can be deleted in Stages 3–4 with nothing to replace them.

**Where the maps live today (all in the UI, all O(n)-to-build, all duplicated):**
`contactsByLocalID` in `ContactsListViewController` and
`OrganizationsListViewController`; `uuidToContact` in `FavoritesListViewController`,
`ContactDetailView`, and `EventDetailView` (the last also keeps `emailToContact`).
Each is rebuilt independently from `repository.contacts`. The package's
`ContactsRepository` currently holds only a flat `[Contact]` and does O(n)
`contacts.first { … }` scans (`contact(localID:)`, `contact(id:)`).

**Design — the cache already lives on the right actor; just index it.**
`ContactsRepository` is ALREADY `@MainActor @Observable` (not an `actor`). It
holds `contacts` on the main actor and only `await`s when it reaches into the
store (`contactsStore.fetch…`) to REFRESH. So the structure Adam described —
"a `@MainActor` cache the UI works with directly, while the package `await`s as
it updates the cache" — already exists; we do NOT need a separate cache object.
Add private indexes as stored properties on the repository:

- `private var contactsByEffectiveID: [String: Contact]` — keyed on
  `ContactID(contact:).effectiveID` (`guessWhoID ?? localID`).
- `private var contactsByLocalID: [String: Contact]` — for the existing
  `contact(localID:)` boundary accessor.
- `private var contactsByEmail: [String: [Contact]]` — lowercased email →
  contacts, so attendee resolution (`contacts(matchingEmail:)`) is O(1) and
  `EventDetailView`'s `emailToContact` can go.

Maintain them at EVERY site that assigns `contacts` — `reload()` (`:46`),
`applyRefresh` (`:200-206`), `removeContact` (`:188`), and the change-watcher
delta apply (`:236`). Funnel ALL mutations through ONE private
`setContacts(_:)` / `rebuildIndexes()` helper so the array and indexes cannot
drift. `contact(id:)` becomes `contactsByEffectiveID[id.effectiveID]` — a
synchronous main-actor dictionary hit, NO `async`, no new type, no actor hop.

**Subtlety — the reconciliation transition re-keys.** When a contact's effective
identity flips `localID → guessWhoID`, its key in `contactsByEffectiveID` moves.
Because the indexes are rebuilt wholesale from the snapshot at each mutation
(not patched in place), this is automatic — but a reviewer must confirm a
re-keying contact is found under its NEW key and not stale under the old one.

Tasks:
1. Add the three private indexes + a single `setContacts(_:)` funnel; route
   `reload`/`applyRefresh`/`removeContact`/delta-apply through it.
2. Rewrite `contact(id:)`, `contact(localID:)`, and `contacts(matchingEmail:)`
   as O(1) index reads. Public signatures UNCHANGED (still synchronous,
   non-`async`).
3. Tests: O(1) lookup correctness after full reload, after an incremental
   update, after a delete, and ACROSS a reconciliation transition (a contact
   gains a `guessWhoID` and is then found under the new effective id, not the
   old). Plus a parity test: index results equal the old O(n)-scan results for
   the same cache.

Acceptance: `contact(id:)` is O(1) and synchronous; one funnel maintains all
indexes; no public signature changed; the UI-layer maps are deletable in
Stages 3–4 (they are removed there, not here).

### Stage 2 — Package permission API — DONE (`fa79533`, `13851e0`, `6a7fba9`)

Shipped as described in the "Permission API" section above, plus the
status-binding/`.notDetermined`-seed refinements (`6b463c2`, `fad00f1`,
`ff18113`). Acceptance met: grep shows zero `CNContactStore(` / `EKEventStore(`
in the app target; Catalyst + iPhone-simulator builds green; permission flow
intact.

### Stage 3 — Migrate list view controllers — DONE (`d3f1a83`, `97c0cb8`, `a2d6bb0`)

1. `ContactsListViewController` and `OrganizationsListViewController` snapshot
   `NSDiffableDataSourceSnapshot<String, ContactID>`. Cell provider fetches the
   row's `Contact` via `repository.contact(id:)` — a SYNCHRONOUS main-actor,
   O(1) index read after Stage 1.5 (no store I/O, no `await`) — and passes it to
   the existing `configure(with: Contact)`. Delete `contactsByLocalID`.
2. `ContactID` is identity-only, so keep an EXPLICIT content-change pass: a
   `[ContactID: Contact]` last-rendered map; on each snapshot, `reconfigureItems`
   the rows whose fetched `Contact` differs from the last-rendered one (exclude
   rows absent from the new snapshot — reconfiguring an absent item traps). This
   replaces the old `localID`-keyed `previousByID`/`reconfigureItems` pass with a
   `ContactID`-keyed one; it does NOT rely on `ContactID`'s `==`.
3. DE-DUPE the snapshot by `effectiveID` (a `Set<ContactID>` as you append; first
   wins) so the transient duplicate-`guessWhoID` window can't trap `appendItems`.
4. `didSelectRowAt` reads the `ContactID` item identifier and resolves via
   `repository.contact(id:)`. `didSelectContact: (Contact)` stays unchanged so
   `GuessWhoSceneDelegate` is untouched (navigation re-keying is Stage 4).

NOTE: the FIRST attempt (commit `f2087ff`) leaned on `ContactID`'s `==` to drive
reconfigure-for-free and was rejected in review — `apply()` does not reconfigure
on `==`-difference (Apple docs), and equal duplicate `ContactID`s trapped
`appendItems`. The redesign above (identity-only `ContactID` + explicit pass +
dedup) is the corrected approach.

Acceptance: list VCs hold no `localID` and no side `[String: Contact]`
dictionary; in-place edits still repaint via reconfigure; selection still
navigates.

### Stage 4 — Migrate navigation + detail + connections + favorites — DONE (`fc50b7e`, `4496320`)

Shipped as described below. Two small package accessors were added to bridge the
app off the deleted maps: `contactID(for: Contact) -> ContactID` (mint a nav
token from a held Contact, since `ContactID.init` is `package`) and
`contact(guessWhoID: String) -> Contact?` (resolve a bare link-endpoint /
favorite UUID, O(1) over `contactsByEffectiveID`, confirmed by `guessWhoID` so a
localID coincidence can't mis-resolve). `ContactDetailView` keeps a
`resolvedLocalID`/`boundaryLocalID` token (stable across a reconcile re-key) for
its SyncService/repository boundary calls. `service.guessWhoUUID(in:)` remains
only for the opened contact's own UUID + the debug section (Stage 5 removes it).

1. Re-key `ContactReference` (`NavigationReferences.swift`) on `ContactID` (or
   `guessWhoID`). Update every `pushContactReference(...)` site and the
   `GuessWhoSceneDelegate` Catalyst-replace + iPhone-push paths together.
2. Re-root `ContactDetailView` on `ContactID`: load, edit, save, delete,
   reconcile-after-write, related-contact rows. `localID` resolution happens
   only inside repository/package methods (e.g. `save(id:edit:)`,
   `delete(id:)`, image fetch).
3. Replace identity comparisons at `ContactDetailView.swift:654` and
   `ConnectionsSection.swift:266` with `guessWhoID` comparisons.
4. Remove `uuidToContact` / `emailToContact` map-builders in `EventDetailView`,
   `FavoritesListViewController`, `ContactDetailView`; resolve via
   `repository.contact(id:)` and `contacts(matchingEmail:)`.
5. `ConnectionsSection.EligibleContact` keyed by `ContactID`.

Acceptance: a stale reference (deleted contact, retired Case-D UUID with no
resolvable canonical) yields a non-crashing "unavailable" state, never a
`localID` fallback.

### Stage 5 — Tighten visibility + remove dead wrappers

1. Remove `SyncService.guessWhoUUID(in:)` and any app `localID`-keyed
   contact wrappers.
2. Consider making `Contact.localID` non-public once no app caller reads it
   (the package fetch path uses `ContactID.localID` internally). Do this in its
   own commit, after Stage 4, so it's a clean visibility flip.
3. Static identity audit: `grep` the app target for `localID`. Every remaining
   occurrence must be (a) the debug-only Contact Detail display, or (b) an
   explicitly commented adapter bridge. No app code may pass `localID` to
   navigation, store it in a dictionary/set, or compare it.

Acceptance: `grep` over the app target finds no `localID` identity use outside
the enumerated debug/bridge exceptions; one `ContactsRepository` in the package
is the sole contact API the app uses.

#### Shipped

- **New package accessor** `ContactsRepository.guessWhoID(in: Contact) -> String?`
  returns `ContactID(contact:).guessWhoID` — the reconciled GuessWho UUID, or nil
  when un-reconciled (NEVER the `localID` fallback). It is a PURE function of the
  passed contact (no cache read → no cache-miss window), so it reads the UUID off
  the live record the caller already holds. Covered by two package tests
  (`guessWhoIDInReturnsReconciledUUIDAndNilOtherwise`,
  `guessWhoIDInIsPureAndIndependentOfTheCache`).
- **The VIEW no longer calls `service.guessWhoUUID(in:)`.** `contactUUID` (which
  drives ALL favorites/notes/links/tags binding), the debug section, and the
  post-load UUID read all go through `repository.guessWhoID(in: <loaded contact>)`.
  Crucially it reads off the LOADED `self.contact` (tracked via the stable
  `resolvedLocalID`), NOT the nav `id`: `id` is captured at selection time and is
  never re-keyed, so an on-open Case-A reconcile that mints the UUID would leave
  `repository.contact(id: id)` resolving to nil — keying `contactUUID` on `id`
  would null the binding right after reconcile. Reading off `self.contact`
  reproduces the former `service.guessWhoUUID(in:)` semantics byte-for-byte.
- **`SyncService.guessWhoUUID(in:)` is now `private`** (not deleted). SyncService
  does not retain a `ContactsRepository` (it builds one for the app but doesn't
  hold it), so its own sidecar/reconcile seams (`sidecar(for:)`,
  `reconcileIfNeeded(contact:)`) keep calling the private helper — the lowest-churn
  option, and the helper is identical to `repository.guessWhoID(in:)`.
- **Static `localID` audit (app target).** Every `.localID` read is one of:
  (a) a boundary token threaded INTO a SyncService/repository method —
  `ContactDetailView.performInlineSave` (`saveLocalID`, commented),
  `ContactDetailView.boundaryLocalID` (`repository.contact(id:)?.localID`),
  `ContactDetailView.loadContact` (`resolvedLocalID = loaded.localID`),
  `SyncService.reconcileIfNeeded` (`contact.localID` → `reconcile`/`fetch`);
  (b) the empty new-contact seed `Contact(localID: "")` in `ContactDetailView`
  and `EventDetailView`; (c) the debug-section display in
  `ContactDetailView.debugRows` (commented); (d) comments
  (`GuessWhoSceneDelegate`, `SyncService` doc, `ConnectionsSection`,
  `NavigationReferences`). NO `localID` is used as `@State` identity, a
  dict/set key, an identity comparison, or a navigation payload — Stage 4
  cleared them; verified.

#### Stage 5.5 assessment (Contact.localID visibility) — ASSESSED, NOT IMPLEMENTED

A blind `Contact.localID` `public → package` flip would BREAK these app reads:

| App site | Reads `Contact.localID` for | Could go through a package method? |
| --- | --- | --- |
| `ContactDetailView.debugRows` (`contact.localID` display) | Debug-only diagnostic display of the raw `CNContact.identifier` | NO clean substitute — it must surface the literal identifier string. A package accessor like `debugLocalID(for: Contact) -> String` could front it, but that just re-exports the same field under a new name purely for one debug row. |
| `ContactDetailView.performInlineSave` (`model.edited.localID`) | Capture the save target localID for post-save boundary calls | The localID rides on the `ContactEditModel.edited` Contact; the save path already takes a `Contact`. Could thread the captured token differently, but the edit model holds a `Contact` whose `localID` it legitimately needs. |
| `ContactDetailView.loadContact` (`loaded.localID` → `resolvedLocalID`) | Capture the stable boundary token on first load | Could be replaced by a package accessor `boundaryToken(for: Contact)`, but that is exactly `Contact.localID` re-exported. |
| `SyncService.reconcileIfNeeded` (`contact.localID`) | Pass into `reconcile(localID:)` / `contactsAdapter.fetch(localID:)` | These ARE the Contacts-boundary calls; the localID is the boundary token by definition. |

Recommendation: **keep `Contact.localID` `public`** as the documented
Contacts-boundary token, OR — if the flip is judged worth it — it requires the
package to add accessors that re-export the same string (`debugLocalID(for:)` for
the debug row, plus a boundary-token vendor for the save/load capture and the
SyncService reconcile seams). That trades a single well-documented public field
for several thin pass-through accessors whose only job is to hand back
`contact.localID`. Given `Contact.localID` is already documented as the transient
Contacts-boundary identifier (and `ContactID.localID` — the carrier the UI keys
on — is already `package`), the public field earns its keep at the boundary; the
flip is low-value churn. Defer Stage 5.5 unless a concrete need to seal
`Contact.localID` arises.

### Stage 6 — `ContactID`-keyed contact sidecar API; internalize reconcile

**Depends on Stage 5 landing first** (Stage 5 made `guessWhoUUID(in:)` private and
ran the `localID` audit; Stage 6 then moves the rest of the contact-sidecar
boundary).

#### Sub-phases (land in order; 6c and 6d can overlap after 6b)

Stage 6 is large — split it so each piece is independently buildable, testable,
and reviewable. The Design / call-surface / tests sections below are the detail;
this is the sequencing:

- **6a — Foundation (package only) — DONE (`7ddd05e`, `0476402`).** Wire the
  `GuessWhoSync` engine AND the
  standalone `FavoritesStore` into `ContactsRepository` (Design step 0, both
  `Optional`) and add the internal resolve-or-mint /
  reconcile-on-write primitive (Design step 2, incl. the accept-double-mint /
  Case-D-collapses-it concurrency stance). No public API change, no app change yet. Flip
  `reconcileContactIdentity` to `internal` here, keeping the existing direct-call
  tests. **Everything else depends on 6a.**
- **6b — Vend the `ContactID`-keyed read/write API — DONE (`bf20afd`).** On the repository (Design
  step 1) — `notes/links/eventLinks/favorite` verbs, plain-named, reconcile-on-
  write internally, package owns the post-write cache update (decision B). Package
  tests (Tests section). Still no app migration.
- **6b2 — One `Contact` cache + a guessWhoID→localID pointer index; make
  `contact(id:)` reconcile-stable** (package only; depends on 6a, independent of
  6b — can land in parallel). Replace the mixed-key `contactsByEffectiveID` with
  the SINGLE `Contact` cache `contactsByLocalID` (every contact, one copy of each
  struct) plus a lightweight `guessWhoIDToLocalID: [String: String]` POINTER index
  (reconciled only — no second copy of any `Contact`, so the two cannot drift).
  Resolve `contact(id:)` guessWhoID-first (chase the pointer) else by localID
  (load-bearing for the captured-pre-reconcile token), and on a reconcile-on-write
  mint update the cache struct AND add the pointer. `contact(guessWhoID:)` STAYS
  PUBLIC — favorites/links sync guessWhoIDs to disk, so the app legitimately writes
  and resolves bare UUIDs; `ContactID` is NOT `Codable` for persistence (it carries
  the transient `localID`). This is the prerequisite that lets 6d DELETE
  `ContactDetailView.resolvedLocalID` / `boundaryLocalID`: once `contact(id:)`
  survives a reconcile re-key, the view keys purely on its captured `ContactID`.
  Full detail in the "Stage 6b2" section below. No public signature change, no app
  change yet. **6c and 6d's detail-view `resolvedLocalID` removal depend on 6b2.**
- **6c — `prepareContactForDetail` (decision A).** Self-contained package
  addition; depends on 6a. (The prior draft's debug `lastReconcileOutcome` vend is
  DROPPED — see Debug section.) Pairs with 6b2: `prepareContactForDetail` runs the
  on-open reconcile and 6b2's cache poke keeps the view's captured `ContactID`
  resolving afterward, so the view re-loads off the same `id` rather than a
  threaded `localID`.
- **6d — Migrate the app consumers, one at a time** (Stage-4-style sweep), each
  repointing a store/view at the repository API and deleting the matching
  `SyncService` contact-sidecar method: `NotesStore` → `ContactLinksStore` →
  contact-favorite path → `ContactDetailView` → `ConnectionsSection` /
  `EventDetailView` (drop their `reconcileIfNeeded`). Depends on 6b (+6c for the
  detail view). CAVEAT — less parallelizable than Stage 4: `NotesStore`/
  `ContactLinksStore` take `init(service:contactUUID:String)`, and BOTH are built
  by `ContactDetailView.reload()`, so changing either constructor drags the detail
  view; `ConnectionsSection`'s `onSave` callback signature must change to carry a
  `ContactID`. `ContactDetailView` is the shared serialization point — treat each
  store + the detail view as ONE migration unit. Realistically 6d is mostly serial
  (the detail view touches everything); only the leaf views (Connections, Event)
  parallelize once the detail view lands. ALSO in 6d (needs 6b2 first): DELETE
  `ContactDetailView.resolvedLocalID` / `boundaryLocalID` and the localID-threaded
  `loadContact` path — the view keys boundary reads on its captured `ContactID`
  via the now-reconcile-stable `contact(id:)`. (The contact-LIFECYCLE boundary
  calls that genuinely need a `CNContact.identifier` — `fetchContactForEditing` /
  `deleteContact` / `fetch` — read it from the loaded `Contact` at the call site;
  they do not need a retained `resolvedLocalID` token.)
- **6e — Tighten + audit.** Final identity audit with the corrected acceptance
  grep (below), confirm `SyncService` holds no contact-identity translation,
  remove any now-dead wrappers.

**Goal.** Finish the identity collapse: the app speaks ONLY `Contact` and
`ContactID`. Every contact-sidecar operation the app calls takes a `ContactID`,
never a bare UUID `String`. Reconciliation becomes a package-INTERNAL side effect
of writing a sidecar — the app never triggers, sees, or names it. After Stage 6
the words `guessWhoID`, `localID`, `SidecarKey`, and `reconcile` do not appear in
the app target outside the debug carve-out.

**Why now.** The bare-UUID `forContactUUID: String` boundary and the
`Contact → UUID` translation helper `reconcileIfNeeded` live in `SyncService` —
APP code (`App/GuessWho/Support/SyncService.swift`), a thin
`SidecarKey`-wrap-and-forward facade over the package `sync` engine. (Stage 5
already made `SyncService.guessWhoUUID(in:)` `private` and added the package twin
`ContactsRepository.guessWhoID(in:)`; Stage 6 removes the REMAINING app-side
translation.) Keeping identity translation app-side is the last violation of the
"app keys on `ContactID` only" contract. The hard part — the four-case algorithm
`sync.reconcileContactIdentity(localID:)` — is ALREADY in the package; Stage 6
relocates the TRIGGER and the bare-string boundary, not the algorithm.

#### Scope: CONTACTS ONLY (events explicitly out)

The event sidecar surface (`eventNotes`/`addEventNote`/`eventTags`/event links/
event lifecycle in `SyncService`) is structurally identical but is NOT in scope —
moving `EventsRepository` into the package is a separately-tracked migration
(Non-goals). Stage 6 touches the event surface ONLY where a contact-side call
crosses into it: the contact↔event link path (`addContactEventLink`,
`eventLinks(forContactUUID:)`, `refreshLinkedEvents(forContactUUID:)`) takes a
`ContactID` for its CONTACT endpoint while the event endpoint stays a UUID until
the event migration. Do not let "dissolve `SyncService`" pull events in.

#### The full contact-sidecar call surface to re-key (enumerated)

App stores / views that bind to the contact-sidecar methods today:

- **`NotesStore`** (`:25,32,42,51`) — `notes/addNote/editNote/deleteNote(forContactUUID:)`.
- **`ContactLinksStore`** (`:31,39,49,58`) — `contactLinks(forContactUUID:)`,
  `addContactLink(fromUUID:toUUID:)`, `setContactLinkNote`, `removeContactLink`.
- **`FavoritesStore`** (`:40,46,56`) — `favorites()`, `toggleFavorite(kind:id:)`,
  `setFavoritesOrder`. The CONTACT favorite's `id: String` is a bare GuessWho
  UUID, so the contact-favorite path is in scope (event favorites stay event-UUID
  keyed; the `FavoriteKind` discriminator selects which).
- **`ContactDetailView`** (`:717,1023,1047,1051,1057,1063,1079,1085,1139,1140,
  1212,1324,1325`) — the opened contact's own notes/links/event-links/favorite
  binding, the debug `sidecar(for:)` readout (REMOVED, not re-keyed — see Debug
  section), and `performReconcile()`.
- **`ConnectionsSection`** (`:279`) — `reconcileIfNeeded(contact:)` before linking.
- **`EventDetailView`** (`:500,506`) — `reconcileIfNeeded(contact:)` +
  `addContactEventLink` (contact endpoint only; see scope note).

ALSO in scope (the reviewer found these missing from the first draft — they're
app-side `SidecarKey`/endpoint handling the acceptance grep will flag): the
`SidecarKey`-constructing / endpoint-resolving sites — `ContactDetailView`'s
`otherEndpoint`/`otherContact` (which build a `SidecarKey` and resolve the far
endpoint) and the `LinkDirection`-style endpoint enum in `ConnectionsSection`;
and the bare-GuessWho-UUID resolution via `repository.contact(guessWhoID:)` in
`EventDetailView`, `FavoritesListViewController`, and `ContactDetailView`. These
move behind the repository link API (which should vend the resolved far-endpoint
`Contact`/`ContactID` and the direction, so the app never touches a `SidecarKey`).
NOTE: all the line numbers in this enumeration were captured pre-Stage-5 and have
drifted — re-grep for the METHODS at implementation time, don't trust the refs.

#### Design

**No app-facing "sidecar" type or vocabulary.** Per `CLAUDE.md`, the sidecar is
an implementation detail the app never names. There is NO public `ContactSidecar`
type the app imports. The app works with `Contact` + `ContactID` + plain-verb
methods on the one object it already uses — `ContactsRepository` — and whether a
note/link/favorite is persisted in `CNContactStore` or a sidecar file is entirely
the package's business. Method names stay plain (`notes(for:)`, not
`sidecarNotes(for:)`). If a `package`/`internal` helper type owns the
sidecar+engine plumbing, it is named in implementation terms and the app never
sees it.

0. **PREREQUISITE — give `ContactsRepository` the engine.** Today
   `ContactsRepository` holds ONLY `contactsStore: ContactStoreProtocol`
   (`ContactsRepository.swift:21`); its `init(contacts:)` (`:55`) gets just the
   adapter, and `makeContactsRepository()` (`SyncService.swift:457`) passes only
   that. The `GuessWhoSync` engine lives PRIVATELY in `SyncService` (`:33`). So the
   repository currently CANNOT reconcile or write a sidecar — the engine isn't
   wired to it. Step 0 changes `ContactsRepository.init` to also take the
   `GuessWhoSync` engine and updates `makeContactsRepository()` to pass it. This is
   real architecture (a new dependency on the repository), not a relocation — it
   must land before any reconcile-on-write / sidecar method can exist on the
   repository. Package-only; no app behavior change yet.
   ALSO WIRE FAVORITES: the contact-favorite path needs the `FavoritesStore`, which
   is STANDALONE (`FavoritesStore(root: URL)`, not on the engine) and held
   SEPARATELY by `SyncService`. So Step 0 injects BOTH the engine AND the
   favorites store into `ContactsRepository` (else `repository.toggleFavorite(_:)`/
   `isFavorite(_:)` in step 6 have nothing to call). Both are `Optional` and nil in
   `.unavailable`.
   THE DEPENDENCIES ARE OPTIONAL: `SyncService.sync` is `GuessWhoSync?` and
   `favoritesStore` is `FavoritesStore?` — nil in the `.unavailable` storage state
   (no writable sidecar root). So the repository takes `GuessWhoSync?` +
   `FavoritesStore?`, and EVERY new method must degrade when nil: READS return
   empty/false; WRITES (notes/links/favorite-toggle) THROW the existing
   `SidecarUnavailableError` (match `SyncService:722`'s behavior — do NOT silently
   no-op a write, the caller expects a thrown error); `prepareContactForDetail`
   does nothing. Mirror how `SyncService` already guards on `guard let sync`.

1. **Repository vends a `ContactID`-keyed contact API (plain verbs, no "sidecar"
   in the name).** On `ContactsRepository`, add the contact operations keyed on
   `ContactID`: `notes(for:)`, `addNote(for:body:)`, `editNote`, `deleteNote`,
   `links(for:)`, `addLink(from:to:note:)` (both endpoints `ContactID`),
   `setLinkNote`, `removeLink`, `eventLinks(for:)`,
   `addEventLink(contactID:eventUUID:note:)`, `isFavorite(_:)`,
   `toggleFavorite(_:)` — for the CONTACT favorite path only (see the favorites
   scope note below). Internally each maps `ContactID → SidecarKey` and calls the
   engine; the app never constructs a `SidecarKey` or sees the word.

2. **Reconcile-on-WRITE, internal (the core change).** Every WRITE entry point
   resolves-or-mints the GuessWho UUID internally:
   ```
   guessWhoID = id.guessWhoID ?? (reconcile(id.localID) → minted UUID)  // mint IFF writing
   write sidecar at SidecarKey(.contact, guessWhoID)
   update the repository cache   // package pokes its own cache (see decision B)
   ```
   `reconcileContactIdentity` and the resolve-or-mint helper become `internal`
   (NOT `package`). `internal` and `package` both hide from the app target —
   `internal` is the tighter bound that matches "reconcile is an invisible side
   effect of a write." KEEP the existing DIRECT-call reconcile unit tests
   (`SingleContactReconcilerTests` etc., incl. Case-D collapse) — they stay valid
   under `@testable import` after the visibility flip and are the ONLY place the
   four-case algorithm is covered in isolation. ADD new tests that prove the
   trigger fires through the public write API; do NOT replace the direct tests
   with write-routed ones (that would lose Case-D coverage).

   CONCURRENCY (decision: ACCEPT double-mint as a practical non-event — do NOT try
   to lock across the await). Two truly-concurrent writes to the SAME unreconciled
   `ContactID` could each mint a UUID before the other's write lands, because
   resolve-or-mint must `await contacts.fetch` before minting and the orchestrator's
   per-key locks (`PerKeyLockTable.withLock`, `withCaseDLocks`) are SYNCHRONOUS
   `NSLock`s — you CANNOT hold one across that `await`. Why accept it: a double-mint
   needs a NEVER-reconciled contact AND two genuinely-simultaneous writes from
   different surfaces — effectively only Catalyst multi-window; the detail-open
   reconcile is latched (`didAutoReconcile`) and the link reconcile short-circuits
   once a URL exists, so there is no deterministic codepath that produces it.
   ⚠️ ACCURATE OUTCOME (do NOT claim "Case-D self-heals it" unconditionally — that
   is FALSE single-device): `CNContactStoreAdapter.apply()` replaces a contact's
   `urlAddresses` WHOLESALE (`CNContactStoreAdapter.swift:593`), so on ONE device
   the second write CLOBBERS the first's URL (last-write-wins) → one minted UUID
   wins, the other's sidecar is ORPHANED (not two co-resident URLs). Case-D only
   heals the MULTI-DEVICE case, where iCloud merges BOTH URLs onto the card so the
   contact genuinely carries two GuessWho UUIDs for Case-D to collapse. The
   orphan-recovery sweep `reconcileContactIdentities()` currently has NO app caller
   (no launch/foreground sweep), so a single-device orphan is not auto-cleaned —
   but it is harmless (a stray unreferenced sidecar file) and the race is a
   practical non-event. The plan makes NO "no double-mint" guarantee. (A future
   phase may add async serialization, or wire a periodic orphan sweep, if it ever
   proves measurable; not now.)

3. **Reads do NOT reconcile; writes DO.** READS — `notes(for:)` / `links(for:)` /
   `isFavorite(_:)` — return empty/false when `id.guessWhoID` is nil (an
   unreconciled contact has no sidecar yet, nothing to read). WRITES —
   `addNote`/`addLink`/`toggleFavorite(_:)` — resolve-or-mint (step 2). This keeps
   reconcile firing ONLY on write and satisfies the "no silent write-sweep on read"
   Non-goal for free.

   WRITING TO AN UNRECONCILED CONTACT IS ALLOWED (Adam — intended behavior CHANGE,
   not silent). Today THREE detail-view actions are gated `.disabled(contactUUID
   == nil)` so you can't act on a never-touched contact: the FAVORITE button, "Link
   Contact" (`AddLinkSheet`), and "Link Event" (`EventLinkSheet`). All three are
   WRITES, so reconcile-on-write mints for them. REMOVE all three gates:
   `toggleFavorite(_:)` / `addLink(from:to:)` / `addEventLink(contactID:)` each
   reconcile (mint the UUID) THEN write, transparent to the caller. Re-key the
   `AddLinkSheet`/`EventLinkSheet` construction (which currently takes the contact
   UUID string) to take a `ContactID`. Call this out as a deliberate UX improvement
   in the 6d commit.

4. **Detail-open reconcile stays — moved behind a package call (decision A).**
   `ContactDetailView.performReconcile()` exists so OPENING a never-touched
   contact stamps its URL and repairs malformed/duplicate URLs (Cases B/C/D) even
   with no write. This is a legitimate REPAIR trigger that should not wait for a
   write. Replace `performReconcile()` + `service.reconcile(localID:)` with ONE
   opaque package call — `repository.prepareContactForDetail(_: ContactID) async`
   — that runs the same reconcile internally and refreshes the repository cache.
   The app calls it blindly on load; it never sees `localID`, a report, or the word
   reconcile. This preserves today's open-without-writing repair behavior; if
   instead you want "ONLY writes reconcile," dropping this call is the alternative —
   decision A picks KEEP.
   SEQUENCING: today `performReconcile()` does reconcile → `refreshContact` →
   `loadContact`. `prepareContactForDetail` covers the first two (reconcile +
   cache refresh); the view STILL runs its own `loadContact()` afterward to pull
   the now-canonical record into its `@State`. Make the call `await`-then-reload so
   the view doesn't render a pre-reconcile snapshot. A reconcile that changes the
   effective identity means the view's nav `ContactID` (`id`) may no longer resolve
   — re-derive from the loaded contact (as Stage 4/5 already do via
   `resolvedLocalID`), or show the non-crashing unavailable state.

5. **Package owns the post-write cache update (decision B), for SIDECAR writes.**
   Today the sidecar write paths deliberately do NOT poke the repository
   (the sidecar methods at `SyncService.swift:576+` carry no repository poke; the
   `:551-563` comment is about the separate `saveContact` path decision B
   EXCLUDES), so every app caller runs its own
   `reconcile → loadContact → repository.reload` dance. Stage 6 REVERSES that for
   the new `ContactID`-keyed SIDECAR methods + `prepareContactForDetail`: after
   Step 0 wires the engine in (the coupling that comment deferred), they update
   `ContactsRepository` after writing, so the app does no post-write reload
   choreography. SCOPE: this covers SIDECAR writes (notes/links/favorite/reconcile)
   ONLY — the `saveContact` CONTACT-RECORD path is out of scope (it stays on
   `SyncService` and keeps its existing `refreshContact`/`loadContact` flow); do
   not claim it loses its dance.
   RE-ENTRANCY (state this — it's why decision B is race-safe): reconcile's own
   `CNContact` write is tagged with our `transactionAuthor` and the change-watcher
   self-excludes those (`CNContactStoreAdapter.swift:42,235`), so the write
   produces an EMPTY delta that is NOT posted — the watcher does NOT double-rebuild
   the cache against the package's own poke. Call decision B out in the commit.

6. **Delete the CONTACT-sidecar surface from `SyncService` (favorites stay).**
   Remove the `forContactUUID:` notes/links/event-link methods and
   `reconcileIfNeeded`/`reconcile`/`sidecar(for:)` from `SyncService`; repoint
   `NotesStore`/`ContactLinksStore`/`ContactDetailView`/`ConnectionsSection`/
   `EventDetailView` at the repository API. `ConnectionsSection` and
   `EventDetailView` drop their `reconcileIfNeeded` calls entirely — the link WRITE
   now reconciles internally, so the app just calls `addLink(from:to:)` /
   `addEventLink(contactID:)` with `ContactID`s.
   FAVORITES STAY ON `SyncService`: `favorites()`/`toggleFavorite(kind:id:)`/
   `setFavoritesOrder` are SHARED contact+event (the `FavoriteKind` discriminator
   selects which), so they cannot move to a contacts-only repository API. The
   repository's `isFavorite(_:)`/`toggleFavorite(_:)` cover the CONTACT path by
   translating `ContactID → guessWhoID` and calling through; the shared
   `FavoritesStore` surface remains on `SyncService` for the event path until the
   event migration. Do not delete the shared favorites methods.

#### Stage 6b2 — one `Contact` cache + guessWhoID→localID pointer; reconcile-stable `contact(id:)`

**Problem.** `ContactsRepository` indexes contacts in `contactsByEffectiveID`
(`ContactsRepository.swift:57`), keyed on `ContactID(contact:).effectiveID`
(`guessWhoID ?? localID`). That is a MIXED-KEY index: an unreconciled contact is
stored under its `localID`, a reconciled one under its `guessWhoID`, in one
`[String: Contact]`. Two consequences:

1. **A captured `ContactID` stops resolving across a reconcile re-key.**
   `ContactDetailView` holds a `let id: ContactID` captured at navigation. When an
   on-open reconcile (Case A) mints the contact's `guessWhoID`, the next
   `setContacts` rebuild re-keys the contact from `contactsByEffectiveID["<localID>"]`
   to `contactsByEffectiveID["<guessWhoID>"]`. The captured `id` is immutable —
   its `effectiveID` is still the old `localID` — so `contact(id: id)` now MISSES.
   This is the ONLY reason `ContactDetailView` retains `resolvedLocalID` /
   `boundaryLocalID` (`:33`, `:1123`): `localID` is the one identifier that does
   NOT move across the flip, so the view threads it to re-find its record. That
   token is a blessed Stage-5 boundary token, but it exists solely to paper over
   the mixed-key index — the information needed (the `localID`) is ALREADY inside
   the captured `ContactID` (`ContactID.localID`, always present even once
   `guessWhoID` populates), the repository just doesn't consult it.
2. **`contact(guessWhoID:)` (`:176`) abuses the same index** — it looks a bare
   UUID up in `contactsByEffectiveID` then needs a confirm-guard
   (`ContactID(contact: candidate).guessWhoID == needle`, `:179`) precisely
   because a query string could coincide with some unreconciled contact's
   `localID` slot. A pure guessWhoID keyspace removes the need for that guard.

**Fix — ONE `Contact` cache + a lightweight guessWhoID→localID pointer index.**

Do NOT keep two `Contact` dictionaries. `Contact` is a value type; storing each
struct in both a localID map and a guessWhoID map duplicates the value and lets
the two copies drift (an edit applied to one but not the other). Instead keep the
SINGLE source-of-truth `Contact` cache and add a string→string POINTER index:

```swift
private var contactsByLocalID:   [String: Contact]   // THE cache — one copy of each Contact struct
private var guessWhoIDToLocalID: [String: String]    // index: guessWhoID → localID (RECONCILED contacts only)
// DELETE contactsByEffectiveID — nothing needs a fused-key dictionary, and no
// second copy of the Contact structs is kept anywhere.
```

- `contactsByLocalID` already exists (`:61`) and stays as-is (every contact, one
  copy of each struct — the sole `Contact` store).
- `guessWhoIDToLocalID` is new and holds ONLY `String` localIDs, never a `Contact`.
  An entry is added in the `setContacts` funnel ONLY for contacts where
  `ContactID(contact:).guessWhoID != nil`. Because it points INTO the one cache,
  the contact data cannot diverge — a guessWhoID lookup chases the pointer into
  `contactsByLocalID`, so there is exactly one `Contact` value per contact.
- `effectiveID` STAYS on `ContactID` (`ContactID.swift:74`) as the diffable
  IDENTITY — that single fused value is correct for `Hashable`/diffing. The bug is
  using it as a STORAGE key. Identity-for-diffing wants one fused value;
  storage-for-lookup wants two clean namespaces. Do not remove `effectiveID` from
  `ContactID`; only remove the fused index from the repository.

`contact(id:)` resolves guessWhoID first (canonical identity wins; a stale localID
can never override a real UUID match) via the pointer, else by localID directly
(always present, stable across the reconcile re-key):

```swift
public func contact(id: ContactID) -> Contact? {
    if let gw = id.guessWhoID, let lid = guessWhoIDToLocalID[gw] {
        return contactsByLocalID[lid]
    }
    return contactsByLocalID[id.localID]
}
```

The localID branch is LOAD-BEARING, not a mere fallback: it is exactly the
captured-pre-reconcile-token case (the view's `id.guessWhoID` is still nil after
the contact reconciled, so resolution MUST go by `id.localID`). Comment it as
such so a future reader doesn't "simplify" it away. Add the symmetric subtlety
the old `:120-124` doc raised — a Case-D loser `localID` could in principle still
resolve to a merged-away duplicate — but note guessWhoID-first ordering makes it
moot for any RECONCILED token (it hits the pointer index and never reaches the
localID branch); the localID branch is only reached when there is no `guessWhoID`,
where `localID` legitimately IS the only identity.

`contact(guessWhoID:)` STAYS PUBLIC and becomes a clean pointer hop, NO
confirm-guard — see "Why `contact(guessWhoID:)` survives" below:

```swift
public func contact(guessWhoID: String) -> Contact? {
    guard let lid = guessWhoIDToLocalID[guessWhoID.lowercased()] else { return nil }
    return contactsByLocalID[lid]
}
```

(The `:179` confirm-guard existed only to reject a localID-coincidence in the
mixed index; `guessWhoIDToLocalID` is keyed ONLY on real guessWhoIDs, so it cannot
return a localID-coincidence — the index IS the guarantee.)

**Why `contact(guessWhoID:)` survives (and `ContactID` is NOT `Codable` for
persistence).** Favorites and links SYNC BETWEEN DEVICES, so their durable records
must be keyed on the stable GuessWho UUID, NOT a `ContactID`. `ContactID` carries
the transient `localID` (`CNContact.identifier`), which Apple re-mints across
unification / new-device / re-added-account — persisting a `ContactID` would write
that transient string to disk and dangle the favorite/link after the next
re-unification (this is a durability invariant, NOT a one-time migration — being
the sole user does not exempt it; Apple still re-mints the identifier). Therefore
the favorites/links durable endpoint stays the guessWhoID (`Favorite.id` /
`SidecarKey`), the APP legitimately writes and resolves bare guessWhoID strings
for that path, and `contact(guessWhoID:)` remains a PUBLIC app-facing resolver.
This REVISES the Stage 6 acceptance clause that flagged app-side
`contact(guessWhoID:)` as a defect: FAVORITE resolution was always blessed and
stays; LINK-ENDPOINT resolution should still move behind a `links(for:)` that
vends the resolved far-endpoint `Contact`/`ContactID` + direction (the cleaner
end-state — so the app doesn't construct a `SidecarKey`), but a surviving
`contact(guessWhoID:)` link use is no longer a hard defect. (OPEN — links: keep on
`contact(guessWhoID:)` vs. move behind a resolved `links(for:)`. Plan keeps the
resolved-`links(for:)` target; revisit during 6d if it adds friction.)

**Update BOTH maps on reconcile-on-write (the cache-update-on-reconcile point).**
`resolveOrMintGuessWhoID` (`:221`) mints a UUID but does NOT currently refresh the
cache — so immediately after a Case-A write-reconcile, `contactsByLocalID` still
holds the PRE-reconcile contact (`guessWhoID` nil) and `guessWhoIDToLocalID` has
NO entry for it. A subsequent `contact(guessWhoID:)` / `contact(id:)` guessWhoID
hop would then miss until the next full `setContacts`. Decision B already says the
package owns the post-write cache update; 6b2 makes that concrete for the identity
flip: after a mint, re-fetch the now-canonical record
(`contactsStore.fetch(localID:)`), write it into `contactsByLocalID[localID]`
(replacing the stale struct — one copy, no drift), and add
`guessWhoIDToLocalID[minted] = localID`. One struct write + one pointer add, both
through the single `setContacts`/rebuild funnel where practical (a one-contact
in-place update is also fine as long as it touches both maps). Re-entrancy is safe
for the same reason decision B is: reconcile's own `CNContact` write is tagged with
our `transactionAuthor` and the change-watcher self-excludes it, so the package's
own poke is not double-applied by an inbound delta.

**Tests (add to the Stage 6 set):**
- `contact(id:)` round-trips a contact BEFORE and AFTER a reconcile re-key using
  the SAME captured `ContactID` (guessWhoID still nil on the token) — the localID
  branch keeps it resolving. This is the test that pins the `resolvedLocalID`
  removal.
- `contact(id:)` on a reconciled token resolves via the guessWhoID branch even if
  a different contact occupies the token's `localID` slot (guessWhoID-first
  ordering; no wrong-contact fallback).
- `contact(guessWhoID:)` returns nil for a string that is only some contact's
  `localID` (pure-namespace correctness; the dropped confirm-guard's invariant
  still holds).
- After a reconcile-on-WRITE mints a UUID, `contact(guessWhoID: minted)` and
  `contact(id: capturedPreReconcileID)` BOTH resolve to the canonical record
  WITHOUT an intervening full `reload()` (the post-mint cache poke updated
  `contactsByLocalID` AND added the `guessWhoIDToLocalID` pointer).
- Single-source-of-truth: after an edit applied through the funnel, the contact
  fetched via `contact(id:)` (guessWhoID branch), `contact(guessWhoID:)`, and
  `contact(localID:)` are the SAME value — there is one `Contact` struct, the
  guessWhoID path only chases a pointer into the localID cache, so no stale copy.
- Parity: the index results equal the old `effectiveID`-index results for a
  fully-reconciled book (no behavior change for the steady state).

**Acceptance (6b2):** `contactsByEffectiveID` is gone; the repository holds
exactly ONE `Contact` cache (`contactsByLocalID`) plus the `guessWhoIDToLocalID`
POINTER index (+ `contactsByEmail`) — no second copy of any `Contact` struct;
`contact(id:)` resolves a captured `ContactID` across a reconcile re-key with no
`localID` threaded by the caller; `contact(guessWhoID:)` stays PUBLIC (favorites/
links resolve bare guessWhoIDs read off disk) and has no confirm-guard; a
reconcile-on-write updates the cache struct AND adds the pointer. No public
signature changes; the diffable list layer is untouched (`ContactID.effectiveID`
still drives snapshot identity). This UNBLOCKS the 6d deletion of
`ContactDetailView.resolvedLocalID` / `boundaryLocalID`.

#### What remains of `SyncService` (it shrinks, it does not vanish)

`SyncService` survives after Stage 6 holding only what has no package home YET:
the `@Observable` permission state the SwiftUI gate binds to
(`contactsAuthorization`/`eventsAuthorization`/`lastError`, the
`requestAccessIfNeeded` calls); the entire EVENT surface (event notes/tags/links/
lifecycle, the EventKit-inclusion gate `includeEventKit`); contact LIFECYCLE
(`fetchAll`/`fetch`/`saveContact`/`deleteContact`/`makeContactsRepository`/the
change-watcher); and bootstrap/config (sidecar location, iCloud-vs-local fallback,
device id, cursor URL). Fully dissolving `SyncService` additionally requires the
deferred `EventsRepository` migration and a home for the observable permission
state — NOT this stage. Stage 6's claim is narrower and exact: `SyncService` no
longer performs ANY contact-identity translation.

#### Debug section

DECISION (Adam): DROP the debug-only reconcile/sidecar readout in Stage 6. Today
the contact-detail Debug section shows the `IdentityReconcileReport.ContactOutcome`
of the reconcile the VIEW kicked off, plus the raw sidecar envelope (`sidecar(for:)`).
Once reconcile is a package-internal side effect the app no longer drives, that
report has no app-side source — and rather than retain new per-contact package
state (`lastReconcileOutcome`) just to feed a debug row, we simply remove those
debug rows. The cheap, stateless debug bits that don't depend on an app-driven
reconcile (e.g. the `localID` display) MAY stay as-is under the `CLAUDE.md` debug
carve-out; no new retained package state is added. This deletes the
`lastReconcileOutcome` API the prior draft proposed and its lifecycle question.

#### Tests

- Package: writing a note/link/favorite to an UNRECONCILED `ContactID` mints the
  URL and creates the sidecar (reconcile fired via the write, not a direct call);
  the same write on an already-reconciled `ContactID` does NOT re-stamp.
- Reading from an unreconciled `ContactID` returns empty and mints NOTHING.
- `prepareContactForDetail` on an unreconciled contact stamps its URL (Case A) and
  repairs malformed/duplicate URLs (Cases B/C/D); the repository cache reflects the
  new identity afterward (re-key found under the new effective id).
- A contact-link write across two `ContactID`s reconciles BOTH endpoints and the
  durable `Link` is keyed on their GuessWho UUIDs.

Acceptance (the grep must EXCLUDE the sanctioned Stage-4/5 accessors and blessed
boundary tokens, or it can't pass — those are the agreed identity surface, not
violations):
- zero `forContactUUID` in the app target;
- zero app-side `SidecarKey(.contact …)` CONSTRUCTION and zero app-side
  CONTACT-side `SidecarKey`-typed values / `LinkDirection`-style endpoint enums.
  EXCLUDED from the count (allowed): `SidecarKey.parseGuessWhoContactURL` (not
  construction); and `SidecarKey(.event …)` construction on the OUT-OF-SCOPE
  event surface (e.g. in `EventDetailView`) — the event identity boundary is
  DEFERRED TO PHASE 7 (see below), so event-side `SidecarKey` survives Stage 6 by
  design;
- zero `reconcile` in app contact CODE outside the debug carve-out. EXCLUDED:
  the word `reconcile` appearing in CODE COMMENTS (e.g. `ContactsListViewController`/
  `OrganizationsListViewController`/`ContactEditView` comments that merely mention
  reconciliation) — grep for `reconcile` as an IDENTIFIER/call, not in comments;
- `guessWhoID`/`localID` appear ONLY as the enumerated allowed set; grep that
  nothing else matches:
  - `guessWhoID(in:)` (the opened contact's own UUID, Stage 5);
  - `contact(guessWhoID:)` ONLY at the surviving FAVORITE-resolution sites
    (`FavoritesListViewController` cell-provider + selection). The
    LINK-ENDPOINT-resolution uses of `contact(guessWhoID:)` (`ContactDetailView`'s
    `otherContact`, `ConnectionsSection`, `EventDetailView`'s linked-contact tap)
    MUST move behind the repository link API and are DEFECTS if they survive — do
    NOT bless all `contact(guessWhoID:)` calls or the grep hides that regression;
  - the blessed boundary tokens (`boundaryLocalID`/`resolvedLocalID`,
    `model.edited.localID`/`saveLocalID`, the `lookupLocalID` load token) threaded
    into package/SyncService calls;
  - the `SyncService` contact-LIFECYCLE `localID:` params that survive by design
    (`fetch`/`fetchContactForEditing`/`deleteContact`/`reconcileIfNeeded`-removal aside);
  - the empty new-contact seed (`localID: ""`);
  - the debug-section display (incl. `SidecarKey.guessWhoContactURLPrefix` used to
    render the debug uuid row);
- `reconcileContactIdentity` is `internal` to the package, with its EXISTING
  direct-call tests kept AND new write-routed trigger tests added;
- the list VCs' `effectiveID` snapshot DE-DUPE guard
  (`ContactsListViewController`/`OrganizationsListViewController`, before
  `appendItems`) is PRESERVED — it is load-bearing: a Stage-6 reconcile can
  momentarily put two contacts under the same `effectiveID`, and that guard is the
  only thing keeping `appendItems` from trapping (the one crash risk). A Stage-6
  snapshot re-key must not remove it;
- `SyncService` contains no contact-sidecar or contact-identity-translation
  method (favorites' shared `FavoriteKind` surface may remain — see step 6);
- opening a never-written contact still stamps/repairs its identity; writing a
  note/link/contact-favorite to a fresh contact works end-to-end with no app-side
  reconcile or reload dance.

### Stage 7 — `EventID` + event-identity boundary (DEFERRED, the events analogue)

Stage 6 deliberately leaves the EVENT identity boundary half-migrated: the app
still constructs `SidecarKey(.event …)`, the contact↔event link keeps a bare
event-UUID endpoint, and event sidecar ops (`eventNotes`/`eventTags`/event links/
event lifecycle) stay on `SyncService` keyed on UUID strings. The Stage 6
acceptance grep ALLOWS the event-side `SidecarKey`/UUID surface for exactly this
reason. Stage 7 does for events what Stages 1–6 did for contacts: vend an opaque
`EventID`, move `EventsRepository` into the package, internalize event reconcile/
adoption, and re-key the event sidecar API on `EventID` so the app speaks only
`Event` + `EventID`. This is the separately-tracked `EventsRepository`-into-package
migration (Non-goals) given a stage number; it is NOT part of Stage 6. Scope and
design TBD when Stage 6 lands.

## Verification

1. `swift test` (rerun with `--disable-sandbox` only if the harness blocks the
   sandbox, and record that reason).
2. `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination
   'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/DerivedData
   build`.
3. iPhone simulator build (`platform=iOS Simulator`) so the tab-bar/gate path is
   covered.
4. Static `localID` audit per Stage 5 acceptance, plus the Stage 6 audit:
   `grep` the app target for `forContactUUID`, app-side `SidecarKey(` construction,
   `reconcile`, and `guessWhoID` — every hit must fall in the ALLOWED set
   enumerated in the Acceptance above (sanctioned accessors, blessed boundary
   tokens, empty seed, debug carve-out); anything outside that set is a defect.
5. Review cycle: identity correctness (one canonical UUID per row, Case-D
   collapse re-keys cleanly), diffable change-detection (edit repaints without
   flicker, no delete+insert), concurrency/actor isolation, permission-flow
   regression, and (Stage 6) reconcile-on-write correctness: a write to a fresh
   contact mints exactly once, a read mints nothing, and the post-write cache
   poke leaves no stale row. Resolve all findings before declaring done.

## Open questions for review

- **DECIDED — display fields:** raw components on `ContactID` (not a single
  `secondaryText`). See "Display fields" above.
- **Retired-UUID resolution (still open, Stage 4).** Whether
  `repository.contact(id:)` should actively resolve a known-retired Case-D loser
  UUID to its canonical record, or simply return nil (→ "unavailable"). Shipped
  Stage 1 returns nil for an unknown id; active resolution from the durable
  on-disk link-rewrite record is a clean follow-up if desired.
- **`Contact.localID` visibility (still open, Stage 5).** `ContactID.localID` is
  the carrier the UI uses, but `Contact.localID` is still `public` and read by
  package fetch paths. Stage 5 decides whether it can be made non-public once no
  app caller reads it.
- **DECIDED — reconcile is package-internal, fired on sidecar WRITE (Stage 6).**
  The app never triggers, sees, or names reconcile. Write entry points
  resolve-or-mint the GuessWho UUID internally; reads do not reconcile.
  `reconcileContactIdentity` becomes `internal` and is tested through the public
  write API. See Stage 6.
- **DECIDED — keep a detail-open reconcile trigger, behind a package call
  (Stage 6, decision A).** `prepareContactForDetail(_: ContactID)` preserves
  today's open-without-writing URL stamp + Case-B/C/D repair, but the app calls it
  blindly and never sees `localID`/the report. Alternative ("only writes
  reconcile") was rejected so first-open repairs don't wait for a write.
- **DECIDED — package owns the post-write cache update (Stage 6, decision B).**
  Reverses the "sidecar writes don't poke the repository" decoupling (the sidecar
  methods at `SyncService.swift:576+`); the package's write methods update
  `ContactsRepository` so the app does no post-write reload dance. Internalizing reconcile is the reason to accept
  the coupling that comment deferred.
