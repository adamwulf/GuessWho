import UIKit
import SwiftUI
import Contacts
import EventKit
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
    /// paths (CNContactStore notifications, list selections) all see
    /// the same instance.
    let contactsRepository: ContactsRepository
    /// Owned here for the same reason as `contactsRepository`. After
    /// Phase 5 the iPhone shell is also UIKit and consumes this repo,
    /// so the gate that previously made this Catalyst-only is gone.
    let eventsRepository: EventsRepository

    /// Opaque tokens for the store-change observers registered in
    /// `didFinishLaunching`. Held so the AppDelegate (which lives for
    /// the lifetime of the process) keeps them alive without needing
    /// explicit removal.
    private var contactStoreObserver: NSObjectProtocol?
    private var eventStoreObserver: NSObjectProtocol?

    override init() {
        // Register defaults so non-@AppStorage readers and the iOS
        // Settings pane both see the canonical default before the user
        // toggles it. Mirrors what `GuessWhoApp.init()` used to do.
        UserDefaults.standard.register(defaults: [
            AppSettings.Key.debugModeEnabled: AppSettings.Default.debugModeEnabled
        ])
        let service = SyncService()
        self.service = service
        self.favoritesStore = FavoritesListStore(service: service)
        self.contactsRepository = ContactsRepository(service: service)
        self.eventsRepository = EventsRepository(service: service)
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

        // Refresh both repositories on external store changes so an
        // edit in Contacts.app / Calendar.app surfaces here without a
        // relaunch. Lifted out of the old SwiftUI RootView observers
        // because RootView is gone after Phase 5. Centralising at the
        // AppDelegate (single owner of both repositories) avoids
        // duplicating the same observer in every list controller and
        // gives a single reload-fan-out point — each list VC then
        // re-applies its diffable snapshot via the existing
        // `.contactsRepositoryDidReload` / `.eventsRepositoryDidReload`
        // notifications fired by the repository's reload().
        contactStoreObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                Task { @MainActor in
                    // Incremental: re-read only the contacts that changed in
                    // Contacts.app (our own writes are excluded via
                    // transactionAuthor), falling back to a full reload on
                    // first run / history truncation. Far cheaper than the old
                    // full re-enumerate of every contact on each change.
                    await self.contactsRepository.applyExternalChanges()
                    // A contact change can affect event invitee/attendee
                    // rendering, so still refresh events — PRESERVED from the
                    // pre-incremental observer.
                    await self.eventsRepository.reload()
                }
            }
        }
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                Task { @MainActor in
                    await self.eventsRepository.reload()
                }
            }
        }

        return true
    }
}
