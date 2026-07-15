import Foundation

/// The order the places inside one guide are sorted by. Sibling of
/// `GuideSortOrder`: the app-side `GuidesRepository` holds the CURRENT order;
/// the APP owns persistence (the `rawValue` strings are stable so they can be
/// stored in `UserDefaults`).
public enum PlaceSortOrder: String, CaseIterable, Sendable {
    /// The guide's own entry order (`MapsPlace.sortOrder`, from the share
    /// link) — the list's original default behavior.
    case guideOrder
    /// By display name, A→Z (case-insensitive).
    case nameAscending
    /// By display name, Z→A (case-insensitive).
    case nameDescending
    /// By `MapsPlace.lastViewedAt`, most recently opened first. Never-opened
    /// places sort after every opened one.
    case lastViewed

    /// User-facing menu title for this order.
    public var title: String {
        switch self {
        case .guideOrder:     return "Guide Order"
        case .nameAscending:  return "Name (A–Z)"
        case .nameDescending: return "Name (Z–A)"
        case .lastViewed:     return "Last Viewed"
        }
    }

    /// The title a place row shows, used as the alpha key so name sorting
    /// matches what the user reads: the business name, else the address (an
    /// address entry, or a resolved place with no name, displays its address as
    /// its title). An unresolved place-ID entry yields "" and sorts first.
    static func displayKey(_ place: MapsPlace) -> String {
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Sort `places` by this order. Deterministic: ties (including the
    /// nil-timestamp tail of "Last Viewed") fall back to the guide's entry
    /// order, then to the place UUID, so repeat sorts of the same data can't
    /// shuffle rows.
    public func sorted(_ places: [MapsPlace]) -> [MapsPlace] {
        places.sorted { lhs, rhs in
            switch self {
            case .guideOrder:
                break
            case .nameAscending:
                let cmp = Self.displayKey(lhs).localizedCaseInsensitiveCompare(Self.displayKey(rhs))
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case .nameDescending:
                let cmp = Self.displayKey(lhs).localizedCaseInsensitiveCompare(Self.displayKey(rhs))
                if cmp != .orderedSame { return cmp == .orderedDescending }
            case .lastViewed:
                let l = lhs.lastViewedAt ?? .distantPast
                let r = rhs.lastViewedAt ?? .distantPast
                if l != r { return l > r }
            }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
