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

    /// The current UI selection this scene would restore to. Updated as the user
    /// switches sections and opens/closes detail; handed back to the system in
    /// `stateRestorationActivity(for:)` when the scene disconnects. Nil until the
    /// first section is selected. See `RestorationState`.
    private var restorationState: RestorationState?

    /// One-shot observer for the first `contactsRepositoryDidReload`, used to
    /// finish restoring a contact detail when the contacts cache wasn't loaded
    /// yet at scene connect. Cleared on first fire. MainActor-isolated so the
    /// stored `NSObjectProtocol` token never crosses an actor boundary.
    private var restorationReloadObserver: NSObjectProtocol?

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

        // Decode any saved section + record for this scene. On Catalyst a ⌘Q
        // relaunch restores it; on iOS the system restores it after discarding a
        // backgrounded scene. Absent/corrupt → nil → the shell comes up on its
        // default section. Built BEFORE the shell so the section is selected up
        // front (no default → restored flash).
        let restored = RestorationState(userActivity: session.stateRestorationActivity)
        if let restored {
            Self.lifecycleLog.notice("scene restoring", [
                "scene": Self.sceneTag(scene),
                "section": restored.section.rawValue,
                "hasSelection": "\(restored.selection != nil)"
            ])
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = makeRootViewController(appDelegate: appDelegate, restoring: restored)
        self.window = window
        window.makeKeyAndVisible()

        // Reopen the saved detail now that the shell exists and its section is
        // selected. Catalyst restores here (the split is the root and ready);
        // the iPhone shell restores inside `makeIPhoneTabs`, pushing onto the
        // target tab's nav BEFORE the permission gate swaps the tabs on screen
        // (`activeTabNavigationController()` is still nil at this point).
        // Section-only restores need nothing more.
        #if targetEnvironment(macCatalyst)
        if let restored, let selection = restored.selection {
            restoreSelection(selection, on: nil, appDelegate: appDelegate)
        }
        #endif

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
        // Tear down the one-shot restoration reload observer if it never fired
        // (scene discarded before the first contacts reload) so it can't leak per
        // discarded scene in a multi-window session. UIKit guarantees
        // `sceneDidDisconnect` runs before this delegate is released, so this is
        // the complete teardown — no `deinit` fallback needed (and a nonisolated
        // `deinit` can't touch this main-actor-isolated token anyway).
        clearRestorationReloadObserver()
    }

    // MARK: - State restoration

    /// Hand the scene's current section + selected record to the system so it can
    /// be restored on the next launch. On Catalyst a ⌘Q quit + relaunch restores
    /// it; on iPhone/iPad the system restores it when it discards a backgrounded
    /// scene. Returns nil before any section has been shown, in which case the
    /// scene relaunches to its default section.
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard let restorationState else { return nil }
        Self.lifecycleLog.notice("scene stateRestorationActivity", [
            "scene": Self.sceneTag(scene),
            "section": restorationState.section.rawValue,
            "hasSelection": "\(restorationState.selection != nil)"
        ])
        return restorationState.makeUserActivity()
    }

    /// Record the section now showing, clearing any selected record (a
    /// section switch lands on the list/placeholder, no detail). Called from
    /// every section-selection entry point on both shells.
    private func noteSectionShown(_ section: SidebarTab) {
        restorationState = RestorationState(section: section, selection: nil)
    }

    /// Record which record is now open in the detail area, keeping the current
    /// section. No-op if no section has been recorded yet (shouldn't happen — a
    /// detail is always reached through a section).
    ///
    /// `stampedOn`, when supplied, is the view controller now showing this
    /// detail. The selection is stamped onto it so that when the user later
    /// navigates AWAY (pops back to a shallower detail or the list root),
    /// `navigationController(_:didShow:)` can recompute the selection from
    /// whatever is on top — keeping "restore what I'm looking at" accurate after
    /// Back, not just after a forward push.
    private func noteSelectionShown(
        _ selection: RestorationState.Selection,
        stampedOn viewController: UIViewController? = nil
    ) {
        viewController?.gwRestorationSelection = selection
        guard var state = restorationState else { return }
        state.selection = selection
        restorationState = state
    }

    /// Set the current section's selection to whatever detail (if any) the given
    /// top view controller represents. A list root / placeholder carries no
    /// stamped selection, so this CLEARS it — the fix for a detail the user
    /// backed out of being wrongly restored. Keeps the current section.
    private func syncSelectionToTop(_ topViewController: UIViewController?) {
        guard var state = restorationState else { return }
        state.selection = topViewController?.gwRestorationSelection
        restorationState = state
    }

    /// Map an iPhone tab-bar index to its `SidebarTab`. The tab order is built
    /// from `SidebarTab.allCases` (`makeIPhoneTabs`), so the index IS the
    /// `allCases` index. Returns nil for an out-of-range index (defensive).
    /// Not Catalyst-guarded — `makeIPhoneTabs` compiles on Catalyst too.
    static func section(forTabIndex index: Int) -> SidebarTab? {
        let all = SidebarTab.allCases
        guard all.indices.contains(index) else { return nil }
        return all[index]
    }

    private func makeRootViewController(
        appDelegate: GuessWhoAppDelegate,
        restoring: RestorationState?
    ) -> UIViewController {
        #if targetEnvironment(macCatalyst)
        return makeCatalystSplit(appDelegate: appDelegate, restoring: restoring)
        #else
        return makeIPhoneRoot(appDelegate: appDelegate, restoring: restoring)
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
    private func makeCatalystSplit(
        appDelegate: GuessWhoAppDelegate,
        restoring: RestorationState?
    ) -> UISplitViewController {
        let split = UISplitViewController(style: .tripleColumn)
        split.preferredDisplayMode = .twoBesideSecondary
        split.preferredSplitBehavior = .tile
        split.primaryBackgroundStyle = .sidebar

        let sidebar = SidebarViewController()
        // Wire the selection callback and the restored initial tab BEFORE the
        // view can load: `setViewController(_:for: .primary)` may load the
        // sidebar's view, which runs `selectInitialTab()` synchronously, so both
        // must be in place first or the initial selection is lost / misrouted.
        sidebar.didSelectTab = { [weak self] tab in
            self?.handleSidebarSelection(tab, appDelegate: appDelegate)
        }
        sidebar.initialTab = restoring?.section

        let sidebarNav = UINavigationController(rootViewController: sidebar)

        self.split = split
        self.sidebar = sidebar

        split.setViewController(sidebarNav, for: .primary)

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

        // A section switch resets the detail column to a placeholder, so restore
        // to this section with no selected record.
        noteSectionShown(tab)

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
        // Observe pops so backing out of an in-detail drill-down re-syncs the
        // restore selection to whatever detail is left on top.
        nav.delegate = self
        // setViewController REPLACES the secondary column wholesale on every
        // sidebar/list selection — a fresh nav stack at the entry point.
        // Drill-down from inside the hosted detail (matched attendees, linked
        // contacts, etc.) pushes onto this same `nav` via the injected env
        // closures.
        split.setViewController(nav, for: .secondary)
        noteSelectionShown(.contact(contact.contactID.restorationToken), stampedOn: hosting)
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
        nav.delegate = self
        split.setViewController(nav, for: .secondary)
        noteSelectionShown(.event(eventUUID: eventUUID, eventKitID: eventKitID), stampedOn: hosting)
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
        // Restore-to the DEEPEST detail the user drilled into (B scope: reopen
        // what they were looking at, re-rooted — not the full breadcrumb). Stamp
        // the pushed VC so a later Back re-syncs to the shallower detail.
        noteSelectionShown(.contact(ref.id.restorationToken), stampedOn: hosting)
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
        noteSelectionShown(.event(eventUUID: ref.eventUUID, eventKitID: ref.eventKitID), stampedOn: hosting)
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

    // MARK: - State restoration: reopen the saved detail

    /// Reopen the record that was showing when the app quit, using each shell's
    /// own detail-presentation path. The section is already selected (built into
    /// the shell), so this only layers the detail on top.
    ///
    /// A contact token resolves through the repository's reconcile-stable path
    /// (`contact(restorationToken:)`); if it can't resolve — the contact was
    /// deleted, or a device-local `localID` moved — we simply leave the section
    /// showing its list, never a wrong contact. Events reopen directly from their
    /// durable `eventUUID` (+ `eventKitID` for pre-adoption EventKit rows).
    ///
    /// `nav` is the target section's navigation controller. On Catalyst it is
    /// unused — the detail REPLACES the secondary column; on iPhone the detail is
    /// PUSHED onto `nav`. The nav may be off-screen (the iPhone permission gate
    /// installs the tab bar later) — a push onto a not-yet-visible nav is valid,
    /// so the detail is already on the stack when the gate swaps the tabs in.
    private func restoreSelection(
        _ selection: RestorationState.Selection,
        on nav: UINavigationController?,
        appDelegate: GuessWhoAppDelegate
    ) {
        switch selection {
        case .contact(let token):
            // The contacts cache may not be loaded yet at cold-launch scene
            // connect (the repository's initial `reload()` runs in a Task kicked
            // off from `didFinishLaunching`). Resolve asynchronously: try now,
            // and if the cache is empty, wait for the first reload before
            // deciding the contact is really gone.
            resolveRestoredContact(token: token, appDelegate: appDelegate) { [weak self, weak nav] contact in
                guard let self, let contact else {
                    Self.lifecycleLog.notice("restore: contact not found — section only")
                    return
                }
                #if targetEnvironment(macCatalyst)
                self.showContactDetail(contact: contact, appDelegate: appDelegate)
                #else
                self.pushContactDetail(contact: contact, on: nav, appDelegate: appDelegate)
                #endif
            }

        case .event(let eventUUID, let eventKitID):
            // Events reopen straight from their durable UUID — `EventDetailView`
            // does its own async load, so no cache wait is needed here.
            #if targetEnvironment(macCatalyst)
            showEventDetail(eventUUID: eventUUID, eventKitID: eventKitID, appDelegate: appDelegate)
            #else
            pushEventDetail(eventUUID: eventUUID, eventKitID: eventKitID, on: nav, appDelegate: appDelegate)
            #endif
        }
    }

    /// Resolve a restored contact token to a `Contact`, waiting for the
    /// repository's initial load if the cache is still empty. Calls `completion`
    /// on the main actor with the resolved contact, or nil if it can't be found
    /// even after the first reload (genuinely deleted, or a moved device-local
    /// `localID`).
    ///
    /// A nil from `contact(restorationToken:)` at cold launch is ambiguous —
    /// "cache not loaded yet" vs. "deleted." Waiting for the first CONTACTS
    /// reload disambiguates: after it, nil means gone. If the cache is already
    /// populated (warm scene connect), it resolves synchronously without waiting.
    ///
    /// It waits specifically for a `contactDataChanged: true` post — the actual
    /// `reload()` completing. `.contactsRepositoryDidReload` is ALSO posted with
    /// `contactDataChanged: false` for presentation-only refreshes (a Groups
    /// fetch from the Groups tab's `viewDidLoad`, a sort flip, a photo write); if
    /// one of those won the race we would re-check a still-empty cache and give
    /// up, losing the restore. Filtering to `true` ignores those lighter posts.
    @MainActor
    private func resolveRestoredContact(
        token: ContactRestorationToken,
        appDelegate: GuessWhoAppDelegate,
        completion: @escaping @MainActor (Contact?) -> Void
    ) {
        let repository = appDelegate.contactsRepository
        if let contact = repository.contact(restorationToken: token) {
            completion(contact)
            return
        }

        // Cache empty so far. Wait for the first post that could actually
        // populate the cache, then resolve once more. The observer token is held
        // on `self` (MainActor-isolated) rather than captured into the @Sendable
        // closure, so nothing non-Sendable crosses an actor boundary. Delivered
        // on `.main`; torn down here and in `sceneDidDisconnect` if it never
        // fires.
        restorationReloadObserver = NotificationCenter.default.addObserver(
            forName: .contactsRepositoryDidReload,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Skip presentation-only posts (contactDataChanged:false — a Groups
            // fetch from the Groups tab's viewDidLoad, a sort flip, a photo
            // write): those don't populate the contacts cache, so re-resolving
            // against it would still miss and wrongly give up. Any data-changing
            // post (true — the reload() fetch and other record mutations) is a
            // valid moment to retry. A missing key defaults to true (retry).
            let dataChanged = (note.userInfo?[ContactsRepositoryDidReloadKey.contactDataChanged] as? Bool) ?? true
            guard dataChanged else { return }
            MainActor.assumeIsolated {
                self?.clearRestorationReloadObserver()
                completion(repository.contact(restorationToken: token))
            }
        }
    }

    /// Remove the one-shot restoration reload observer if it is still registered.
    /// Safe to call when it was never set. Called on first fire and on scene
    /// teardown so a scene discarded before the first reload doesn't leak it.
    @MainActor
    private func clearRestorationReloadObserver() {
        if let observer = restorationReloadObserver {
            NotificationCenter.default.removeObserver(observer)
            restorationReloadObserver = nil
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
    private func makeIPhoneRoot(
        appDelegate: GuessWhoAppDelegate,
        restoring: RestorationState?
    ) -> UIViewController {
        let tabs = makeIPhoneTabs(appDelegate: appDelegate, restoring: restoring)
        return PermissionGateViewController(service: appDelegate.service, tabs: tabs)
    }

    private func makeIPhoneTabs(
        appDelegate: GuessWhoAppDelegate,
        restoring: RestorationState?
    ) -> UITabBarController {
        let peopleNav = makeIPhonePeopleTab(appDelegate: appDelegate)
        let orgsNav = makeIPhoneOrganizationsTab(appDelegate: appDelegate)
        let eventsNav = makeIPhoneEventsTab(appDelegate: appDelegate)
        let favoritesNav = makeIPhoneFavoritesTab(appDelegate: appDelegate)
        let groupsNav = makeIPhoneGroupsTab(appDelegate: appDelegate)

        let tabs = UITabBarController()
        // Order matches the sidebar's `SidebarTab.allCases`: Favorites first,
        // then People, Organizations, Events, and Groups last.
        let tabNavs = [favoritesNav, peopleNav, orgsNav, eventsNav, groupsNav]
        tabs.viewControllers = tabNavs
        // Observe each tab nav's push/pop so backing out of a detail re-syncs the
        // restore selection to the top VC (`navigationController(_:didShow:)`).
        for nav in tabNavs { nav.delegate = self }
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

        // Select the restored section's tab up front (no default → restored
        // flash). `didSelect` doesn't fire for a programmatic `selectedIndex`, so
        // seed the restore state explicitly below.
        if let section = restoring?.section, let index = SidebarTab.allCases.firstIndex(of: section) {
            tabs.selectedIndex = index
        }

        // Seed the restore section from the current tab (`didSelect` only fires
        // on later user taps).
        if let section = Self.section(forTabIndex: tabs.selectedIndex) {
            noteSectionShown(section)
        }

        // Reopen the saved detail by pushing onto the selected tab's nav. The
        // nav exists here even though the permission gate hasn't put the tab bar
        // on screen yet — a push onto an off-screen nav is valid, so the detail
        // is already on the stack when the tabs are installed.
        if let selection = restoring?.selection,
           let selectedNav = tabs.selectedViewController as? UINavigationController {
            restoreSelection(selection, on: selectedNav, appDelegate: appDelegate)
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
        // Restore-to this contact (deepest detail = what the user is looking at).
        // Edit mode is intentionally NOT restored — reopen shows the card, not an
        // editing session. Stamped so a later Back re-syncs the selection.
        noteSelectionShown(.contact(id.restorationToken), stampedOn: hosting)
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
        noteSelectionShown(.event(eventUUID: eventUUID, eventKitID: eventKitID), stampedOn: hosting)
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
            sourceDisplayName: profile.sourceDisplayName,
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
                if profile.department?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    extras.insert(.department)
                }
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
            LinkedInDiff.riceDepartmentFieldName,
            LinkedInDiff.riceBioFieldName,
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
            case .phones: out.insert(.phones)
            case .websites: out.insert(.websites)
            case .linkedInURL: out.insert(.linkedInURL)
            case .department: out.insert(.department)
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
        // Descend to the frontmost presented controller — but stop at one that
        // is mid-dismissal. A being-dismissed VC is still wired as the
        // `presentedViewController` for the length of its dismiss animation, yet
        // presenting *on* it is silently dropped by UIKit. Returning the
        // controller it's dismissing back to (its `presentingViewController`)
        // lets a caller present against a base that can actually accept it once
        // the transition settles (see `presentAfterAnyDismissal(on:_:)`).
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
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
        // `.recordDoesNotExist`'s stock wording ("Tap Cancel to refresh")
        // assumes the contact editor's two-button alert; this one only has OK.
        let message = category == .recordDoesNotExist
            ? "This contact has been deleted on another device."
            : category.saveFailureMessage
        let alert = UIAlertController(
            title: "Couldn’t Save LinkedIn Info",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        guard let presenter = topmostPresenter() else {
            Self.handoffLog.error("apply-failed alert: NO presenter available")
            return
        }
        presentAfterAnyDismissal(on: presenter) { presenter.present(alert, animated: true) }
    }

    /// Present `body` on `presenter`, but only once any dismissal transition
    /// already running on it has finished. The matched-contact confirm flow
    /// calls `dismissPresented()` and *then*, ~half a second later, tries to
    /// surface an apply-failure alert. During that window the confirm sheet is
    /// still animating out, so a bare `present(_:animated:)` races the dismissal
    /// and UIKit silently drops it — the user saw neither the saved data nor an
    /// error. If a transition is in flight, chain off its completion; otherwise
    /// present immediately.
    @MainActor
    private func presentAfterAnyDismissal(on presenter: UIViewController, _ body: @escaping () -> Void) {
        if let coordinator = presenter.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in body() }
        } else {
            body()
        }
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

    /// Record the newly-selected tab as the restore section. Switching tabs
    /// shows that tab's own nav stack (its list at the root after a fresh
    /// switch), so the selected record is cleared — restore lands on the list.
    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelect viewController: UIViewController
    ) {
        guard let section = Self.section(forTabIndex: tabBarController.selectedIndex) else { return }
        noteSectionShown(section)
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

// MARK: - Nav-stack selection tracking (both shells)

extension GuessWhoSceneDelegate: UINavigationControllerDelegate {
    /// After every push/pop on a detail nav, set the restore selection to
    /// whatever is now on top: a hosted detail carries its stamped
    /// `RestorationState.Selection`; a list root / placeholder carries none, so
    /// the selection is CLEARED. This keeps "restore what I'm looking at"
    /// accurate when the user backs out of a detail — without it, a contact the
    /// user popped away from would still be restored next launch.
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        syncSelectionToTop(viewController)
    }
}

/// Reference box so a value-type `RestorationState.Selection` can ride along as
/// an Objective-C associated object (which requires a class instance).
private final class RestorationSelectionBox {
    let selection: RestorationState.Selection
    init(_ selection: RestorationState.Selection) { self.selection = selection }
}

private extension UIViewController {
    private static var gwRestorationSelectionKey: UInt8 = 0

    /// The restoration selection this view controller represents, if it hosts a
    /// contact/event detail. Stamped when the detail is pushed/replaced so the
    /// nav delegate can recompute the scene's selection from the top VC after a
    /// pop. Nil on list roots and placeholders (→ clears the selection).
    var gwRestorationSelection: RestorationState.Selection? {
        get {
            (objc_getAssociatedObject(self, &Self.gwRestorationSelectionKey)
                as? RestorationSelectionBox)?.selection
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.gwRestorationSelectionKey,
                newValue.map(RestorationSelectionBox.init),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
