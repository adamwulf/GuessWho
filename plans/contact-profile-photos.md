# Plan: contact profile photos

## Status (2026-06-26)

Planning only. No app or package implementation has been changed.

This plan covers how GuessWho should load and display contact profile photos
without violating the contact-identity boundary:

- The app continues to speak `ContactID` and resolved `Contact` values only.
- The package/repository owns all translation to Contacts-framework identifiers.
- The app must not import or call `CNContactStore` / `CNContact` for photos.
- Photo bytes are loaded lazily, based on what is visible in list and detail
  surfaces, not during the bulk contact reload.

## Current codebase findings

- `Contact` already carries `imageDataAvailable`, but no image bytes. This is
  the right shape for lazy loading: rows can know whether a photo may exist
  without `fetchAll()` paying for image payloads.
- `CNContactStoreAdapter.keys` includes `CNContactImageDataAvailableKey`, but
  deliberately omits `CNContactImageDataKey` and
  `CNContactThumbnailImageDataKey` from bulk fetches.
- `CNContactStoreAdapter` already exposes two lazy byte loaders:
  `loadThumbnailImageData(localID:)` and `loadImageData(localID:)`. Both fetch
  through `unifiedContact(withIdentifier:keysToFetch:)` on the adapter's
  dedicated work queue.
- `ContactStoreProtocol` already includes the same lazy image methods, and
  `InMemoryContactStore` already models image sideband data for tests.
- `ContactsRepository` does not yet expose a `ContactID`-keyed photo API. That
  is the missing package boundary piece.
- People and Organizations lists are UIKit `UITableView`s backed by diffable data
  sources keyed by `ContactID`.
- Favorites is a UIKit `UITableView` backed by package-vended
  `FavoriteListItem.ID`; resolved contact favorite rows already carry a
  `Contact`.
- `ContactDetailView` is SwiftUI. Its header currently renders a 96-point
  initials circle and has access to the loaded `ContactID` / `Contact`.
- `EventDetailView` linked-contact rows are SwiftUI text rows today. They can
  share the thumbnail path later, but should not block the first photo pass.

## Design goals

- Keep the bulk contact reload cheap. It should continue fetching display fields
  and `imageDataAvailable`, not image bytes.
- Load thumbnails only for rows that are visible or about to become visible.
- Load full-size images only for a visible contact detail.
- Cancel work when a cell is reused, when a row scrolls off-screen, or when a
  detail view navigates to another contact.
- Keep Contacts framework I/O off the main thread and publish decoded UI images
  back on the main actor.
- Make re-scrolling cheap with an in-memory cache.
- Invalidate photo cache entries when Contacts changes or when a contact is
  edited/deleted through GuessWho.
- Preserve the package-owned identity boundary. Photo APIs are keyed by
  `ContactID`; app code never sees `localID`.

## Recommended API shape

Add a package-level image type and repository API rather than exposing raw
Contacts-framework details to the app:

```swift
public enum ContactPhotoKind: Hashable, Sendable {
    case thumbnail
    case fullSize
}

public struct ContactPhoto: Sendable {
    public let data: Data
    public let kind: ContactPhotoKind
}

extension ContactsRepository {
    public func contactPhotoData(
        for id: ContactID,
        kind: ContactPhotoKind
    ) async throws -> ContactPhoto?
}
```

Repository behavior:

- Resolve `ContactID` to the current cached `Contact` on the main actor.
- If the contact no longer resolves, return `nil`.
- If `imageDataAvailable == false`, return `nil` without calling the store.
- Internally read the package-scoped `localID` and call either
  `contactsStore.loadThumbnailImageData(localID:)` or
  `contactsStore.loadImageData(localID:)`.
- Catch `ContactStoreError.contactNotFound` from the store loader and translate
  it into `nil` plus any repository cache refresh/removal that matches existing
  deleted-record conventions. Do not let a stale visible row surface a photo-load
  alert.

The repository should vend bytes, not `UIImage`, because `GuessWhoSync` is a
Swift package that should stay UI-framework neutral. The app layer should decode
`UIImage(data:)` in a small app-owned loader/cache.

Use `async/await` as the primary API. It matches the existing store protocol,
inherits Swift task cancellation naturally, and avoids callback plumbing in both
UIKit cell tasks and SwiftUI `.task(id:)`.

## App photo-loading service

Add an app-owned `@MainActor` photo loader object that wraps
`ContactsRepository.contactPhotoData(for:kind:)` and caches decoded images:

- `ContactPhotoLoader.image(for:kind:) async -> UIImage?`
- `ContactPhotoLoader.cachedImage(for:kind:) -> UIImage?`
- `ContactPhotoLoader.invalidate(_ id: ContactID?)`
- `ContactPhotoLoader.removeAll()`

Cache design:

- Use a plain `NSCache` keyed by `ContactID` plus `ContactPhotoKind`. This is
  the intentionally simple v1 cache: no custom LRU, recency tracking, or
  count/cost tuning unless profiling proves it is needed.
- Let `NSCache` handle memory-pressure eviction.
- Clear the cache on `.contactsRepositoryDidReload`.

`ContactPhotoCacheKey` must not expose `ContactID` internals. It can be an
app-local wrapper around the public `Hashable` token and the photo kind.

The loader should coalesce duplicate in-flight requests per cache key so a
fast-scrolling table does not launch multiple store reads for the same contact.
Keep the coalescing map main-actor isolated and remove entries when the task
finishes or is cancelled.

## Fetching strategy

Lists:

- Use `thumbnailImageData` only.
- Render the placeholder immediately.
- Start thumbnail loading when the row is configured and still visible.
- Cancel the row task in `prepareForReuse()` and when
  `tableView(_:didEndDisplaying:forRowAt:)` fires.
- Adopt `UITableViewDataSourcePrefetching` for People, Organizations, and
  Favorites so near-future rows begin thumbnail fetches before display.
- Cancel prefetch tasks in `tableView(_:cancelPrefetchingForRowsAt:)`.

Detail:

- Use `imageData` for `ContactDetailView.headerView`.
- Start loading with `.task(id: contact.contactID)` or an explicit task tied to
  the loaded contact.
- Cancel automatically when the view disappears or the contact ID changes.
- If full-size data is unavailable, fall back to the thumbnail cache before
  showing initials.
- Decode full-size image data off the main actor, then deliver the ready
  `UIImage` to the main actor for assignment.

Event detail and linked-contact rows:

- Treat linked-contact thumbnails as a follow-up after the shared loader exists.
  They should use the same thumbnail API and cache; they do not need a separate
  Contacts path.

## UI behavior

Placeholders:

- Use circular initials monograms for list rows while loading and when a contact
  has no image.
- Derive initials with the app-side `Contact.initials` helper in
  `App/GuessWho/Support/Contact+Display.swift`: people use given-name +
  family-name initials; organizations and nickname-only contacts fall back to one
  or two letters from `displayName`.
- Use a deterministic background color chosen from public display fields such as
  `displayName` and `contactType`. Do not use `ContactID.hashValue` as a
  cross-launch color seed and do not read raw identity fields; if stronger
  duplicate-name differentiation is needed later, have the package vend an
  opaque color seed.
- In `ContactDetailView`, keep the existing initials circle as the no-photo
  fallback and replace only the circle contents with the loaded image.

Organizations:

- Organizations are `Contact` values with `contactType == .organization`, a
  public `Contact.contactID`, `imageDataAvailable`, and the same package-backed
  Contacts image source. They can use the exact same
  `contactPhotoData(for:kind:)` repository API, app `NSCache`, table-cell
  loading/cancellation, and detail fallback path as person contacts.
- The only organization-specific behavior is avatar text: when given/family
  names are empty, the app-side `Contact.initials` helper derives the monogram
  from the organization `displayName` instead of person-name parts. No separate
  organization image loader, cache key, or Contacts access path is needed.

Presentation:

- Crop photos to a circle in list cells and the detail header.
- Use stable image-view dimensions so late image arrival does not change row
  height.
- Fade image replacement only if it does not create table-view flicker during
  fast scrolling.
- Never block text rendering on image loading.

Failure behavior:

- No image, missing contact, cancelled task, decode failure, or permission error
  all degrade to the same placeholder.
- Avoid surfacing per-row photo failures as user-facing alerts.
- Log debug-only diagnostics if useful, but do not add user-visible error copy.

## Cache invalidation

Invalidate all cached photos on `.contactsRepositoryDidReload` for the first
implementation. This is conservative and correct for external Contacts edits,
image changes, contact unification, deletes, and repository full reloads.

After the first pass, narrow invalidation if needed:

- App-facing `refreshContact(id:)` and `removeContact(id:)` flows can clear only
  that contact's thumbnail and full-size entries.
- Package-internal `localID` refresh/remove paths may do the same internally, but
  should surface cache invalidation to the app as `ContactID`-keyed events or a
  package-owned notification, not as app-visible `localID` work.
- Change-history deltas can clear only changed/deleted local records inside the
  package, but the app should still receive this through repository events or a
  package-vended invalidation notification keyed by `ContactID`.

Do not persist photo cache entries. Contacts remains the source of truth and
system contact images can change outside GuessWho.

## Threading and cancellation

- `CNContactStoreAdapter` already performs blocking Contacts calls on its
  `guesswho.contacts-adapter` queue. Keep using that path.
- `ContactsRepository` remains `@MainActor`, but its async photo API should only
  stay on main long enough to resolve `ContactID` and inspect
  `imageDataAvailable`; the awaited store load happens off main through the
  adapter.
- Decode `UIImage(data:)` off the main actor for both thumbnails and full-size
  images. Assign only the ready `UIImage` on the main actor.
- UIKit cells keep a `Task<Void, Never>?` property. `prepareForReuse()` cancels
  and clears it.
- Before assigning a loaded image, verify the cell's represented `ContactID` and
  requested kind still match the completed task.
- SwiftUI detail uses `.task(id:)` so SwiftUI cancels stale loads when the
  contact changes.

## Phase 1: package ContactID photo API

Scope:

- Add `ContactPhotoKind`.
- Add a `ContactID`-keyed async photo-data method on `ContactsRepository`.
- Route thumbnail/full-size requests to the existing `ContactStoreProtocol`
  lazy methods.
- Keep `Contact` free of image bytes.

Touch-points:

- `Sources/GuessWhoSync/ContactsRepository.swift`
- `Sources/GuessWhoSync/ContactStoreProtocol.swift` only if the existing method
  comments need tightening
- `Sources/GuessWhoSyncTesting/InMemoryContactStore.swift` tests
- `Tests/GuessWhoSyncTests`

Acceptance criteria:

- `grep -R "loadImageData(localID:\\|loadThumbnailImageData(localID:" -n App/GuessWho`
  returns zero.
- Bulk `repository.reload()` still does not access image sideband data in
  `InMemoryContactStore`.
- A `ContactID` whose contact has `imageDataAvailable == false` returns nil
  without calling the store image loaders.
- A deleted or unresolved `ContactID` returns nil and does not crash.
- Thumbnail requests call `loadThumbnailImageData`; full-size requests call
  `loadImageData`.

Risk notes:

- Do not expose `localID` or any CNContact type in the new public API.
- Avoid adding image bytes to `Contact`; that would make every list reload more
  expensive and undermine lazy loading.

## Phase 2: app in-memory photo loader and cache

Scope:

- Add an app-owned `ContactPhotoLoader` or equivalent observable/cache object.
- Cache decoded `UIImage`s in a plain `NSCache`.
- Coalesce duplicate in-flight requests.
- Observe repository reloads and clear the cache.
- Clear the cache on repository reload and let `NSCache` handle memory-pressure
  eviction.
- Inject the loader where UIKit list controllers and SwiftUI detail views can
  share it.

Touch-points:

- `App/GuessWho/GuessWhoSceneDelegate.swift` or the existing app dependency
  wiring point
- New app-side loader file
- UIKit list view controller initializers if dependency injection is explicit
- SwiftUI environment setup for `ContactDetailView`

Acceptance criteria:

- Re-requesting the same visible thumbnail after it has loaded hits the cache and
  does not call the repository again.
- `.contactsRepositoryDidReload` clears cached images.
- The loader API accepts `ContactID`, not raw strings.
- The app target contains no `Contacts` / `CNContact` photo-loading code.

Risk notes:

- Keep the cache simple for v1; do not add custom recency tracking or tuning
  unless measured scrolling/detail performance requires it.
- Do not make the loader a second contact repository; it should cache images
  only.

## Phase 3: People and Organizations thumbnails

Scope:

- Update `ContactsListViewController.ContactCell` to render a circular thumbnail
  when available.
- Update `OrganizationsListViewController.OrganizationCell` to use the same
  loader and the same monogram fallback path.
- Add row task cancellation in cell reuse and table-view display lifecycle.
- Add `UITableViewDataSourcePrefetching` for both list controllers.

Touch-points:

- `App/GuessWho/ContactsListViewController.swift`
- `App/GuessWho/OrganizationsListViewController.swift`
- Shared UIKit avatar view/cell helper if duplication becomes meaningful

Acceptance criteria:

- Visible rows load thumbnails asynchronously without blocking initial text
  render.
- Fast scrolling does not show a previous contact's photo in a reused cell.
- `prepareForReuse()` cancels any active row load.
- Prefetch starts thumbnail loads for upcoming index paths and cancellation stops
  no-longer-needed prefetch tasks.
- Rows with no photo show a stable circular initials monogram, not an SF Symbol.
- Person and organization rows share the same photo API, cache, loader, and
  cancellation path.

Risk notes:

- Diffable `ContactID` identity and explicit reconfigure logic must stay
  unchanged.
- Late-arriving images should update only the cell currently representing the
  completed `ContactID`.

## Phase 4: Favorites thumbnails

Scope:

- Load thumbnails for resolved contact favorite rows.
- Keep event rows on their current calendar icons.
- Reuse the same app photo loader/cache and cancellation pattern.

Touch-points:

- `App/GuessWho/FavoritesListViewController.swift`

Acceptance criteria:

- Resolved contact favorites show thumbnails when available.
- Unavailable contact favorites keep the question-mark placeholder.
- Event favorites are unchanged.
- Reordering and swipe-to-unfavorite behavior still work.

Risk notes:

- `FavoriteListItem.ID` remains the row identity; photo loading should use the
  resolved contact's `contactID` only for image lookup.

## Phase 5: Contact detail full-size photo

Scope:

- Update `ContactDetailView.headerView` to show a loaded full-size contact photo
  in the existing 96-point circle.
- Use thumbnail fallback if full-size data is missing but a thumbnail is cached.
- Keep initials as the final fallback.
- Tie loading to the currently loaded `Contact.contactID`.
- Decode full-size image data off the main actor before assigning the image to
  the header.

Touch-points:

- `App/GuessWho/ContactDetailView.swift`
- Shared SwiftUI avatar view if useful

Acceptance criteria:

- Opening a detail view starts one full-size load for that contact.
- Full-size decode runs off the main actor; only final image assignment happens
  on the main actor.
- Navigating to another contact cancels or ignores the stale load.
- The header layout does not jump when the image arrives.
- An edited/deleted/reloaded contact clears stale photo state through the shared
  cache invalidation path.

Risk notes:

- Keep image loading separate from `loadContact()`. Contact data can render while
  image work is pending.
- Do not make detail-open reconcile or mint identity; photo reads are display
  reads and must preserve the write-only reconcile rule.

## Phase 6: shared avatar polish and optional linked-contact rows

Scope:

- Factor shared UIKit/SwiftUI avatar rendering only after the first list/detail
  integrations prove the shape.
- Optionally add thumbnails to `EventDetailView` linked-contact rows and contact
  link picker rows.
- Reuse the initials monogram fallback across all contact avatar surfaces.

Touch-points:

- `App/GuessWho/ContactRow.swift`
- `App/GuessWho/EventDetailView.swift`
- `App/GuessWho/ConnectionsSection.swift`
- Shared avatar helper files, if added

Acceptance criteria:

- All contact avatar surfaces use the same cache and repository photo API.
- No surface imports Contacts or resolves `localID`.
- Placeholder styling is consistent across UIKit and SwiftUI surfaces.

Risk notes:

- Avoid a premature abstraction if only two cells need different UIKit layouts.
- SwiftUI row image loading in large lists should not create one unbounded task
  per contact; keep visible-row-driven loading.

## Verification plan

- `swift test`
- Catalyst app build with local DerivedData
- iPhone simulator app build with local DerivedData
- Manual simulator checks:
  - People list initial paint is text-first and non-blocking.
  - Fast scroll does not flash wrong photos.
  - Scrolling away and back reuses cached thumbnails.
  - Contact detail shows full-size photo, then falls back to initials when none
    exists.
  - Organization rows use the same thumbnail loader/cache as person rows and
    fall back to initials derived from organization display names.
  - Clearing on `.contactsRepositoryDidReload` removes cached images.
  - Full-size detail image decode does not run on the main actor.
  - External contact photo change clears stale cached images after repository
    reload.
- Static audits:
  - Review existing `CNContact` / `CNContactStore` hits in `App/GuessWho` and
    confirm no new photo-loading path was added there. This is not a zero-hit
    grep because current edit/lifecycle code already imports Contacts.
  - `grep -R "loadImageData(localID:\\|loadThumbnailImageData(localID:" -n App/GuessWho`
    returns zero.
  - `grep -R "\\.localID\\|localID:" -n App/GuessWho` has no new photo-related
    hits.

## Resolved design decisions

- List fallback: use initials monograms, not SF Symbols.
- Organizations: handle organizations exactly like other contacts for photo
  loading. They share `ContactID`, `Contact`, `imageDataAvailable`,
  `contactPhotoData(for:kind:)`, the same `NSCache`, and the same visible-row
  loading/cancellation path. The only difference is monogram derivation when
  person-name fields are empty: use one or two initials from `displayName`.
- Cache: use a plain `NSCache` for v1. Whole-cache invalidation on
  `.contactsRepositoryDidReload` is the invalidation path; per-contact
  invalidation remains a later refinement.
- Full-size decode: decode off the main actor and deliver the ready `UIImage` to
  the main actor for display.

## Boundary confirmation

The revised design still respects the contact-identity boundary:

- App photo requests are keyed only by `ContactID`.
- The repository translates `ContactID` to the package-scoped Contacts lookup
  token internally.
- App code never touches `CNContact`, `CNContactStore`, `localID`, or
  `CNContactImageDataKey` / `CNContactThumbnailImageDataKey` for photo loading.
- Organizations do not introduce a second identity path; they are the same
  `ContactID` / `Contact` records with `contactType == .organization`.
