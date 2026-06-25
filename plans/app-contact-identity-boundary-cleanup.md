# Plan: app contact-identity boundary cleanup

## Status (2026-06-25)

This plan synthesizes two independent agent passes:

- `favroites-check` produced an audit plus a 7-step removal plan. It found
  app-side leaks in favorites, contact detail link resolution, GuessWho URL
  parsing/debug display, contact lifecycle operations, and package public API
  escape hatches.
- `contactuuid-check` started implementing the favorites part, then stopped at
  usage limit before build or verification. Its transcript says it changed
  `ContactDetailView.isContactFavorited` to read through a `ContactID`-based
  `FavoritesListStore.isFavorite(_:)`, deleted the dead `contactUUID` property,
  and added the store overload using package `Favorite.matches(_:)`.
  `ib status contactuuid-check` reports uncommitted changes in
  `App/GuessWho/ContactDetailView.swift`, `App/GuessWho/FavoritesStore.swift`,
  and `Sources/GuessWhoSync/Favorite.swift`; however
  `ib diff contactuuid-check` returned no diff output. Treat the transcript as
  design signal only, not as verified code.

The two reports agree on the architecture: the app should hold, compare, fetch,
and navigate with `ContactID` or resolved `Contact` values; raw `localID`, bare
GuessWho UUIDs, and `guesswho://contact/...` URL parsing should live inside
`GuessWhoSync`. The only difference is scope. `favroites-check` planned the full
boundary cleanup; `contactuuid-check` attempted the first concrete slice. This
plan keeps the audit's full scope and incorporates the implementation agent's
successful insight: favorites can preserve observable star reactivity by adding a
`ContactID`-keyed favorite read path that delegates matching to the package.

## Current leaks to remove

- Favorites list UI resolves contact favorites with bare UUIDs:
  `App/GuessWho/FavoritesListViewController.swift` calls
  `repository.contact(guessWhoID: favorite.id)` for cells and selection.
- Contact detail still derives and stores the opened contact's bare UUID:
  `ContactDetailView.contactUUID` calls `repository.guessWhoID(in:)`, and
  `isContactFavorited` passes the result into
  `favoritesStore.isFavorite(kind: .contact, id:)`.
- Contact detail still resolves far contact link endpoints from raw
  `SidecarKey.id` with `repository.contact(guessWhoID:)`.
- Contact detail filters and debugs GuessWho URLs directly with
  `SidecarKey.parseGuessWhoContactURL`, `SidecarKey.guessWhoContactURLPrefix`,
  `repository.guessWhoID(in:)`, and `contact.localID`.
- Contact edit/save/delete still crosses the app boundary with raw `localID`
  through `service.fetchContactForEditing(localID:)`,
  `service.deleteContact(localID:)`, `repository.refreshContact(localID:)`, and
  `repository.removeContact(localID:)`.
- Package public API still exposes escape hatches that make the boundary a
  convention rather than compile-time enforcement:
  `Contact.localID`, `ContactsRepository.contact(localID:)`,
  `ContactsRepository.contact(guessWhoID:)`,
  `ContactsRepository.guessWhoID(in:)`,
  `ContactsRepository.refreshContact(localID:)`, and
  `ContactsRepository.removeContact(localID:)`.
- `docs/contact-identity.md` still documents the favorite/link endpoint carve-out
  as acceptable app behavior.

## Phase 6g: ContactID-keyed favorite reactivity

Scope:

- Finish the slice `contactuuid-check` began, but re-implement and verify it in
  this branch rather than merging the stopped worktree blindly.
- Add an app-side observable read helper that accepts `ContactID`, for example
  `FavoritesListStore.isFavorite(_ contactID: ContactID) -> Bool`.
- Implement the helper by asking each `Favorite` whether it matches the contact
  through a package-owned matcher. If `Favorite.matches(_:)` does not already
  exist on `main`, add it in `Sources/GuessWhoSync/Favorite.swift` with
  `ContactID` internals remaining package-only.
- Change `ContactDetailView.isContactFavorited` to use the loaded
  `Contact.contactID`, not `contactUUID`.
- Delete `ContactDetailView.contactUUID` once it has no non-debug consumers.

Touch-points:

- `App/GuessWho/ContactDetailView.swift`
- `App/GuessWho/FavoritesStore.swift`
- `Sources/GuessWhoSync/Favorite.swift`
- Focused tests for `Favorite.matches(_:)` if the package does not already cover
  contact favorite matching.

Acceptance criteria:

- `grep -n "private var contactUUID" App/GuessWho/ContactDetailView.swift`
  returns zero.
- `grep -n "isFavorite(kind: .contact" App/GuessWho/ContactDetailView.swift`
  returns zero.
- `grep -n "guessWhoID(in:" App/GuessWho/ContactDetailView.swift` returns only
  debug rows until Phase 6j removes those too.
- Toggling a favorite for an unstamped contact still mints through
  `repository.toggleFavorite(id)` and updates both the toolbar star and the
  favorites list after `favoritesStore.reload()`.

Risk notes:

- Do not key star reactivity on `ContactsRepository.isFavorite(_:)` alone unless
  it is observable in the same way as `FavoritesListStore.items`; the
  implementation agent specifically preserved the app observable cache for this
  reason.
- Read from the loaded contact's current `contactID`, not the navigation `id`,
  because first favorite write can mint a GuessWho UUID after navigation.

## Phase 6h: Package-vended favorites projection

Scope:

- Move favorites list contact resolution out of
  `FavoritesListViewController`.
- Add a package/repository projection that turns persisted favorites into app
  rows without exposing contact favorite IDs to the app. Possible shapes:
  `ContactsRepository.favoriteRows()` or `FavoritesListStore` storing a
  package-vended row type.
- The row should carry an opaque stable row identity, kind, display data, and
  resolved `Contact?` / `Event?` as needed. Contact rows must not expose the bare
  contact favorite UUID.
- Selection should navigate with `Contact.contactID` for contacts and existing
  event identity for events.

Touch-points:

- `App/GuessWho/FavoritesListViewController.swift`
- `App/GuessWho/FavoritesStore.swift`
- `Sources/GuessWhoSync/ContactsRepository.swift`
- `Sources/GuessWhoSync/Favorite.swift`

Acceptance criteria:

- `grep -n "contact(guessWhoID:" App/GuessWho/FavoritesListViewController.swift`
  returns zero.
- `grep -n "favorite.id" App/GuessWho/FavoritesListViewController.swift` returns
  no contact-resolution or contact-navigation uses. Event favorite uses may
  remain until the later EventID migration.
- Swipe-to-unfavorite and drag reorder still preserve existing favorite ordering.

Risk notes:

- Keep event favorites out of this cleanup unless needed for the shared row
  model; event identity is explicitly deferred by the existing plan.
- Preserve `Favorite.stableID` semantics for diffable data source identity unless
  the replacement row type has equivalent stable identity.

## Phase 6i: Package-vended contact link endpoint resolution

Scope:

- Remove app reads of contact link endpoint UUIDs. The package should convert
  `SidecarKey(kind: .contact, id: ...)` endpoints into `ContactID` or resolved
  `Contact` before the app renders rows.
- Replace `ContactDetailView.otherContact(for:)` with a repository helper such
  as `contact(for linkDirection:)`, `linkedContact(for:)`, or a richer
  package-vended activity row model.
- Replace `EventDetailView.linkedContactRows` / `linkedContactsSection` style
  resolution that currently uses `repository.contact(guessWhoID: other.id)`.

Touch-points:

- `App/GuessWho/ContactDetailView.swift`
- `App/GuessWho/EventDetailView.swift`
- `App/GuessWho/ConnectionsSection.swift`
- `Sources/GuessWhoSync/ContactsRepository.swift`
- `Sources/GuessWhoSync/SidecarKey.swift`

Acceptance criteria:

- `grep -n "contact(guessWhoID:" App/GuessWho/ContactDetailView.swift` returns
  zero.
- `grep -n "contact(guessWhoID:" App/GuessWho/EventDetailView.swift` returns
  zero.
- `grep -n "\\.id" App/GuessWho/ContactDetailView.swift` has no contact
  `SidecarKey.id` resolution paths.
- Existing `SidecarKey.matches(_ contactID:)` remains the package-owned identity
  comparison for link direction.

Risk notes:

- Link direction comparison was already correctly moved into the package in the
  7ac8c16 cleanup. Do not regress by reintroducing string comparison in the app.
- Unknown or retired link endpoints need an explicit unavailable row state so the
  UI can still show/delete stale links without resolving a contact.

## Phase 6j: Package-owned GuessWho URL filtering and diagnostics

Scope:

- Remove app knowledge of `guesswho://contact/...` URL structure.
- Replace app-side URL filtering in `ContactDetailView.infoRows(for:)` with a
  package-vended display list, for example `Contact.userVisibleURLAddresses` or
  `ContactsRepository.visibleURLAddresses(for:)`.
- Replace debug rows that directly show `contact.localID`, `guessWhoID(in:)`, or
  raw GuessWho URLs with package-vended diagnostics if Adam still wants them.
  Debug can remain, but the app should consume a diagnostic value model rather
  than parse identity internals.

Touch-points:

- `App/GuessWho/ContactDetailView.swift`
- `Sources/GuessWhoSync/Contact.swift`
- `Sources/GuessWhoSync/ContactsRepository.swift`
- `Sources/GuessWhoSync/SidecarKey.swift`
- Tests around URL filtering and debug diagnostics if added.

Acceptance criteria:

- `grep -n "parseGuessWhoContactURL\\|guessWhoContactURLPrefix" App/GuessWho`
  returns zero.
- `grep -n "guesswho://contact" App/GuessWho` returns zero.
- `grep -n "guessWhoID(in:" App/GuessWho` returns zero.
- `grep -n "\\.localID" App/GuessWho/ContactDetailView.swift` returns no debug
  display reads after Phase 6k handles lifecycle reads.

Risk notes:

- The debug carve-out should not block compile-time enforcement. If debug needs
  identity internals, vend a package-owned `ContactIdentityDebugInfo` struct.
- Keep normal contact URLs visible; only GuessWho-owned identity URLs should be
  hidden from the user-facing info rows.

## Phase 6k: Contact lifecycle APIs keyed by ContactID

Scope:

- Move edit, save, delete, refresh, and removal entry points behind
  `ContactID`-keyed package/repository APIs so `ContactDetailView` never reads a
  `localID`.
- Candidate APIs:
  `editableContact(id:) async throws -> Contact?`,
  `saveContact(_ edited: Contact, for id: ContactID) async throws`,
  `deleteContact(id:) async throws`,
  and internal/package `refreshContact(id:)` / `removeContact(id:)` helpers.
- Decide whether these APIs live directly on `ContactsRepository` or whether
  `SyncService` keeps Contacts write responsibility and exposes
  `ContactID`-keyed wrappers. The boundary outcome matters more than the owner:
  the app must not pass raw `localID`.
- Update `ContactDetailView.beginInlineEdit`, `performInlineSave`,
  `performInlineDelete`, and `loadContact(preferFresh:)`.

Touch-points:

- `App/GuessWho/ContactDetailView.swift`
- `App/GuessWho/SyncService.swift`
- `Sources/GuessWhoSync/ContactsRepository.swift`
- Any package Contacts adapter that currently requires raw `localID`.

Acceptance criteria:

- `grep -n "\\.localID" App/GuessWho/ContactDetailView.swift` returns zero,
  except possibly the empty new-contact seed until that creation path has its
  own package factory.
- `grep -n "localID:" App/GuessWho/ContactDetailView.swift` returns zero for
  fetch/save/delete/refresh/remove calls.
- `grep -n "refreshContact(localID:\\|removeContact(localID:" App/GuessWho`
  returns zero.
- Edit, save, delete, and record-does-not-exist delete handling behave as today.

Risk notes:

- Save/delete must target the exact loaded contact record, not whichever contact
  a stale navigation token resolves to after a reconcile. The package API should
  resolve the current `ContactID` to the correct local Contacts record at the
  boundary.
- Catalyst Contacts can lag immediately after `CNSaveRequest.update`; preserve
  the existing fresh-fetch behavior inside the package wrapper.

## Phase 6l: Compile-time enforcement

Scope:

- After app call sites are gone, demote or split public package APIs so misuse no
  longer compiles from the app target.
- Demote these to `package` or `internal` where feasible:
  `Contact.localID`, `ContactsRepository.contact(localID:)`,
  `ContactsRepository.contact(guessWhoID:)`,
  `ContactsRepository.guessWhoID(in:)`,
  `ContactsRepository.refreshContact(localID:)`, and
  `ContactsRepository.removeContact(localID:)`.
- If `Contact.localID` cannot be demoted because public initializer or tests need
  it, split storage from app-facing model or add package-only factories so the app
  receives a `Contact` without readable Contacts identity.
- Keep lower-level sidecar storage keyed by GuessWho UUID. This phase only hides
  those details from app consumers.

Touch-points:

- `Sources/GuessWhoSync/Contact.swift`
- `Sources/GuessWhoSync/ContactsRepository.swift`
- Package tests that currently construct `Contact(localID:)` directly.
- App tests or previews that seed contacts with raw local IDs.

Acceptance criteria:

- `grep -n "public var localID" Sources/GuessWhoSync/Contact.swift` returns zero.
- `grep -n "public func contact(localID:\\|public func contact(guessWhoID:\\|public func guessWhoID(in:\\|public func refreshContact(localID:\\|public func removeContact(localID:" Sources/GuessWhoSync/ContactsRepository.swift`
  returns zero.
- Full app build proves app target can no longer call the raw identity APIs.
- Package tests still have explicit package/internal seams for constructing
  realistic contacts.

Risk notes:

- This is the enforcement endgame, not the first move. Flipping visibility before
  Phases 6g-6k will create compile errors without improving the boundary design.
- Be careful with Swift access control across package tests; tests may need
  package test support helpers rather than public production escape hatches.

## Phase 6m: Documentation and audit checks

Scope:

- Tighten `docs/contact-identity.md` to remove the favorite/link endpoint
  exception. The app contract should say:
  app code uses `ContactID` and resolved `Contact`; package/repository code owns
  GuessWho UUIDs, `localID`, and GuessWho contact URLs.
- Update the existing plan/status docs after implementation, including this plan
  and `plans/package-vended-contact-identity.md` if it remains the canonical
  historical plan.
- Add or document grep-style checks that should pass before future identity work
  is considered done.

Acceptance criteria:

- `grep -n "favorite / link endpoint\\|favorite/link endpoint\\|bare GuessWho UUID.*app\\|contact(guessWhoID:)"`
  in `docs/contact-identity.md` finds no text blessing app-side raw UUID
  resolution. Historical footnotes should be removed or rewritten as package
  internals.
- Final app audit:
  `grep -n "contact(guessWhoID:\\|guessWhoID(in:\\|parseGuessWhoContactURL\\|guessWhoContactURLPrefix\\|guesswho://contact" App/GuessWho`
  returns zero.
- Final localID audit:
  `grep -n "\\.localID\\|localID:" App/GuessWho` returns only approved non-contact
  creation/test seams, or zero if those are also moved behind package APIs.
- Final package API audit from Phase 6l passes.

Risk notes:

- Do not rewrite storage documentation to imply sidecar records stop using
  GuessWho UUIDs. The cleanup is about the package boundary, not the persistence
  format.
- Keep the event identity deferral explicit. Event favorites may still carry raw
  event UUIDs until the separate EventID migration.

## Suggested execution order

1. 6g first, because it removes `ContactDetailView.contactUUID`'s main
   non-debug reason to exist and validates the implementation agent's approach.
2. 6h next, because it removes favorites-list dependence on
   `contact(guessWhoID:)`.
3. 6i next, because it removes the other app-side
   `contact(guessWhoID:)` consumers.
4. 6j and 6k can proceed independently after 6g, but both must land before
   visibility demotion.
5. 6l only after all app grep checks are clean.
6. 6m last, so the docs describe the enforced boundary rather than an aspirational
   one.
