import Foundation

/// What a member list shows: one group's direct members, or the union of the
/// members of EVERY group beneath a folder, at any depth
/// (`plans/group-folders.md`, "Folder member aggregation").
public enum GroupMemberScope: Sendable, Hashable {
    case group(ContactGroup)
    /// A folder by its durable id.
    case folder(id: String)
}

/// One consistent read of a scope's members, with everything a list needs to
/// say honestly what it is showing.
///
/// A folder's members come from several Contacts fetches, which is a
/// best-effort read and not a transaction. Two things make that safe to show.
/// `failedGroups` names any group whose fetch failed, so a partial union is
/// never presented as the whole answer. `revisions` records the repository
/// state the read started from; `ContactsRepository.isCurrent(_:)` tells the
/// caller whether that state moved while the fetches were in flight, in which
/// case the snapshot must be discarded and read again rather than published.
public struct GroupMemberSnapshot: Sendable {
    /// The repository state a snapshot was read against.
    public struct Revisions: Sendable, Equatable {
        /// `ContactsRepository.groupHierarchyRevision`: which groups are in scope.
        public let hierarchy: Int
        /// Advances when a membership write lands or Contacts changes underneath.
        public let membership: Int
        /// Advances whenever the repository's contact records are replaced — an
        /// edit, a reload, a reconciliation, an external change — even when no
        /// membership moved, because the rows themselves may be out of date.
        public let contactData: Int

        public init(hierarchy: Int, membership: Int, contactData: Int) {
            self.hierarchy = hierarchy
            self.membership = membership
            self.contactData = contactData
        }
    }

    public let scope: GroupMemberScope
    /// The groups whose members this scope covers, in tree order. One element
    /// for a group scope; possibly none for a folder.
    public let groups: [ContactGroup]
    /// The members, each once, in a deterministic order (first contributing
    /// group in tree order, then the order that group's fetch returned). Lists
    /// sort and section this themselves.
    public let contacts: [Contact]
    /// For each member, the groups in scope it belongs to, in tree order.
    public let contributingGroups: [ContactID: [ContactGroup]]
    /// Groups in scope whose members could NOT be fetched. Non-empty means
    /// `contacts` is a partial result.
    public let failedGroups: [ContactGroup]
    public let revisions: Revisions

    public init(
        scope: GroupMemberScope,
        groups: [ContactGroup],
        contacts: [Contact],
        contributingGroups: [ContactID: [ContactGroup]],
        failedGroups: [ContactGroup],
        revisions: Revisions
    ) {
        self.scope = scope
        self.groups = groups
        self.contacts = contacts
        self.contributingGroups = contributingGroups
        self.failedGroups = failedGroups
        self.revisions = revisions
    }

    /// True when some group's members are missing from `contacts`. A partial
    /// snapshot must never be labeled with a complete count or as "no members."
    public var isPartial: Bool { !failedGroups.isEmpty }

    /// Why `contacts` is empty, when it is — a list words each case differently.
    public enum Emptiness: Sendable, Equatable {
        /// There are members.
        case notEmpty
        /// A folder with no groups beneath it.
        case noGroups
        /// There are groups, every fetch succeeded, and none has a member.
        case noMembers
        /// Nothing to show AND at least one group failed to load, so "no
        /// members" would be a guess.
        case unavailable
    }

    public var emptiness: Emptiness {
        if !contacts.isEmpty { return .notEmpty }
        if groups.isEmpty { return .noGroups }
        return failedGroups.isEmpty ? .noMembers : .unavailable
    }
}
