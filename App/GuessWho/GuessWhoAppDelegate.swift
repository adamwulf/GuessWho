import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit application entry point. Replaces the previous SwiftUI `App`
/// (`@main GuessWhoApp`) so we can drive the window with a UIKit
/// `UIWindowSceneDelegate` and host a `UISplitViewController` as the
/// root on Catalyst. iPhone/iPad continue to render the existing
/// SwiftUI `RootView` — the SceneDelegate decides which root to mount
/// based on `targetEnvironment(macCatalyst)`.
@main
final class GuessWhoAppDelegate: UIResponder, UIApplicationDelegate {
    /// Hoisted to the AppDelegate so a single instance survives every
    /// scene the user opens and so the SceneDelegate can read it when
    /// constructing the root view controller. Matches the lifetime the
    /// previous SwiftUI `@State` properties had under `GuessWhoApp`.
    let service: SyncService
    let favoritesStore: FavoritesListStore
    /// Owned here so the UIKit Catalyst list controller can render
    /// against a shared repository and reload paths (CNContactStore
    /// change notifications, sidebar tab swaps) all see the same
    /// instance. The SwiftUI RootView still constructs its own copy on
    /// iPhone because that flow gates creation on Contacts auth — Phase
    /// 3's UIKit shell intentionally takes the simpler "reload eagerly,
    /// empty if denied" path since users have typically already granted
    /// permission by the time they're using the app on a Mac.
    let contactsRepository: ContactsRepository
    #if targetEnvironment(macCatalyst)
    /// Catalyst-only — iPhone's `RootView` constructs its own
    /// `EventsRepository` so we don't duplicate the fetch there.
    let eventsRepository: EventsRepository
    #endif

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
        #if targetEnvironment(macCatalyst)
        self.eventsRepository = EventsRepository(service: service)
        #endif
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Kick the repository's initial fetch so the UIKit list
        // controller has data ready when the user picks People in the
        // sidebar. Runs even when Contacts access has not been granted
        // yet — `fetchAll()` returns an empty array in that case, and a
        // later CNContactStoreDidChange (fired by SyncService when
        // permission flips to authorized) refreshes the list.
        //
        // Catalyst-only because iPhone's `RootView` constructs its own
        // `ContactsRepository` and ignores this one — the eager reload
        // here would be wasted I/O on iPhone. Matches the
        // `eventsRepository` gating below.
        //
        // PHASE-5-RISK: if the iPhone migration starts consuming
        // `appDelegate.contactsRepository` instead of `RootView`'s
        // local copy, this gate needs to come back out.
        #if targetEnvironment(macCatalyst)
        Task { @MainActor in
            await contactsRepository.reload()
        }
        Task { @MainActor in
            await eventsRepository.reload()
        }
        #endif
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Hand-built config so we don't need a matching entry under
        // UIApplicationSceneManifest.UISceneConfigurations — the
        // Info.plist entry would otherwise need to repeat the same
        // delegate class name and we'd own two sources of truth.
        let configuration = UISceneConfiguration(
            name: "Default",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = GuessWhoSceneDelegate.self
        return configuration
    }
}
