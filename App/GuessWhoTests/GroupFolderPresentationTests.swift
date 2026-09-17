import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

/// The Groups tree's presentation rules (`GroupFolderPresentation.swift`,
/// `GroupMemberListPresentation.swift`) — everything the list, its menus, and
/// its drag and drop decide without needing a table view.
@MainActor
@Suite("Group folder presentation")
struct GroupFolderPresentationTests {
    // MARK: - Fixture
    //
    //   Family                       folder
    //     Activities                 folder
    //       Soccer Parents           group
    //     Immediate Family           group
    //   Friends                      folder (empty)
    //   Work                         group

    private func folder(_ id: String, _ name: String, parent: String? = nil) -> GroupFolderRecord {
        GroupFolderRecord(
            id: id, name: name,
            placement: parent.map {
                FolderPlacement(parentFolderID: $0, modifiedAt: Date(timeIntervalSince1970: 100), modifiedBy: "d/op")
            },
            deletion: nil)
    }

    private func placement(_ parent: String?) -> FolderPlacement {
        FolderPlacement(parentFolderID: parent, modifiedAt: Date(timeIntervalSince1970: 100), modifiedBy: "d/op")
    }

    private var tree: GroupFolderTree {
        GroupFolderTree(
            records: GroupHierarchyRecords(
                folders: [
                    folder("family", "Family"),
                    folder("activities", "Activities", parent: "family"),
                    folder("friends", "Friends"),
                ],
                groupPlacements: [
                    "id-soccer": placement("activities"),
                    "id-immediate": placement("family"),
                ]),
            groups: [
                .init(localID: "g-soccer", name: "Soccer Parents", identityID: "id-soccer"),
                .init(localID: "g-immediate", name: "Immediate Family", identityID: "id-immediate"),
                .init(localID: "g-work", name: "Work", identityID: nil),
            ])
    }

    private func row(_ id: GroupFolderTree.NodeID, collapsed: Set<String> = []) throws -> GroupFolderTree.Row {
        try #require(tree.visibleRows(collapsed: collapsed).first { $0.id == id })
    }

    // MARK: - Destinations

    @Test
    func newItemsDefaultToTheSelectedFolderOrTheSelectedGroupsFolder() {
        #expect(GroupFolderDestination.defaultParent(forSelection: .folder("activities"), in: tree) == "activities")
        #expect(GroupFolderDestination.defaultParent(forSelection: .group("g-soccer"), in: tree) == "activities")
        #expect(GroupFolderDestination.defaultParent(forSelection: .group("g-work"), in: tree) == nil)
        #expect(GroupFolderDestination.defaultParent(forSelection: nil, in: tree) == nil)
        #expect(GroupFolderDestination.defaultParent(forSelection: .folder("gone"), in: tree) == nil)
    }

    @Test
    func promptsSayWhereTheItemWillGoBeforeItGoes() {
        #expect(GroupFolderDestination.promptMessage(parentFolderID: "family", in: tree) == "In “Family”")
        #expect(GroupFolderDestination.promptMessage(parentFolderID: nil, in: tree) == "At the top level")
        #expect(GroupFolderDestination.deletionMessage(forFolder: "activities", in: tree)
            == "The items inside will move to “Family”.")
        #expect(GroupFolderDestination.deletionMessage(forFolder: "family", in: tree)
            == "The items inside will move to the top level.")
    }

    // MARK: - Move targets

    @Test
    func aFolderCannotBeOfferedItselfOrAnythingInsideIt() {
        let forFamily = GroupFolderMoveTargets.targets(for: .folder("family"), in: tree)
        #expect(forFamily.map(\.folderID) == ["friends"])

        let forActivities = GroupFolderMoveTargets.targets(for: .folder("activities"), in: tree)
        #expect(forActivities.map(\.folderID) == ["family", "friends"])
        // Its current parent is shown, marked, and its own branch is gone.
        #expect(forActivities[0].isCurrentParent)
        #expect(forActivities[0].children.isEmpty)
    }

    @Test
    func aGroupIsOfferedEveryFolderNestedAsTheListNestsThem() {
        let targets = GroupFolderMoveTargets.targets(for: .group("g-soccer"), in: tree)

        #expect(targets.map(\.name) == ["Family", "Friends"])
        #expect(targets[0].children.map(\.name) == ["Activities"])
        #expect(targets[0].children[0].isCurrentParent)
        #expect(targets[0].isCurrentParent == false)
    }

    @Test
    func moveToTopLevelIsOfferedInsideAFolderAndForAnItemTheTreeCouldNotPlace() {
        #expect(GroupFolderMoveTargets.offersMoveToTopLevel(for: .group("g-soccer"), in: tree))
        #expect(GroupFolderMoveTargets.offersMoveToTopLevel(for: .folder("activities"), in: tree))
        #expect(GroupFolderMoveTargets.offersMoveToTopLevel(for: .group("g-work"), in: tree) == false)
        #expect(GroupFolderMoveTargets.offersMoveToTopLevel(for: .folder("family"), in: tree) == false)

        // Shown at the top level only because its saved folder never arrived:
        // moving it to the top level is how the user settles it.
        let stranded = GroupFolderTree(
            records: GroupHierarchyRecords(folders: [folder("lost", "Lost", parent: "never-synced")]),
            groups: [])
        #expect(stranded.folders["lost"]?.parentFolderID == nil)
        #expect(GroupFolderMoveTargets.offersMoveToTopLevel(for: .folder("lost"), in: stranded))
    }

    // MARK: - Add to Group nesting

    private indirect enum Entry: Equatable {
        case group(String)
        case folder(String, [Entry])
    }

    /// Only groups are choices; a folder is a heading, and a folder with no
    /// group anywhere beneath it is dropped rather than shown as a dead end.
    @Test
    func foldNestsGroupsUnderFolderHeadingsAndDropsEmptyBranches() {
        let entries: [Entry] = GroupFolderTreeFold.fold(
            tree,
            group: { .group($0.name) },
            folder: { folder, children in children.isEmpty ? nil : .folder(folder.name, children) })

        #expect(entries == [
            .folder("Family", [
                .folder("Activities", [.group("Soccer Parents")]),
                .group("Immediate Family"),
            ]),
            .group("Work"),
        ])
    }

    @Test
    func foldHandlesAVeryDeepTreeWithoutRecursion() {
        let depth = 1_000
        var folders = [folder("f0", "F0")]
        for index in 1..<depth { folders.append(folder("f\(index)", "F\(index)", parent: "f\(index - 1)")) }
        let deep = GroupFolderTree(
            records: GroupHierarchyRecords(
                folders: folders, groupPlacements: ["id-g": placement("f\(depth - 1)")]),
            groups: [.init(localID: "g", name: "Deep", identityID: "id-g")])

        let counts: [Int] = GroupFolderTreeFold.fold(
            deep, group: { _ in 1 }, folder: { _, children in children.reduce(0, +) })

        #expect(counts == [1])
        #expect(GroupFolderMoveTargets.targets(for: .group("g"), in: deep).count == 1)
    }

    // MARK: - Drag and drop

    private func proposal(
        _ dragged: GroupFolderTree.NodeID, onto target: GroupFolderTree.NodeID?, at fraction: CGFloat
    ) -> GroupFolderDropProposal {
        GroupFolderDropPolicy.proposal(
            dragged: dragged, target: target, verticalFraction: fraction,
            rows: tree.visibleRows(), in: tree)
    }

    @Test
    func droppingOnAFoldersCenterMovesInside() {
        #expect(proposal(.group("g-work"), onto: .folder("friends"), at: 0.5) == .moveInto(folderID: "friends"))
        #expect(proposal(.folder("friends"), onto: .folder("activities"), at: 0.5) == .moveInto(folderID: "activities"))
    }

    @Test
    func invalidCenterDropsAreRefused() {
        // A group holds contacts, never groups or folders.
        #expect(proposal(.group("g-work"), onto: .group("g-soccer"), at: 0.5) == .forbidden)
        // Into itself, or into something inside itself.
        #expect(proposal(.folder("family"), onto: .folder("family"), at: 0.5) == .forbidden)
        #expect(proposal(.folder("family"), onto: .folder("activities"), at: 0.5) == .forbidden)
        // Already there.
        #expect(proposal(.group("g-soccer"), onto: .folder("activities"), at: 0.5) == .forbidden)
    }

    /// Siblings are alphabetical, so a gap can only ever mean "out to the top
    /// level" — and only at the boundary of a top-level branch.
    @Test
    func gapsPromoteToTopLevelOnlyAtATopLevelBoundary() {
        // Rows: Family, Activities, Soccer Parents, Immediate Family, Friends, Work.
        // The gap above "Friends" ends the Family branch.
        #expect(proposal(.group("g-soccer"), onto: .folder("friends"), at: 0.05) == .moveToTopLevel)
        #expect(proposal(.group("g-soccer"), onto: .group("g-immediate"), at: 0.95) == .moveToTopLevel)
        // Below the last row.
        #expect(proposal(.group("g-soccer"), onto: nil, at: 0.5) == .moveToTopLevel)
        // A gap INSIDE a folder would imply an order the list does not have.
        #expect(proposal(.group("g-work"), onto: .group("g-soccer"), at: 0.05) == .forbidden)
        #expect(proposal(.group("g-soccer"), onto: .folder("activities"), at: 0.05) == .forbidden)
        // Already at the top level: nothing to promote.
        #expect(proposal(.group("g-work"), onto: .folder("friends"), at: 0.05) == .forbidden)
        #expect(proposal(.group("g-work"), onto: nil, at: 0.5) == .forbidden)
    }

    // MARK: - Rows

    @Test
    func drawnIndentIsCappedByWidthButNeverBelowTwoLevels() {
        #expect(GroupFolderRowLayout.drawnIndentLevels(depth: 1, availableWidth: 320) == 1)
        #expect(GroupFolderRowLayout.drawnIndentLevels(depth: 40, availableWidth: 320) == 6)
        #expect(GroupFolderRowLayout.drawnIndentLevels(depth: 40, availableWidth: 100) == 2)
        #expect(GroupFolderRowLayout.drawnIndentLevels(depth: 3, availableWidth: 1_000) == 3)
    }

    /// The count is of a folder's immediate ITEMS and is worded so it cannot be
    /// taken for a count of contacts; depth and path survive the indent cap.
    @Test
    func accessibilityLabelCarriesKindCountDepthAndPath() throws {
        let family = try row(.folder("family"))
        #expect(GroupFolderRowLayout.accessibilityLabel(for: family, isFavorite: false, in: tree)
            == "Family, folder, 2 items")
        #expect(GroupFolderRowLayout.accessibilityValue(for: family) == "Expanded")

        let activities = try row(.folder("activities"), collapsed: ["activities"])
        #expect(GroupFolderRowLayout.accessibilityLabel(for: activities, isFavorite: false, in: tree)
            == "Activities, folder, 1 item, level 2, in Family")
        #expect(GroupFolderRowLayout.accessibilityValue(for: activities) == "Collapsed")

        let soccer = try row(.group("g-soccer"))
        #expect(GroupFolderRowLayout.accessibilityLabel(for: soccer, isFavorite: true, in: tree)
            == "Soccer Parents, group, favorite, level 3, in Family, Activities")
        #expect(GroupFolderRowLayout.accessibilityValue(for: soccer) == nil)

        // An empty folder announces no state it cannot change.
        #expect(GroupFolderRowLayout.accessibilityValue(for: try row(.folder("friends"))) == nil)
    }

    // MARK: - Expansion state

    @Test
    func expansionStorePersistsClosedFoldersAndNewFoldersStartOpen() throws {
        let suite = "group-folder-expansion-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = GroupFolderExpansionStore(defaults: defaults)
        #expect(store.isCollapsed("family") == false)
        store.setCollapsed(true, folderID: "family")
        store.setCollapsed(true, folderID: "activities")

        // A relaunch reads the same state; a folder never seen before is open.
        let relaunched = GroupFolderExpansionStore(defaults: defaults)
        #expect(relaunched.collapsed == ["family", "activities"])
        #expect(relaunched.isCollapsed("brand-new") == false)

        // Re-opening the parent keeps the child's own choice.
        relaunched.setCollapsed(false, folderID: "family")
        #expect(relaunched.collapsed == ["activities"])

        relaunched.expand(["activities", "family"])
        #expect(relaunched.collapsed.isEmpty)

        relaunched.setCollapsed(true, folderID: "deleted-folder")
        relaunched.prune(keeping: ["family"])
        #expect(GroupFolderExpansionStore(defaults: defaults).collapsed.isEmpty)
    }

    // MARK: - Click arbitration

    /// A manual clock and scheduler, so the arbitration is tested without waiting.
    @MainActor
    private final class ManualScheduler {
        var now: TimeInterval = 0
        private var scheduled: [(due: TimeInterval, id: Int, work: @MainActor () -> Void)] = []
        private var cancelled: Set<Int> = []
        private var nextID = 0

        func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            let id = nextID
            nextID += 1
            scheduled.append((now + delay, id, work))
            return { [weak self] in self?.cancelled.insert(id) }
        }

        func advance(to time: TimeInterval) {
            now = time
            let due = scheduled.filter { $0.due <= time }.sorted { $0.due < $1.due }
            scheduled.removeAll { $0.due <= time }
            for item in due where !cancelled.contains(item.id) { item.work() }
        }
    }

    private func makeArbiter(_ scheduler: ManualScheduler) -> GroupFolderClickArbiter {
        GroupFolderClickArbiter(
            interval: 0.3,
            now: { scheduler.now },
            schedule: { delay, work in scheduler.schedule(delay, work) })
    }

    @Test
    func aSingleClickOpensAfterTheDoubleClickInterval() {
        let scheduler = ManualScheduler()
        let arbiter = makeArbiter(scheduler)
        var opened = 0

        arbiter.singleClick { opened += 1 }
        scheduler.advance(to: 0.29)
        #expect(opened == 0)
        scheduler.advance(to: 0.31)
        #expect(opened == 1)
    }

    /// UIKit does not promise whether the selection or the double-tap reports
    /// the second click first. Either way: toggle once, never open.
    @Test(arguments: [true, false])
    func aDoubleClickTogglesOnceAndNeverOpens(selectionReportsSecondClickFirst: Bool) {
        let scheduler = ManualScheduler()
        let arbiter = makeArbiter(scheduler)
        var opened = 0
        var toggled = 0

        arbiter.singleClick { opened += 1 }
        scheduler.advance(to: 0.15)
        if selectionReportsSecondClickFirst {
            arbiter.singleClick { opened += 1 }
            arbiter.doubleClick { toggled += 1 }
        } else {
            arbiter.doubleClick { toggled += 1 }
            arbiter.singleClick { opened += 1 }
        }
        scheduler.advance(to: 2)

        #expect(toggled == 1)
        #expect(opened == 0)
    }

    @Test
    func aLaterSingleClickStillOpensAfterADoubleClick() {
        let scheduler = ManualScheduler()
        let arbiter = makeArbiter(scheduler)
        var opened = 0

        arbiter.singleClick { opened += 1 }
        scheduler.advance(to: 0.15)
        arbiter.doubleClick {}
        scheduler.advance(to: 5)
        arbiter.singleClick { opened += 1 }
        scheduler.advance(to: 6)

        #expect(opened == 1)
    }

    @Test
    func cancelDropsAPendingOpen() {
        let scheduler = ManualScheduler()
        let arbiter = makeArbiter(scheduler)
        var opened = 0

        arbiter.singleClick { opened += 1 }
        arbiter.cancel()
        scheduler.advance(to: 1)

        #expect(opened == 0)
    }

    // MARK: - Errors

    @Test
    func errorCopyIsPlainLanguage() {
        let messages = [
            GroupFolderErrorPresentation.message(for: GroupHierarchyError.wouldCreateCycle),
            GroupFolderErrorPresentation.message(for: GroupHierarchyError.folderDeleted("x")),
            GroupFolderErrorPresentation.message(for: GroupHierarchyError.lossyEnvelope(
                SidecarKey(kind: .groupFolder, id: "x"))),
            GroupFolderErrorPresentation.message(for: GroupHierarchyError.invalidName),
            GroupFolderErrorPresentation.message(for: SidecarUnavailableError()),
            GroupFolderErrorPresentation.message(for: CocoaError(.fileNoSuchFile)),
        ]
        #expect(messages[0].contains("into itself"))
        #expect(messages[1] == "That folder no longer exists.")
        // Nothing about how any of it is stored may reach the user.
        for message in messages {
            for word in ["sidecar", "envelope", "identity", "UUID", "reconcile", "iCloud", "cell"] {
                #expect(!message.localizedCaseInsensitiveContains(word), "\(word) in: \(message)")
            }
        }
    }

    // MARK: - Member list wording

    private func snapshot(
        groups: [ContactGroup], contacts: [Contact] = [], failed: [ContactGroup] = []
    ) -> GroupMemberSnapshot {
        GroupMemberSnapshot(
            scope: .folder(id: "family"),
            groups: groups,
            contacts: contacts,
            contributingGroups: [:],
            failedGroups: failed,
            revisions: .init(hierarchy: 0, membership: 0, contactData: 0))
    }

    @Test
    func memberListNeverPassesAPartialAnswerOffAsTheWholeOne() {
        let work = ContactGroup(localID: "g", name: "Work")
        let other = ContactGroup(localID: "h", name: "Other")
        let ann = Contact(givenName: "Ann")

        let loading = GroupMemberListPresentation.make(snapshot: nil, visibleRowCount: 0, searchQuery: "")
        #expect(loading.showsSpinner)
        #expect(loading.emptyMessage == nil)

        let noGroups = GroupMemberListPresentation.make(
            snapshot: snapshot(groups: []), visibleRowCount: 0, searchQuery: "")
        #expect(noGroups.emptyMessage == "No Groups in This Folder")

        let noMembers = GroupMemberListPresentation.make(
            snapshot: snapshot(groups: [work]), visibleRowCount: 0, searchQuery: "")
        #expect(noMembers.emptyMessage == "No Members")
        #expect(noMembers.showsPartialBanner == false)

        // Nothing to show BECAUSE a group failed: not "No Members".
        let unavailable = GroupMemberListPresentation.make(
            snapshot: snapshot(groups: [work], failed: [work]), visibleRowCount: 0, searchQuery: "")
        #expect(unavailable.emptyMessage == "Couldn’t Load Members")
        #expect(unavailable.showsPartialBanner)

        // Some loaded, some did not: the rows show, under the banner.
        let partial = GroupMemberListPresentation.make(
            snapshot: snapshot(groups: [work, other], contacts: [ann], failed: [other]),
            visibleRowCount: 1, searchQuery: "")
        #expect(partial.emptyMessage == nil)
        #expect(partial.showsPartialBanner)

        // Members exist; the search hid them all.
        let filtered = GroupMemberListPresentation.make(
            snapshot: snapshot(groups: [work], contacts: [ann]), visibleRowCount: 0, searchQuery: " zed ")
        #expect(filtered.emptyMessage == "No members match \"zed\".")
    }
}
