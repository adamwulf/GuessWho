import UIKit
import SwiftUI
import GuessWhoSync
import GuessWhoLogging

/// UIKit `UIWindowSceneDelegate` that owns the per-scene `UIWindow`
/// and picks its root view controller based on the build target:
///
/// * Mac Catalyst → a 3-column `UISplitViewController` (sidebar /
///   content / detail); selecting a row REPLACES the secondary column.
/// * iPhone and iPad regular-width → a `PermissionGateViewController`
///   that swaps between a ContentUnavailable gate and a
///   `UITabBarController` of navigation stacks (Favorites / People /
///   Organizations / Events / Groups); selecting a row PUSHES a
///   `UIHostingController(rootView: ContactDetailView…)` or
///   `EventDetailView` onto the tab's nav stack.
///
/// Both shells reuse the same UIKit list controllers. iPad regular-width
/// lands in the tab shell, not a Catalyst-shaped split view.
@objc(GuessWhoSceneDelegate)
final class GuessWhoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    #if targetEnvironment(macCatalyst)
    /// Strong references to the Catalyst columns so the sidebar callback can
    /// swap supplementary/secondary view controllers on each tab switch without
    /// walking the split's child stack.
    private var split: UISplitViewController?
    private var sidebar: SidebarViewController?
    #endif

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // First scene breadcrumb. `urlContextCount` flags a cold-launch deep
        // link (a handoff wake arrives here, not in `openURLContexts`, when the
        // app wasn't already running), so the wake path is traceable from the
        // scene's very first line.
        Self.lifecycleLog.notice("scene willConnect", [
            "scene": Self.sceneTag(scene),
            "role": scene.session.role.rawValue,
            "activationState": Self.activationStateName(scene.activationState),
            "urlContextCount": connectionOptions.urlContexts.count
        ])

        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate else {
            fatalError("GuessWhoAppDelegate missing during scene connection")
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = makeRootViewController(appDelegate: appDelegate)
        self.window = window
        window.makeKeyAndVisible()

        // Cold-launch path: a LinkedIn handoff URL
        // (`guesswho-linkedin[-debug]://handoff`) that woke the app arrives here, not in
        // `scene(_:openURLContexts:)`. Drain it once the window exists so the
        // spike alert has something to present on.
        if !connectionOptions.urlContexts.isEmpty {
            handleLinkedInHandoff(urlContexts: connectionOptions.urlContexts, entry: "cold-launch")
        }
    }

    /// Running-app path for the LinkedIn handoff spike: UIKit delivers the
    /// `guesswho-linkedin[-debug]://handoff` URL here when a scene is already
    /// connected. Only handoff-scheme URLs (`LinkedInHandoffScheme.scheme`) are
    /// handled, not the `guesswho://contact/<uuid>` identity scheme.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleLinkedInHandoff(urlContexts: URLContexts, entry: "warm-open")
    }

    // MARK: - Scene lifecycle breadcrumbs
    //
    // One log line per UIKit transition. Paired with the handoff breadcrumbs
    // this makes the wake path legible: a `guesswho-linkedin[-debug]://` deep link
    // shows `willEnterForeground` → `openURLContexts`/handoff → `didBecomeActive`
    // when already running, or `willConnect (urlContextCount=1)` on a cold
    // launch. A wake that only foregrounds WITHOUT delivering the URL shows the
    // foreground/active transitions with no handoff line — exactly the "app just
    // opened, nothing happened" symptom we're chasing.

    func sceneWillEnterForeground(_ scene: UIScene) {
        Self.lifecycleLog.notice("scene willEnterForeground", ["scene": Self.sceneTag(scene)])
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        Self.lifecycleLog.notice("scene didBecomeActive", ["scene": Self.sceneTag(scene)])
    }

    func sceneWillResignActive(_ scene: UIScene) {
        Self.lifecycleLog.notice("scene willResignActive", ["scene": Self.sceneTag(scene)])
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        Self.lifecycleLog.notice("scene didEnterBackground", ["scene": Self.sceneTag(scene)])
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Self.lifecycleLog.notice("scene didDisconnect", ["scene": Self.sceneTag(scene)])
    }

    private func makeRootViewController(appDelegate: GuessWhoAppDelegate) -> UIViewController {
        #if targetEnvironment(macCatalyst)
        return makeCatalystSplit(appDelegate: appDelegate)
        #else
        return makeIPhoneRoot(appDelegate: appDelegate)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Catalyst shell. Sidebar selection drives content/detail column swaps
    /// (e.g. .people → ContactsListViewController + ContactDetailView). Settings
    /// has no sidebar row: the Debug Mode toggle is reached through the system
    /// Settings app via the bundled `Settings.bundle`, which Catalyst
    /// auto-renders into the ⌘, preferences window. Picking a tab with no
    /// selected detail resets the secondary column to a "Nothing Selected"
    /// placeholder.
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

        // Seed both columns with placeholders. The sidebar's
        // selectInitialTab() immediately invokes didSelectTab and swaps
        // supplementary to the People list, so these show only if sidebar
        // selection fails.
        let initialContent = PlaceholderViewController(
            title: "Content",
            message: "Pick a section from the sidebar."
        )
        split.setViewController(UINavigationController(rootViewController: initialContent), for: .supplementary)
        installInitialDetailPlaceholder(in: split)

        return split
    }

    private func handleSidebarSelection(_ tab: SidebarTab, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }

        switch tab {
        case .people:
            let list = ContactsListViewController(
                repository: appDelegate.contactsRepository,
                photoLoader: appDelegate.contactPhotoLoader
            )
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            list.didRequestAddContact = { [weak self] in
                self?.createNewContact(appDelegate: appDelegate) { [weak self] created in
                    self?.showContactDetail(contact: created, appDelegate: appDelegate, startsInEditMode: true)
                }
            }
            let nav = UINavigationController(rootViewController: list)
            split.setViewController(nav, for: .supplementary)
            installDetailPlaceholder(in: split, for: .people)

        case .organizations:
            let list = OrganizationsListViewController(
                repository: appDelegate.contactsRepository,
                photoLoader: appDelegate.contactPhotoLoader
            )
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            installDetailPlaceholder(in: split, for: .organizations)

        case .events:
            let list = EventsListViewController(
                repository: appDelegate.eventsRepository,
                service: appDelegate.service
            )
            list.didSelectEvent = { [weak self] event in
                self?.showEventDetail(
                    eventUUID: event.id.uuidString,
                    eventKitID: event.eventKitID,
                    appDelegate: appDelegate
                )
            }
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            installDetailPlaceholder(in: split, for: .events)

        case .favorites:
            let list = FavoritesListViewController(
                store: appDelegate.favoritesStore,
                service: appDelegate.service,
                repository: appDelegate.contactsRepository,
                photoLoader: appDelegate.contactPhotoLoader
            )
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            list.didSelectEvent = { [weak self] event in
                self?.showEventDetail(
                    eventUUID: event.id.uuidString,
                    eventKitID: event.eventKitID,
                    appDelegate: appDelegate
                )
            }
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            installDetailPlaceholder(in: split, for: .favorites)

        case .groups:
            let list = GroupsListViewController(repository: appDelegate.contactsRepository)
            // Selecting a group PUSHES the members list onto the supplementary
            // column's nav (back-button returns to the group list); selecting a
            // member REPLACES the secondary/detail column via
            // `showContactDetail` — the established Catalyst pattern.
            let nav = UINavigationController(rootViewController: list)
            list.didSelectGroup = { [weak self, weak nav] group in
                self?.showGroupMembers(group: group, on: nav, appDelegate: appDelegate)
            }
            split.setViewController(nav, for: .supplementary)
            installDetailPlaceholder(in: split, for: .groups)
        }
    }

    /// Push a `GroupMembersListViewController` for `group` onto the supplementary
    /// column's `nav`. Member selection REPLACES the secondary/detail column via
    /// `showContactDetail`, like the People list.
    private func showGroupMembers(
        group: ContactGroup,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let members = GroupMembersListViewController(
            group: group,
            repository: appDelegate.contactsRepository,
            photoLoader: appDelegate.contactPhotoLoader
        )
        members.didSelectContact = { [weak self] contact in
            self?.showContactDetail(contact: contact, appDelegate: appDelegate)
        }
        nav.pushViewController(members, animated: true)
    }

    private func showContactDetail(
        contact: Contact,
        appDelegate: GuessWhoAppDelegate,
        startsInEditMode: Bool = false
    ) {
        guard let split else { return }
        // No `.id(...)` needed: `setViewController(_:for: .secondary)` replaces
        // the whole hosting controller per selection, so a fresh
        // ContactDetailView + @State tree is built automatically.
        let nav = UINavigationController()
        // List VCs vend a `Contact`; re-key it to the opaque `ContactID` the
        // detail roots on — the app never threads a raw `localID` through
        // navigation.
        let detail = ContactDetailView(id: contact.contactID, startsInEditMode: startsInEditMode)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.contactPhotoLoader)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.viewControllers = [hosting]
        // setViewController REPLACES the secondary column wholesale on every
        // sidebar/list selection — a fresh nav stack at the entry point.
        // Drill-down from inside the hosted detail (matched attendees, linked
        // contacts, etc.) pushes onto this same `nav` via the injected env
        // closures.
        split.setViewController(nav, for: .secondary)
    }

    private func showEventDetail(eventUUID: String, eventKitID: String?, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }
        // `eventKitID` lets EventDetailView adopt ephemeral EventKit rows whose
        // `eventUUID` is the synthetic `Event.stableID(forEventKitID:)` and have
        // no sidecar yet — otherwise the detail shows "(Unknown event)".
        let nav = UINavigationController()
        let detail = EventDetailView(eventUUID: eventUUID, eventKitID: eventKitID)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.contactPhotoLoader)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.viewControllers = [hosting]
        split.setViewController(nav, for: .secondary)
    }

    /// Catalyst-side analog of `injectIPhonePushHandlers`. Pushes a fresh hosted
    /// detail onto the SAME secondary-column nav so back-swipe / the nav-bar back
    /// button returns to the originating detail. List/sidebar entry points still
    /// REPLACE the secondary column via `setViewController(_:for: .secondary)` —
    /// only in-detail drill-downs push.
    private func pushCatalystContactDetail(
        ref: ContactReference,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let detail = ContactDetailView(id: ref.id)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.contactPhotoLoader)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.pushViewController(hosting, animated: true)
    }

    private func pushCatalystEventDetail(
        ref: EventReference,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let detail = EventDetailView(eventUUID: ref.eventUUID, eventKitID: ref.eventKitID)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.contactPhotoLoader)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.pushViewController(hosting, animated: true)
    }

    /// Bind the SwiftUI env push closures to the supplied secondary-column nav.
    /// Both closures capture `nav` and `self` weakly so popping the stack or
    /// tearing down the scene doesn't keep this delegate or its column alive.
    private func injectCatalystPushHandlers<V: View>(
        _ view: V,
        on nav: UINavigationController,
        appDelegate: GuessWhoAppDelegate
    ) -> some View {
        view
            .environment(\.pushContactReference) { [weak self, weak nav] ref in
                self?.pushCatalystContactDetail(ref: ref, on: nav, appDelegate: appDelegate)
            }
            .environment(\.pushEventReference) { [weak self, weak nav] ref in
                self?.pushCatalystEventDetail(ref: ref, on: nav, appDelegate: appDelegate)
            }
    }

    private func installDetailPlaceholder(in split: UISplitViewController, for tab: SidebarTab) {
        let detail = PlaceholderViewController(
            title: tab.detailPlaceholderTitle,
            message: tab.detailPlaceholderMessage
        )
        split.setViewController(UINavigationController(rootViewController: detail), for: .secondary)
    }

    /// Neutral placeholder shown only at scene-connection time, before the
    /// sidebar's `selectInitialTab()` invokes `didSelectTab` and a tab-specific
    /// placeholder takes over.
    private func installInitialDetailPlaceholder(in split: UISplitViewController) {
        let detail = PlaceholderViewController(
            title: "Nothing Selected",
            message: "Pick a section from the sidebar."
        )
        split.setViewController(UINavigationController(rootViewController: detail), for: .secondary)
    }
    #endif

    // MARK: - Shared add-contact flow (both shells)

    /// The "+" add-contact flow, shared by both shells: create a BLANK record
    /// immediately (same brand-new-record semantics as Contacts.app), then hand
    /// it to `show`, which opens the standard detail view already in edit mode —
    /// the new-contact form IS the edit form. `show` runs on the main actor
    /// only after the create succeeded; a failure is logged and shows nothing
    /// (the list is still consistent — nothing was created).
    ///
    /// Shell-agnostic: the caller's `show` closure decides how to present —
    /// Catalyst's People list REPLACES the secondary column via
    /// `showContactDetail`, the iPhone tab shell PUSHES via `pushContactDetail`.
    /// That's why this lives outside the Catalyst `#if`.
    private func createNewContact(
        appDelegate: GuessWhoAppDelegate,
        show: @escaping @MainActor (Contact) -> Void
    ) {
        Task { @MainActor in
            do {
                let created = try await appDelegate.contactsRepository.createContact(Contact())
                Self.contactsLog.notice("add-contact: created blank record")
                show(created)
            } catch {
                Self.contactsLog.error("add-contact: create failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - iPhone / iPad (non-Catalyst) shell

    /// iPhone shell. Same UIKit list VCs the Catalyst sidebar mounts, but the
    /// entry point is a tab bar not a split view, selection PUSHES detail onto
    /// each tab's nav stack instead of REPLACING a secondary column, and there's
    /// no Settings tab (iOS surfaces the Debug toggle via Settings.bundle).
    ///
    /// Wrapped in a `PermissionGateViewController` so the three
    /// Contacts-authorization states (notDetermined / denied / restricted)
    /// surface as `UIContentUnavailableConfiguration`s, swapping to the tabs
    /// only once access flips to `.authorized`.
    ///
    /// iPad regular-width also lands here, not in a Catalyst-shaped split shell.
    private func makeIPhoneRoot(appDelegate: GuessWhoAppDelegate) -> UIViewController {
        let tabs = makeIPhoneTabs(appDelegate: appDelegate)
        return PermissionGateViewController(service: appDelegate.service, tabs: tabs)
    }

    private func makeIPhoneTabs(appDelegate: GuessWhoAppDelegate) -> UITabBarController {
        let peopleNav = makeIPhonePeopleTab(appDelegate: appDelegate)
        let orgsNav = makeIPhoneOrganizationsTab(appDelegate: appDelegate)
        let eventsNav = makeIPhoneEventsTab(appDelegate: appDelegate)
        let favoritesNav = makeIPhoneFavoritesTab(appDelegate: appDelegate)
        let groupsNav = makeIPhoneGroupsTab(appDelegate: appDelegate)

        let tabs = UITabBarController()
        // Order matches the sidebar's `SidebarTab.allCases`: Favorites first,
        // then People, Organizations, Events, and Groups last.
        tabs.viewControllers = [favoritesNav, peopleNav, orgsNav, eventsNav, groupsNav]
        // Re-tapping the active tab scrolls its list to top (iPhone/iPad
        // tab-shell behavior). Its `UITabBarControllerDelegate` conformance is
        // `#if !targetEnvironment(macCatalyst)` — Catalyst's split-view shell has
        // no tab bar — so this assignment must be guarded the same way.
        #if !targetEnvironment(macCatalyst)
        tabs.delegate = self
        #endif

        // iOS 18 sidebar-adaptable tab bar: a bottom tab bar on iPhone (compact),
        // a leading sidebar on iPad (regular). On iOS 17 the API doesn't exist
        // and the plain bottom tab bar is the right fallback.
        if #available(iOS 18.0, *) {
            tabs.mode = .tabSidebar
        }

        return tabs
    }

    private func makeIPhonePeopleTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = ContactsListViewController(
            repository: appDelegate.contactsRepository,
            photoLoader: appDelegate.contactPhotoLoader
        )
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
        }
        list.didRequestAddContact = { [weak self, weak list] in
            self?.createNewContact(appDelegate: appDelegate) { [weak self, weak list] created in
                self?.pushContactDetail(
                    id: created.contactID,
                    on: list?.navigationController,
                    appDelegate: appDelegate,
                    startsInEditMode: true
                )
            }
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.people.title,
            image: UIImage(systemName: SidebarTab.people.systemImage),
            tag: 1
        )
        return nav
    }

    private func makeIPhoneOrganizationsTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = OrganizationsListViewController(
            repository: appDelegate.contactsRepository,
            photoLoader: appDelegate.contactPhotoLoader
        )
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.organizations.title,
            image: UIImage(systemName: SidebarTab.organizations.systemImage),
            tag: 2
        )
        return nav
    }

    private func makeIPhoneEventsTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = EventsListViewController(
            repository: appDelegate.eventsRepository,
            service: appDelegate.service
        )
        list.didSelectEvent = { [weak self] event in
            self?.pushEventDetail(
                eventUUID: event.id.uuidString,
                eventKitID: event.eventKitID,
                on: list.navigationController,
                appDelegate: appDelegate
            )
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.events.title,
            image: UIImage(systemName: SidebarTab.events.systemImage),
            tag: 3
        )
        return nav
    }

    private func makeIPhoneFavoritesTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = FavoritesListViewController(
            store: appDelegate.favoritesStore,
            service: appDelegate.service,
            repository: appDelegate.contactsRepository,
            photoLoader: appDelegate.contactPhotoLoader
        )
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
        }
        list.didSelectEvent = { [weak self] event in
            self?.pushEventDetail(
                eventUUID: event.id.uuidString,
                eventKitID: event.eventKitID,
                on: list.navigationController,
                appDelegate: appDelegate
            )
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.favorites.title,
            image: UIImage(systemName: SidebarTab.favorites.systemImage),
            tag: 0
        )
        return nav
    }

    /// Groups tab (LAST). A `GroupsListViewController` in its own nav stack;
    /// selecting a group PUSHES a `GroupMembersListViewController`, and selecting
    /// a member PUSHES the contact detail — the same push-to-drill-in flow as the
    /// People tab.
    private func makeIPhoneGroupsTab(appDelegate: GuessWhoAppDelegate) -> UINavigationController {
        let list = GroupsListViewController(repository: appDelegate.contactsRepository)
        list.didSelectGroup = { [weak self] group in
            self?.pushGroupMembers(group: group, on: list.navigationController, appDelegate: appDelegate)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.tabBarItem = UITabBarItem(
            title: SidebarTab.groups.title,
            image: UIImage(systemName: SidebarTab.groups.systemImage),
            tag: 4
        )
        return nav
    }

    /// Push a `GroupMembersListViewController` for `group` onto `nav`, wiring
    /// member selection to push the contact detail onto the same stack. Used by
    /// the iPhone Groups tab.
    private func pushGroupMembers(
        group: ContactGroup,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let members = GroupMembersListViewController(
            group: group,
            repository: appDelegate.contactsRepository,
            photoLoader: appDelegate.contactPhotoLoader
        )
        members.didSelectContact = { [weak self, weak nav] contact in
            self?.pushContactDetail(contact: contact, on: nav, appDelegate: appDelegate)
        }
        nav.pushViewController(members, animated: true)
    }

    /// Push a fresh `UIHostingController<ContactDetailView>` onto the owning
    /// tab's nav stack. Mirrors `showContactDetail` on Catalyst but PUSHES
    /// (back-swipe pops) instead of REPLACING the secondary column. The
    /// @Environment values (`SyncService`, `ContactsRepository`,
    /// `ContactPhotoLoader`, `FavoritesListStore`) must be injected on the
    /// rootView because the hosted view has no SwiftUI parent.
    ///
    /// Also injects the `pushContactReference` / `pushEventReference` env
    /// closures so SwiftUI rows inside the pushed detail (linked events on a
    /// contact, attendees on an event, etc.) can fan out onto the same UIKit nav
    /// stack. Without them the `NavigationLink(value:)` callsites silently no-op
    /// on iPhone.
    private func pushContactDetail(
        contact: Contact,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        // List selection vends a `Contact`; re-key it to its opaque `ContactID`
        // so the pushed detail roots on stable GuessWho identity, not localID.
        pushContactDetail(id: contact.contactID, on: nav, appDelegate: appDelegate)
    }

    private func pushContactDetail(
        ref: ContactReference,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        pushContactDetail(id: ref.id, on: nav, appDelegate: appDelegate)
    }

    private func pushContactDetail(
        id: ContactID,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate,
        startsInEditMode: Bool = false
    ) {
        guard let nav else { return }
        let detail = injectIPhonePushHandlers(
            ContactDetailView(id: id, startsInEditMode: startsInEditMode)
                .environment(appDelegate.service)
                .environment(appDelegate.contactsRepository)
                .environment(appDelegate.contactPhotoLoader)
                .environment(appDelegate.favoritesStore),
            on: nav,
            appDelegate: appDelegate
        )
        let hosting = UIHostingController(rootView: detail)
        nav.pushViewController(hosting, animated: true)
    }

    private func pushEventDetail(
        ref: EventReference,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        pushEventDetail(eventUUID: ref.eventUUID, eventKitID: ref.eventKitID, on: nav, appDelegate: appDelegate)
    }

    private func pushEventDetail(
        eventUUID: String,
        eventKitID: String?,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let detail = injectIPhonePushHandlers(
            EventDetailView(eventUUID: eventUUID, eventKitID: eventKitID)
                .environment(appDelegate.service)
                .environment(appDelegate.contactsRepository)
                .environment(appDelegate.contactPhotoLoader)
                .environment(appDelegate.favoritesStore),
            on: nav,
            appDelegate: appDelegate
        )
        let hosting = UIHostingController(rootView: detail)
        nav.pushViewController(hosting, animated: true)
    }

    /// Bind `pushContactReference` / `pushEventReference` to the SAME nav this
    /// view is pushed onto. Both closures capture `nav` weakly so popping the
    /// stack tears down cleanly, and `self` weakly so they can't keep the
    /// SceneDelegate alive past scene teardown.
    private func injectIPhonePushHandlers<V: View>(
        _ view: V,
        on nav: UINavigationController,
        appDelegate: GuessWhoAppDelegate
    ) -> some View {
        view
            .environment(\.pushContactReference) { [weak self, weak nav] ref in
                self?.pushContactDetail(ref: ref, on: nav, appDelegate: appDelegate)
            }
            .environment(\.pushEventReference) { [weak self, weak nav] ref in
                self?.pushEventDetail(ref: ref, on: nav, appDelegate: appDelegate)
            }
    }

    // MARK: - LinkedIn handoff spike (step-0)

    /// App Group shared with the `GuessWhoLinkedIn` Safari Web Extension.
    /// Centralized in `AppGroup.id` (resolved from the `GuessWhoAppGroup`
    /// Info.plist key, fed by `GUESSWHO_APP_GROUP` in the xcconfig) so the
    /// derivation lives in one place. Holds ONLY the ephemeral handoff file the
    /// extension parks; synced GuessWho data lives in the iCloud ubiquity
    /// container, never here.
    private static let handoffAppGroupID: String = AppGroup.id

    /// Filename the extension's native handler writes into the App Group.
    private static let handoffFilename = "pending-handoff.json"

    /// Upper bound on the handoff payload we read into memory. The payload
    /// carries the full-res profile photo as a base64 data URL in the JSON: an
    /// 800x800 JPEG is ~tens–hundreds of KB, base64 inflates ~33%, and the JSON
    /// wraps it — 8 MB is generous headroom while still rejecting a huge or
    /// hostile payload. Never read unbounded. Internal (not private) because
    /// the Chrome-handoff listener (`LinkedInLocalhostReceiver`, constructed in
    /// `GuessWhoAppDelegate`) caps its POST bodies with the SAME bound.
    static let handoffMaxBytes = 8 * 1024 * 1024

    /// LinkedIn-handoff breadcrumbs route through swift-log to
    /// `<AppGroup>/Logs/app.log` (echoed to Console via the stderr handler).
    /// Developer-facing label; see GuessWhoLogging notes.
    private static let handoffLog = GuessWhoLog.logger("app.linkedin-handoff")

    /// Per-scene lifecycle breadcrumbs. Every scene transition (connect →
    /// foreground → active → resign → background → disconnect) is logged to
    /// `<AppGroup>/Logs/app.log` alongside the handoff breadcrumbs. The
    /// `session.persistentIdentifier` tags each line so multi-window scenes
    /// (Catalyst/iPad) stay distinguishable. Developer-facing label; see
    /// GuessWhoLogging notes.
    private static let lifecycleLog = GuessWhoLog.logger("app.lifecycle.scene")

    /// Contact-creation breadcrumbs for the "+" add-contact flow (the LinkedIn
    /// import logs on `handoffLog` instead, keeping its whole timeline in one
    /// label).
    private static let contactsLog = GuessWhoLog.logger("app.contacts")

    /// Stable short tag for the scene driving a log line, so multi-window scenes
    /// stay distinguishable without dumping the full session identifier.
    private static func sceneTag(_ scene: UIScene) -> String {
        scene.session.persistentIdentifier
    }

    /// Human-readable name for a `UIScene.ActivationState`, so the logged
    /// timeline reads "foregroundActive" rather than a bare enum rawValue.
    private static func activationStateName(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .unattached: return "unattached"
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    /// Drains a LinkedIn handoff wake. Acts only on URLs with the
    /// per-configuration handoff scheme (`LinkedInHandoffScheme.scheme`,
    /// `guesswho-linkedin[-debug]`); anything else (including the `guesswho://`
    /// identity scheme, which never reaches this scene type) is ignored. Reads
    /// and clears the App Group payload, logs it, and shows a spike alert.
    ///
    /// - Parameter entry: which UIKit delivery path called us — `"cold-launch"`
    ///   (`scene(_:willConnectTo:)`) or `"warm-open"`
    ///   (`scene(_:openURLContexts:)`). A web-side wake that reaches the app logs
    ///   exactly one of these; if neither appears, the URL never crossed the
    ///   boundary (the "app just opened, nothing happened" symptom).
    private func handleLinkedInHandoff(urlContexts: Set<UIOpenURLContext>, entry: String) {
        // Log EVERY scheme that arrived, not just the handoff one — otherwise a
        // wake that drops the URL or delivers an unexpected scheme is invisible.
        // This line is the app-side proof the deep link did (or did not) cross
        // from the web context.
        let schemes = urlContexts.compactMap { $0.url.scheme }.sorted()
        Self.handoffLog.notice("wake URL(s) received", [
            "entry": entry,
            "count": urlContexts.count,
            "schemes": schemes.joined(separator: ",")
        ])

        let isHandoff = urlContexts.contains { context in
            context.url.scheme == LinkedInHandoffScheme.scheme
        }
        guard isHandoff else {
            // Not our scheme (e.g. the `guesswho://` identity URL). Log the
            // ignore so it isn't a silent return.
            Self.handoffLog.notice("not a LinkedIn handoff — ignoring", ["schemes": schemes.joined(separator: ",")])
            return
        }

        Self.handoffLog.notice("APP resolved App Group id=\(Self.handoffAppGroupID)")
        Self.handoffLog.notice("LinkedIn handoff wake received", ["entry": entry])

        guard let data = readAndClearHandoffPayload() else { return }
        processLinkedInHandoff(data: data, entry: entry)
    }

    /// Runs the match → diff → confirm → save pipeline on a raw handoff
    /// payload (the `{ stampedBy, payload }` envelope JSON). This is the
    /// transport-independent half of the handoff: the Safari path reaches it by
    /// draining the App-Group parked file on a wake URL
    /// (`handleLinkedInHandoff` above); the Chrome/Brave path reaches it from
    /// `GuessWhoAppDelegate` when `LinkedInLocalhostReceiver` accepts a POST
    /// from the extension. Internal (not private) for that app-delegate caller.
    /// Main-thread only — it presents UIKit.
    ///
    /// - Parameter entry: which transport delivered the payload
    ///   (`"cold-launch"` / `"warm-open"` for Safari wakes,
    ///   `"chrome-localhost"` for the listener), for the log timeline.
    func processLinkedInHandoff(data: Data, entry: String) {
        Self.handoffLog.notice("processing handoff payload", [
            "entry": entry,
            "bytes": data.count
        ])

        // Decode the envelope ({ stampedBy, payload: {...} }) into the
        // package-vended LinkedInProfile, then ask the package to match it.
        let profile: LinkedInProfile
        do {
            let envelope = try JSONDecoder().decode(HandoffEnvelope.self, from: data)
            profile = envelope.payload
        } catch {
            Self.handoffLog.error("decode: \(error.localizedDescription)")
            return
        }

        // Log the decoded payload (photo elided — its size says enough) so
        // "did field X arrive?" is answerable from app.log alone, without
        // opening the LinkedIn tab's Web Inspector.
        Self.handoffLog.notice("decoded payload: \(Self.payloadDescription(profile))")

        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate else { return }
        let repo = appDelegate.contactsRepository
        let matches = repo.matchLinkedIn(profile: profile)
        Self.handoffLog.notice(
            "match: \(matches.count) contact(s) for \(profile.fullName ?? "?") (url=\(profile.contactInfo?.profileUrl ?? "-"))"
        )

        // No match: CREATE the contact from the profile and open it in the
        // detail column already editing — same create-then-edit shape as the
        // "+" add-contact flow (no sheet, no separate new-contact form).
        guard let matchID = matches.first, let contact = repo.contact(id: matchID) else {
            Self.handoffLog.notice("match: none — creating contact from profile")
            createLinkedInContact(profile: profile, appDelegate: appDelegate)
            return
        }

        // Headline / About / Location live as named sidecar fields, not on the
        // CNContact — read them so the diff shows current values on the
        // existing side (and marks unchanged rows). `fields(for:)` returns []
        // for an unreconciled contact, so this is empty in that case.
        let existingSidecar = Self.existingSidecarFields(repo.fields(for: matchID))
        let rows = LinkedInDiff.rows(existing: contact, incoming: profile, existingSidecar: existingSidecar)
        Task {
            await presentLinkedInConfirmSheet(
                profile: profile, matchID: matchID, contact: contact, rows: rows
            )
        }
    }

    /// Decode the incoming photo OFF the main thread (full-res LinkedIn
    /// photos run to megabytes of base64), then build and present the
    /// confirm sheet. Split from `processLinkedInHandoff` solely so the
    /// decode can be awaited; presentation stays on the main actor.
    private func presentLinkedInConfirmSheet(
        profile: LinkedInProfile,
        matchID: ContactID,
        contact: Contact,
        rows: [LinkedInDiffRow]
    ) async {
        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate else { return }
        let repo = appDelegate.contactsRepository
        let photoPayload = profile.photo
        let incomingPhoto = await Task.detached(priority: .userInitiated) {
            photoPayload?.decodedData().flatMap { UIImage(data: $0) }
        }.value

        let confirm = LinkedInConfirmView(
            contactID: matchID,
            contactDisplayName: contact.displayName,
            rows: rows,
            incomingPhoto: incomingPhoto,
            loadExistingPhoto: { [weak repo] in
                guard let repo else { return nil }
                let photo = try? await repo.contactPhotoData(for: matchID, kind: .thumbnail)
                return photo.flatMap { UIImage(data: $0.data) }
            },
            onConfirm: { [weak self, weak repo] selected in
                self?.dismissPresented()
                guard let repo else { return }
                let fields = Self.packageFields(from: selected)
                Self.handoffLog.notice("confirm: applying \(fields.map(\.rawValue).sorted().joined(separator: ","))")
                Task {
                    do {
                        let updated = try await repo.applyLinkedIn(profile: profile, to: matchID, fields: fields)
                        Self.handoffLog.notice("confirm: saved \(updated.givenName) \(updated.familyName)")
                    } catch {
                        // Tell the user, not just the log — a silent failure
                        // here reads as "saved" (the sheet is already gone).
                        Self.handoffLog.error("confirm: apply failed: \(error.localizedDescription)")
                        await MainActor.run {
                            self?.presentLinkedInApplyFailureAlert(error: error)
                        }
                    }
                    // Nudge an open ContactDetailView to reload: applyLinkedIn
                    // freshens the package cache, but the SwiftUI view won't
                    // re-read until told. Posted on failure too — applyLinkedIn
                    // can partially apply (the card save lands before a later
                    // sidecar/photo step throws), so the open card should
                    // re-read either way.
                    await MainActor.run {
                        NotificationCenter.default.post(name: .linkedInImportDidSave, object: nil)
                    }
                }
            },
            onCancel: { [weak self] in self?.dismissPresented() }
        )

        let hosting = UIHostingController(rootView: confirm)
        hosting.modalPresentationStyle = .formSheet
        // Wider sheet so the two columns (esp. About / multi-line values) have room.
        hosting.preferredContentSize = CGSize(width: 840, height: 660)
        // Present from the topmost VC. With no presenter (window not yet key, or
        // a teardown race) the sheet would silently never appear — log that
        // instead. Resolve the presenter BEFORE the "presenting" line so a
        // failure reads as a clean "NO presenter available", not "presenting"
        // followed by a contradiction.
        guard let presenter = topmostPresenter() else {
            Self.handoffLog.error("diff: NO presenter available — confirm sheet not shown")
            return
        }
        Self.handoffLog.notice("diff: presenting confirm sheet", [
            "contact": contact.displayName,
            "rows": rows.count
        ])
        presenter.present(hosting, animated: true)
    }

    /// No-match half of the LinkedIn import: CREATE the contact immediately
    /// from the parsed profile (the `LinkedInContactSeed` card fields), attach
    /// the extras a CN card can't hold (headline/about/location sidecar
    /// fields, photo), then open the standard detail view in the detail column
    /// already in edit mode — the same create-then-edit shape as the "+"
    /// add-contact flow, not a sheet. The user reviews/fixes the imported
    /// values in place; deleting the card is the undo.
    private func createLinkedInContact(profile: LinkedInProfile, appDelegate: GuessWhoAppDelegate) {
        let repo = appDelegate.contactsRepository
        Task { @MainActor in
            var created: Contact
            do {
                created = try await repo.createContact(LinkedInContactSeed.contact(from: profile))
                Self.handoffLog.notice("new-contact: created", ["name": created.displayName])
            } catch {
                Self.handoffLog.error("new-contact: create failed: \(error.localizedDescription)")
                return
            }

            // One applyLinkedIn call attaches everything the card fields can't
            // carry — it skips empty per-field values and an
            // unchanged/undecodable photo itself; the any-content check just
            // avoids a pointless CNContact re-save when the profile carries no
            // extras. Best-effort: a failure here still shows the created card.
            do {
                var extras: Set<LinkedInField> = []
                let hasSidecarContent = [profile.headline, profile.about, profile.location]
                    .contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                if hasSidecarContent { extras.formUnion([.headline, .about, .location]) }
                // Presence check only — applyLinkedIn itself skips an
                // undecodable/unchanged photo, so don't base64-decode the
                // full payload here just to test emptiness.
                if profile.photo != nil { extras.insert(.photo) }
                if !extras.isEmpty {
                    // Reassign: applyLinkedIn's sidecar writes mint the GuessWho
                    // ID, and the returned contact carries the post-mint identity
                    // the detail view should root on.
                    created = try await repo.applyLinkedIn(profile: profile, to: created.contactID, fields: extras)
                    Self.handoffLog.notice(
                        "new-contact: attached \(extras.map(\.rawValue).sorted().joined(separator: ","))"
                    )
                }
            } catch {
                Self.handoffLog.error("new-contact: attaching LinkedIn extras failed: \(error.localizedDescription)")
                // The card itself was created; tell the user the extras
                // (photo/headline/about/location) didn't make it on.
                self.presentLinkedInApplyFailureAlert(error: error)
            }

            NotificationCenter.default.post(name: .linkedInImportDidSave, object: nil)
            // Open the freshly-created card in edit mode, using each shell's
            // own detail-presentation path. Catalyst REPLACES the secondary
            // column; the iPhone/iPad tab shell PUSHES onto the active tab's
            // nav stack. `showContactDetail` only exists under the Catalyst
            // `#if`, so the branch is required to keep the iOS target building.
            #if targetEnvironment(macCatalyst)
            self.showContactDetail(contact: created, appDelegate: appDelegate, startsInEditMode: true)
            #else
            self.pushContactDetail(
                id: created.contactID,
                on: self.activeTabNavigationController(),
                appDelegate: appDelegate,
                startsInEditMode: true
            )
            #endif
        }
    }

    /// The LinkedIn-sourced sidecar fields (Headline / About / Location) as a
    /// `[name: value]` map for the diff's existing side. Includes only
    /// string-valued fields whose name the import writes; everything else is
    /// ignored.
    private static func existingSidecarFields(_ fields: [SidecarField]) -> [String: String] {
        let names: Set<String> = [
            LinkedInDiff.headlineFieldName,
            LinkedInDiff.aboutFieldName,
            LinkedInDiff.locationFieldName,
        ]
        var out: [String: String] = [:]
        for field in fields where names.contains(field.field) {
            if case .string(let value) = field.value { out[field.field] = value }
        }
        return out
    }

    /// Map the dialog's chosen diff-row fields to the package's `LinkedInField`
    /// set that `applyLinkedIn` understands.
    private static func packageFields(from rows: Set<LinkedInDiffRow.Field>) -> Set<LinkedInField> {
        var out: Set<LinkedInField> = []
        for row in rows {
            switch row {
            case .name: out.insert(.name)
            case .jobTitle: out.insert(.jobTitle)
            case .organization: out.insert(.organization)
            case .headline: out.insert(.headline)
            case .location: out.insert(.location)
            case .about: out.insert(.about)
            case .emails: out.insert(.emails)
            case .websites: out.insert(.websites)
            case .linkedInURL: out.insert(.linkedInURL)
            case .photo: out.insert(.photo)
            }
        }
        return out
    }

    /// The decoded handoff payload as a single loggable line: the profile's
    /// JSON with the photo elided (an 800x800 base64 data URL would swamp the
    /// log), plus the photo's type/size so its presence is still on record.
    private static func payloadDescription(_ profile: LinkedInProfile) -> String {
        var elided = profile
        elided.photo = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(elided))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "<encode failed>"
        let photo = profile.photo
            .map { "photo=\($0.contentType ?? "?") \($0.byteLength ?? 0)B" } ?? "photo=none"
        return "\(json) \(photo)"
    }

    /// The topmost presented view controller to present from (works for the
    /// Catalyst split shell and the iPhone tab/gate shell).
    private func topmostPresenter() -> UIViewController? {
        guard var presenter = window?.rootViewController else { return nil }
        while let presented = presenter.presentedViewController { presenter = presented }
        return presenter
    }

    private func dismissPresented() {
        topmostPresenter()?.dismiss(animated: true)
    }

    /// User-facing alert for a failed LinkedIn apply (matched-contact confirm
    /// or new-contact extras). Plain language only — the developer detail is
    /// already in the log; `saveErrorCategory` owns the message wording, same
    /// as the contact editor's save-failure alert.
    @MainActor
    private func presentLinkedInApplyFailureAlert(error: Error) {
        let category = ContactEditModel.saveErrorCategory(error)
        let alert = UIAlertController(
            title: "Couldn’t Save LinkedIn Info",
            message: category.saveFailureMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        guard let presenter = topmostPresenter() else {
            Self.handoffLog.error("apply-failed alert: NO presenter available")
            return
        }
        presenter.present(alert, animated: true)
    }

    /// The handoff JSON envelope the extension writes: a `payload` object plus a
    /// `stampedBy` marker. The payload is the parsed `LinkedInProfile`.
    private struct HandoffEnvelope: Decodable {
        let payload: LinkedInProfile
    }

    /// Reads `pending-handoff.json` from the App Group container, deletes it (so
    /// the payload is never replayed), and returns the RAW bytes for decoding.
    /// Returns nil on any failure (a receiver, not production error handling —
    /// failures are logged).
    private func readAndClearHandoffPayload() -> Data? {
        Self.handoffLog.notice("read: resolving App Group id=\(Self.handoffAppGroupID)")
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.handoffAppGroupID) else {
            Self.handoffLog.error("read: App Group container unavailable: \(Self.handoffAppGroupID)")
            return nil
        }

        let fileURL = container.appendingPathComponent(Self.handoffFilename)
        Self.handoffLog.notice("read: looking for \(fileURL.path)")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Not an error: a Chrome/Brave-initiated wake parks nothing (its
            // payload arrives over the localhost listener, before or after the
            // wake), and a duplicate Safari wake finds the file already
            // drained. A SAFARI handoff that logs this line IS a problem —
            // check the extension's "park: wrote" line and the App Group ids.
            Self.handoffLog.notice("read: no \(Self.handoffFilename) at \(fileURL.path) — nothing parked (Chrome-flow wake or already drained)")
            return nil
        }

        do {
            // Cap the read: reject and clear an oversized file rather than
            // load it unbounded.
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.handoffMaxBytes {
                try? FileManager.default.removeItem(at: fileURL)
                Self.handoffLog.error("read: handoff file too large (\(size) bytes > \(Self.handoffMaxBytes)); discarded")
                return nil
            }

            let data = try Data(contentsOf: fileURL)
            // Clear immediately so a re-open can't replay a stale handoff.
            try FileManager.default.removeItem(at: fileURL)
            return data
        } catch {
            Self.handoffLog.error("read: failed to read/clear handoff: \(error.localizedDescription)")
            return nil
        }
    }

}

#if !targetEnvironment(macCatalyst)
extension GuessWhoSceneDelegate: UITabBarControllerDelegate {
    /// The active tab's navigation stack in the iPhone/iPad tab shell, so a
    /// programmatic open (e.g. the LinkedIn new-contact flow) can PUSH detail
    /// the same way list selection does. The scene root is a
    /// `PermissionGateViewController` that hosts the `UITabBarController` as a
    /// CHILD once Contacts access is authorized, so we walk the VC tree to find
    /// it rather than assuming a fixed root type. Returns nil before the gate
    /// installs the tabs (access not yet granted); `pushContactDetail`
    /// tolerates a nil nav and no-ops, so the open is simply skipped when
    /// there's nowhere to push.
    private func activeTabNavigationController() -> UINavigationController? {
        guard let root = window?.rootViewController else { return nil }
        guard let tabs = Self.firstTabBarController(in: root) else { return nil }
        return tabs.selectedViewController as? UINavigationController
    }

    /// Depth-first search for the first `UITabBarController` reachable from
    /// `viewController`, following both presented and child view controllers.
    private static func firstTabBarController(in viewController: UIViewController) -> UITabBarController? {
        if let tabs = viewController as? UITabBarController { return tabs }
        if let presented = viewController.presentedViewController,
           let tabs = firstTabBarController(in: presented) {
            return tabs
        }
        for child in viewController.children {
            if let tabs = firstTabBarController(in: child) { return tabs }
        }
        return nil
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        shouldSelect viewController: UIViewController
    ) -> Bool {
        guard tabBarController.selectedViewController === viewController else {
            return true
        }

        scrollReselectedTabToTop(viewController)
        return false
    }

    private func scrollReselectedTabToTop(_ viewController: UIViewController) {
        guard let navigationController = viewController as? UINavigationController else {
            (viewController as? ScrollsToTop)?.scrollToTop(animated: true)
            return
        }

        guard let root = navigationController.viewControllers.first else { return }
        guard let scrollsToTop = root as? ScrollsToTop else { return }

        if navigationController.topViewController === root {
            scrollsToTop.scrollToTop(animated: true)
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            scrollsToTop.scrollToTop(animated: true)
        }
        navigationController.popToRootViewController(animated: true)
        CATransaction.commit()
    }
}
#endif
