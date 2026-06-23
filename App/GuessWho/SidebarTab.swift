import Foundation

/// Sidebar entries for the 3-column NavigationSplitView used on
/// macOS and on regular-width iPadOS. Scoped to People for the first
/// pass so we can validate the architecture; the other tabs still
/// ship via the iPhone TabView and will land here as follow-ups.
enum SidebarTab: String, Identifiable, Hashable, CaseIterable {
    case people
    /// Placeholder slot used to verify the sidebar's selection wiring.
    /// Selecting it should immediately swap the content column to the
    /// "Coming soon" view; selecting "People" should restore the list.
    /// Will be replaced by a real Organizations list view once the
    /// content-column selection pattern is proven out.
    case organizationsPlaceholder
    /// Catalyst-only entry: Settings.bundle is ignored by Catalyst, so
    /// the in-app SettingsView is the only way for a Mac user to reach
    /// the Debug Mode toggle. iPhone keeps Settings out of the TabView
    /// because iOS users reach the same toggle via System Settings.
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .organizationsPlaceholder: return "Organizations"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .people: return "person.2.fill"
        case .organizationsPlaceholder: return "building.2.fill"
        case .settings: return "gear"
        }
    }
}
