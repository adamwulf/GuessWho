import UIKit
import GuessWhoSync

// Pure presentation rules for the Groups tree — everything the list, its menus,
// and its drag and drop decide that does NOT need a table view to decide. Kept
// here, free of UIKit state, so the rules are tested directly
// (`GroupFolderPresentationTests`) and the view controllers only wire them up.
//
// Vocabulary: the user sees folders, groups, and "the top level". Nothing here
// may mention how any of it is stored.

// MARK: - Errors

enum GroupFolderErrorPresentation {
    /// Plain-language copy for a failed folder command.
    static func message(for error: Error) -> String {
        if let hierarchyError = error as? GroupHierarchyError {
            switch hierarchyError {
            case .invalidName:
                return "Enter a name."
            case .folderNotFound, .folderDeleted, .invalidFolderID:
                return "That folder no longer exists."
            case .wouldCreateCycle:
                return "A folder can’t be moved into itself or into a folder inside it."
            case .identityNotFound, .lossyEnvelope, .recordUnavailable, .hierarchyUnavailable:
                return "This item’s saved information can’t be read right now. Try again later."
            case .timestampOverflow:
                return "This change couldn’t be saved. Check this device’s date and time, then try again."
            }
        }
        if error is SidecarUnavailableError {
            return "Storage isn’t available right now. Try again later."
        }
        return "This change couldn’t be saved. Please try again."
    }
}

// MARK: - Destinations

enum GroupFolderDestination {
    /// Where a new folder or group goes by default: inside the selected folder,
    /// beside the selected group, or at the top level.
    static func defaultParent(forSelection selection: GroupFolderTree.NodeID?, in tree: GroupFolderTree) -> String? {
        switch selection {
        case .folder(let id): return tree.folders[id] == nil ? nil : id
        case .group(let localID): return tree.groups[localID]?.parentFolderID
        case nil: return nil
        }
    }

    /// The line a creation prompt shows so the user knows where the new item
    /// will land BEFORE confirming.
    static func promptMessage(parentFolderID: String?, in tree: GroupFolderTree) -> String {
        guard let parentFolderID, let folder = tree.folders[parentFolderID] else {
            return "At the top level"
        }
        return "In “\(displayName(folder.name))”"
    }

    /// What deleting a folder does to its contents, said before it happens.
    static func deletionMessage(forFolder folderID: String, in tree: GroupFolderTree) -> String {
        guard let parentID = tree.folders[folderID]?.parentFolderID,
              let parent = tree.folders[parentID] else {
            return "The items inside will move to the top level."
        }
        return "The items inside will move to “\(displayName(parent.name))”."
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(Unnamed Folder)" : trimmed
    }
}

// MARK: - Move targets

/// One entry of a "Move to…" menu or an "Add to Group" folder heading.
struct GroupFolderMoveTarget: Equatable {
    let folderID: String
    let name: String
    /// Already this node's parent: shown, checked, and not actionable.
    let isCurrentParent: Bool
    let children: [GroupFolderMoveTarget]
}

enum GroupFolderMoveTargets {
    /// Every folder `node` may move into, as a tree in list order. A folder
    /// cannot move into itself or anything beneath it, so that whole branch is
    /// left out — not shown disabled — because nothing under it is reachable.
    static func targets(for node: GroupFolderTree.NodeID, in tree: GroupFolderTree) -> [GroupFolderMoveTarget] {
        let excluded: String? = {
            if case .folder(let id) = node { return id }
            return nil
        }()
        let currentParent = tree.parentFolderID(of: node)
        return build(under: nil, excluding: excluded, currentParent: currentParent, in: tree)
    }

    /// Whether "Move to Top Level" should be offered: the node is shown inside a
    /// folder, OR it is shown at the top level while its saved location says
    /// otherwise (a folder that no longer exists, or a loop two devices made).
    /// The second case is how a user settles such an item for good.
    static func offersMoveToTopLevel(for node: GroupFolderTree.NodeID, in tree: GroupFolderTree) -> Bool {
        if tree.parentFolderID(of: node) != nil { return true }
        switch node {
        case .folder(let id): return tree.folders[id]?.storedParentFolderID != nil
        case .group(let localID): return tree.groups[localID]?.storedParentFolderID != nil
        }
    }

    // Iterative over an explicit stack, built bottom-up, so a very deep tree
    // costs memory and not call depth.
    private static func build(
        under root: String?,
        excluding excluded: String?,
        currentParent: String?,
        in tree: GroupFolderTree
    ) -> [GroupFolderMoveTarget] {
        func folderChildren(_ parent: String?) -> [String] {
            tree.children(of: parent).compactMap {
                guard case .folder(let id) = $0, id != excluded else { return nil }
                return id
            }
        }
        // Post-order: a folder's targets are assembled once all its children are.
        var built: [String: [GroupFolderMoveTarget]] = [:]
        var stack: [(id: String, expanded: Bool)] = folderChildren(root).map { ($0, false) }
        while let (id, expanded) = stack.popLast() {
            if expanded {
                built[id] = folderChildren(id).compactMap { childID in
                    tree.folders[childID].map {
                        GroupFolderMoveTarget(
                            folderID: childID,
                            name: GroupFolderDestination.displayName($0.name),
                            isCurrentParent: childID == currentParent,
                            children: built[childID] ?? [])
                    }
                }
            } else {
                stack.append((id, true))
                stack.append(contentsOf: folderChildren(id).map { ($0, false) })
            }
        }
        return folderChildren(root).compactMap { id in
            tree.folders[id].map {
                GroupFolderMoveTarget(
                    folderID: id,
                    name: GroupFolderDestination.displayName($0.name),
                    isCurrentParent: id == currentParent,
                    children: built[id] ?? [])
            }
        }
    }
}

// MARK: - Folding the tree into nested elements

enum GroupFolderTreeFold {
    /// Build one element per group and per folder, bottom-up, in list order:
    /// `folder` receives the elements already built for everything inside it.
    /// Return nil from either closure to leave that node out — a picker of
    /// groups, for instance, drops a folder with no group anywhere beneath it,
    /// since it would be a heading that leads nowhere.
    ///
    /// This is how "Add to Group" nests its menu: folders become headings to
    /// navigate, and only groups — the leaves — are choices. Iterative over an
    /// explicit stack, so depth costs memory and not call depth.
    static func fold<Element>(
        _ tree: GroupFolderTree,
        group: (GroupFolderTree.Group) -> Element?,
        folder: (GroupFolderTree.Folder, [Element]) -> Element?
    ) -> [Element] {
        var built: [String: Element] = [:]
        func elements(of parent: String?) -> [Element] {
            tree.children(of: parent).compactMap { node in
                switch node {
                case .group(let localID): tree.groups[localID].flatMap(group)
                case .folder(let id): built[id]
                }
            }
        }
        func folderIDs(of parent: String?) -> [String] {
            tree.children(of: parent).compactMap {
                if case .folder(let id) = $0 { return id }
                return nil
            }
        }
        var stack: [(id: String, childrenDone: Bool)] = folderIDs(of: nil).map { ($0, false) }
        while let (id, childrenDone) = stack.popLast() {
            if childrenDone {
                built[id] = tree.folders[id].flatMap { folder($0, elements(of: id)) }
            } else {
                stack.append((id, true))
                stack.append(contentsOf: folderIDs(of: id).map { ($0, false) })
            }
        }
        return elements(of: nil)
    }
}

// MARK: - Drag and drop

/// What a drop at some point of the list would do.
enum GroupFolderDropProposal: Equatable {
    case moveInto(folderID: String)
    case moveToTopLevel
    case forbidden
}

enum GroupFolderDropPolicy {
    /// The middle of a row means "into this row"; its top and bottom edges are
    /// the gaps between rows.
    static let centerBand: ClosedRange<CGFloat> = 0.25...0.75

    /// - Parameters:
    ///   - dragged: the single local item being dragged.
    ///   - target: the row under the pointer, or nil below the last row.
    ///   - verticalFraction: 0 at the row's top edge, 1 at its bottom.
    ///   - rows: the list as currently shown, in order.
    ///
    /// Siblings are always alphabetical, so there is no "drop between these two"
    /// to honor: the ONLY thing a gap can mean is "out to the top level", and
    /// only at a boundary of a top-level branch, where that reading is
    /// unambiguous. A gap inside a folder would imply a manual order the list
    /// does not have, so it is refused rather than guessed at.
    static func proposal(
        dragged: GroupFolderTree.NodeID,
        target: GroupFolderTree.NodeID?,
        verticalFraction: CGFloat,
        rows: [GroupFolderTree.Row],
        in tree: GroupFolderTree
    ) -> GroupFolderDropProposal {
        let alreadyAtTopLevel = tree.parentFolderID(of: dragged) == nil

        guard let target, let index = rows.firstIndex(where: { $0.id == target }) else {
            // Below the last row: the end of the last top-level branch.
            return alreadyAtTopLevel ? .forbidden : .moveToTopLevel
        }

        if centerBand.contains(verticalFraction) {
            guard case .folder(let folderID) = target, tree.folders[folderID] != nil else {
                return .forbidden   // a group holds contacts, never folders or groups
            }
            if case .folder(let draggedID) = dragged, tree.isFolder(folderID, inSubtreeOf: draggedID) {
                return .forbidden   // into itself, or into something inside itself
            }
            if tree.parentFolderID(of: dragged) == folderID { return .forbidden }   // already there
            return .moveInto(folderID: folderID)
        }

        // A gap. It is a top-level boundary only when the row BELOW the gap is a
        // top-level row (the gap above it), or the gap is after the final row.
        let rowBelowGap = verticalFraction < centerBand.lowerBound ? index : index + 1
        let isTopLevelBoundary = rowBelowGap >= rows.count || rows[rowBelowGap].depth == 0
        guard isTopLevelBoundary, !alreadyAtTopLevel else { return .forbidden }
        return .moveToTopLevel
    }
}

// MARK: - Row layout and accessibility

enum GroupFolderRowLayout {
    static let indentStep: CGFloat = 20
    /// Width a row keeps for its icon, name, and trailing badge at any depth.
    static let minimumContentWidth: CGFloat = 200

    /// How many levels of indentation to DRAW. Logical depth is unlimited, but
    /// a narrow list would squeeze a deep row's name to nothing, so the drawn
    /// indent is capped by what the width can spare (never below two levels,
    /// which every supported width affords). The true depth and the full path
    /// stay available to assistive technology through `accessibilityLabel`.
    static func drawnIndentLevels(depth: Int, availableWidth: CGFloat) -> Int {
        let affordable = Int(((availableWidth - minimumContentWidth) / indentStep).rounded(.down))
        return min(depth, max(2, affordable))
    }

    /// "Activities, folder, 3 items, collapsed, level 2, in Family". The count is
    /// of the folder's immediate items — folders and groups — and is worded so
    /// it cannot be taken for a count of contacts.
    static func accessibilityLabel(for row: GroupFolderTree.Row, isFavorite: Bool, in tree: GroupFolderTree) -> String {
        var parts = [row.name.isEmpty ? (row.isFolder ? "Unnamed folder" : "Unnamed group") : row.name]
        parts.append(row.isFolder ? "folder" : "group")
        if row.isFolder {
            parts.append(row.childCount == 1 ? "1 item" : "\(row.childCount) items")
        }
        if isFavorite { parts.append("favorite") }
        if row.depth > 0 {
            parts.append("level \(row.depth + 1)")
            let path = tree.pathNames(to: row.id).map(GroupFolderDestination.displayName)
            if !path.isEmpty { parts.append("in " + path.joined(separator: ", ")) }
        }
        return parts.joined(separator: ", ")
    }

    /// "Expanded" / "Collapsed" for a folder that has something to show; nil
    /// otherwise, so an empty folder does not announce a state it cannot change.
    static func accessibilityValue(for row: GroupFolderTree.Row) -> String? {
        guard row.isFolder, row.childCount > 0 else { return nil }
        return row.isExpanded ? "Expanded" : "Collapsed"
    }
}

// MARK: - Expansion state

/// Which folders the user has closed, remembered on THIS device only. Storing
/// the closed ones (rather than the open ones) means a folder that is new here —
/// created just now, or synced from another device — starts open, and closing a
/// folder never forgets which of the folders inside it were open.
@MainActor
final class GroupFolderExpansionStore {
    private let defaults: UserDefaults
    private let key: String
    private(set) var collapsed: Set<String>

    init(defaults: UserDefaults = .standard, key: String = "groupsList.collapsedFolders") {
        self.defaults = defaults
        self.key = key
        self.collapsed = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func isCollapsed(_ folderID: String) -> Bool { collapsed.contains(folderID) }

    func setCollapsed(_ isCollapsed: Bool, folderID: String) {
        let changed = isCollapsed ? collapsed.insert(folderID).inserted : collapsed.remove(folderID) != nil
        guard changed else { return }
        persist()
    }

    /// Open every folder in `folderIDs` — the ancestors of a row about to be
    /// selected programmatically, which must be visible to be scrolled to.
    func expand(_ folderIDs: [String]) {
        let before = collapsed
        collapsed.subtract(folderIDs)
        if collapsed != before { persist() }
    }

    /// Forget folders that no longer exist, so the stored set cannot grow
    /// without bound. Only call with a COMPLETE tree: a folder missing because
    /// its file has not downloaded yet must keep its state.
    func prune(keeping liveFolderIDs: Set<String>) {
        let before = collapsed
        collapsed.formIntersection(liveFolderIDs)
        if collapsed != before { persist() }
    }

    private func persist() {
        defaults.set(collapsed.sorted(), forKey: key)
    }
}

// MARK: - Click arbitration (Mac Catalyst)

/// Decides between "open this folder's members" (single click) and "expand or
/// collapse it" (double click) for a pointer on Mac Catalyst.
///
/// The two cannot simply both fire, as they do in the sidebar: a single click on
/// a folder PUSHES the member list over the tree, so by the time the second
/// click of a double click arrived there would be no tree left to toggle. So a
/// folder's single click is held for the double-click interval; a double click
/// inside that window cancels it and only toggles. The cost is a short delay
/// before a folder opens. Groups are leaves — nothing to toggle — so they never
/// come through here and open at once.
///
/// UIKit does not promise which of `didSelectRowAt` and the double-tap
/// recognizer reports the second click first, so both orders are handled: a
/// double click cancels an open that is already pending, and an open scheduled
/// by the very click that completed a double click is dropped when it comes due.
@MainActor
final class GroupFolderClickArbiter {
    /// Undoes one scheduled piece of work.
    typealias Cancel = @MainActor () -> Void
    /// Schedules `work` after `delay` and returns a way to cancel it.
    typealias Scheduler = @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Cancel

    private let interval: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let schedule: Scheduler
    private var cancelPending: Cancel?
    private var lastDoubleClickAt: TimeInterval?

    /// Two clicks this close together are the same physical click reported
    /// twice (once as a selection, once as the end of a double click).
    private static let sameClickTolerance: TimeInterval = 0.1

    init(
        interval: TimeInterval = 0.3,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = GroupFolderClickArbiter.mainQueueScheduler
    ) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
    }

    /// A folder row was clicked. `open` runs after the interval unless a double
    /// click claims the click first.
    func singleClick(open: @escaping @MainActor () -> Void) {
        cancelPending?()
        let clickedAt = now()
        cancelPending = schedule(interval) { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            if let doubleClickAt = self.lastDoubleClickAt,
               doubleClickAt >= clickedAt - Self.sameClickTolerance {
                return
            }
            open()
        }
    }

    /// A double click landed on a folder row: toggle, and do not open.
    func doubleClick(toggle: () -> Void) {
        cancelPending?()
        cancelPending = nil
        lastDoubleClickAt = now()
        toggle()
    }

    /// Drop anything pending — the list is going away or the tree changed under
    /// the click.
    func cancel() {
        cancelPending?()
        cancelPending = nil
    }

    static let mainQueueScheduler: Scheduler = { delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
