# Plan: package-vended `Contact` + opaque `ContactID`

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

```swift
/// Opaque, stable identity for a contact as the UI sees it.
///
/// Equality and hashing are defined ONLY on the GuessWho UUID, so the same
/// contact compares equal across reloads, across a Case-D canonical-ID
/// collapse (the package re-mints the value with the surviving UUID), and
/// regardless of any change to its display fields. The bare display fields
/// ride along so a diffable data source can detect a name/job/org/photo
/// change without the app keeping a parallel `[ID: Contact]` dictionary.
public struct ContactID: Hashable, Sendable {
    /// Canonical lowercase bare UUID string (NOT the `guesswho://` URL).
    /// The only identity the package or the UI ever compares.
    public let guessWhoID: String

    /// Apple's unified-contact identifier. INTERNAL to the package's fetch
    /// path — the UI must never read, compare, or persist it. `package`
    /// (or `internal` + same-module) visibility; not `public`.
    let localID: String

    // Bare display fields — present so `Hashable` can drive diffable
    // change-detection. They are NOT identity: see `==`/`hash` below.
    public let displayName: String
    public let secondaryText: String   // job title / org, per row policy
    public let imageDataAvailable: Bool

    public static func == (lhs: ContactID, rhs: ContactID) -> Bool {
        lhs.guessWhoID == rhs.guessWhoID
            && lhs.displayName == rhs.displayName
            && lhs.secondaryText == rhs.secondaryText
            && lhs.imageDataAvailable == rhs.imageDataAvailable
    }

    public func hash(into hasher: inout Hasher) {
        // Hash on identity ONLY. Two values for the same contact with
        // different display fields must land in the same bucket so a
        // diffable snapshot treats them as the same row (moved/reconfigured),
        // never as a delete + insert. `==` then catches the field delta and
        // the data source reconfigures in place.
        hasher.combine(guessWhoID)
    }
}
```

### Why this exact `Equatable`/`Hashable` split

A `UITableViewDiffableDataSource` decides "same row vs different row" by
`Hashable`, and "reconfigure in place vs leave alone" by `Equatable` on the item
identifier. Splitting them as above gives us, for free, the behavior the app
currently hand-rolls at `ContactsListViewController.swift:195-217`:

- **hash on identity only** → an edited contact keeps its row (no flicker, no
  scroll jump, no delete+insert animation).
- **`==` includes display fields** → an edited contact's row is reported as
  *changed*, so the data source reconfigures the cell. This deletes the manual
  `previousByID` snapshot diff + `reconfigureItems` pass and the entire
  `contactsByLocalID` side-dictionary.

The snapshot becomes `NSDiffableDataSourceSnapshot<Section, ContactID>` and the
cell provider reads display fields straight off the `ContactID` (or fetches the
full `Contact` by ID for richer cells — see Stage 3).

### What goes in `secondaryText`

Row rendering policy stays in the app, but the *fields* must come from the
package so the value is self-describing for diffing. Vend the raw components
(`displayName`, `jobTitle`, `organizationName`) on `ContactID` if a single
`secondaryText` is too lossy for both People and Organizations rows. Keep the
set minimal: only fields that appear in a list cell. Notes/tags/links never
belong on `ContactID` — they are not part of a row's visual identity and change
far more often.

## What the app stops doing

Direct consequences once `ContactID` lands and the app migrates to it:

- **No `contactsByLocalID` dictionaries.** `ContactsListViewController` and
  `OrganizationsListViewController` snapshot `ContactID` directly; the cell
  provider needs no side lookup for list rendering.
- **No manual `reconfigureItems` diff.** `Equatable` on `ContactID` drives it.
- **No `localID` in navigation.** `ContactReference` (`NavigationReferences.swift`)
  is re-keyed on `ContactID` (carry the whole value, or just `guessWhoID`).
- **No `localID` identity comparisons.** `ContactDetailView.swift:654` and
  `ConnectionsSection.swift:266` compare `guessWhoID`.
- **No app-built GuessWho-UUID maps.** The 3 duplicated
  `for c in repository.contacts { map[guessWhoUUID(in: c)] = c }` builders
  (`EventDetailView:482`, `FavoritesListViewController:213`,
  `ContactDetailView`) are replaced by `repository.contact(id:)`.
- **No `SyncService.guessWhoUUID(in:)` in the app.** Identity is already on the
  vended value.
- **No app-owned `CNContactStore`.** See the permission section below.

## Identity construction (where the UUID comes from)

`ContactID.guessWhoID` is always the canonical lowercase bare UUID produced by
the existing single validator/canonicalizer in `SidecarKey`
(`parseGuessWhoContactURL` / `forContact`) — never a parallel parser. The
package materializes a `ContactID` only for a contact that has exactly one
distinct valid GuessWho URL *after* reconciliation. A contact with zero or
multiple URLs is reconciled first (mint / Case-D collapse) so that by the time
the UI sees a `ContactID`, identity is settled and stable.

Because identity is settled before the value is vended, a Case-D collapse simply
causes the package to publish a new snapshot where the affected contact's
`ContactID` now carries the surviving UUID. The old row (old UUID) drops and the
new row (canonical UUID) appears — handled by the diffable apply, no alias map
required. A navigation reference or favorite holding the retired UUID resolves
through the repository, which can map a known-retired UUID to its canonical one
*from the sidecar link-rewrite record the reconciler already writes* — i.e. the
durable on-disk record, not an in-memory session map. (If that lookup is more
than a thin read, it is a follow-up, not a blocker: a stale reference resolving
to a non-crashing "unavailable" state is acceptable for v1.)

## Permission API (removes the app's `CNContactStore`)

`SyncService.swift:69` constructs a second `CNContactStore` solely to call
`requestAccess(for: .contacts)` on the main actor, and owns the `EKEventStore`
at `:79`. Move both behind the package:

- Add `requestContactsAccess() async -> CNAuthorizationStatus` (or a package
  enum that doesn't leak `CN*`) and `contactsAuthorizationStatus` to the
  Contacts adapter / a small package auth surface. The adapter already owns the
  one true `CNContactStore`; the request runs there.
- Do the same for events on the EventKit adapter
  (`requestEventsAccess()` / `eventsAuthorizationStatus`).
- `SyncService` keeps only the *app-level* authorization-state binding the UI
  observes (e.g. for `PermissionGateViewController`); it owns zero Apple store
  objects.

Authorization *status* may still be surfaced to the UI as a package-vended enum;
the goal is no `CNContactStore()` / `EKEventStore()` instantiation in the app
target, not hiding the concept of permission.

## Non-goals / explicitly out of scope

- No session-scoped loser→canonical alias map. (The deleted plan's mechanism.)
- No `bootstrapIdentityBaseline()` that makes `reload()` a write-sweep. Keep the
  existing reconcile triggers; do not silently turn every reload into a write.
- No parallel app-side or repository `ID↔localID` index dictionaries surviving
  the migration. The only `localID` carrier is the private field inside
  `ContactID`, consumed exclusively by package fetch methods.
- No change to how relationships vs links work, and no new
  pick-from-existing-contact UI. (Honors `CLAUDE.md`.)
- Not bundled here: moving `EventsRepository` into the package, the
  Organizations/Contacts list-VC de-duplication, and the `EventLinkSheet`
  "pick existing calendar event" product-principle question. Those are tracked
  separately; this plan is scoped to contact identity + permissions.

## Implementation stages

Each stage ends green (`swift test` + Catalyst build) before the next begins.

### Stage 1 — Vend `ContactID` from the package

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
3. `ContactID` is built only via `SidecarKey` from a fully-reconciled contact
   with exactly one valid URL.
4. Package tests: identity equality across display-field changes; hash stability
   across a field edit; `==` inequality on a name/job/org/photo change;
   `contact(id:)` round-trip; duplicate display-name returns all matches;
   `contactsReferencing` self-exclusion by `guessWhoID`.

Acceptance: package vends `ContactID`-addressed reads; `localID` is not public;
no query enumerates `CNContactStore` (cache reads only).

### Stage 2 — Package permission API

1. Add `requestContactsAccess()` / `contactsAuthorizationStatus` to the Contacts
   adapter (runs on its existing store) and event equivalents on the EventKit
   adapter.
2. `SyncService` calls the package API; delete its `CNContactStore()` (`:69`).
   `EKEventStore` is already constructed for the adapter — keep one instance,
   owned by the adapter, none owned by `SyncService` directly.
3. `PermissionGateViewController` observes the package-vended auth state.

Acceptance: grep shows zero `CNContactStore(` / `EKEventStore(` in the app
target; permission flow still works on iPhone (gate) and Catalyst.

### Stage 3 — Migrate list view controllers

1. `ContactsListViewController` and `OrganizationsListViewController` snapshot
   `NSDiffableDataSourceSnapshot<String, ContactID>`. Cell provider renders from
   `ContactID` display fields (or `repository.contact(id:)` for full cells).
2. Delete `contactsByLocalID`, the `previousByID` diff, and the manual
   `reconfigureItems` pass — `ContactID`'s `Equatable`/`Hashable` replaces them.
3. `didSelectRowAt` reads the `ContactID` item identifier directly.

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

- **`secondaryText` vs raw components on `ContactID`.** Single pre-rendered
  string is simplest for diffing but couples row policy to the package. Vending
  `displayName` + `jobTitle` + `organizationName` keeps policy in the app at the
  cost of a slightly wider value. Lean toward raw components.
- **Retired-UUID resolution.** Whether `repository.contact(id:)` should actively
  resolve a known-retired Case-D loser UUID to its canonical record, or simply
  return nil (→ "unavailable"). v1 can ship with nil; durable link-rewrite
  records already on disk make active resolution a clean follow-up if desired.
- **Does `Contact` keep `localID` at all?** Stage 5 can make it non-public, but
  the package still needs it on the fetch path. Confirm `ContactID.localID` is
  the single carrier and `Contact.localID` can be dropped from the public value
  entirely, or whether internal package code still reads `Contact.localID`
  directly.
