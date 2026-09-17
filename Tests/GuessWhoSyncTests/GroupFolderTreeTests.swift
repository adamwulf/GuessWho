import Foundation
import Testing
@testable import GuessWhoSync

/// The pure tree projection (`plans/group-folders.md`, delivery step 2). No
/// storage and no repository here: records in, tree out.
@Suite("Group folder tree")
struct GroupFolderTreeTests {
    typealias Tree = GroupFolderTree

    // MARK: - Builders

    private func placement(_ parent: String?, at seconds: TimeInterval, by writer: String) -> FolderPlacement {
        FolderPlacement(
            parentFolderID: parent,
            modifiedAt: Date(timeIntervalSince1970: seconds),
            modifiedBy: writer)
    }

    /// A live folder. `parent: .some(nil)` is an explicit top-level assignment;
    /// omitting `parent` means no placement was ever written.
    private func folder(
        _ id: String, _ name: String,
        parent: String?? = .none,
        at seconds: TimeInterval = 100,
        by writer: String = "device-A/op"
    ) -> GroupFolderRecord {
        GroupFolderRecord(
            id: id, name: name,
            placement: parent.map { placement($0, at: seconds, by: writer) },
            deletion: nil)
    }

    private func deletedFolder(
        _ id: String, parent: String? = nil, promotedTo: String?
    ) -> GroupFolderRecord {
        GroupFolderRecord(
            id: id, name: "",
            placement: parent.map { placement($0, at: 50, by: "device-A/op") },
            deletion: FolderDeletion(
                promotedToFolderID: promotedTo,
                modifiedAt: Date(timeIntervalSince1970: 200),
                modifiedBy: "device-A/delete"))
    }

    private func group(_ localID: String, _ name: String, identity: String? = nil) -> Tree.GroupInput {
        Tree.GroupInput(localID: localID, name: name, identityID: identity)
    }

    private func records(
        _ folders: [GroupFolderRecord],
        placing placements: [String: String?] = [:]
    ) -> GroupHierarchyRecords {
        GroupHierarchyRecords(
            folders: folders,
            groupPlacements: placements.mapValues { placement($0, at: 100, by: "device-A/op") })
    }

    private func names(_ rows: [Tree.Row]) -> [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + $0.name }
    }

    // MARK: - The example from the plan

    private var familyTree: Tree {
        Tree(
            records: records(
                [
                    folder("family", "Family"),
                    folder("activities", "Activities", parent: "family"),
                ],
                placing: [
                    "id-immediate": "family",
                    "id-extended": "family",
                    "id-soccer": "activities",
                ]),
            groups: [
                group("g-soccer", "Soccer Parents", identity: "id-soccer"),
                group("g-immediate", "Immediate Family", identity: "id-immediate"),
                group("g-extended", "Extended Family", identity: "id-extended"),
                group("g-work", "Work"),
            ])
    }

    @Test
    func rowsShowFoldersAndGroupsMixedAlphabeticallyWithDepth() {
        let rows = familyTree.visibleRows()

        #expect(names(rows) == [
            "Family",
            "  Activities",
            "    Soccer Parents",
            "  Extended Family",
            "  Immediate Family",
            "Work",
        ])
        let family = rows[0]
        #expect(family.isFolder && family.isExpanded)
        // IMMEDIATE children: one folder and two groups — not contacts, and not
        // the group nested inside Activities.
        #expect(family.childCount == 3)
        #expect(rows[5].childCount == 0)
        #expect(rows[5].isFolder == false)
    }

    /// Collapsing hides rows. It never changes what a folder contains.
    @Test
    func collapsingHidesRowsButNotDescendantGroups() {
        let tree = familyTree

        let rows = tree.visibleRows(collapsed: ["activities"])

        #expect(names(rows) == ["Family", "  Activities", "  Extended Family", "  Immediate Family", "Work"])
        #expect(rows[1].isExpanded == false)
        #expect(rows[1].childCount == 1)
        #expect(tree.visibleRows(collapsed: ["family"]).map(\.name) == ["Family", "Work"])
        #expect(Set(tree.descendantGroupLocalIDs(ofFolder: "family"))
            == ["g-soccer", "g-immediate", "g-extended"])
        #expect(tree.descendantGroupLocalIDs(ofFolder: "activities") == ["g-soccer"])
    }

    @Test
    func pathsAndAncestryAreComputedOnDemand() {
        let tree = familyTree

        #expect(tree.pathNames(to: .group("g-soccer")) == ["Family", "Activities"])
        #expect(tree.ancestorFolderIDs(of: .group("g-soccer")) == ["activities", "family"])
        #expect(tree.pathNames(to: .folder("family")).isEmpty)
        #expect(tree.isFolder("activities", inSubtreeOf: "family"))
        #expect(tree.isFolder("family", inSubtreeOf: "family"))
        #expect(tree.isFolder("family", inSubtreeOf: "activities") == false)
    }

    // MARK: - Order

    @Test
    func equalNamesKeepAStableOrderAtEveryLevel() {
        let tree = Tree(
            records: records(
                [
                    folder("f2", "team"),
                    folder("f1", "Team"),
                    folder("box", "Box"),
                    folder("n2", "same", parent: "box"),
                    folder("n1", "Same", parent: "box"),
                ],
                placing: ["id-n": "box"]),
            groups: [
                group("g1", "TEAM"),
                group("gn", "SAME", identity: "id-n"),
            ])

        // Case-insensitively equal, so the typed id decides: "folder:…" sorts
        // before "group:…", and ids in order within a type. Same rule nested.
        #expect(tree.children(of: nil) == [.folder("box"), .folder("f1"), .folder("f2"), .group("g1")])
        #expect(tree.children(of: "box") == [.folder("n1"), .folder("n2"), .group("gn")])
    }

    // MARK: - Groups

    @Test
    func groupsWithoutAnIdentityOrPlacementSitAtTopLevel() {
        let tree = Tree(
            records: records([folder("family", "Family")], placing: ["id-cleared": nil as String?]),
            groups: [
                group("g-none", "No Identity"),
                group("g-unplaced", "Unplaced", identity: "id-unplaced"),
                group("g-cleared", "Cleared", identity: "id-cleared"),
            ])

        for localID in ["g-none", "g-unplaced", "g-cleared"] {
            #expect(tree.groups[localID]?.parentFolderID == nil)
            #expect(tree.groups[localID]?.status == .asStored)
        }
        #expect(tree.children(of: "family").isEmpty)
    }

    /// A placement whose identity resolves to no group on this device produces
    /// no row: the tree only ever shows groups the caller handed it.
    @Test
    func placementForAGroupNotOnThisDeviceProducesNoRow() {
        let tree = Tree(
            records: records([folder("family", "Family")], placing: ["id-elsewhere": "family"]),
            groups: [group("g-here", "Here")])

        #expect(tree.children(of: "family").isEmpty)
        #expect(tree.visibleRows().map(\.name) == ["Family", "Here"])
    }

    @Test
    func aGroupSuppliedTwiceAppearsOnce() {
        let tree = Tree(
            records: records([]),
            groups: [group("g", "Work"), group("g", "Work")])
        #expect(tree.rootChildren == [.group("g")])
    }

    // MARK: - Unknown and deleted parents

    /// Unknown is not deleted. The child waits at top level with its assignment
    /// intact, and lands in the folder when the parent syncs in.
    @Test
    func unknownParentIsProvisionalAndKeepsTheStoredAssignment() {
        let before = Tree(
            records: records([folder("child", "Child", parent: "late")], placing: ["id-g": "late"]),
            groups: [group("g", "Group", identity: "id-g")])

        #expect(before.folders["child"]?.parentFolderID == nil)
        #expect(before.folders["child"]?.storedParentFolderID == "late")
        #expect(before.folders["child"]?.status == .parentUnavailable)
        #expect(before.groups["g"]?.status == .parentUnavailable)
        #expect(before.groups["g"]?.storedParentFolderID == "late")

        let after = Tree(
            records: records(
                [folder("child", "Child", parent: "late"), folder("late", "Late")],
                placing: ["id-g": "late"]),
            groups: [group("g", "Group", identity: "id-g")])

        #expect(after.folders["child"]?.parentFolderID == "late")
        #expect(after.folders["child"]?.status == .asStored)
        #expect(after.children(of: "late") == [.folder("child"), .group("g")])
    }

    @Test
    func deletedFolderPromotesItsContentsThroughItsMarker() {
        let tree = Tree(
            records: records(
                [
                    folder("family", "Family"),
                    deletedFolder("activities", parent: "family", promotedTo: "family"),
                    folder("sports", "Sports", parent: "activities"),
                ],
                placing: ["id-soccer": "activities"]),
            groups: [group("g-soccer", "Soccer Parents", identity: "id-soccer")])

        #expect(tree.folders["activities"] == nil)
        #expect(tree.children(of: "family") == [.group("g-soccer"), .folder("sports")])
        #expect(tree.folders["sports"]?.status == .redirected)
        // Nothing was rewritten: the children still name the deleted folder.
        #expect(tree.folders["sports"]?.storedParentFolderID == "activities")
        #expect(tree.groups["g-soccer"]?.storedParentFolderID == "activities")
    }

    @Test
    func redirectsFollowChainsOfDeletedFoldersAndEndAtTopLevel() {
        let tree = Tree(
            records: records([
                folder("top", "Top"),
                deletedFolder("d1", promotedTo: "d2"),
                deletedFolder("d2", promotedTo: "top"),
                deletedFolder("d3", promotedTo: nil),
                folder("a", "A", parent: "d1"),
                folder("b", "B", parent: "d3"),
            ]),
            groups: [])

        #expect(tree.folders["a"]?.parentFolderID == "top")
        #expect(tree.folders["a"]?.status == .redirected)
        #expect(tree.folders["b"]?.parentFolderID == nil)
        #expect(tree.folders["b"]?.status == .redirected)
    }

    @Test
    func redirectLoopsAndMissingTargetsFallBackToTopLevel() {
        let tree = Tree(
            records: records([
                deletedFolder("d1", promotedTo: "d2"),
                deletedFolder("d2", promotedTo: "d1"),
                deletedFolder("d3", promotedTo: "never-synced"),
                folder("looped", "Looped", parent: "d1"),
                folder("dangling", "Dangling", parent: "d3"),
            ]),
            groups: [])

        #expect(tree.folders["looped"]?.parentFolderID == nil)
        #expect(tree.folders["looped"]?.status == .redirectLoop)
        #expect(tree.folders["dangling"]?.parentFolderID == nil)
        #expect(tree.folders["dangling"]?.status == .parentUnavailable)
        #expect(tree.visibleRows().map(\.name) == ["Dangling", "Looped"])
    }

    // MARK: - Cycles

    /// Two devices each made a valid move; together they form a cycle. Exactly
    /// the OLDEST edge is suppressed, and an edge that merely leads into the
    /// cycle is left alone.
    @Test
    func cycleSuppressesOnlyItsOldestEdge() {
        let tree = Tree(
            records: records([
                folder("a", "A", parent: "b", at: 100),
                folder("b", "B", parent: "a", at: 200),
                folder("tail", "Tail", parent: "a", at: 1),
            ]),
            groups: [])

        #expect(tree.folders["a"]?.status == .cycleSuppressed)
        #expect(tree.folders["a"]?.parentFolderID == nil)
        #expect(tree.folders["a"]?.storedParentFolderID == "b")
        #expect(tree.folders["b"]?.status == .asStored)
        #expect(tree.folders["b"]?.parentFolderID == "a")
        // Older than both cycle edges, but not ON the cycle.
        #expect(tree.folders["tail"]?.status == .asStored)
        #expect(names(tree.visibleRows()) == ["A", "  B", "  Tail"])
    }

    @Test
    func cycleTiesBreakByWriterThenByFolder() {
        let sameStampDifferentWriter = Tree(
            records: records([
                folder("a", "A", parent: "b", at: 100, by: "device-B/op"),
                folder("b", "B", parent: "c", at: 100, by: "device-A/op"),
                folder("c", "C", parent: "a", at: 100, by: "device-C/op"),
            ]),
            groups: [])
        #expect(sameStampDifferentWriter.folders.values.filter { $0.status == .cycleSuppressed }.map(\.id) == ["b"])

        let identicalStamps = Tree(
            records: records([
                folder("y", "Y", parent: "x", at: 100, by: "same/op"),
                folder("x", "X", parent: "y", at: 100, by: "same/op"),
            ]),
            groups: [])
        #expect(identicalStamps.folders.values.filter { $0.status == .cycleSuppressed }.map(\.id) == ["x"])
    }

    /// Suppression is a reading, not a repair. When another edge of the cycle
    /// changes, the suppressed assignment takes effect again.
    @Test
    func suppressedEdgeBecomesEffectiveAgainWhenTheCycleIsBroken() {
        let broken = Tree(
            records: records([
                folder("a", "A", parent: "b", at: 100),
                folder("b", "B", parent: .some(nil), at: 300),
            ]),
            groups: [])

        #expect(broken.folders["a"]?.status == .asStored)
        #expect(broken.folders["a"]?.parentFolderID == "b")
        #expect(names(broken.visibleRows()) == ["B", "  A"])
    }

    /// A cycle can close THROUGH a deleted folder's redirect. The edge keeps
    /// the stamp of the placement that created it.
    @Test
    func cycleThroughARedirectUsesTheOriginatingStamp() {
        let tree = Tree(
            records: records([
                deletedFolder("gone", promotedTo: "b"),
                folder("a", "A", parent: "gone", at: 100),
                folder("b", "B", parent: "a", at: 200),
            ]),
            groups: [])

        #expect(tree.folders["a"]?.status == .cycleSuppressed)
        #expect(tree.folders["b"]?.parentFolderID == "a")
    }

    @Test
    func groupsInsideACycleStayWithTheirFolder() {
        let tree = Tree(
            records: records(
                [
                    folder("a", "A", parent: "b", at: 100),
                    folder("b", "B", parent: "a", at: 200),
                ],
                placing: ["id-g": "b"]),
            groups: [group("g", "Group", identity: "id-g")])

        #expect(tree.groups["g"]?.parentFolderID == "b")
        #expect(tree.groups["g"]?.status == .asStored)
        #expect(tree.descendantGroupLocalIDs(ofFolder: "a") == ["g"])
    }

    // MARK: - Determinism and scale

    @Test
    func shufflingTheSameInputsYieldsTheSameForest() {
        var folders: [GroupFolderRecord] = [
            deletedFolder("gone", promotedTo: "f3"),
            deletedFolder("loop1", promotedTo: "loop2"),
            deletedFolder("loop2", promotedTo: "loop1"),
            // A three-folder cycle whose stamps tie, so the tie-breaks run too.
            folder("c1", "Cycle", parent: "c2", at: 500, by: "device-1/op"),
            folder("c2", "Cycle", parent: "c3", at: 500, by: "device-0/op"),
            folder("c3", "Cycle", parent: "c1", at: 500, by: "device-0/op"),
        ]
        for index in 0..<40 {
            let parent: String?? = switch index % 5 {
            case 0: .none
            case 1: .some("f\((index * 7) % 40)")
            case 2: .some("gone")
            case 3: .some("f\((index + 1) % 40)")
            default: .some("loop1")
            }
            folders.append(folder(
                "f\(index)", "Folder \(index % 6)", parent: parent,
                at: TimeInterval(100 + index % 4), by: "device-\(index % 3)/op"))
        }
        var placements: [String: String?] = [:]
        var groups: [Tree.GroupInput] = []
        for index in 0..<30 {
            placements["id-\(index)"] = "f\((index * 3) % 40)"
            groups.append(group("g\(index)", "Group \(index % 4)", identity: "id-\(index)"))
        }
        let reference = Tree(records: records(folders, placing: placements), groups: groups)
        #expect(reference.folders.values.contains { $0.status == .cycleSuppressed })

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<25 {
            let shuffled = Tree(
                records: records(folders.shuffled(using: &generator), placing: placements),
                groups: groups.shuffled(using: &generator))
            #expect(shuffled == reference)
            #expect(shuffled.visibleRows() == reference.visibleRows())
        }
    }

    /// Unlimited logical depth must stay usable: no traversal may recurse.
    @Test
    func aThousandFolderChainBuildsAndTraversesIteratively() {
        let depth = 1_000
        var folders = [folder("f0", "Folder 0")]
        for index in 1..<depth {
            folders.append(folder("f\(index)", "Folder \(index)", parent: "f\(index - 1)"))
        }
        let tree = Tree(
            records: records(folders, placing: ["id-deep": "f\(depth - 1)"]),
            groups: [group("g-deep", "Deep Group", identity: "id-deep")])

        let rows = tree.visibleRows()
        #expect(rows.count == depth + 1)
        #expect(rows.last?.name == "Deep Group")
        #expect(rows.last?.depth == depth)
        #expect(tree.ancestorFolderIDs(of: .group("g-deep")).count == depth)
        #expect(tree.pathNames(to: .group("g-deep")).first == "Folder 0")
        #expect(tree.descendantGroupLocalIDs(ofFolder: "f0") == ["g-deep"])
        #expect(tree.visibleRows(collapsed: ["f0"]).count == 1)
    }

    @Test
    func aThousandFolderCycleSuppressesExactlyOneEdge() {
        let count = 1_000
        let folders = (0..<count).map { index in
            folder(
                "f\(index)", "Folder \(index)", parent: "f\((index + 1) % count)",
                at: TimeInterval(1_000 + index))
        }
        let tree = Tree(records: records(folders), groups: [])

        let suppressed = tree.folders.values.filter { $0.status == .cycleSuppressed }
        #expect(suppressed.map(\.id) == ["f0"])
        #expect(tree.visibleRows().count == count)
    }

    // MARK: - Completeness

    @Test
    func incompleteAndUntrustworthyRecordsAreReportedOnTheTree() {
        let unreadable = SidecarKey(kind: .groupFolder, id: "pending")
        let unavailable = SidecarKey(kind: .group, id: "broken")
        let tree = Tree(
            records: GroupHierarchyRecords(
                folders: [folder("a", "A")],
                unavailableKeys: [unavailable],
                unreadableKeys: [unreadable]),
            groups: [])

        #expect(tree.isComplete == false)
        #expect(tree.unavailableKeys == [unavailable])
        #expect(Tree(records: records([]), groups: []).isComplete)
        #expect(Tree.empty.visibleRows().isEmpty)
    }
}
