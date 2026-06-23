import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit `UIWindowSceneDelegate` that owns the per-scene `UIWindow`
/// and picks its root view controller based on the build target:
///
/// * Mac Catalyst → a 3-column `UISplitViewController` (sidebar /
///   content / detail) — the UIKit shell introduced in Phase 2 and
///   completed in Phases 3 / 4A–C with real list controllers.
/// * iPhone (and iPad until Phase 6) → a `PermissionGateViewController`
///   that swaps between a SwiftUI-parity ContentUnavailable gate and a
///   `UITabBarController` of 4 navigation stacks (People /
///   Organizations / Events / Favorites). Each tab reuses the same
///   UIKit list controller the Catalyst columns host — selection
///   pushes a `UIHostingController(rootView: ContactDetailView…)` or
///   `EventDetailView` onto the tab's nav stack (iPhone uses push
///   semantics; Catalyst uses column REPLACE).
///
/// iPad regular-width loses the 3-column SwiftUI flow this phase —
/// it falls back to the same UIKit tab shell as iPhone-compact until
/// Phase 6 stands up the Catalyst-shaped `UISplitViewController` on
/// iPad too. Documented in MIGRATION_STATUS.
final class GuessWhoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    #if targetEnvironment(macCatalyst)
    /// Strong references to the Catalyst columns so the sidebar
    /// callback can swap supplementary/secondary view controllers on
    /// each tab switch without us walking the split's child stack.
    private var split: UISplitViewController?
    private var sidebar: SidebarViewController?
    #endif

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate else {
            fatalError("GuessWhoAppDelegate missing during scene connection")
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = makeRootViewController(appDelegate: appDelegate)
        self.window = window
        window.makeKeyAndVisible()
    }

    private func makeRootViewController(appDelegate: GuessWhoAppDelegate) -> UIViewController {
        #if targetEnvironment(macCatalyst)
        return makeCatalystSplit(appDelegate: appDelegate)
        #else
        return makeIPhoneRoot(appDelegate: appDelegate)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Phase-3 Catalyst shell. The sidebar's selection now drives real
    /// content/detail column swaps:
    ///   * .people → ContactsListViewController + ContactDetailView on selection
    ///   * .organizations → OrganizationsListViewController + ContactDetailView on selection
    ///   * .settings → SwiftUI SettingsView hosted via UIHostingController
    /// When the user picks a tab that doesn't have a selected detail
    /// the secondary column resets to a "Nothing Selected" placeholder.
    private func makeCatalystSplit(appDelegate: GuessWhoAppDelegate) -> UISplitViewController {
        let split = UISplitViewController(style: .tripleColumn)
        split.preferredDisplayMode = .twoBesideSecondary
        split.preferredSplitBehavior = .tile
        split.primaryBackgroundStyle = .sidebar

        let sidebar = SidebarViewController()
        let sidebarNav = UINavigationController(rootViewController: sidebar)

        split.setViewController(sidebarNav, for: .primary)

        self.split = split
        self.sidebar = sidebar

        sidebar.didSelectTab = { [weak self] tab in
            self?.handleSidebarSelection(tab, appDelegate: appDelegate)
        }

        // Seed both columns with placeholders; the sidebar's
        // selectInitialTab() will immediately invoke didSelectTab and
        // swap supplementary to the People list, so this is only ever
        // visible if sidebar selection somehow fails.
        let initialContent = PlaceholderViewController(
            title: "Content",
            message: "Pick a section from the sidebar."
        )
        split.setViewController(UINavigationController(rootViewController: initialContent), for: .supplementary)
        installDetailPlaceholder(in: split)

        return split
    }

    private func handleSidebarSelection(_ tab: SidebarTab, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }

        switch tab {
        case .people:
            let list = ContactsListViewController(repository: appDelegate.contactsRepository)
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            list.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            list.navigationItem.leftItemsSupplementBackButton = true
            let nav = UINavigationController(rootViewController: list)
            split.setViewController(nav, for: .supplementary)
            installDetailPlaceholder(in: split)

        case .organizations:
            let list = OrganizationsListViewController(repository: appDelegate.contactsRepository)
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            list.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            list.navigationItem.leftItemsSupplementBackButton = true
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            installDetailPlaceholder(in: split)

        case .events:
            let list = EventsListViewController(
                repository: appDelegate.eventsRepository,
                service: appDelegate.service
            )
            list.didSelectEvent = { [weak self] event in
                self?.showEventDetail(eventUUID: event.id.uuidString, appDelegate: appDelegate)
            }
            list.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            list.navigationItem.leftItemsSupplementBackButton = true
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            installDetailPlaceholder(in: split)

        case .favorites:
            let list = FavoritesListViewController(
                store: appDelegate.favoritesStore,
                service: appDelegate.service
            )
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            list.didSelectEvent = { [weak self] event in
                self?.showEventDetail(eventUUID: event.id.uuidString, appDelegate: appDelegate)
            }
            list.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            list.navigationItem.leftItemsSupplementBackButton = true
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            installDetailPlaceholder(in: split)

        case .settings:
            let settings = UIHostingController(rootView: SettingsView())
            settings.title = "Settings"
            settings.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            settings.navigationItem.leftItemsSupplementBackButton = true
            split.setViewController(UINavigationController(rootViewController: settings), for: .supplementary)
            installDetailPlaceholder(in: split)
        }
    }

    private func showContactDetail(contact: Contact, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }
        // No `.id(contact.localID)` here: `setViewController(_:for:
        // .secondary)` replaces the entire hosting controller per
        // selection, so a fresh ContactDetailView + brand-new @State
        // tree is built automatically. The `.id()` modifier would
        // only matter if we were reusing one hosting controller and
        // mutating its rootView's localID (which is what
        // `RootView.detailColumn` does on the SwiftUI iPhone path).
        let detail = ContactDetailView(localID: contact.localID)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(rootView: detail)
        let nav = UINavigationController(rootViewController: hosting)
        // setViewController REPLACES the secondary column wholesale on
        // every selection — pushing onto a stack would accumulate detail
        // views across taps.
        split.setViewController(nav, for: .secondary)
    }

    private func showEventDetail(eventUUID: String, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }
        let detail = EventDetailView(eventUUID: eventUUID)
            .environment(appDelegate.service)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(rootView: detail)
        let nav = UINavigationController(rootViewController: hosting)
        split.setViewController(nav, for: .secondary)
    }

    private func installDetailPlaceholder(in split: UISplitViewController) {
        let detail = PlaceholderViewController(
            title: "Nothing Selected",
            message: "Choose a person from the list to see details."
        )
        split.setViewController(UINavigationController(rootViewController: detail), for: .secondary)
    }
    #endif

    // MARK: - iPhone / iPad (non-Catalyst) shell

    /// Phase-5 iPhone shell. Mirrors the Catalyst structure (the four
    /// content sections are the same UIKit list VCs the sidebar mounts
    /// on Mac), but the entry point is a tab bar instead of a split
    /// view, selection PUSHES detail onto each tab's nav stack instead
    /// of REPLACING a secondary column, and there is no Settings tab
    /// (iOS surfaces the Debug toggle through the system Settings app
    /// via Settings.bundle, matching the pre-Phase-5 SwiftUI behaviour
    /// — see the `sidebarTabs` filter the SwiftUI RootView used).
    ///
    /// Wrapped in a `PermissionGateViewController` so the same three
    /// Contacts-authorization ContentUnavailableView states the
    /// SwiftUI RootView showed (notRequested / denied / restricted)
    /// surface here as `UIContentUnavailableConfiguration`s, swapping
    /// to the tabs only once access flips to `.authorized`.
    ///
    /// iPad regular-width currently also lands here — temporary
    /// downgrade from the previous 3-column NavigationSplitView until
    /// Phase 6 lifts iPad into the Catalyst-shaped `UISplitView` shell.
    private func makeIPhoneRoot(appDelegate: GuessWhoAppDelegate) -> UIViewController {
        let tabs = makeIPhoneTabs(appDelegate: appDelegate)
        return PermissionGateViewController(service: appDelegate.service, tabs: tabs)
    }

    private func makeIPhoneTabs(appDelegate: GuessWhoAppDelegate) -> UITabBarController {
        let peopleNav = makeIPhonePeopleTab(appDelegate: appDelegate)
        let orgsNav = makeIPhoneOrganizationsTab(appDelegate: appDelegate)
        let eventsNav = makeIPhoneEventsTab(appDelegate: appDelegate)
        let favoritesNav = makeIPhoneFavoritesTab(appDelegate: appDelegate)

        let tabs = UITabBarController()
        tabs.viewControllers = [peopleNav, orgsNav, eventsNav, favoritesNav]

        // iOS 18 sidebar-adaptable tab bar surfaces as a bottom tab bar
        // on iPhone (compact) and as a leading sidebar on iPad
        // (regular). Matches the previous SwiftUI `.sidebarAdaptable`
        // tabViewStyle. Gated on iOS 18 — on iOS 17 the API doesn't
        // exist and the plain bottom tab bar is the right fallback.
        if #available(iOS 18.0, *) {
            tabs.mode = .tabSidebar
        }

        return tabs
    }

    private func makeIPhonePeopleTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = ContactsListViewController(repository: appDelegate.contactsRepository)
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.people.title,
            image: UIImage(systemName: SidebarTab.people.systemImage),
            tag: 0
        )
        return nav
    }

    private func makeIPhoneOrganizationsTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = OrganizationsListViewController(repository: appDelegate.contactsRepository)
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.organizations.title,
            image: UIImage(systemName: SidebarTab.organizations.systemImage),
            tag: 1
        )
        return nav
    }

    private func makeIPhoneEventsTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = EventsListViewController(
            repository: appDelegate.eventsRepository,
            service: appDelegate.service
        )
        list.didSelectEvent = { [weak self] event in
            self?.pushEventDetail(eventUUID: event.id.uuidString, on: list.navigationController, appDelegate: appDelegate)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.events.title,
            image: UIImage(systemName: SidebarTab.events.systemImage),
            tag: 2
        )
        return nav
    }

    private func makeIPhoneFavoritesTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = FavoritesListViewController(
            store: appDelegate.favoritesStore,
            service: appDelegate.service
        )
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
        }
        list.didSelectEvent = { [weak self] event in
            self?.pushEventDetail(eventUUID: event.id.uuidString, on: list.navigationController, appDelegate: appDelegate)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.favorites.title,
            image: UIImage(systemName: SidebarTab.favorites.systemImage),
            tag: 3
        )
        return nav
    }

    /// Push a fresh `UIHostingController<ContactDetailView>` onto the
    /// owning tab's nav stack. Mirrors `showContactDetail` on Catalyst
    /// but PUSHES (back-swipe pops) instead of REPLACING the secondary
    /// column. Same three @Environment values
    /// (`SyncService`, `ContactsRepository`, `FavoritesListStore`)
    /// must be injected on the rootView because the hosted SwiftUI
    /// view has no SwiftUI parent on iPhone now that RootView is gone.
    private func pushContactDetail(
        contact: Contact,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let detail = ContactDetailView(localID: contact.localID)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(rootView: detail)
        nav.pushViewController(hosting, animated: true)
    }

    private func pushEventDetail(
        eventUUID: String,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let detail = EventDetailView(eventUUID: eventUUID)
            .environment(appDelegate.service)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(rootView: detail)
        nav.pushViewController(hosting, animated: true)
    }
}
