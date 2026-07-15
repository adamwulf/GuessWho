import Foundation

/// The list surfaces shown as sidebar rows in the Catalyst/iPad 3-column
/// shell and as tabs in the iPhone tab-bar shell.
enum SidebarTab: String, Identifiable, Hashable, CaseIterable, Codable {
    // `allCases` order drives both the Catalyst/iPad sidebar rows and the
    // iPhone tab-bar order, so the declaration order IS the display order:
    // Favorites first, then People, Organizations, Events, Guides, and
    // Groups last.
    case favorites
    case people
    case organizations
    case events
    case guides
    case groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .organizations: return "Organizations"
        case .events: return "Events"
        case .favorites: return "Favorites"
        case .guides: return "Guides"
        case .groups: return "Groups"
        }
    }

    var systemImage: String {
        switch self {
        case .people: return "person.2.fill"
        case .organizations: return "building.2.fill"
        case .events: return "calendar"
        case .favorites: return "star.fill"
        case .guides: return "map"
        case .groups: return "person.3.fill"
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
        case .guides: return "Choose a guide from the list to see its places."
        case .groups: return "Choose a group from the list to see its members."
        }
    }
}
