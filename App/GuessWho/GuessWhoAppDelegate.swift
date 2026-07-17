import UIKit
import SwiftUI
import GuessWhoSync
import GuessWhoLogging

/// UIKit application entry point. A UIKit delegate (rather than a SwiftUI
/// `App`) lets us drive the window with a `UIWindowSceneDelegate` and host a
/// `UISplitViewController` (Catalyst) or a `UITabBarController`
/// (iPhone/iPad-compact) as the root. SceneDelegate picks the root based on
/// `targetEnvironment(macCatalyst)`.
@main
final class GuessWhoAppDelegate: UIResponder, UIApplicationDelegate {
    /// Owned by the AppDelegate so a single instance survives every scene the
    /// user opens and so the SceneDelegate can read it when constructing the
    /// root view controller.
    let service: SyncService
    let favoritesStore: FavoritesListStore
    /// Owned here so every UIKit list controller (iPhone tabs and
    /// Catalyst columns) renders against a shared repository and reload
    /// paths (external-change notifications, list selections) all see
    /// the same instance.
    let contactsRepository: ContactsRepository
    /// Owned here for the same reason as `contactsRepository`: both the iPhone
    /// tab shell and the Catalyst columns consume this one instance.
    let eventsRepository: EventsRepository
    /// Imported Apple Maps guides + their places. Owned here for the same
    /// reason as the other repositories: one instance serves both shells and
    /// every reload path.
    let guidesRepository: GuidesRepository
    let contactPhotoLoader: ContactPhotoLoader
    #if targetEnvironment(macCatalyst)
    /// App-side end of the CLI/MCP channel (plans/cli-mcp.md). Lazy so it
    /// only materializes on `bootstrap()` in `didFinishLaunching`; Catalyst
    /// only (INV-5 — iOS has no host to serve).
    private(set) lazy var mcpHostController = MCPHostController(
        service: service, repository: contactsRepository)
    #endif

    #if targetEnvironment(macCatalyst)
    /// Loopback listener for the Chrome/Brave extension's LinkedIn handoff
    /// (`POST 127.0.0.1:<port>/handoff` — see `LinkedInLocalhostReceiver`).
    /// Catalyst-only: Chromium browsers don't exist on iOS, and the port +
    /// network-server entitlement are only wired for the Catalyst build.
    /// Owned here (not by a scene) so one listener serves the whole process.
    private var chromeHandoffReceiver: LinkedInLocalhostReceiver?

    /// Phase 0 diagnostic hook for the embedded relay CLI (plans/cli-mcp.md):
    /// a FIFO in the shared CLI App Group container that `guesswho-cli probe`
    /// writes its "connected" line into. Follows the debug-mode Settings
    /// toggle at RUNTIME (ships in Release — Phase 0 verifies on exported
    /// builds, so this is deliberately not `#if DEBUG`). Catalyst-only per
    /// INV-5. Owned here so one listener serves the whole process.
    private let cliProbeListener = CLIProbeListener()
    /// Re-evaluates the probe listener when debug mode flips while the app is
    /// open (same UserDefaults-observer pattern the events list uses for its
    /// Export Logs button).
    private nonisolated(unsafe) var cliProbeDebugModeObserver: NSObjectProtocol?
    #endif

    /// App-process lifecycle breadcrumbs. Routes through swift-log so it lands in
    /// `<AppGroup>/Logs/app.log` (and echoes to Console). The scene-level
    /// transitions (connect / active / background / disconnect) are logged from
    /// `GuessWhoSceneDelegate` under `app.lifecycle.scene`; this app-process
    /// logger only covers events UIKit delivers to the *application* delegate
    /// (process launch + termination). Developer-facing label; see
    /// GuessWhoLogging notes.
    private static let lifecycleLog = GuessWhoLog.logger("app.lifecycle")

    override init() {
        // Bootstrap file logging FIRST — before UserDefaults.register and before
        // SyncService() — so the logging backend is live before any logger in the
        // construction path can fire. processName "app" gives this process its own
        // <AppGroup>/Logs/app.log. Idempotent and lock-guarded; safe to call once
        // here. (Bodies are developer-facing; see GuessWhoLogging notes.)
        GuessWhoLog.bootstrap(processName: "app", appGroupID: AppGroup.id)

        // Register defaults so non-@AppStorage readers and the iOS
        // Settings pane both see the canonical default before the user
        // toggles it.
        UserDefaults.standard.register(defaults: [
            AppSettings.Key.debugModeEnabled: AppSettings.Default.debugModeEnabled
        ])
        let service = SyncService()
        let contactsRepository = service.makeContactsRepository()
        self.service = service
        self.favoritesStore = FavoritesListStore(service: service)
        self.contactsRepository = contactsRepository
        self.eventsRepository = EventsRepository(service: service)
        self.guidesRepository = GuidesRepository(service: service)
        self.contactPhotoLoader = ContactPhotoLoader(repository: contactsRepository)
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First app-process breadcrumb: the process has launched. `hasURL`
        // records whether UIKit handed us a launch URL here (vs. delivering it
        // to the scene) so a cold-launch deep link is traceable from the very
        // first line. The handoff URL itself arrives in the scene delegate, not
        // here, but logging the launch options' shape disambiguates the path.
        Self.lifecycleLog.notice("app didFinishLaunching", [
            "hasLaunchOptions": launchOptions != nil,
            "hasURL": launchOptions?[.url] != nil
        ])

        // Restore the persisted global contact-list sort order BEFORE the
        // first list renders, so a relaunch shows the order the user last
        // chose. Setting `repository.sortOrder` only posts the reload when the
        // value actually changes, so seeding the default-on-default case is
        // silent. This is the launch half of the single source of truth in
        // `SortOrderSetting` — the picker owns the runtime half.
        SortOrderSetting.restore(into: contactsRepository)
        // Same launch-half restore for the events list's sort order (the
        // picker in EventsListViewController owns the runtime half via
        // `EventSortOrderSetting.apply`).
        EventSortOrderSetting.restore(into: eventsRepository)
        // Same launch-half restore for the guides list's sort order (the
        // picker in GuidesListViewController owns the runtime half via
        // `GuideSortOrderSetting.apply`).
        GuideSortOrderSetting.restore(into: guidesRepository)
        // And for the per-guide places list's sort order (the picker in
        // GuidePlacesListViewController owns the runtime half via
        // `PlaceSortOrderSetting.apply`). Same repository backs both.
        PlaceSortOrderSetting.restore(into: guidesRepository)
        // And for the unified Places tab's sort order (the picker in
        // PlacesListViewController owns the runtime half via
        // `AllPlacesSortOrderSetting.apply`). A separate setting from the
        // per-guide order, but the same repository holds both.
        AllPlacesSortOrderSetting.restore(into: guidesRepository)

        // Kick the repositories' initial fetch so the UIKit list
        // controllers have data ready when the user picks a tab. Runs
        // even when access has not been granted yet — fetches return
        // empty in that case, and a later store-changed notification
        // refreshes the list once permission flips.
        //
        // Request access BEFORE reload so Catalyst (which has no
        // PermissionGateViewController in its path) actually prompts;
        // the request methods are idempotent on iPhone where the gate
        // already asked.
        Task { @MainActor in
            await service.requestContactsAccessIfNeeded()
            await contactsRepository.reload()
        }
        Task { @MainActor in
            // Sidecar-only migration first — permission-free (it runs even
            // when access stays denied), with its sidecar walk off the main
            // actor. This explicit await starts it at launch; the HARD
            // migration-before-window-read ordering lives inside
            // `fetchEventsRange`, which awaits the same memoized run — so
            // even a notification-driven events reload racing this Task
            // cannot read pre-migration keys.
            await service.migrateEventsIfNeeded()
            await service.requestEventsAccessIfNeeded()
            await eventsRepository.reload()
        }

        // Start the package-owned external-contact-change watcher. The package
        // owns the `.CNContactStoreDidChange` observer, the change-history
        // cursor, and the coalescing; it posts `.guessWhoContactsDidChange` when
        // an external edit lands. The repositories subscribe to that (and
        // `EventsRepository` also owns its own `.EKEventStoreChanged` observer),
        // so the AppDelegate registers no store-change observer itself — it owns
        // the instances and kicks the watcher once at launch.
        //
        // Ordering against the reloads above doesn't matter: they run as Task
        // blocks not yet complete when this synchronous call fires, and the
        // watcher's first delta read is idempotent against the in-flight reload
        // (first run yields a full-reload signal; later edits an incremental
        // delta), so whichever finishes first, the cache converges.
        service.startContactChangeWatcher()

        // Start the sidecar-file watcher (iCloud storage only; a no-op
        // otherwise). It posts `.guessWhoSidecarsDidChange` when sidecar files
        // arrive or change under the iCloud root — a remote device's edit
        // syncing down, or a `notYetDownloaded` file materializing after
        // `read()` requested it — and both repositories subscribe with
        // debounced, read-only refreshes. Same ordering argument as the
        // contact watcher above: reload-vs-first-post races converge because
        // the refresh paths are idempotent reads.
        service.startSidecarFileWatcher()

        #if targetEnvironment(macCatalyst)
        startChromeHandoffReceiver()

        // Start (or later stop) the CLI diagnostic FIFO with the debug-mode
        // toggle. Evaluated once at launch, then re-evaluated whenever
        // UserDefaults changes so flipping the toggle takes effect live.
        cliProbeDebugModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCLIProbeListener()
            }
        }
        updateCLIProbeListener()

        // App-side end of the CLI/MCP channel: observes the master toggles
        // and runs the channel only while one is on (plans/cli-mcp.md
        // Phase 1). Injects the live service + repository (INV-2b).
        mcpHostController.bootstrap()

        // Phase 3 launch check: confirm the embedded helper resolves, and
        // breadcrumb when the app's location changed since the user last
        // copied/installed the helper path (their client configs are then
        // stale — the Settings sheet shows the plain repair hint).
        CLIInstallModel.verifyHelperAtLaunch()
        #endif

        return true
    }

    #if targetEnvironment(macCatalyst)
    /// Aligns the CLI diagnostic listener with the debug-mode toggle. Start
    /// and stop are both idempotent, so re-evaluating on every defaults
    /// change is safe.
    private func updateCLIProbeListener() {
        if UserDefaults.standard.bool(forKey: AppSettings.Key.debugModeEnabled) {
            cliProbeListener.start()
        } else {
            cliProbeListener.stop()
        }
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// Starts the Chrome/Brave handoff listener. Payloads hop to the main
    /// thread and into the same scene-delegate pipeline the Safari wake uses
    /// (`processLinkedInHandoff`), so the two transports stay behaviorally
    /// identical past this point.
    private func startChromeHandoffReceiver() {
        guard let port = ChromeHandoff.port else {
            Self.lifecycleLog.notice("Chrome handoff receiver disabled (no GuessWhoChromeHandoffPort)")
            return
        }
        let receiver = LinkedInLocalhostReceiver(
            port: port,
            allowedExtensionIDs: ChromeHandoff.allowedExtensionIDs,
            maxBodyBytes: GuessWhoSceneDelegate.handoffMaxBytes
        ) { data in
            // Called on the receiver's queue; the pipeline presents UIKit, so
            // hop to the main actor.
            Task { @MainActor in
                GuessWhoAppDelegate.routeChromeHandoff(data)
            }
        }
        receiver.start()
        chromeHandoffReceiver = receiver
    }

    /// Hands a Chrome-delivered payload to a connected scene's delegate. The
    /// extension wakes the app BEFORE posting, so normally a foreground scene
    /// exists — but on a cold launch the POST can land in the gap between
    /// `didFinishLaunching` (listener up) and the first scene connecting, so
    /// retry briefly instead of dropping the payload.
    private static let chromeHandoffLog = GuessWhoLog.logger("app.linkedin-handoff.chrome")

    @MainActor
    private static func routeChromeHandoff(_ data: Data, attempt: Int = 0) {
        let scenes = UIApplication.shared.connectedScenes
        let delegate = scenes
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .compactMap { $0.delegate as? GuessWhoSceneDelegate }
            .first
            ?? scenes.compactMap { $0.delegate as? GuessWhoSceneDelegate }.first
        if let delegate {
            delegate.processLinkedInHandoff(data: data, entry: "chrome-localhost")
        } else if attempt < 10 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                routeChromeHandoff(data, attempt: attempt + 1)
            }
        } else {
            chromeHandoffLog.error("no scene connected after \(attempt) attempts — payload dropped")
        }
    }
    #endif

    /// Last app-process breadcrumb. UIKit calls this when the app is about to
    /// terminate (rare on iOS — the system usually suspends rather than
    /// terminates — but reliable on Mac Catalyst quit). Pairs with the
    /// `didFinishLaunching` line to bracket a process's whole lifetime in the
    /// log.
    func applicationWillTerminate(_ application: UIApplication) {
        Self.lifecycleLog.notice("app willTerminate")
        #if targetEnvironment(macCatalyst)
        mcpHostController.shutdown()
        #endif
    }

    // MARK: - Help menu (developer-facing debug actions)

    /// Append developer-facing items to the **Help** menu:
    /// "Export Debug Logs" (zip + save panel / share sheet) and
    /// "Open Container Folder" (reveal the App Group container — in Finder on
    /// Mac Catalyst). Mac Catalyst also gets "Open Resources Folder" to reveal
    /// the app bundle's resources directory in Finder. These are sanctioned
    /// debug-mode surfaces per the project's product principle: they exist to
    /// diagnose silent failures, so they are intentionally always visible rather
    /// than gated on app state.
    ///
    /// The commands target this AppDelegate (always live in the responder
    /// chain), and each `@objc` action just forwards into the self-presenting
    /// `DebugMenuActions` presenter, which resolves its own frontmost view
    /// controller — so presentation never depends on what happens to be focused.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)

        // Only the main menu bar carries the Help menu (Catalyst). On iOS the
        // physical-keyboard menu has no Help menu, so insertion is a no-op
        // there — guarding on `.main` keeps us from touching contextual menus.
        guard builder.system == .main else { return }

        let exportLogs = UICommand(
            title: "Export Debug Logs",
            action: #selector(exportDebugLogsMenuAction)
        )
        let openContainer = UICommand(
            title: "Open Container Folder",
            action: #selector(openContainerFolderMenuAction)
        )
        #if targetEnvironment(macCatalyst)
        let openResources = UICommand(
            title: "Open Resources Folder",
            action: #selector(openResourcesFolderMenuAction)
        )
        let children = [exportLogs, openContainer, openResources]
        #else
        let children = [exportLogs, openContainer]
        #endif

        let menu = UIMenu(
            title: "",
            options: .displayInline,
            children: children
        )
        builder.insertChild(menu, atEndOfMenu: .help)

        #if targetEnvironment(macCatalyst)
        // Settings… (⌘,) — the in-app Settings sheet (plans/cli-mcp.md
        // Phase 3): the CLI/MCP toggles, command-line install, agent
        // activity, Recently Deleted, and the Debug Mode toggle. Replaces
        // the system-provided preferences item (which auto-renders
        // Settings.bundle — that bundle stays for iOS, and its one control,
        // Debug Mode, lives in the sheet too so Catalyst loses nothing).
        // Phase 2's File-menu "Recently Deleted…" entry moved into the
        // sheet as a Preferences row.
        let settings = UIKeyCommand(
            title: "Settings…",
            action: #selector(settingsMenuAction),
            input: ",",
            modifierFlags: .command
        )
        builder.replace(menu: .preferences, with: UIMenu(
            title: "",
            identifier: .preferences,
            options: .displayInline,
            children: [settings]
        ))
        #endif
    }

    // These run on the main thread (UIKit delivers menu actions there) and the
    // AppDelegate is already `@MainActor`-isolated via its `UIApplicationDelegate`
    // conformance, so they can call the `@MainActor` presenter directly.
    @objc private func exportDebugLogsMenuAction() {
        DebugMenuActions.exportLogs()
    }

    @objc private func openContainerFolderMenuAction() {
        DebugMenuActions.openContainerFolder()
    }

    #if targetEnvironment(macCatalyst)
    @objc private func openResourcesFolderMenuAction() {
        DebugMenuActions.openResourcesFolder()
    }

    @objc private func settingsMenuAction() {
        MCPPreferencesPresenter.present()
    }
    #endif
}
