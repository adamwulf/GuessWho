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
- **Stage 4 (navigation/detail/connections/favorites), Stage 5 (visibility
  tighten): NOT STARTED.**

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

### Stage 4 — Migrate navigation + detail + connections + favorites

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

## Verification

1. `swift test` (rerun with `--disable-sandbox` only if the harness blocks the
   sandbox, and record that reason).
2. `xcodebuild -project App/GuessWho.xcodeproj -scheme GuessWho -destination
   'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build/DerivedData
   build`.
3. iPhone simulator build (`platform=iOS Simulator`) so the tab-bar/gate path is
   covered.
4. Static `localID` audit per Stage 5 acceptance.
5. Review cycle: identity correctness (one canonical UUID per row, Case-D
   collapse re-keys cleanly), diffable change-detection (edit repaints without
   flicker, no delete+insert), concurrency/actor isolation, permission-flow
   regression. Resolve all findings before declaring done.

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
