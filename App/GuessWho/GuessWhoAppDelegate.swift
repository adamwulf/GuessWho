import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit application entry point. Replaces the previous SwiftUI `App`
/// (`@main GuessWhoApp`) so we can drive the window with a UIKit
/// `UIWindowSceneDelegate` and host a `UISplitViewController` (Catalyst)
/// or a `UITabBarController` (iPhone/iPad-compact) as the root.
/// SceneDelegate picks the root based on `targetEnvironment(macCatalyst)`.
@main
final class GuessWhoAppDelegate: UIResponder, UIApplicationDelegate {
    /// Hoisted to the AppDelegate so a single instance survives every
    /// scene the user opens and so the SceneDelegate can read it when
    /// constructing the root view controller. Matches the lifetime the
    /// previous SwiftUI `@State` properties had under `GuessWhoApp`.
    let service: SyncService
    let favoritesStore: FavoritesListStore
    /// Owned here so every UIKit list controller (iPhone tabs and
    /// Catalyst columns) renders against a shared repository and reload
    /// paths (external-change notifications, list selections) all see
    /// the same instance.
    let contactsRepository: ContactsRepository
    /// Owned here for the same reason as `contactsRepository`. After
    /// Phase 5 the iPhone shell is also UIKit and consumes this repo,
    /// so the gate that previously made this Catalyst-only is gone.
    let eventsRepository: EventsRepository
    let contactPhotoLoader: ContactPhotoLoader

    override init() {
        // Register defaults so non-@AppStorage readers and the iOS
        // Settings pane both see the canonical default before the user
        // toggles it. Mirrors what `GuessWhoApp.init()` used to do.
        UserDefaults.standard.register(defaults: [
            AppSettings.Key.debugModeEnabled: AppSettings.Default.debugModeEnabled
        ])
        let service = SyncService()
        let contactsRepository = service.makeContactsRepository()
        self.service = service
        self.favoritesStore = FavoritesListStore(service: service)
        self.contactsRepository = contactsRepository
        self.eventsRepository = EventsRepository(service: service)
        self.contactPhotoLoader = ContactPhotoLoader(repository: contactsRepository)
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Sidecar-only migration runs BEFORE any permission prompt so it
        // executes even when Contacts/Events access is denied. Moved out
        // of the old SwiftUI RootView.task to keep the same "migrate
        // before gate" ordering now that the iPhone shell is UIKit.
        service.migrateEventsIfNeeded()

        // Kick the repositories' initial fetch so the UIKit list
        // controllers have data ready when the user picks a tab. Runs
        // even when access has not been granted yet — fetches return
        // empty in that case, and a later store-changed notification
        // refreshes the list once permission flips. NO Catalyst-only
        // gate: after Phase 5 the iPhone shell consumes this same
        // AppDelegate-owned repo (Worker A had introduced a gate based
        // on the pre-Phase-5 state where RootView built its own copy —
        // the gate needed to come back out once iPhone migrated, which
        // is now).
        // Request access BEFORE reload so Catalyst (which has no
        // PermissionGateViewController in its path) actually prompts;
        // the request methods are idempotent on iPhone where the gate
        // already asked.
        Task { @MainActor in
            await service.requestContactsAccessIfNeeded()
            await contactsRepository.reload()
        }
        Task { @MainActor in
            await service.requestEventsAccessIfNeeded()
            await eventsRepository.reload()
        }

        // Start the package-owned external-contact-change watcher. The package
        // now owns the `.CNContactStoreDidChange` observer, the change-history
        // cursor, and the coalescing; it posts `.guessWhoContactsDidChange` when
        // an external edit lands. The repositories subscribe to that (and
        // `EventsRepository` also owns its own `.EKEventStoreChanged` observer)
        // — so the AppDelegate no longer registers any store-change observer; it
        // just owns the instances and kicks the watcher once at launch.
        //
        // Ordering doesn't matter: the reloads above are dispatched as Task
        // blocks that have NOT completed by the time this synchronous call runs,
        // so this does not gate on the baseline. It needn't — the watcher's
        // first delta read is itself idempotent against the in-flight reload
        // (first run yields a full-reload signal; later edits an incremental
        // delta), so whichever finishes first, the cache converges.
        service.startContactChangeWatcher()

        return true
    }
}
