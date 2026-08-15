public enum SidecarKind: String, Sendable, Codable {
    case contact
    case event
    case link
    case guide
    case place
    /// A favorited Contacts group's durable cross-device identity record
    /// (`GroupIdentity`). Keyed by a minted UUID, like every other kind here
    /// except `.link`; the favorite references that UUID rather than the
    /// device-local `CNGroup.identifier`. See `plans/group-favorite-identity.md`.
    case group
}

/// Shared list-filter state for sidecar-backed relationships. Individual list
/// screens own separate instances so filtering People does not unexpectedly
/// filter Organizations or Places; all of them use the same two-option model.
public enum LinkFilter: CaseIterable, Sendable {
    case all
    case linked
}
