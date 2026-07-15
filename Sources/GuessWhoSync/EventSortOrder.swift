import Foundation

/// The order the Events list is sorted by. Sibling of `ContactSortOrder`:
/// the app-side `EventsRepository` holds the CURRENT order; the APP owns
/// persistence (the `rawValue` strings are stable so they can be stored in
/// `UserDefaults`).
///
/// Unlike the contact orders there is no sectioning — the events list is a
/// single flat section — so this enum carries the comparator itself.
public enum EventSortOrder: String, CaseIterable, Sendable {
    /// By start date, soonest first — the list's original behavior.
    case chronological
    /// By `Event.createdAt`, newest first. Manual events use their sidecar
    /// create time; calendar events use `EKEvent.creationDate`.
    case recentlyAdded
    /// By `Event.lastViewedAt`, most recently opened first. Never-viewed
    /// events sort after every viewed one.
    case lastViewed

    /// User-facing menu title for this order.
    public var title: String {
        switch self {
        case .chronological:  return "Chronological"
        case .recentlyAdded:  return "Recently Added"
        case .lastViewed:     return "Last Viewed"
        }
    }

    /// Sort `events` by this order. Deterministic: ties (including the
    /// nil-timestamp tail of the two time orders) fall back to start date,
    /// then to the event UUID, so repeat sorts of the same data can't
    /// shuffle rows.
    public func sorted(_ events: [Event]) -> [Event] {
        events.sorted { lhs, rhs in
            switch self {
            case .chronological:
                break
            case .recentlyAdded:
                let l = lhs.createdAt ?? .distantPast
                let r = rhs.createdAt ?? .distantPast
                if l != r { return l > r }
            case .lastViewed:
                let l = lhs.lastViewedAt ?? .distantPast
                let r = rhs.lastViewedAt ?? .distantPast
                if l != r { return l > r }
            }
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
