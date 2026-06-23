import UIKit
import SwiftUI
import GuessWhoSync

/// UIKit `UIWindowSceneDelegate` that owns the per-scene `UIWindow`
/// and picks its root view controller based on the build target:
///
/// * Mac Catalyst → a 3-column `UISplitViewController` (sidebar /
///   content / detail) — the new UIKit shell introduced in Phase 2,
///   wired up with the real People list + selection-driven
///   ContactDetailView in Phase 3.
/// * iPhone / iPad → a `UIHostingController` wrapping the existing
///   SwiftUI `RootView` so iPhone behaviour is unchanged while the
///   UIKit migration progresses on Catalyst.
final class GuessWhoSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    #if targetEnvironment(macCatalyst)
    /// Strong references to the Catalyst columns so the sidebar
    /// callback can swap supplementary/secondary view controllers on
    /// each tab switch without us walking the split's child stack.
    private var split: UISplitViewController?
    private var sidebar: SidebarViewController?
    /// Tracks the currently-mounted People list so we can clear it on
    /// tab swaps. Nil while the supplementary column shows a different
    /// section (Organizations / Settings / placeholder).
    private var contactsList: ContactsListViewController?
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
        return makeHostingRoot(appDelegate: appDelegate)
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
            contactsList = list
            installDetailPlaceholder(in: split)

        case .organizations:
            let list = OrganizationsListViewController(repository: appDelegate.contactsRepository)
            list.didSelectContact = { [weak self] contact in
                self?.showContactDetail(contact: contact, appDelegate: appDelegate)
            }
            list.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            list.navigationItem.leftItemsSupplementBackButton = true
            split.setViewController(UINavigationController(rootViewController: list), for: .supplementary)
            contactsList = nil
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
            contactsList = nil
            installDetailPlaceholder(in: split)

        case .settings:
            let settings = UIHostingController(rootView: SettingsView())
            settings.title = "Settings"
            settings.navigationItem.leftBarButtonItem = split.displayModeButtonItem
            settings.navigationItem.leftItemsSupplementBackButton = true
            split.setViewController(UINavigationController(rootViewController: settings), for: .supplementary)
            contactsList = nil
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

    private func makeHostingRoot(appDelegate: GuessWhoAppDelegate) -> UIViewController {
        let root = RootView()
            .environment(appDelegate.service)
            .environment(appDelegate.favoritesStore)
        return UIHostingController(rootView: root)
    }
}
