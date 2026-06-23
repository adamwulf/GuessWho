import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit `UIWindowSceneDelegate` that owns the per-scene `UIWindow`
/// and picks its root view controller based on the build target:
///
/// * Mac Catalyst → a 3-column `UISplitViewController` (sidebar /
///   content / detail) — the new UIKit shell introduced in Phase 2.
/// * iPhone / iPad → a `UIHostingController` wrapping the existing
///   SwiftUI `RootView` so iPhone behaviour is unchanged while the
///   UIKit migration progresses on Catalyst.
final class GuessWhoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let appDelegate = UIApplication.shared.delegate as? GuessWhoAppDelegate

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = makeRootViewController(appDelegate: appDelegate)
        self.window = window
        window.makeKeyAndVisible()
    }

    private func makeRootViewController(appDelegate: GuessWhoAppDelegate?) -> UIViewController {
        #if targetEnvironment(macCatalyst)
        return makeCatalystSplit()
        #else
        return makeHostingRoot(appDelegate: appDelegate)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Phase-2 Catalyst shell. The sidebar is real (drives column
    /// swaps via its `didSelectTab` callback); the content and detail
    /// columns are placeholders that Phase 3+ will replace with the
    /// existing SwiftUI lists and `ContactDetailView`.
    private func makeCatalystSplit() -> UISplitViewController {
        let split = UISplitViewController(style: .tripleColumn)
        split.preferredDisplayMode = .twoBesideSecondary
        split.preferredSplitBehavior = .tile
        split.primaryBackgroundStyle = .sidebar

        let sidebar = SidebarViewController()
        let sidebarNav = UINavigationController(rootViewController: sidebar)

        let content = PlaceholderViewController(
            title: "Content",
            message: "Phase 3 will host the People / Organizations / Settings lists here."
        )
        let contentNav = UINavigationController(rootViewController: content)
        // displayModeButtonItem in the supplementary column gives users
        // a way to show/hide the sidebar even when the window is too
        // narrow for the auto-revealed sidebar handle.
        content.navigationItem.leftBarButtonItem = split.displayModeButtonItem
        content.navigationItem.leftItemsSupplementBackButton = true

        let detail = PlaceholderViewController(
            title: "Detail",
            message: "Phase 3 will host the selected contact's ContactDetailView here."
        )
        let detailNav = UINavigationController(rootViewController: detail)

        split.setViewController(sidebarNav, for: .primary)
        split.setViewController(contentNav, for: .supplementary)
        split.setViewController(detailNav, for: .secondary)

        sidebar.didSelectTab = { [weak content] tab in
            // Phase-2 wiring only: log the selection and surface it in
            // the content placeholder's title so we can confirm the
            // sidebar → content column hookup visually. Phase 3 will
            // replace this with real list-view swaps.
            print("selected: \(tab.title)")
            content?.update(
                title: tab.title,
                message: "Selected '\(tab.title)' from the sidebar. Phase 3 will render the real list here."
            )
        }

        return split
    }
    #endif

    private func makeHostingRoot(appDelegate: GuessWhoAppDelegate?) -> UIViewController {
        // Fall back to a fresh service/store if the AppDelegate is
        // somehow missing — keeps iPhone launchable in the unlikely
        // case `UIApplication.shared.delegate` is nil during scene
        // connection (e.g. an extension or test harness host).
        let service = appDelegate?.service ?? SyncService()
        let favoritesStore = appDelegate?.favoritesStore ?? FavoritesListStore(service: service)
        let root = RootView()
            .environment(service)
            .environment(favoritesStore)
        return UIHostingController(rootView: root)
    }
}
