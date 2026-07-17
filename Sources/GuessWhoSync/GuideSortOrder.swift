import Foundation

/// The order the Guides list is sorted by. Sibling of `EventSortOrder`:
/// the app-side `GuidesRepository` holds the CURRENT order; the APP owns
/// persistence (the `rawValue` strings are stable so they can be stored in
/// `UserDefaults`).
///
/// The guides list is a single flat section (no sectioning), so this enum
/// carries the comparator itself.
public enum GuideSortOrder: String, CaseIterable, Sendable {
    /// By guide name, A→Z (case-insensitive).
    case nameAscending
    /// By guide name, Z→A (case-insensitive).
    case nameDescending
    /// By `MapsGuide.createdAt`, newest import first — the list's original
    /// default behavior.
    case recentlyAdded
    /// By `MapsGuide.lastViewedAt`, most recently opened first. Never-opened
    /// guides sort after every opened one.
    case lastViewed
    /// By the guide's place count, most places first. The count is not on
    /// `MapsGuide` (places are separate `MapsPlace` sidecars keyed by guide),
    /// so this order is the only one that needs the `placeCount` lookup passed
    /// to `sorted(_:placeCount:)`; a guide the lookup doesn't know counts as 0.
    case placeCount

    /// User-facing menu title for this order.
    public var title: String {
        switch self {
        case .nameAscending:  return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .recentlyAdded:  return "Recently Added"
        case .lastViewed:     return "Last Viewed"
        case .placeCount:     return "Place Count"
        }
    }

    /// Sort `guides` by this order. Convenience for the four self-contained
    /// orders; the `.placeCount` order needs counts, so it degrades to the
    /// name→UUID tiebreak here (every guide counts as 0). Callers that support
    /// `.placeCount` must use `sorted(_:placeCount:)`.
    public func sorted(_ guides: [MapsGuide]) -> [MapsGuide] {
        sorted(guides, placeCount: { _ in 0 })
    }

    /// Sort `guides` by this order, resolving each guide's place count through
    /// `placeCount` (only `.placeCount` consults it; the others ignore it).
    /// Deterministic: ties (including the nil-timestamp tail of the two time
    /// orders and equal counts) fall back to a case-insensitive name compare,
    /// then to the guide UUID, so repeat sorts of the same data can't shuffle
    /// rows.
    public func sorted(
        _ guides: [MapsGuide],
        placeCount: (UUID) -> Int
    ) -> [MapsGuide] {
        guides.sorted { lhs, rhs in
            switch self {
            case .nameAscending:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case .nameDescending:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedDescending }
            case .recentlyAdded:
                let l = lhs.createdAt ?? .distantPast
                let r = rhs.createdAt ?? .distantPast
                if l != r { return l > r }
            case .lastViewed:
                let l = lhs.lastViewedAt ?? .distantPast
                let r = rhs.lastViewedAt ?? .distantPast
                if l != r { return l > r }
            case .placeCount:
                let l = placeCount(lhs.id)
                let r = placeCount(rhs.id)
                if l != r { return l > r }
            }
            let nameCmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameCmp != .orderedSame { return nameCmp == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
