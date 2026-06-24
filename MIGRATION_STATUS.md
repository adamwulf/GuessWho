# UIKit + Mac Catalyst Migration Status

In-flight migration of the Mac UI from SwiftUI's NavigationSplitView
to a UIKit `UISplitViewController` shell on Mac Catalyst. iPhone has
also moved off SwiftUI's TabView to a UIKit `UITabBarController`
behind a permission gate (Phase 5). Detail views remain SwiftUI on
both platforms, hosted via `UIHostingController`.

## Architecture

```
GuessWhoAppDelegate (@main, UIKit)
  owns: SyncService, FavoritesListStore,
        ContactsRepository, EventsRepository
  kicks both repositories' reload() in didFinishLaunching
  observes .CNContactStoreDidChange / .EKEventStoreChanged
    (single owner, fans out to list VCs via the
     .contactsRepositoryDidReload / .eventsRepositoryDidReload
     notifications the repositories post)

GuessWhoSceneDelegate.scene(_:willConnectTo:)
  Catalyst     → UISplitViewController(.tripleColumn)
  non-Catalyst → PermissionGateViewController
                   ├── (gate)  UIContentUnavailableConfiguration
                   │           for notRequested / denied / restricted
                   └── (auth)  UITabBarController of 4 nav stacks
                                People / Organizations / Events / Favorites
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
| Window root | UIKit `UISplitViewController` | UIKit `PermissionGateViewController` ⇒ `UITabBarController` |
| Sidebar / tabs | UIKit `SidebarViewController` | UIKit `UITabBarController` (4 tabs) |
| People / Org / Events / Favorites list | UIKit list controllers | UIKit list controllers (same VCs) |
| Detail navigation | column REPLACE (`setViewController(_:for:.secondary)`) | UIKit nav-stack PUSH from each tab |
| Contact detail | SwiftUI `ContactDetailView` hosted | SwiftUI `ContactDetailView` hosted |
| Event detail | SwiftUI `EventDetailView` hosted | SwiftUI `EventDetailView` hosted |
| NavigationLink → push from hosted detail | silent no-op (TBD Phase 6) | env-injected closures bridge to outer UINavigationController |
| Settings | `Settings.bundle` auto-rendered into the ⌘, window (no sidebar row) | `Settings.bundle` in system Settings.app (no tab) |
| Edit sheet | SwiftUI `ContactEditView` | SwiftUI `ContactEditView` |

iPad regular-width currently lands on the same UIKit tab shell as
iPhone — temporary downgrade from the prior 3-column
`NavigationSplitView` until Phase 6 stands up the Catalyst-shaped
`UISplitViewController(.tripleColumn)` on iPad.

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
| 5 cleanup | `664b0b7`, `3c5c2b9`, `f479a90`, `7d353c5` | Phase 4 deferred bundle: Favorites VC redundant `applySnapshot` drop + multi-drag IndexSet fix; `.favoritesDidChange` rawValue PascalCase alignment; Events VC `tableHeaderView` reflow on column resize + `.EKEventStoreChanged`/`.CNContactStoreDidChange` observers (later subsumed by AppDelegate single-owner pattern in `61e2dcf`); dropped unused `SceneDelegate.contactsList` ivar. |
| 5A | `d5c6521` | UIKit iPhone tab shell + `PermissionGateViewController` (UIContentUnavailableConfiguration for the three Contacts-auth states, swaps to UITabBarController once `.authorized`). AppDelegate lifts `eventsRepository` off Catalyst-only gate; centralizes `migrateEventsIfNeeded` + `.CNContactStoreDidChange` / `.EKEventStoreChanged` observers. |
| 5B | `74a2470` | Deleted dead SwiftUI iPhone path: `RootView.swift`, `PeopleListView`, `OrganizationsListView`, `EventsListView`, `FavoritesListView`, `View.contactAndEventDestinations()`. |
| 5C | `1bc69b0` | Rewrote stale UI tests for the Phase 5 iPhone UIKit shell (`test_eventsTabShowsComingSoonPlaceholder` → `test_switchingToEventsTabShowsEventsTitle`). |
| 5D | `61e2dcf` | Drop redundant per-VC `.EKEventStoreChanged` / `.CNContactStoreDidChange` observers in `EventsListViewController` now that AppDelegate is single owner. (Favorites VC's observers stay — they rebuild the contact-uuid map, which the AppDelegate fan-out doesn't.) |
| 5E | `a2c03b1` | Bridge SwiftUI `NavigationLink(value: ContactReference/EventReference)` callsites (5 sites in ContactDetailView, ConnectionsSection, EventDetailView) to outer UIKit nav via env-injected `pushContactReference` / `pushEventReference` closures. `injectIPhonePushHandlers` helper binds both closures to the SAME `nav` weakly so chained drill-downs preserve the capture chain. Catalyst silent no-op preserved (Phase 6 TBD). |
| 5F | `c117652`, `1bcebdf` | Polish: XCTSkip the two `SyncService`-cold-launch-racy UI tests with re-enable-ready post-skip bodies; refresh stale `SyncService.swift:451` comment; MIGRATION_STATUS Phase 5 update. (`3aeac96` attempted to skip 2 more tests but the race just relocated to next-alpha; manually reverted in `1bcebdf` to keep the 2 newly-racy tests RED as a deliberate-loud-signal that the SyncService follow-up is the load-bearing fix.) |
| 5G | `f827aa6` | Removed the Catalyst sidebar Settings row: deleted `SidebarTab.settings` + the dead in-app `SettingsView.swift`, dropped the `.settings` SceneDelegate switch arm, and simplified `SidebarViewController.sidebarTabs` to `allCases` (the platform filter is gone). Settings now lives ONLY in `Settings.bundle` on both platforms — Catalyst auto-renders it into the ⌘, preferences window; iOS/iPadOS show it in system Settings.app. |

### Phase 5 — iPhone UIKit migration + Catalyst cleanup (DONE)

Destructively migrated the iPhone path off `RootView` (SwiftUI
TabView) to a UIKit shell rooted on
`PermissionGateViewController` wrapping a `UITabBarController` of the
four UIKit list view controllers Catalyst already hosts. Tab selection
PUSHES a `UIHostingController(rootView: ContactDetailView/EventDetailView)`
onto the owning tab's nav stack (vs Catalyst's column REPLACE).

`AppDelegate.eventsRepository` is no longer Catalyst-gated; iPhone
consumes the same AppDelegate-owned `contactsRepository` /
`eventsRepository` Catalyst does. `service.migrateEventsIfNeeded()`
and the `.CNContactStoreDidChange` / `.EKEventStoreChanged` observers
moved into the AppDelegate as a single owner; the
`requestContactsAccessIfNeeded` / `requestEventsAccessIfNeeded` async
calls moved into the gate VC's `viewDidAppear`.

`RootView.swift`, the four SwiftUI list views (`PeopleListView`,
`OrganizationsListView`, `EventsListView`, `FavoritesListView`), and
the now-unused `View.contactAndEventDestinations()` modifier are
deleted. `ContactReference` / `EventReference` types stay — still used
inside the detail views.

`SceneDelegate.contactsList` ivar dropped. Worker A landed the Phase 4
deferred items bundle (Favorites VC redundant-apply + multi-drag
IndexSet, Events VC banner reflow, `.favoritesDidChange` rawValue
casing). Worker A's per-VC `.EKEventStoreChanged` /
`.CNContactStoreDidChange` observers on EventsListVC were dropped in a
follow-up commit — the AppDelegate's single-owner observers fan the
reload out via `.eventsRepositoryDidReload` already.

`NavigationLink(value: ContactReference|EventReference)` callsites in
hosted detail views silently no-op'd after `.contactAndEventDestinations`
went away (the outer container is UIKit, not a SwiftUI NavigationStack).
Fixed in a follow-up commit: a bridge through env-injected closures
(`EnvironmentValues.pushContactReference` / `pushEventReference` in
`Support/ReferenceNavigation.swift`) lets SwiftUI rows call back into
the outer `UINavigationController` to push fresh detail VCs. Five
callsites in `ContactDetailView` / `ConnectionsSection` /
`EventDetailView` converted from `NavigationLink(value:)` to
`Button { push…Reference(...) }`. Catalyst intentionally does NOT
inject the closures yet — column-replace drill-down semantics are a
separate question, deferred to Phase 6.

iPad regular-width currently lands on the iPhone tab shell —
documented in code at `SceneDelegate.makeIPhoneRoot`. Phase 6 will
revisit alongside the Catalyst-shaped `UISplitViewController` lift on
iPad and the Catalyst-side NavigationLink drill-down using the same
bridge introduced here.

## Constraints (must respect)

- **iPhone uses the same UIKit list VCs as Catalyst.** Phase 5 made
  this symmetric — don't reintroduce a SwiftUI list-view path on
  iPhone. New features land in the shared UIKit list controllers.
- **iCloud entitlement is on both platforms.** Catalyst entitlements
  file is byte-identical to iOS — same iCloud container, same
  `CloudDocuments` service, so iOS↔Catalyst sync still works.
- **`SyncService`, `FavoritesListStore`, `ContactsRepository`,
  `EventsRepository` are singletons** owned by the AppDelegate.
  SceneDelegate `guard let`s the AppDelegate and `fatalError`s if
  missing — don't reintroduce a fallback that double-constructs them.
- **Catalyst detail swap REPLACES, never pushes.** Use
  `split.setViewController(_:for: .secondary)`, not a navigation
  push, or detail views accumulate. iPhone is the opposite: PUSH onto
  the owning tab's nav stack so back-swipe pops naturally.
- **`ContactDetailView` reads `@Environment` for `SyncService`,
  `ContactsRepository`, `FavoritesListStore`.** Inject all three on
  the `UIHostingController`'s rootView when mounting. On iPhone,
  ALSO inject `pushContactReference` / `pushEventReference`
  (closures bound to the owning `UINavigationController`) so the
  hosted SwiftUI rows can drill into linked contacts/events through
  the outer UIKit nav stack.
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
  `AppDelegate.init()` (synchronous iCloud container resolution via
  `FileManager.url(forUbiquityContainerIdentifier:)`). Pre-existing;
  hoist off main before shipping. This is the load-bearing fix for
  the iOS UI test suite — today the cold-launch stall surfaces in
  four tests:
    - `test_peopleTabIsDefault` and `test_searchClearShowsAllAgain`
      are `XCTSkip`ed pending this fix (verified at 5s / 15s / 30s
      timeouts — all still red without it). Each test's post-skip
      body holds the original 5s `waitForExistence` ready to go.
    - `test_searchFieldFiltersPeopleList` and
      `test_switchingToEventsTabShowsEventsTitle` currently FAIL on
      cold launch for the same SyncService reason. They are LEFT RED
      deliberately rather than skipped — adding `XCTSkip` to those
      just relocates the race to the next-alpha tests
      (`test_switchingToOrganizationsTabShowsOrganizationsTitle` /
      `test_tappingPersonShowsDetailScreen`), shrinking the suite
      without fixing anything. The two reds are a loud signal that
      this SyncService work is the gating fix; once it lands all four
      tests re-enable and the suite returns to 7/7.
- **Catalyst signed builds need iCloud capability** on the dev
  provisioning profile (portal-side action by Adam).
- **Search has no debounce.** Each keystroke re-runs filter+sort and
  applies a snapshot. Fine for small address books; add a debounce
  if performance matters at scale.
- **iPad regular-width 3-column flow lost.** Phase 5 routes iPad-
  regular through the iPhone tab shell (temporary downgrade from the
  prior SwiftUI `NavigationSplitView`). Phase 6 to restore via the
  Catalyst-shaped `UISplitViewController(.tripleColumn)` on iPad.
- **Catalyst drill-down from hosted detail views still silently
  no-ops.** iPhone fixed via env-injected push closures in the Phase 5
  follow-up; Catalyst intentionally doesn't inject because column-
  replace drill-down semantics (push onto secondary-column nav vs.
  REPLACE the whole secondary column) are TBD. Phase 6.
- **Verify in-app on Catalyst:** SwiftUI `.toolbar` items (star +
  Edit) from `ContactDetailView` should appear in the secondary
  column's nav bar when hosted via `UIHostingController`. Same caveat
  applies to iPhone now that push-chains exist. Build-only
  verification can't catch this; needs a real run.
- **`ContactsListViewController.reloadObserver` is
  `nonisolated(unsafe)`** because today the only strong holder is the
  SceneDelegate, which writes and releases on main. If another holder
  (a UIKit nav-stack hold, a delayed Task, a diagnostic singleton)
  ever takes a strong reference and releases it from off-main, the
  `deinit` read of `reloadObserver` becomes a data race. Re-evaluate
  if more holders appear.

### Resolved in Phase 5

- ~~AppDelegate reloads `ContactsRepository` on iPhone too~~ —
  iPhone now consumes the AppDelegate-owned repo directly; the gate
  is intentionally absent.
- ~~Phase 4 deferred items (favorites apply / drag / events banner
  reflow / store-changed observers / favoritesDidChange casing)~~ —
  landed by Worker A. The EventsListVC store-changed observers
  were subsequently dropped in a Phase 5 follow-up because the
  AppDelegate is the single owner of those observers and fans out via
  the `.eventsRepositoryDidReload` notification.
