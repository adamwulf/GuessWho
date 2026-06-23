# UIKit + Mac Catalyst Migration Status

In-flight migration of the Mac UI from SwiftUI's NavigationSplitView
to a UIKit `UISplitViewController` shell on Mac Catalyst. iPhone keeps
SwiftUI.

## Architecture

```
GuessWhoAppDelegate (@main, UIKit)
  owns: SyncService, FavoritesListStore, ContactsRepository
  kicks ContactsRepository.reload() in didFinishLaunching

GuessWhoSceneDelegate.scene(_:willConnectTo:)
  Catalyst  → UISplitViewController(.tripleColumn)
  non-Catalyst → UIHostingController(rootView: RootView())
```

### Catalyst columns

- **Primary (sidebar):** `SidebarViewController` (UICollectionView,
  `.sidebar` list config, diffable data source). Items =
  `SidebarTab.allCases`. Selection invokes `didSelectTab` closure.
- **Supplementary (content):** swapped by sidebar selection via
  `split.setViewController(_:for: .supplementary)`:
  - `.people` → `ContactsListViewController(repository:)`
  - `.organizations` → `OrganizationsListViewController(repository:)`
  - `.events` → `EventsListViewController(repository:service:)`
  - `.favorites` → `FavoritesListViewController(store:service:)`
  - `.settings` → `UIHostingController(rootView: SettingsView())`
- **Secondary (detail):** swapped by content-column selection via
  `split.setViewController(_:for: .secondary)` (REPLACES, never
  pushes). Mounts a `UIHostingController` wrapping
  `ContactDetailView(localID:)` (People / Organizations / Favorites-
  contact) or `EventDetailView(eventUUID:)` (Events / Favorites-event)
  with the required environment values injected. Resets to
  `PlaceholderViewController("Nothing Selected")` on every tab swap.
- `displayModeButtonItem` wired into the supplementary column's
  `leftBarButtonItem`.

### What lives where

| Piece | Catalyst | iPhone |
|---|---|---|
| App entry | UIKit `GuessWhoAppDelegate` | UIKit `GuessWhoAppDelegate` |
| Window root | UIKit `UISplitViewController` | `UIHostingController(RootView)` |
| Sidebar | UIKit `SidebarViewController` | SwiftUI `RootView` TabView |
| People list | UIKit `ContactsListViewController` | SwiftUI `PeopleListView` |
| Org / Events / Favorites list | UIKit list controllers | SwiftUI list views |
| Contact detail | SwiftUI `ContactDetailView` hosted | SwiftUI `ContactDetailView` native |
| Event detail | SwiftUI `EventDetailView` hosted | SwiftUI `EventDetailView` native |
| Settings | SwiftUI `SettingsView` hosted | iOS Settings.bundle |
| Edit sheet | SwiftUI `ContactEditView` | SwiftUI `ContactEditView` |

## Phases

| # | Commit | Scope |
|---|---|---|
| 1 | `767f499` | Enable `SUPPORTS_MACCATALYST=YES`; swap `os(macOS)` → `targetEnvironment(macCatalyst)` (16 sites across 6 files). |
| 1.5 | `c336db2` | Catalyst entitlements file (`GuessWho-MacCatalyst.entitlements`, byte-identical iCloud); `SidebarTab.settings` case + in-app `SettingsView`; "Open System Settings" alert button using `x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts`. |
| 2 | `ce1ef33` | UIKit `@main` cutover (`GuessWhoAppDelegate` + `GuessWhoSceneDelegate`); Catalyst `UISplitViewController(.tripleColumn)` shell with `SidebarViewController` + placeholder content/detail. |
| 3 | `2b38333` | Real People list (`ContactsListViewController` — UITableView, diffable data source, A-Z section index, search); selection mounts `ContactDetailView` in detail column. Extracted `SidebarTab` to its own file. Hardened SceneDelegate guard. `ContactsRepository.reload()` posts `.contactsRepositoryDidReload`. |
| 3.5 | `fa26858` | Review fix: `reload()` flips `isLoading=false` BEFORE posting (synchronous observer needs the final flag); notification handler switched to `addObserver(forName:object:queue:.main, using:)` (defensive main-thread pin); dropped misleading `.id(localID)` on the hosted detail view. |
| 4A | `4f37447` | `OrganizationsListViewController` (mirrors People; shares `.contactsRepositoryDidReload`); renamed `SidebarTab.organizationsPlaceholder` → `.organizations`. |
| 4B | `f2e8d6e`, `5ac3a1e` | `EventsListViewController` (single-section diffable, swipe-delete with confirm, "+" hosts SwiftUI `EventLinkSheet`, permission + sidecar header banners). `EventsRepository.reload()` posts `.eventsRepositoryDidReload` after flipping `isLoading=false`. AppDelegate gets Catalyst-only `eventsRepository`. `SceneDelegate.showEventDetail` mounts hosted `EventDetailView`. Fix commit: sheet's post-create navigation reads `repository.events` (not the VC cache, which is stale until the queue:.main observer runs); adds `SidecarLocationBanner` parity. |
| 4C | `cdbb4ba`, `e3e544f` | `FavoritesListViewController` (two selection callbacks, 4-state cell, swipe-unfavorite, drag-reorder via `UITableViewDragDelegate`/`UITableViewDropDelegate`, async contact-uuid map). Fix commit: `FavoritesListStore.reload()` posts `.favoritesDidChange` so detail-view star toggles refresh the list (SwiftUI gets this for free via `@Observable`); drag uses empty `NSItemProvider()` to avoid leaking stableIDs externally. |

### Phase 5 — iPhone UIKit migration + Catalyst cleanup

Destructively migrate the iPhone path off `RootView` (SwiftUI TabView)
to a UIKit shell, then trim the now-dead Catalyst-only SwiftUI helpers
in `RootView.swift` (`tripleColumn`, `contentColumn`, `detailColumn`,
`sidebarTabs`, and the per-tab placeholder `ContentUnavailableView`s
in `contentColumn` that were added during Phase 4 only to keep the
exhaustive `switch SidebarTab` compiling on iPhone). Also drop the
unused `SceneDelegate.contactsList` ivar (write-only since Phase 3).

## Constraints (must respect)

- **iPhone behavior is preserved.** Every phase must build iOS
  Simulator AND not change the iPhone SwiftUI flow.
- **iCloud entitlement is on both platforms.** Catalyst entitlements
  file is byte-identical to iOS — same iCloud container, same
  `CloudDocuments` service, so iOS↔Catalyst sync still works.
- **`SyncService`, `FavoritesListStore`, `ContactsRepository` are
  singletons** owned by the AppDelegate. SceneDelegate `guard let`s
  the AppDelegate and `fatalError`s if missing — don't reintroduce a
  fallback that double-constructs them.
- **Detail-column swap REPLACES, never pushes.** Use
  `split.setViewController(_:for: .secondary)`, not a navigation
  push, or detail views accumulate.
- **`ContactDetailView` reads `@Environment` for `SyncService`,
  `ContactsRepository`, `FavoritesListStore`.** Inject all three on
  the `UIHostingController`'s rootView when mounting.
- **`UITableViewDiffableDataSource` default doesn't forward
  `titleForHeaderInSection`.** Subclass it (see
  `SectionedDataSource` in `ContactsListViewController.swift`) for
  A-Z section headers + index scrubber.
- **Review cycle every phase, no exceptions.** Spawn 2 worker
  reviewers (positive + skeptical) in parallel. Brief each with the
  exact `xcodebuild` commands for iOS Simulator AND Mac Catalyst
  (`CODE_SIGNING_ALLOWED=NO`) so they verify builds themselves.

## Open follow-ups

- **`SyncService` construction blocks main thread** in
  `AppDelegate.init()` (synchronous iCloud container resolution).
  Pre-existing; hoist off main before shipping.
- **Catalyst signed builds need iCloud capability** on the dev
  provisioning profile (portal-side action by Adam).
- **Search has no debounce.** Each keystroke re-runs filter+sort and
  applies a snapshot. Fine for small address books; add a debounce
  if performance matters at scale.
- **AppDelegate reloads `ContactsRepository` on iPhone too**, but
  iPhone's `RootView` constructs its own `ContactsRepository` and
  ignores the AppDelegate's. Wasted fetch on iPhone. Phase 5 cleanup:
  either gate the eager reload behind `targetEnvironment(macCatalyst)`,
  or have `RootView` consume the shared repo via `@Environment`.
  (Phase 4B already gated `eventsRepository` this way.)
- **Phase 4 deferred items (small, individually trivial; bundle in
  Phase 5 cleanup):**
  - `FavoritesListViewController` permission/calendar/scene-active
    paths still call `applySnapshot` directly after `store.reload()`
    even though `.favoritesDidChange` now drives the same apply —
    redundant second pass. Cosmetic only (diffable no-ops the second
    apply).
  - `FavoritesListViewController.performDropWith` loops over
    `coordinator.items` mutating per-item with the ORIGINAL
    `sourceIndexPath.row` after `store.move` shifts indices. Today
    unreachable because tableView drag sessions carry one item; if
    multi-drag is ever enabled, the loop must collect rows into a
    single `IndexSet` first.
  - `EventsListViewController.installPermissionBanner` and
    `updateHeaderBanners` size the banner against `tableView.bounds.width`
    at install time; Catalyst column resize won't reflow it. Standard
    "tableHeaderView auto-layout dance" fix.
  - `EventsListViewController` and `FavoritesListViewController` don't
    subscribe to `.EKEventStoreChanged` / `.CNContactStoreDidChange` in
    every place SwiftUI does. SwiftUI iPhone reloads on every external
    Calendar.app edit; UIKit Catalyst waits for scene-active or next
    explicit reload. Acceptable for first ship.
  - `FavoritesListStore.reload()` posts `.favoritesDidChange` once from
    `init()` (no observers registered yet — no-op) and once on every
    user mutation. Inconsistent rawValue casing vs
    `.contactsRepositoryDidReload` / `.eventsRepositoryDidReload`
    (camelCase vs PascalCase). Harmless.
- **Verify in-app on Catalyst:** SwiftUI `.toolbar` items (star +
  Edit) from `ContactDetailView` should appear in the secondary
  column's nav bar when hosted via `UIHostingController`. Build-only
  verification can't catch this; needs a real run.
- **`ContactsListViewController.reloadObserver` is
  `nonisolated(unsafe)`** because today the only strong holder is the
  SceneDelegate, which writes and releases on main. If another holder
  (a UIKit nav-stack hold, a delayed Task, a diagnostic singleton)
  ever takes a strong reference and releases it from off-main, the
  `deinit` read of `reloadObserver` becomes a data race. Re-evaluate
  if more holders appear.
