import Foundation

/// The global order the People / Organizations lists are sorted and sectioned
/// by. The repository holds the CURRENT order; the APP owns persistence (the
/// `rawValue` strings are stable so they can be stored in `UserDefaults`).
///
/// Two families:
/// - NAME orders (`firstLast`, `lastFirst`) sort alphabetically and section
///   A–Z by the leading letter of the relevant name key.
/// - TIME orders (`lastModified`, `lastInteracted`, `lastViewed`) sort by the
///   matching contact timestamp, most-recent first, and section into
///   relative-time buckets ("Today", "This Week", "This Month", "Earlier").
public enum ContactSortOrder: String, CaseIterable, Sendable {
    case firstLast
    case lastFirst
    case lastModified
    case lastInteracted
    case lastViewed

    /// True for the three timestamp-driven orders. The app uses this to decide
    /// whether the section titles are A–Z index letters (false) or relative-
    /// time bucket names (true, so the A–Z index is hidden).
    public var isTimeOrder: Bool {
        switch self {
        case .firstLast, .lastFirst:
            return false
        case .lastModified, .lastInteracted, .lastViewed:
            return true
        }
    }

    /// User-facing menu title for this order.
    public var title: String {
        switch self {
        case .firstLast:      return "First, Last"
        case .lastFirst:      return "Last, First"
        case .lastModified:   return "Last Modified"
        case .lastInteracted: return "Last Interacted"
        case .lastViewed:     return "Last Viewed"
        }
    }
}
