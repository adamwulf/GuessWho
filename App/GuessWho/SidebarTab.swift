import Foundation

/// Sidebar entries for the 3-column NavigationSplitView used on
/// macOS and on regular-width iPadOS. Scoped to People for the first
/// pass so we can validate the architecture; the other tabs still
/// ship via the iPhone TabView and will land here as follow-ups.
enum SidebarTab: String, Identifiable, Hashable, CaseIterable {
    // `allCases` order drives both the Catalyst/iPad sidebar rows and the
    // iPhone tab-bar order, so the declaration order IS the display order:
    // Favorites first, then People, Organizations, Events.
    case favorites
    case people
    case organizations
    case events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .organizations: return "Organizations"
        case .events: return "Events"
        case .favorites: return "Favorites"
        }
    }

    var systemImage: String {
        switch self {
        case .people: return "person.2.fill"
        case .organizations: return "building.2.fill"
        case .events: return "calendar"
        case .favorites: return "star.fill"
        }
    }

    /// Title for the Catalyst detail-column placeholder shown when this
    /// tab is selected but no row has been picked yet.
    var detailPlaceholderTitle: String {
        "Nothing Selected"
    }

    /// Message body for the Catalyst detail-column placeholder shown
    /// when this tab is selected but no row has been picked yet.
    var detailPlaceholderMessage: String {
        switch self {
        case .people: return "Choose a person from the list to see details."
        case .organizations: return "Choose an organization from the list to see details."
        case .events: return "Choose an event from the list to see details."
        case .favorites: return "Choose a favorite from the list to see details."
        }
    }
}
