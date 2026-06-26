import UIKit
import SwiftUI
import GuessWhoSync
import os.log

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
@objc(GuessWhoSceneDelegate)
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

        // Cold-launch path: if the app was woken by the LinkedIn handoff URL
        // (`guesswho-linkedin://handoff`) the URL arrives here rather than in
        // `scene(_:openURLContexts:)`. Drain it once the window exists so the
        // spike alert has something to present on.
        if !connectionOptions.urlContexts.isEmpty {
            handleLinkedInHandoff(urlContexts: connectionOptions.urlContexts)
        }
    }

    /// Running-app path for the LinkedIn handoff spike. When the
    /// `guesswho-linkedin://handoff` URL is opened while a scene is already
    /// connected, UIKit delivers it here. Distinct from the
    /// `guesswho://contact/<uuid>` identity scheme — only `guesswho-linkedin`
    /// URLs are handled.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleLinkedInHandoff(urlContexts: URLContexts)
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
    /// Settings has no sidebar row: the Debug Mode toggle is reached
    /// through the system Settings app via the bundled `Settings.bundle`
    /// (Catalyst auto-renders it into the ⌘, preferences window).
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
            // The supplementary column hosts a UINavigationController; selecting a
            // group PUSHES the members list onto it (back-button returns to the
            // group list), and selecting a member REPLACES the secondary/detail
            // column via `showContactDetail` — the established Catalyst pattern.
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
    /// `showContactDetail`, matching how the People list drives detail on Catalyst.
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

    private func showContactDetail(contact: Contact, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }
        // No extra `.id(...)` modifier here: `setViewController(_:for:
        // .secondary)` replaces the entire hosting controller per selection,
        // so a fresh ContactDetailView + brand-new @State tree is built
        // automatically.
        let nav = UINavigationController()
        // The list VCs vend a `Contact` on selection; re-key it to the opaque
        // `ContactID` the detail view now roots on — the app never threads a
        // raw `localID` through navigation.
        let detail = ContactDetailView(id: contact.contactID)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.contactPhotoLoader)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.viewControllers = [hosting]
        // setViewController REPLACES the secondary column wholesale on
        // every sidebar/list selection — a brand-new nav stack is what
        // we want at the entry point. Drill-down from inside the hosted
        // detail (matched attendees, linked contacts, etc.) pushes onto
        // this same `nav` via the injected env closures.
        split.setViewController(nav, for: .secondary)
    }

    private func showEventDetail(eventUUID: String, eventKitID: String?, appDelegate: GuessWhoAppDelegate) {
        guard let split else { return }
        // `eventKitID` is carried so EventDetailView can adopt
        // ephemeral EventKit rows whose `eventUUID` is the synthetic
        // `Event.stableID(forEventKitID:)` and have no sidecar yet —
        // otherwise the detail view shows "(Unknown event)".
        let nav = UINavigationController()
        let detail = EventDetailView(eventUUID: eventUUID, eventKitID: eventKitID)
            .environment(appDelegate.service)
            .environment(appDelegate.contactsRepository)
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.viewControllers = [hosting]
        split.setViewController(nav, for: .secondary)
    }

    /// Catalyst-side analog of `injectIPhonePushHandlers`. Pushes a
    /// fresh hosted detail onto the SAME secondary-column nav
    /// controller so the user can back-swipe / tap the nav-bar back
    /// button to return to the originating detail. The list/sidebar
    /// entry points still REPLACE the secondary column via
    /// `setViewController(_:for: .secondary)` — only in-detail
    /// drill-downs push.
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
            .environment(appDelegate.favoritesStore)
        let hosting = UIHostingController(
            rootView: injectCatalystPushHandlers(detail, on: nav, appDelegate: appDelegate)
        )
        nav.pushViewController(hosting, animated: true)
    }

    /// Bind the SwiftUI env push closures to the supplied secondary-
    /// column nav controller. Both closures capture `nav` and `self`
    /// weakly so popping the stack or tearing down the scene doesn't
    /// keep this delegate or its column alive.
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

    /// Neutral placeholder used only at scene-connection time before the
    /// sidebar's `selectInitialTab()` invokes `didSelectTab` and a
    /// tab-specific placeholder takes over.
    private func installInitialDetailPlaceholder(in split: UISplitViewController) {
        let detail = PlaceholderViewController(
            title: "Nothing Selected",
            message: "Pick a section from the sidebar."
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
    /// SwiftUI RootView showed (notDetermined / denied / restricted)
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
        let groupsNav = makeIPhoneGroupsTab(appDelegate: appDelegate)

        let tabs = UITabBarController()
        // Order matches the sidebar's `SidebarTab.allCases`: Favorites first,
        // then People, Organizations, Events, and Groups last.
        tabs.viewControllers = [favoritesNav, peopleNav, orgsNav, eventsNav, groupsNav]
        // Re-tapping the active tab scrolls its list to top — an iPhone /
        // iPad tab-shell behavior. The `UITabBarControllerDelegate`
        // conformance that drives it is `#if !targetEnvironment(macCatalyst)`
        // (Catalyst uses the split-view shell, which has no tab bar), so the
        // assignment must be guarded the same way to keep both sides in sync.
        #if !targetEnvironment(macCatalyst)
        tabs.delegate = self
        #endif

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
        let list = ContactsListViewController(
            repository: appDelegate.contactsRepository,
            photoLoader: appDelegate.contactPhotoLoader
        )
        list.didSelectContact = { [weak self] contact in
            self?.pushContactDetail(contact: contact, on: list.navigationController, appDelegate: appDelegate)
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

    /// Groups tab (LAST). A `GroupsListViewController` rooted in its own nav
    /// stack; selecting a group PUSHES a `GroupMembersListViewController` onto
    /// the same nav, and selecting a member PUSHES the contact detail — the same
    /// push-to-drill-in flow the People tab uses.
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

    /// Push a `GroupMembersListViewController` for `group` onto `nav`, wiring its
    /// member selection to push the contact detail onto the same stack. Used by
    /// the iPhone Groups tab (and shaped to match `pushContactDetail`).
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

    /// Push a fresh `UIHostingController<ContactDetailView>` onto the
    /// owning tab's nav stack. Mirrors `showContactDetail` on Catalyst
    /// but PUSHES (back-swipe pops) instead of REPLACING the secondary
    /// column. Same three @Environment values
    /// (`SyncService`, `ContactsRepository`, `FavoritesListStore`)
    /// must be injected on the rootView because the hosted SwiftUI
    /// view has no SwiftUI parent on iPhone now that RootView is gone.
    ///
    /// Also injects the `pushContactReference` / `pushEventReference`
    /// env closures so SwiftUI rows inside the pushed detail (linked
    /// events on a contact, attendees on an event, etc.) can fan out
    /// to more details onto the same UIKit nav stack. Without those,
    /// the original `NavigationLink(value:)` callsites silently no-op
    /// on iPhone after Phase 5 deleted `.contactAndEventDestinations`.
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
        appDelegate: GuessWhoAppDelegate
    ) {
        guard let nav else { return }
        let detail = injectIPhonePushHandlers(
            ContactDetailView(id: id)
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
                .environment(appDelegate.favoritesStore),
            on: nav,
            appDelegate: appDelegate
        )
        let hosting = UIHostingController(rootView: detail)
        nav.pushViewController(hosting, animated: true)
    }

    /// Bind `pushContactReference` / `pushEventReference` to the SAME
    /// nav controller this view is being pushed onto. Both closures
    /// capture `nav` weakly so popping the stack tears down cleanly,
    /// and `self` weakly so the closure can't keep the SceneDelegate
    /// alive past scene teardown.
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
    /// Read from the `GuessWhoAppGroup` Info.plist key (fed by
    /// `GUESSWHO_APP_GROUP` in the xcconfig) so it matches the per-platform
    /// entitlement — `group.`-prefixed on iOS, `<TeamID>.`-prefixed on Mac
    /// Catalyst. Used ONLY for the ephemeral handoff file the extension parks;
    /// synced GuessWho data lives in the iCloud ubiquity container, never here.
    private static let handoffAppGroupID: String =
        Bundle.main.object(forInfoDictionaryKey: "GuessWhoAppGroup") as? String
            ?? "group.com.milestonemade.guesswho"

    /// Filename the extension's native handler writes into the App Group.
    private static let handoffFilename = "pending-handoff.json"

    /// Upper bound on the handoff file we will read into memory. The payload now
    /// carries the full-res profile photo as a base64 data URL inside the JSON,
    /// so it's larger than the old text-only handoff but still bounded. An
    /// 800x800 profile JPEG is ~tens–hundreds of KB; base64 inflates ~33% and the
    /// JSON wraps it — 8 MB is generous headroom while still rejecting an
    /// unexpectedly huge or hostile file. Never read unbounded.
    private static let handoffMaxBytes = 8 * 1024 * 1024

    private static let handoffLog = Logger(
        subsystem: "com.milestonemade.guesswho",
        category: "linkedin-handoff"
    )

    /// Drains a LinkedIn handoff wake. Only `guesswho-linkedin://handoff`
    /// URLs are acted on; anything else (including the `guesswho://` identity
    /// scheme, which never reaches this scene type) is ignored. Reads and
    /// clears the App Group payload, logs it, and shows a spike alert.
    private func handleLinkedInHandoff(urlContexts: Set<UIOpenURLContext>) {
        let isHandoff = urlContexts.contains { context in
            context.url.scheme == "guesswho-linkedin"
        }
        guard isHandoff else { return }

        Self.handoffLog.log("APP resolved App Group id=\(Self.handoffAppGroupID, privacy: .public)")
        Self.handoffLog.log("LinkedIn handoff wake received")

        guard let data = readAndClearHandoffPayload() else { return }

        // Decode the envelope ({ stampedBy, payload: {...} }) into the
        // package-vended LinkedInProfile, then ask the package to match it.
        let profile: LinkedInProfile
        do {
            let envelope = try JSONDecoder().decode(HandoffEnvelope.self, from: data)
            profile = envelope.payload
        } catch {
            Self.handoffLog.error("decode: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate else { return }
        let repo = appDelegate.contactsRepository
        let matches = repo.matchLinkedIn(profile: profile)
        Self.handoffLog.log(
            "match: \(matches.count) contact(s) for \(profile.fullName ?? "?", privacy: .public) (url=\(profile.contactInfo?.profileUrl ?? "-", privacy: .public))"
        )

        // No match: a new-contact screen is a later step. For now, log and stop.
        guard let matchID = matches.first, let contact = repo.contact(id: matchID) else {
            Self.handoffLog.log("match: none — new-contact flow not built yet")
            return
        }

        let rows = LinkedInDiff.rows(existing: contact, incoming: profile)
        let incomingPhoto = profile.photo.flatMap { Self.image(fromDataURL: $0.dataURL) }

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
            onConfirm: { [weak self] selected in
                self?.dismissPresented()
                // Saving lands in the next step; log the chosen fields for now.
                Self.handoffLog.log("confirm: save fields \(selected.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
            },
            onCancel: { [weak self] in self?.dismissPresented() }
        )

        let hosting = UIHostingController(rootView: confirm)
        hosting.modalPresentationStyle = .formSheet
        // Wider sheet so the two columns (esp. About / multi-line values) have room.
        hosting.preferredContentSize = CGSize(width: 840, height: 660)
        topmostPresenter()?.present(hosting, animated: true)
    }

    /// Decode a base64 `data:` URL into a UIImage. Returns nil if it isn't a
    /// recognizable base64 data URL or the bytes aren't an image.
    private static func image(fromDataURL dataURL: String) -> UIImage? {
        guard let comma = dataURL.range(of: ",") else { return nil }
        let b64 = String(dataURL[comma.upperBound...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
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

    /// The handoff JSON envelope the extension writes: a `payload` object plus a
    /// `stampedBy` marker. The payload is the parsed `LinkedInProfile`.
    private struct HandoffEnvelope: Decodable {
        let payload: LinkedInProfile
    }

    /// Reads `pending-handoff.json` from the App Group container, deletes it
    /// (so the same payload is never replayed), and returns the RAW bytes for
    /// decoding. Returns nil on any failure (this is a receiver, not production
    /// error handling — failures are logged).
    private func readAndClearHandoffPayload() -> Data? {
        Self.handoffLog.log("read: resolving App Group id=\(Self.handoffAppGroupID, privacy: .public)")
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.handoffAppGroupID) else {
            Self.handoffLog.error("read: App Group container unavailable: \(Self.handoffAppGroupID, privacy: .public)")
            return nil
        }

        let fileURL = container.appendingPathComponent(Self.handoffFilename)
        Self.handoffLog.log("read: looking for \(fileURL.path, privacy: .public)")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Self.handoffLog.error("read: No \(Self.handoffFilename, privacy: .public) at \(fileURL.path, privacy: .public)")
            return nil
        }

        do {
            // Cap the read: reject (and clear) an oversized file instead of
            // loading it into memory unbounded.
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
            Self.handoffLog.error("read: failed to read/clear handoff: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}

#if !targetEnvironment(macCatalyst)
extension GuessWhoSceneDelegate: UITabBarControllerDelegate {
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
