import Foundation

/// The order the unified Places tab (every place across every guide) is
/// sorted by. Sibling of `PlaceSortOrder`, which orders ONE guide's places:
/// the app-side `GuidesRepository` holds the CURRENT order; the APP owns
/// persistence (the `rawValue` strings are stable so they can be stored in
/// `UserDefaults`).
///
/// `PlaceSortOrder.guideOrder` has no cross-guide meaning (entry order is
/// per-guide), so this enum replaces it with `.byGuide`: the app groups the
/// list into one section per guide and this enum orders the places WITHIN
/// each section by their guide entry order. The flat orders ignore guide
/// boundaries entirely.
public enum AllPlacesSortOrder: String, CaseIterable, Sendable {
    /// Grouped one section per guide (section order is the app's guides-list
    /// order); within each section, the guide's own entry order
    /// (`MapsPlace.sortOrder`) — the unified analog of
    /// `PlaceSortOrder.guideOrder`, and the default.
    case byGuide
    /// By display name, A→Z (case-insensitive), flat across all guides.
    case nameAscending
    /// By display name, Z→A (case-insensitive), flat across all guides.
    case nameDescending
    /// By `MapsPlace.createdAt`, newest import first, flat across all guides.
    case recentlyAdded
    /// By `MapsPlace.lastViewedAt`, most recently opened first, flat across
    /// all guides. Never-opened places sort after every opened one.
    case lastViewed

    /// User-facing menu title for this order.
    public var title: String {
        switch self {
        case .byGuide:        return "By Guide"
        case .nameAscending:  return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .recentlyAdded:  return "Recently Added"
        case .lastViewed:     return "Last Viewed"
        }
    }

    /// True when this order displays as one flat list. `.byGuide` is the only
    /// grouped order — the app builds one section per guide and calls
    /// `sorted(_:)` per section.
    public var isFlat: Bool {
        self != .byGuide
    }

    /// Sort `places` by this order. For `.byGuide`, callers pass ONE guide's
    /// places at a time (the grouping itself is the caller's job) and get the
    /// guide's entry order back. Deterministic: ties (including the
    /// nil-timestamp tails of the two time orders) fall back to the display
    /// key, then to the place UUID, so repeat sorts of the same data can't
    /// shuffle rows. Unlike `PlaceSortOrder`, the flat orders do NOT fall back
    /// to `MapsPlace.sortOrder` — entry positions from different guides are
    /// unrelated, so comparing them cross-guide would be meaningless.
    public func sorted(_ places: [MapsPlace]) -> [MapsPlace] {
        places.sorted { lhs, rhs in
            switch self {
            case .byGuide:
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            case .nameAscending:
                let cmp = PlaceSortOrder.displayKey(lhs)
                    .localizedCaseInsensitiveCompare(PlaceSortOrder.displayKey(rhs))
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case .nameDescending:
                let cmp = PlaceSortOrder.displayKey(lhs)
                    .localizedCaseInsensitiveCompare(PlaceSortOrder.displayKey(rhs))
                if cmp != .orderedSame { return cmp == .orderedDescending }
            case .recentlyAdded:
                let l = lhs.createdAt ?? .distantPast
                let r = rhs.createdAt ?? .distantPast
                if l != r { return l > r }
            case .lastViewed:
                let l = lhs.lastViewedAt ?? .distantPast
                let r = rhs.lastViewedAt ?? .distantPast
                if l != r { return l > r }
            }
            let keyCmp = PlaceSortOrder.displayKey(lhs)
                .localizedCaseInsensitiveCompare(PlaceSortOrder.displayKey(rhs))
            if keyCmp != .orderedSame { return keyCmp == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
