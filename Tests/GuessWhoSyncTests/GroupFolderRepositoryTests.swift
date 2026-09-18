import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// The repository's group hierarchy: the tree snapshot, the folder commands,
/// and the two remaining golden cases of `plans/group-folders.md` ("Group
/// identity sync"), on the same two-device harness as `GroupIdentitySyncTests`.
@Suite("Group folders — repository", .serialized)
@MainActor
struct GroupFolderRepositoryTests {
    typealias World = GroupIdentitySyncTests.World
    typealias Device = GroupIdentitySyncTests.Device
    typealias Delivery = GroupIdentitySyncTests.Delivery

    private func makeWorld() throws -> World {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-group-folders-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return World(root: root)
    }

    private func rows(_ device: Device) -> [String] {
        device.repository.groupFolderTree.visibleRows().map {
            String(repeating: "  ", count: $0.depth) + $0.name
        }
    }

    // MARK: - Golden case 2: a non-favorited group moved into a folder

    @Test
    func groupPlacedOnDeviceA_showsInTheFolderOnDeviceBAtLoad() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Soccer Parents")
        await world.a.repository.loadGroups()

        let folderID = try await world.a.repository.createGroupFolder(name: "Activities", inFolder: nil)
        try await world.a.repository.moveGroup(groupA, toFolder: folderID)
        #expect(rows(world.a) == ["Activities", "  Soccer Parents"])

        await world.b.repository.loadGroups()

        #expect(world.b.repository.groupFolderTree.groups[groupB.localID]?.parentFolderID == folderID)
        #expect(rows(world.b) == ["Activities", "  Soccer Parents", "Device B Only"])
        // Placing a group never makes it a favorite, on either device.
        #expect(world.b.repository.isGroupFavorite(groupB) == false)
        #expect(try world.b.favorites.loadAll().isEmpty)
    }

    @Test(arguments: [Delivery.exactKey, .coarseGroupKind, .unknownScope])
    func groupPlacedWhileDeviceBRuns_showsInTheFolderOnDelivery(_ delivery: Delivery) async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Soccer Parents")
        await world.a.repository.loadGroups()
        await world.b.repository.loadGroups()
        let revisionBefore = world.b.repository.groupHierarchyRevision

        let folderID = try await world.a.repository.createGroupFolder(name: "Activities", inFolder: nil)
        try await world.a.repository.moveGroup(groupA, toFolder: folderID)
        let identityID = try #require(try world.a.sync.allGroupIdentities().first?.id)
        #expect(world.b.repository.groupFolderTree.groups[groupB.localID]?.parentFolderID == nil)

        // The identity file and the folder file, as one watcher burst.
        let changeSet: SidecarChangeSet = switch delivery {
        case .exactKey:
            SidecarChangeSet(changedKeys: [
                SidecarKey(kind: .group, id: identityID),
                SidecarKey(kind: .groupFolder, id: folderID),
            ])
        case .coarseGroupKind:
            SidecarChangeSet(changedKeys: nil, changedKinds: [.group, .groupFolder])
        case .unknownScope:
            .fullRefresh
        }
        #expect(await world.b.deliver(changeSet))

        #expect(rows(world.b) == ["Activities", "  Soccer Parents", "Device B Only"])
        #expect(world.b.repository.groupHierarchyRevision > revisionBefore)
    }

    /// The two files of one move can arrive in separate bursts, in either
    /// order. Whatever arrives first must not be lost or misread.
    @Test(arguments: [true, false])
    func placementAndFolderArrivingSeparately_convergeInEitherOrder(folderFirst: Bool) async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Soccer Parents")
        await world.a.repository.loadGroups()
        await world.b.repository.loadGroups()
        let folderID = try await world.a.repository.createGroupFolder(name: "Activities", inFolder: nil)
        try await world.a.repository.moveGroup(groupA, toFolder: folderID)
        let identityID = try #require(try world.a.sync.allGroupIdentities().first?.id)
        let folderChange = SidecarChangeSet(changedKeys: [SidecarKey(kind: .groupFolder, id: folderID)])
        let groupChange = SidecarChangeSet(changedKeys: [SidecarKey(kind: .group, id: identityID)])

        #expect(await world.b.deliver(folderFirst ? folderChange : groupChange))
        #expect(await world.b.deliver(folderFirst ? groupChange : folderChange))

        #expect(world.b.repository.groupFolderTree.groups[groupB.localID]?.parentFolderID == folderID)
        #expect(world.b.repository.groupFolderTree.groups[groupB.localID]?.status == .asStored)
    }

    /// A folder-only delivery re-reads the hierarchy and nothing else: a folder
    /// another device renamed shows its new name.
    @Test(arguments: [true, false])
    func folderOnlyDelivery_updatesTheTree(coarse: Bool) async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        _ = try await world.createSharedGroup(named: "Work")
        let folderID = try await world.a.repository.createGroupFolder(name: "Family", inFolder: nil)
        await world.b.repository.loadGroups()
        #expect(rows(world.b).contains("Family"))

        try await world.a.repository.renameGroupFolder(id: folderID, to: "Relatives")
        let changeSet = coarse
            ? SidecarChangeSet(changedKeys: nil, changedKinds: [.groupFolder])
            : SidecarChangeSet(changedKeys: [SidecarKey(kind: .groupFolder, id: folderID)])
        #expect(await world.b.deliver(changeSet))

        #expect(rows(world.b).contains("Relatives"))
        #expect(rows(world.b).contains("Family") == false)
    }

    // MARK: - Golden case 3: a favorited group moved into a folder

    @Test
    func favoritedGroupPlacedOnDeviceA_isFavoritedAndInTheFolderOnDeviceB() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, groupB) = try await world.createSharedGroup(named: "Immediate Family")
        await world.a.repository.loadGroups()
        #expect(try await world.a.repository.setGroupFavorite(true, for: groupA))
        let favoritesBefore = try world.a.favorites.loadAll()
        let identityBefore = try #require(try world.a.sync.allGroupIdentities().first)

        let folderID = try await world.a.repository.createGroupFolder(name: "Family", inFolder: nil)
        try await world.a.repository.moveGroup(groupA, toFolder: folderID)

        // ONE identity: placement reused the favorite's, and left it alone.
        #expect(try world.a.sync.allGroupIdentities() == [identityBefore])
        #expect(try world.a.favorites.loadAll() == favoritesBefore)
        #expect(world.a.repository.isGroupFavorite(groupA))

        await world.b.repository.loadGroups()

        #expect(world.b.repository.isGroupFavorite(groupB))
        #expect(world.b.repository.groupFolderTree.groups[groupB.localID]?.parentFolderID == folderID)
    }

    /// The other order: placed first, favorited second. Still one identity, and
    /// favoriting never touches the placement.
    @Test
    func favoritingAPlacedGroupReusesItsIdentityAndLeavesThePlacementAlone() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Immediate Family")
        await world.a.repository.loadGroups()
        let folderID = try await world.a.repository.createGroupFolder(name: "Family", inFolder: nil)
        try await world.a.repository.moveGroup(groupA, toFolder: folderID)
        let identityID = try #require(try world.a.sync.allGroupIdentities().first?.id)
        let placementBefore = try #require(try world.a.sync.groupPlacement(identityID: identityID))

        #expect(try await world.a.repository.setGroupFavorite(true, for: groupA))

        #expect(try world.a.sync.allGroupIdentities().map(\.id) == [identityID])
        #expect(try world.a.favorites.loadAll().map(\.id) == [identityID])
        #expect(try world.a.sync.groupPlacement(identityID: identityID) == placementBefore)
        #expect(world.a.repository.groupFolderTree.groups[groupA.localID]?.parentFolderID == folderID)
    }

    @Test
    func movingAnUnidentifiedGroupToTopLevelMintsNothing() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Work")
        await world.a.repository.loadGroups()

        try await world.a.repository.moveGroup(groupA, toFolder: nil)

        #expect(try world.a.sync.allGroupIdentities().isEmpty)
    }

    // MARK: - Commands

    @Test(arguments: [true, false])
    func moveRevalidatesDestinationAfterIdentityFetch(adoptingIdentity: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contacts = ScriptedMembersContactStore()
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-A")
        let repo = ContactsRepository(
            contacts: contacts, sync: sync, favorites: FavoritesStore(root: root),
            notificationCenter: NotificationCenter())
        let group = try await contacts.seedGroup(name: "Work")
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Destination", inFolder: nil)
        if adoptingIdentity {
            // Arrive after loadGroups, so move must adopt it across an await.
            _ = try sync.mintGroupIdentity(
                name: group.name, memberCount: 0,
                memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
                hashedMemberCount: 0, localID: "remote-group")
        }
        await contacts.gateFingerprint(group)
        let move = Task { try await repo.moveGroup(group, toFolder: folder) }
        await contacts.waitUntilGated(group)
        // A peer deletes the destination while Contacts is resolving identity.
        // No watcher delivery: the command must re-read the durable hierarchy.
        try sync.markGroupFolderDeleted(id: folder, promotedToFolderID: nil)
        await contacts.release(group)

        await #expect(throws: GroupHierarchyError.folderDeleted(folder)) {
            try await move.value
        }
        #expect(try await sync.groupHierarchyRecords().groupPlacements.isEmpty)
        #expect(repo.groupFolderTree.groups[group.localID]?.parentFolderID == nil)
    }

    @Test
    func folderMovesCarryTheSubtreeAndRefuseCycles() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Soccer Parents")
        let repo = world.a.repository
        await repo.loadGroups()
        let family = try await repo.createGroupFolder(name: "Family", inFolder: nil)
        let activities = try await repo.createGroupFolder(name: "Activities", inFolder: nil)
        let sports = try await repo.createGroupFolder(name: "Sports", inFolder: activities)
        try await repo.moveGroup(groupA, toFolder: sports)

        try await repo.moveGroupFolder(id: activities, toFolder: family)
        #expect(rows(world.a) == ["Family", "  Activities", "    Sports", "      Soccer Parents"])

        await #expect(throws: GroupHierarchyError.wouldCreateCycle) {
            try await repo.moveGroupFolder(id: family, toFolder: family)
        }
        await #expect(throws: GroupHierarchyError.wouldCreateCycle) {
            try await repo.moveGroupFolder(id: family, toFolder: sports)
        }
        let missing = UUID().uuidString.lowercased()
        await #expect(throws: GroupHierarchyError.folderNotFound(missing)) {
            try await repo.moveGroupFolder(id: family, toFolder: missing)
        }
        await #expect(throws: GroupHierarchyError.folderNotFound(missing)) {
            try await repo.moveGroup(groupA, toFolder: missing)
        }
        // Nothing moved.
        #expect(rows(world.a) == ["Family", "  Activities", "    Sports", "      Soccer Parents"])

        try await repo.moveGroupFolder(id: activities, toFolder: nil)
        #expect(rows(world.a) == ["Activities", "  Sports", "    Soccer Parents", "Family"])
    }

    @Test
    func deletingAFolderMovesItsContentsUpOneLevel() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Soccer Parents")
        let repo = world.a.repository
        await repo.loadGroups()
        let family = try await repo.createGroupFolder(name: "Family", inFolder: nil)
        let activities = try await repo.createGroupFolder(name: "Activities", inFolder: family)
        let sports = try await repo.createGroupFolder(name: "Sports", inFolder: activities)
        try await repo.moveGroup(groupA, toFolder: activities)

        try await repo.deleteGroupFolder(id: activities)

        // Into Family — where Activities was — not to top level. The group and
        // its members are untouched, and no child was rewritten.
        #expect(rows(world.a) == ["Family", "  Soccer Parents", "  Sports"])
        #expect(repo.groups.map(\.localID) == [groupA.localID])
        #expect(try world.a.sync.groupFolderRecord(id: sports)?.placement?.parentFolderID == activities)
        #expect(try world.a.sync.groupFolderRecord(id: activities)?.deletion?.promotedToFolderID == family)

        await #expect(throws: GroupHierarchyError.folderDeleted(activities)) {
            try await repo.renameGroupFolder(id: activities, to: "Again")
        }
        await #expect(throws: GroupHierarchyError.folderDeleted(activities)) {
            try await repo.moveGroup(groupA, toFolder: activities)
        }

        // Deleting the promotion parent follows the chain to top level.
        try await repo.deleteGroupFolder(id: family)
        #expect(rows(world.a) == ["Soccer Parents", "Sports"])
    }

    @Test
    func hierarchyRevisionAdvancesOnlyWhenTheTreeChanges() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        _ = try await world.createSharedGroup(named: "Work")
        let repo = world.a.repository
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Family", inFolder: nil)
        let revision = repo.groupHierarchyRevision

        await repo.loadGroups()
        try await repo.renameGroupFolder(id: folder, to: "Family")
        try await repo.moveGroupFolder(id: folder, toFolder: nil)
        #expect(repo.groupHierarchyRevision == revision)

        try await repo.renameGroupFolder(id: folder, to: "Relatives")
        #expect(repo.groupHierarchyRevision == revision + 1)
    }

    // MARK: - New group in a folder

    @Test
    func createGroupInFolderPlacesIt() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let repo = world.a.repository
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Family", inFolder: nil)

        let group = try await repo.createGroup(name: "Cousins", inFolder: folder)

        #expect(repo.groupFolderTree.groups[group.localID]?.parentFolderID == folder)
    }

    /// When placement fails the group already exists. The error carries it, it
    /// stays reachable at top level, and the retry places THAT group — it never
    /// creates a second one.
    @Test
    func failedPlacementKeepsTheCreatedGroupForRetry() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let repo = world.a.repository
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Family", inFolder: nil)
        let missing = UUID().uuidString.lowercased()

        let failure = await #expect(throws: GroupPlacementFailedError.self) {
            try await repo.createGroup(name: "Cousins", inFolder: missing)
        }
        let created = try #require(failure).group

        #expect(repo.groups.map(\.localID) == [created.localID])
        #expect(repo.groupFolderTree.rootChildren.contains(.group(created.localID)))

        try await repo.moveGroup(created, toFolder: folder)
        #expect(repo.groups.count == 1)
        #expect(repo.groupFolderTree.groups[created.localID]?.parentFolderID == folder)
    }

    // MARK: - Deleting a group

    /// Deleting a group clears its placement, so a later group with the same
    /// name — which adopts the old identity by name, as a favorite's would —
    /// does not turn up inside the old folder.
    @Test
    func deletingAGroupClearsItsPlacementSoASuccessorStartsAtTopLevel() async throws {
        let world = try makeWorld()
        defer { world.cleanup() }
        let (groupA, _) = try await world.createSharedGroup(named: "Soccer Parents")
        let repo = world.a.repository
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Activities", inFolder: nil)
        try await repo.moveGroup(groupA, toFolder: folder)
        let identityID = try #require(try world.a.sync.allGroupIdentities().first?.id)
        let placed = try #require(try world.a.sync.groupPlacement(identityID: identityID))

        #expect(try await repo.deleteGroup(groupA) == nil)

        let cleared = try #require(try world.a.sync.groupPlacement(identityID: identityID))
        #expect(cleared.parentFolderID == nil)
        #expect(cleared.modifiedAt > placed.modifiedAt)
        // The identity record itself stays, as it does for a favorite.
        #expect(try world.a.sync.groupIdentity(id: identityID) != nil)

        let successor = try await repo.createGroup(name: "Soccer Parents")
        await repo.loadGroups()
        #expect(repo.groupFolderTree.groups[successor.localID]?.parentFolderID == nil)
        #expect(rows(world.a) == ["Activities", "Soccer Parents"])
    }

    /// The Contacts deletion and the placement cleanup are separate writes. When
    /// only the cleanup fails, the group IS deleted, the failure is reported as
    /// owed cleanup rather than as a failed delete, and retrying it deletes
    /// nothing again.
    @Test
    func failedPlacementCleanupIsReportedSeparatelyAndRetried() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-group-folders-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contacts = InMemoryContactStore()
        let sidecars = FailingWriteSidecarStore(wrapping: InMemorySidecarStore())
        let sync = GuessWhoSync(
            contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-A")
        let repo = ContactsRepository(
            contacts: contacts, sync: sync, favorites: FavoritesStore(root: root),
            notificationCenter: NotificationCenter())
        let group = try await contacts.createGroup(name: "Soccer Parents")
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Activities", inFolder: nil)
        try await repo.moveGroup(group, toFolder: folder)
        let identityID = try #require(try sync.allGroupIdentities().first?.id)

        sidecars.failingWrites = [SidecarKey(kind: .group, id: identityID)]
        let pending = try #require(try await repo.deleteGroup(group))

        #expect(repo.groups.isEmpty)
        #expect(try await contacts.fetchAllGroups().isEmpty)
        #expect(try sync.groupPlacement(identityID: identityID)?.parentFolderID == folder)

        sidecars.failingWrites = []
        try await repo.retryGroupPlacementCleanup(pending)

        #expect(try sync.groupPlacement(identityID: identityID)?.parentFolderID == nil)
        #expect(try await contacts.fetchAllGroups().isEmpty)
    }

    // MARK: - Unreadable records

    /// A folder whose file cannot be read right now keeps its last good value:
    /// slow iCloud must not make a folder — and everything in it — drop out.
    @Test
    func unreadableFolderKeepsItsLastGoodValueInTheTree() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-group-folders-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contacts = InMemoryContactStore()
        let sidecars = UnreadableKeySidecarStore(wrapping: InMemorySidecarStore())
        let sync = GuessWhoSync(
            contacts: contacts, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-A")
        let repo = ContactsRepository(
            contacts: contacts, sync: sync, favorites: FavoritesStore(root: root),
            notificationCenter: NotificationCenter())
        let group = try await contacts.createGroup(name: "Soccer Parents")
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Activities", inFolder: nil)
        try await repo.moveGroup(group, toFolder: folder)
        #expect(repo.groupFolderTree.isComplete)

        sidecars.unreadable = [SidecarKey(kind: .groupFolder, id: folder)]
        await repo.loadGroups()

        #expect(repo.groupFolderTree.isComplete == false)
        #expect(repo.groupFolderTree.folders[folder]?.name == "Activities")
        #expect(repo.groupFolderTree.groups[group.localID]?.parentFolderID == folder)
        // And a command against a record this device cannot read is refused.
        await #expect(throws: GroupHierarchyError.recordUnavailable(SidecarKey(kind: .groupFolder, id: folder))) {
            try await repo.renameGroupFolder(id: folder, to: "Sports")
        }
    }
}

/// Test-only sidecar store whose writes to chosen keys fail.
class FailingWriteSidecarStore: SidecarStoreProtocol {
    struct WriteFailed: Error {}

    private let inner: InMemorySidecarStore
    var failingWrites: Set<SidecarKey> = []

    init(wrapping inner: InMemorySidecarStore) { self.inner = inner }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? { try inner.read(key) }
    func allKeys() throws -> [SidecarKey] { try inner.allKeys() }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        if failingWrites.contains(key) { throw WriteFailed() }
        try inner.write(envelope, at: key)
    }
    func delete(_ key: SidecarKey) throws { try inner.delete(key) }
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus { inner.downloadStatus(key) }
    func requestDownload(_ key: SidecarKey) throws { try inner.requestDownload(key) }
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws {
        try inner.writeBlob(data, blobId: blobId, for: key)
    }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? {
        try inner.readBlob(blobId: blobId, for: key)
    }
    func deleteBlob(blobId: String, for key: SidecarKey) throws {
        try inner.deleteBlob(blobId: blobId, for: key)
    }
    func blobIds(for key: SidecarKey) throws -> [String] { try inner.blobIds(for: key) }
}

/// Controls corpus enumeration independently of record reads. One read can be
/// held while a watcher publishes a newer hierarchy, without blocking main.
final class ScriptedHierarchySidecarStore: FailingWriteSidecarStore {
    struct EnumerationFailed: Error {}
    private let lock = NSLock()
    private var fails = false
    private var nextGate: ReadGate?
    var failEnumeration: Bool {
        get { lock.withLock { fails } }
        set { lock.withLock { fails = newValue } }
    }
    func gateNextEnumeration() -> ReadGate {
        let gate = ReadGate()
        lock.withLock { nextGate = gate }
        return gate
    }
    override func allKeys() throws -> [SidecarKey] {
        let (fail, gate) = lock.withLock {
            let result = (fails, nextGate)
            nextGate = nil
            return result
        }
        gate?.enterAndWait()
        if fail { throw EnumerationFailed() }
        return try super.allKeys()
    }

    final class ReadGate {
        private let lock = NSLock()
        private let releaseSignal = DispatchSemaphore(value: 0)
        private var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        func enterAndWait() {
            let continuation = lock.withLock {
                entered = true
                defer { waiter = nil }
                return waiter
            }
            continuation?.resume()
            releaseSignal.wait()
        }
        func waitUntilEntered() async {
            await withCheckedContinuation { continuation in
                let alreadyEntered = lock.withLock {
                    if entered { return true }
                    waiter = continuation
                    return false
                }
                if alreadyEntered { continuation.resume() }
            }
        }
        func release() { releaseSignal.signal() }
    }
}
