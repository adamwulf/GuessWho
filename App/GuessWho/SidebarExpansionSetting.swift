import Foundation

/// Single source of truth for which sidebar sections the user has closed, and
/// its persistence — the sidebar-side sibling of the sort-order settings. The
/// closed sections are stored in `UserDefaults` as an array of `SidebarTab`
/// raw values under a stable key, so a relaunch brings the sidebar back the way
/// the user left it.
///
/// It stores the CLOSED sections rather than the open ones, because every
/// section is open by default: a tab that has never been touched is simply
/// absent, and a `SidebarTab` case added in a later version is therefore open
/// on first run rather than silently closed.
enum SidebarExpansionSetting {
    /// Stable `UserDefaults` key. Namespaced like the other app settings so it
    /// can't collide with a package or system default.
    static let key = "com.milestonemade.guesswho.settings.sidebarCollapsedSections"

    /// The sections the user has closed. Raw strings are round-tripped through
    /// `SidebarTab` and unknown ones are dropped, so a stale value left behind
    /// by a renamed or removed case can't crash — it just reads as open.
    static var collapsed: Set<SidebarTab> {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(SidebarTab.init(rawValue:)))
    }

    /// The complement of `collapsed`: every section that should come up open.
    /// This is what the sidebar seeds `expandedSections` from at launch.
    static var expanded: Set<SidebarTab> {
        Set(SidebarTab.allCases).subtracting(collapsed)
    }

    /// Persist `expandedSections` by storing everything NOT in it. Sorted by
    /// `allCases` order so the stored array is stable across writes and a
    /// diff of the defaults plist stays readable.
    static func save(expanded: Set<SidebarTab>) {
        let closed = SidebarTab.allCases.filter { !expanded.contains($0) }
        UserDefaults.standard.set(closed.map(\.rawValue), forKey: key)
    }
}
