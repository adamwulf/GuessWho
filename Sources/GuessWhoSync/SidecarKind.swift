/// Declaration order is load-bearing: `allCases` is the stable kind order of
/// `FileSystemSidecarStore.allKeys()` and every scoped listing.
public enum SidecarKind: String, Sendable, Codable, CaseIterable {
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

extension SidecarKind {
    /// The directory under the sidecar root that holds this kind's files. The
    /// ONE mapping between a kind and its on-disk directory: the filesystem
    /// store routes writes and listings through it and the file watcher maps
    /// paths back through `init?(directoryName:)`, so the two cannot disagree
    /// and a new kind cannot be added to one and forgotten in the other.
    ///
    /// These names are the synced on-disk layout. Never rename one: peers on
    /// other app versions read and write the same directories.
    var directoryName: String {
        switch self {
        case .contact: "contacts"
        case .event: "events"
        case .link: "links"
        case .guide: "guides"
        case .place: "places"
        case .group: "groups"
        }
    }

    /// The kind stored in the directory named `directoryName`, or nil for a
    /// directory this build does not know (another app version's kind, or
    /// anything else under the root). Exact, case-sensitive match.
    init?(directoryName: String) {
        guard let kind = Self.allCases.first(where: { $0.directoryName == directoryName }) else {
            return nil
        }
        self = kind
    }
}

/// Shared list-filter state for sidecar-backed relationships. Individual list
/// screens own separate instances so filtering People does not unexpectedly
/// filter Organizations or Places; all of them use the same two-option model.
public enum LinkFilter: CaseIterable, Sendable {
    case all
    case linked
}
