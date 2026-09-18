import Foundation

/// The group hierarchy as a tree: a pure, immutable projection of the stored
/// parent assignments (`plans/group-folders.md`, "Tree projection, cycles, and
/// deletion").
///
/// Storage records only each child's parent. Everything a list needs — child
/// lists, order, depth, paths, the groups under a folder — is derived here, so
/// it can never disagree with storage. The projection is READ-ONLY: it repairs
/// nothing on disk. A stored assignment it cannot honor (a deleted parent, a
/// cycle two devices created independently, a parent that has not synced yet)
/// is resolved to an EFFECTIVE parent for display, reported through
/// `PlacementStatus`, and left stored as it was, because the inputs that made
/// it unhonorable can change on the next sync.
///
/// Deterministic: the same records and groups always produce an equal tree,
/// in whatever order they are supplied. Every traversal is iterative, so a
/// pathological chain thousands of folders deep costs memory, not stack.
public struct GroupFolderTree: Sendable, Equatable {
    /// A typed row identity. A folder's id is its durable UUID; a group's is
    /// its device-local Contacts id, which is what a group row has always been
    /// keyed by. The two id spaces never collide because the case is part of
    /// the identity.
    public enum NodeID: Hashable, Sendable {
        case folder(String)
        case group(String)

        /// A total order used ONLY to break equal-name ties, so two rows named
        /// alike keep a stable order between snapshots.
        var tieBreak: String {
            switch self {
            case .folder(let id): "folder:\(id)"
            case .group(let id): "group:\(id)"
            }
        }
    }

    /// How a node's effective parent relates to its stored assignment.
    public enum PlacementStatus: Sendable, Equatable {
        /// The effective parent IS the stored one (including "none": top level).
        case asStored
        /// The stored parent was deleted; the effective parent came from that
        /// folder's promotion destination, following deleted folders as far as
        /// needed.
        case redirected
        /// The stored parent (or a promotion destination on the way) is not
        /// available on this device right now — not synced yet, not downloaded,
        /// or not trustworthy. Shown at top level PROVISIONALLY.
        case parentUnavailable
        /// Deleted folders promote to each other in a loop. Shown at top level.
        case redirectLoop
        /// This folder's edge was the oldest in a cycle and is suppressed to
        /// break it. Shown at top level; the stored assignment is untouched and
        /// becomes effective again if another edge of the cycle changes.
        case cycleSuppressed
    }

    public struct Folder: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Where this folder is shown. nil = top level.
        public let parentFolderID: String?
        /// What is stored, whatever `parentFolderID` resolved to.
        public let storedParentFolderID: String?
        public let status: PlacementStatus
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { localID }
        public let localID: String
        public let name: String
        /// The group's durable identity, or nil when it has none yet (a group
        /// that was never favorited or placed).
        public let identityID: String?
        public let parentFolderID: String?
        public let storedParentFolderID: String?
        public let status: PlacementStatus
    }

    /// A group as the caller sees it on this device, with the identity its
    /// placement is read from.
    public struct GroupInput: Sendable, Equatable {
        public let localID: String
        public let name: String
        public let identityID: String?

        public init(localID: String, name: String, identityID: String?) {
            self.localID = localID
            self.name = name
            self.identityID = identityID?.lowercased()
        }
    }

    /// One row of the flattened, expansion-aware list.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: NodeID
        public let name: String
        /// 0 at top level.
        public let depth: Int
        /// Immediate children: folders plus groups. Always 0 for a group.
        public let childCount: Int
        /// Meaningful for folders with children; false otherwise.
        public let isExpanded: Bool
        public let status: PlacementStatus

        public var isFolder: Bool {
            if case .folder = id { return true }
            return false
        }
    }

    public private(set) var folders: [String: Folder] = [:]
    public private(set) var groups: [String: Group] = [:]
    /// Sorted children per folder id; top level under `nil`'s stand-in below.
    private var childrenByParent: [String: [NodeID]] = [:]
    public private(set) var rootChildren: [NodeID] = []
    /// False when enumeration failed or a hierarchy record cannot be read or
    /// trusted, so nodes may be missing or provisionally placed for that reason.
    public private(set) var isComplete = true
    /// Records excluded because their data cannot be trusted.
    public private(set) var unavailableKeys: Set<SidecarKey> = []

    public static let empty = GroupFolderTree()

    private init() {}

    // MARK: - Build

    public init(records: GroupHierarchyRecords, groups inputGroups: [GroupInput]) {
        isComplete = records.isComplete
        unavailableKeys = records.unavailableKeys

        var recordsByID: [String: GroupFolderRecord] = [:]
        for record in records.folders { recordsByID[record.id] = record }

        // 1 + 2. Effective parents, through deletion redirects.
        var effectiveParent: [String: String] = [:]
        var statusByFolder: [String: PlacementStatus] = [:]
        let liveIDs = recordsByID.values.filter { !$0.isDeleted }.map(\.id).sorted()
        for id in liveIDs {
            let resolved = Self.resolve(
                recordsByID[id]?.placement?.parentFolderID, in: recordsByID)
            statusByFolder[id] = resolved.status
            if let parent = resolved.parent { effectiveParent[id] = parent }
        }

        // 3. Break cycles among live folders. Every folder has at most one
        // parent, so the cycles are disjoint: walking parent pointers from any
        // folder either leaves through the top or runs into the walk's own
        // path, and that path's tail IS the cycle. Suppress exactly its oldest
        // edge and nothing else.
        var visitState: [String: Bool] = [:]   // false = on the current walk, true = finished
        for start in liveIDs where visitState[start] == nil {
            var path: [String] = []
            var cursor: String? = start
            while let id = cursor, visitState[id] == nil {
                visitState[id] = false
                path.append(id)
                cursor = effectiveParent[id]
            }
            if let id = cursor, visitState[id] == false, let entry = path.firstIndex(of: id) {
                let cycle = path[entry...]
                let oldest = cycle.min { lhs, rhs in
                    Self.edgePrecedes(lhs, rhs, records: recordsByID, parents: effectiveParent)
                }
                if let oldest {
                    effectiveParent[oldest] = nil
                    statusByFolder[oldest] = .cycleSuppressed
                }
            }
            for id in path { visitState[id] = true }
        }

        // 4. Nodes and child lists.
        var children: [String?: [NodeID]] = [:]
        for id in liveIDs {
            guard let record = recordsByID[id] else { continue }
            folders[id] = Folder(
                id: id,
                name: record.name,
                parentFolderID: effectiveParent[id],
                storedParentFolderID: record.placement?.parentFolderID,
                status: statusByFolder[id] ?? .asStored)
            children[effectiveParent[id], default: []].append(.folder(id))
        }
        var seenLocalIDs = Set<String>()
        for input in inputGroups where seenLocalIDs.insert(input.localID).inserted {
            let stored = input.identityID.flatMap { records.groupPlacements[$0]?.parentFolderID }
            let resolved = Self.resolve(stored, in: recordsByID)
            groups[input.localID] = Group(
                localID: input.localID,
                name: input.name,
                identityID: input.identityID,
                parentFolderID: resolved.parent,
                storedParentFolderID: stored,
                status: resolved.status)
            children[resolved.parent, default: []].append(.group(input.localID))
        }
        for (parent, nodes) in children {
            let sorted = nodes.sorted { precedes($0, $1) }
            if let parent { childrenByParent[parent] = sorted } else { rootChildren = sorted }
        }
    }

    /// Follow `storedParent` to the live folder a child is shown in.
    private static func resolve(
        _ storedParent: String?,
        in records: [String: GroupFolderRecord]
    ) -> (parent: String?, status: PlacementStatus) {
        guard var current = storedParent else { return (nil, .asStored) }
        var visited = Set<String>()
        var redirected = false
        while true {
            guard let record = records[current] else {
                // Not here. Whether it is still coming (not synced, not
                // downloaded, untrustworthy) or never will, the honest answer
                // today is the same: UNKNOWN — which is not a deletion. Only a
                // deletion marker redirects. So show the child provisionally at
                // top level and keep its assignment for when the parent turns
                // up.
                return (nil, .parentUnavailable)
            }
            guard let deletion = record.deletion else {
                return (current, redirected ? .redirected : .asStored)
            }
            guard visited.insert(current).inserted else { return (nil, .redirectLoop) }
            redirected = true
            guard let next = deletion.promotedToFolderID else { return (nil, .redirected) }
            current = next
        }
    }

    /// Whether folder `lhs`'s parent edge is OLDER than `rhs`'s: by the stamp of
    /// the placement that created it (kept through any redirect), then writer,
    /// then the edge's own endpoints, so the order is total and identical on
    /// every device.
    private static func edgePrecedes(
        _ lhs: String, _ rhs: String,
        records: [String: GroupFolderRecord],
        parents: [String: String]
    ) -> Bool {
        let l = records[lhs]?.placement
        let r = records[rhs]?.placement
        let lAt = l?.modifiedAt ?? .distantPast
        let rAt = r?.modifiedAt ?? .distantPast
        if lAt != rAt { return lAt < rAt }
        let lBy = l?.modifiedBy ?? ""
        let rBy = r?.modifiedBy ?? ""
        if lBy != rBy { return lBy < rBy }
        if lhs != rhs { return lhs < rhs }
        return (parents[lhs] ?? "") < (parents[rhs] ?? "")
    }

    /// The Groups list's order, at every level: names compared the way the flat
    /// list always has, folders and groups mixed, ties broken by typed id.
    private func precedes(_ lhs: NodeID, _ rhs: NodeID) -> Bool {
        switch name(of: lhs).localizedCaseInsensitiveCompare(name(of: rhs)) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.tieBreak < rhs.tieBreak
        }
    }

    // MARK: - Queries

    public func name(of node: NodeID) -> String {
        switch node {
        case .folder(let id): folders[id]?.name ?? ""
        case .group(let localID): groups[localID]?.name ?? ""
        }
    }

    /// Immediate children of `folderID` (nil = top level), sorted.
    public func children(of folderID: String?) -> [NodeID] {
        guard let folderID else { return rootChildren }
        return childrenByParent[folderID] ?? []
    }

    public func parentFolderID(of node: NodeID) -> String? {
        switch node {
        case .folder(let id): folders[id]?.parentFolderID
        case .group(let localID): groups[localID]?.parentFolderID
        }
    }

    /// The folders above `node`, nearest first. Computed on demand.
    public func ancestorFolderIDs(of node: NodeID) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var cursor = parentFolderID(of: node)
        while let id = cursor, seen.insert(id).inserted {
            result.append(id)
            cursor = folders[id]?.parentFolderID
        }
        return result
    }

    /// The names of the folders above `node`, outermost first — what tells two
    /// same-named folders apart. Computed on demand, never stored per node.
    public func pathNames(to node: NodeID) -> [String] {
        ancestorFolderIDs(of: node).reversed().map { folders[$0]?.name ?? "" }
    }

    /// Whether `folderID` is `ancestorID` or sits anywhere beneath it.
    public func isFolder(_ folderID: String, inSubtreeOf ancestorID: String) -> Bool {
        folderID == ancestorID || ancestorFolderIDs(of: .folder(folderID)).contains(ancestorID)
    }

    /// Every group beneath `folderID`, at any depth, regardless of which
    /// branches a list happens to show expanded. Local ids, in tree order.
    public func descendantGroupLocalIDs(ofFolder folderID: String) -> [String] {
        var result: [String] = []
        var stack = Array(children(of: folderID).reversed())
        while let node = stack.popLast() {
            switch node {
            case .group(let localID): result.append(localID)
            case .folder(let id): stack.append(contentsOf: children(of: id).reversed())
            }
        }
        return result
    }

    /// The flattened list. `collapsed` holds the folder ids the user closed;
    /// every other folder is open, so a folder that is new to this device shows
    /// its contents. Collapsing affects ONLY which rows appear here.
    public func visibleRows(collapsed: Set<String> = []) -> [Row] {
        var rows: [Row] = []
        var stack: [(node: NodeID, depth: Int)] = rootChildren.reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            switch node {
            case .group(let localID):
                guard let group = groups[localID] else { continue }
                rows.append(Row(
                    id: node, name: group.name, depth: depth, childCount: 0,
                    isExpanded: false, status: group.status))
            case .folder(let id):
                guard let folder = folders[id] else { continue }
                let kids = children(of: id)
                let expanded = !kids.isEmpty && !collapsed.contains(id)
                rows.append(Row(
                    id: node, name: folder.name, depth: depth, childCount: kids.count,
                    isExpanded: expanded, status: folder.status))
                if expanded {
                    stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
                }
            }
        }
        return rows
    }
}
