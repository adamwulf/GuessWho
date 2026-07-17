public enum SidecarKind: String, Sendable, Codable {
    case contact
    case event
    case link
    case guide
    case place
}

/// Shared list-filter state for sidecar-backed relationships. Individual list
/// screens own separate instances so filtering People does not unexpectedly
/// filter Organizations or Places; all of them use the same two-option model.
public enum LinkFilter: CaseIterable, Sendable {
    case all
    case linked
}
