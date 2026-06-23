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
  - `.organizationsPlaceholder` → `PlaceholderViewController`
  - `.settings` → `UIHostingController(rootView: SettingsView())`
- **Secondary (detail):** swapped by content-column selection via
  `split.setViewController(_:for: .secondary)` (REPLACES, never
  pushes). Mounts `UIHostingController(rootView: ContactDetailView(localID:).environment(...))`.
  Resets to `PlaceholderViewController("Nothing Selected")` on every
  tab swap.
- `displayModeButtonItem` wired into the supplementary column's
  `leftBarButtonItem`.

### What lives where

| Piece | Catalyst | iPhone |
|---|---|---|
| App entry | UIKit `GuessWhoAppDelegate` | UIKit `GuessWhoAppDelegate` |
| Window root | UIKit `UISplitViewController` | `UIHostingController(RootView)` |
| Sidebar | UIKit `SidebarViewController` | SwiftUI `RootView` TabView |
| People list | UIKit `ContactsListViewController` | SwiftUI `PeopleListView` |
| Org / Events / Favorites list | UIKit placeholder (Phase 4) | SwiftUI list views |
| Contact detail | SwiftUI `ContactDetailView` hosted | SwiftUI `ContactDetailView` native |
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

### Phase 4 — Organizations / Events / Favorites lists (next)

Same selection-driven column-swap pattern as Phase 3. Likely
parameterize `ContactsListViewController` (filter + sections-source
closure) so Organizations shares code; Events and Favorites get their
own VCs. Replace `.organizationsPlaceholder` with `.organizations` +
add `.events`, `.favorites` cases to `SidebarTab`. Favorites needs
`UITableViewDragDelegate` for reorder.

### Phase 5 — Cleanup

Trim the Catalyst-only SwiftUI helpers in `RootView.swift`
(`tripleColumn`, `contentColumn`, `detailColumn`, `sidebarTabs`)
since Catalyst no longer reaches them.

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
  ignores the AppDelegate's. Wasted fetch on iPhone. Phase 4 cleanup:
  either gate the eager reload behind `targetEnvironment(macCatalyst)`,
  or have `RootView` consume the shared repo via `@Environment`.
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
