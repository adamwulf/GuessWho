import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
@_spi(ConflictReconcile) import GuessWhoSyncTesting

/// The storage layer for group folders and group placement
/// (`plans/group-folders.md`, delivery step 1): the reserved cells, their
/// stamps, and the guards that keep untrustworthy data from being written
/// through or read as authoritative.
@Suite("Group folder storage")
struct GroupFolderStorageTests {
    private static let deviceID = "device-A"

    private func makeSync(
        sidecars: SidecarStoreProtocol = InMemorySidecarStore(),
        deviceID: String = GroupFolderStorageTests.deviceID
    ) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: deviceID)
    }

    private func folderKey(_ id: String) -> SidecarKey { SidecarKey(kind: .groupFolder, id: id) }
    private func groupKey(_ id: String) -> SidecarKey { SidecarKey(kind: .group, id: id) }

    private func mintIdentity(_ sync: GuessWhoSync, name: String = "Work") throws -> GroupIdentity {
        try sync.mintGroupIdentity(
            name: name,
            memberCount: 0,
            memberHash: GroupIdentity.fingerprint(forGuessWhoIDs: []).memberHash,
            hashedMemberCount: 0,
            localID: "local-\(name)")
    }

    private let otherFolder = "aaaaaaaa-0000-4000-8000-000000000001"

    // MARK: - Create

    @Test
    func createWritesNameAndParentInOneEnvelopeWrite() throws {
        let store = WriteCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(sidecars: store)

        let folder = try sync.createGroupFolder(name: "  Family  ", parentFolderID: otherFolder.uppercased())

        #expect(folder.name == "Family")
        #expect(folder.placement?.parentFolderID == otherFolder)
        #expect(folder.deletion == nil)
        #expect(UUID(uuidString: folder.id) != nil)
        #expect(folder.id == folder.id.lowercased())
        // One write: no peer can ever observe the folder without its name.
        #expect(store.writeCount(for: folderKey(folder.id)) == 1)
        #expect(try sync.groupFolderRecord(id: folder.id) == folder)
    }

    @Test
    func createAtTopLevelWritesNoPlacementCell() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)

        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: nil)

        #expect(folder.placement == nil)
        let envelope = try #require(try store.read(folderKey(folder.id)))
        #expect(Set(envelope.fields.keys) == [GroupHierarchyCells.folderNameKey])
    }

    @Test
    func createWithTheSameIDIsIdempotent() throws {
        let store = WriteCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(sidecars: store)
        let id = UUID()

        let first = try sync.createGroupFolder(name: "Family", parentFolderID: nil, id: id)
        let second = try sync.createGroupFolder(name: "Something Else", parentFolderID: otherFolder, id: id)

        #expect(second == first)
        #expect(store.writeCount(for: folderKey(first.id)) == 1)
    }

    @Test
    func createRejectsBadInput() throws {
        let sync = makeSync()
        let id = UUID()

        #expect(throws: GroupHierarchyError.invalidName) {
            try sync.createGroupFolder(name: "   \n", parentFolderID: nil)
        }
        #expect(throws: GroupHierarchyError.invalidFolderID("not-a-uuid")) {
            try sync.createGroupFolder(name: "Family", parentFolderID: "not-a-uuid")
        }
        #expect(throws: GroupHierarchyError.wouldCreateCycle) {
            try sync.createGroupFolder(name: "Family", parentFolderID: id.uuidString, id: id)
        }
        #expect(try sync.groupHierarchyRecords().folders.isEmpty)
    }

    // MARK: - Rename

    @Test
    func renameChangesOnlyTheNameCell() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: otherFolder)
        let before = try #require(try store.read(folderKey(folder.id)))

        #expect(try sync.renameGroupFolder(id: folder.id, to: " Relatives "))

        let after = try #require(try store.read(folderKey(folder.id)))
        #expect(try sync.groupFolderRecord(id: folder.id)?.name == "Relatives")
        let placementKey = GroupHierarchyCells.parentFolderKey
        #expect(after.fields[placementKey]?.modifiedAt == before.fields[placementKey]?.modifiedAt)
        #expect(after.fields[placementKey]?.modifiedBy == before.fields[placementKey]?.modifiedBy)
        #expect(after.fields[placementKey]?.value == before.fields[placementKey]?.value)
        // An unchanged name writes nothing.
        #expect(try sync.renameGroupFolder(id: folder.id, to: "Relatives") == false)
    }

    // MARK: - Placement

    @Test
    func clearingAParentWritesANewerNullAndKeepsTheCell() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: otherFolder)
        let assigned = try #require(folder.placement)

        #expect(try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil))

        // The cell is still there, as an explicit top-level assignment that a
        // stale "inside otherFolder" write arriving later cannot beat.
        let envelope = try #require(try store.read(folderKey(folder.id)))
        #expect(envelope.fields[GroupHierarchyCells.parentFolderKey] != nil)
        let cleared = try #require(try sync.groupFolderRecord(id: folder.id)?.placement)
        #expect(cleared.parentFolderID == nil)
        #expect(cleared.modifiedAt > assigned.modifiedAt)
        // Already at top level: nothing to write.
        #expect(try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil) == false)
    }

    @Test
    func moveToTopLevelWithNoPlacementCellWritesNothing() throws {
        let store = WriteCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: nil)

        #expect(try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil) == false)
        #expect(store.writeCount(for: folderKey(folder.id)) == 1)
    }

    /// A device whose clock runs behind must still win against the assignment
    /// it replaces, and what it writes must survive the wire unchanged.
    @Test
    func stampIsStrictlyLaterThanTheObservedAssignmentEvenWhenTheClockIsBehind() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let future = Date(timeIntervalSince1970: 2_000_000_000.123)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: otherFolder, now: future)
        let first = try #require(folder.placement)

        let behind = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil, now: behind))

        let second = try #require(try sync.groupFolderRecord(id: folder.id)?.placement)
        #expect(second.modifiedAt > first.modifiedAt)
        #expect(second.modifiedAt.timeIntervalSince(first.modifiedAt) < 0.01)

        // The stamp a peer decodes is the stamp this process compared.
        let envelope = try #require(try store.read(folderKey(folder.id)))
        let decoded = try JSONDecoder().decode(
            SidecarEnvelope.self, from: try SidecarEnvelopeCodec.encode(envelope))
        #expect(decoded.fields[GroupHierarchyCells.parentFolderKey]?.modifiedAt == second.modifiedAt)
    }

    @Test
    func stampHonorsEveryObservedAssignmentAndRejectsOverflow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_800_000_000.5)

        let stamp = try GroupHierarchyCells.stamp(laterThan: [now, later], now: now)
        #expect(stamp > later)
        #expect(try GroupHierarchyCells.stamp(laterThan: [], now: now) == now)
        // A year the persisted format cannot hold.
        #expect(throws: GroupHierarchyError.timestampOverflow) {
            try GroupHierarchyCells.stamp(laterThan: [Date(timeIntervalSince1970: 1e15)], now: now)
        }
    }

    @Test
    func writerTokenNamesTheOperationAndARetryDoesNotWriteAgain() throws {
        let store = WriteCountingSidecarStore(wrapping: InMemorySidecarStore())
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: nil)
        let operation = UUID()

        #expect(try sync.setGroupFolderParent(id: folder.id, parentFolderID: otherFolder, operationID: operation))
        let placement = try #require(try sync.groupFolderRecord(id: folder.id)?.placement)
        #expect(placement.modifiedBy == "\(Self.deviceID)/\(operation.uuidString.lowercased())")

        let writes = store.writeCount(for: folderKey(folder.id))
        #expect(try sync.setGroupFolderParent(
            id: folder.id, parentFolderID: otherFolder, operationID: operation) == false)
        #expect(store.writeCount(for: folderKey(folder.id)) == writes)
    }

    // MARK: - Deletion

    @Test
    func deletionMarkerRecordsThePromotionDestinationAndIsFinal() throws {
        let sync = makeSync()
        let folder = try sync.createGroupFolder(name: "Activities", parentFolderID: otherFolder)

        #expect(try sync.markGroupFolderDeleted(id: folder.id, promotedToFolderID: otherFolder))

        let deleted = try #require(try sync.groupFolderRecord(id: folder.id))
        #expect(deleted.isDeleted)
        #expect(deleted.deletion?.promotedToFolderID == otherFolder)
        let placement = try #require(deleted.placement)
        #expect(try #require(deleted.deletion).modifiedAt > placement.modifiedAt)
        // A second delete keeps the first marker.
        #expect(try sync.markGroupFolderDeleted(id: folder.id, promotedToFolderID: nil) == false)
        #expect(try sync.groupFolderRecord(id: folder.id)?.deletion == deleted.deletion)
        // A deleted folder can be neither renamed nor moved.
        #expect(throws: GroupHierarchyError.folderDeleted(folder.id)) {
            try sync.renameGroupFolder(id: folder.id, to: "Again")
        }
        #expect(throws: GroupHierarchyError.folderDeleted(folder.id)) {
            try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil)
        }
    }

    /// A peer that never saw the deletion renames and moves the folder LATER.
    /// Merging its cells in must not bring the folder back.
    @Test
    func markerBeatsLaterStaleNameAndParentWrites() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Activities", parentFolderID: nil)
        let key = folderKey(folder.id)
        let beforeDelete = try #require(try store.read(key))
        try sync.markGroupFolderDeleted(id: folder.id, promotedToFolderID: nil)
        let deleted = try #require(try store.read(key))

        // The stale peer's envelope: the pre-delete state, renamed and moved
        // with stamps far later than the marker's.
        let peerStore = InMemorySidecarStore()
        try peerStore.write(beforeDelete, at: key)
        let peer = makeSync(sidecars: peerStore, deviceID: "device-B")
        let muchLater = Date().addingTimeInterval(86_400)
        try peer.renameGroupFolder(id: folder.id, to: "Sports", now: muchLater)
        try peer.setGroupFolderParent(id: folder.id, parentFolderID: otherFolder, now: muchLater)
        let stale = try #require(try peerStore.read(key))

        for merged in [try merge(deleted, stale).get(), try merge(stale, deleted).get()] {
            let record = try GroupHierarchyCells.decodeFolder(merged, key: key)
            #expect(record.isDeleted)
            #expect(record.deletion?.promotedToFolderID == nil)
        }
    }

    // MARK: - Group placement

    @Test
    func groupPlacementNeedsAnIdentity() throws {
        let sync = makeSync()
        let missing = UUID().uuidString.lowercased()
        #expect(throws: GroupHierarchyError.identityNotFound(missing)) {
            try sync.setGroupPlacement(identityID: missing, parentFolderID: otherFolder)
        }
    }

    @Test
    func groupPlacementWritesOnlyItsOwnCell() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let identity = try mintIdentity(sync)
        let key = groupKey(identity.id)
        let before = try #require(try store.read(key))

        #expect(try sync.setGroupPlacement(identityID: identity.id, parentFolderID: otherFolder))

        let after = try #require(try store.read(key))
        let identityCell = GuessWhoSync.groupIdentityCellKey
        #expect(after.fields[identityCell]?.modifiedAt == before.fields[identityCell]?.modifiedAt)
        #expect(after.fields[identityCell]?.value == before.fields[identityCell]?.value)
        #expect(try sync.groupIdentity(id: identity.id) == identity)
        #expect(try sync.groupPlacement(identityID: identity.id)?.parentFolderID == otherFolder)
    }

    /// Identity refresh and placement share an envelope and must never
    /// overwrite each other, in either order.
    @Test
    func identityRefreshPreservesPlacementAndUnknownCells() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        var identity = try mintIdentity(sync)
        let key = groupKey(identity.id)
        // A cell some newer build wrote, which this build cannot interpret.
        var envelope = try #require(try store.read(key))
        var fields = envelope.fields
        fields["futureCell"] = SidecarCell(
            value: .object(["type": .string("from-the-future"), "value": .number(7)]),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedBy: "device-Z")
        envelope = SidecarEnvelope(entityID: envelope.entityID, fields: fields)
        try store.write(envelope, at: key)
        try sync.setGroupPlacement(identityID: identity.id, parentFolderID: otherFolder)
        let placed = try #require(try sync.groupPlacement(identityID: identity.id))

        identity.memberCount = 12
        try sync.writeGroupIdentity(identity)

        #expect(try sync.groupIdentity(id: identity.id)?.memberCount == 12)
        #expect(try sync.groupPlacement(identityID: identity.id) == placed)
        let after = try #require(try store.read(key))
        #expect(after.fields["futureCell"]?.value == fields["futureCell"]?.value)
        // Its presence does not make the record unavailable either.
        #expect(try sync.groupHierarchyRecords().unavailableKeys.isEmpty)
    }

    // MARK: - Reading the hierarchy

    @Test
    func hierarchyRecordsCollectFoldersAndPlacements() throws {
        let sync = makeSync()
        let family = try sync.createGroupFolder(name: "Family", parentFolderID: nil)
        let activities = try sync.createGroupFolder(name: "Activities", parentFolderID: family.id)
        let placed = try mintIdentity(sync, name: "Soccer Parents")
        let unplaced = try mintIdentity(sync, name: "Work")
        try sync.setGroupPlacement(identityID: placed.id, parentFolderID: activities.id)

        let records = try sync.groupHierarchyRecords()

        #expect(Set(records.folders.map(\.id)) == [family.id, activities.id])
        #expect(records.groupPlacements[placed.id]?.parentFolderID == activities.id)
        #expect(records.groupPlacements[unplaced.id] == nil)
        #expect(records.unavailableKeys.isEmpty)
        #expect(records.isComplete)
    }

    // MARK: - Untrustworthy data

    /// A reserved payload this build cannot trust makes the record
    /// UNAVAILABLE. It is never read as though the cell were absent — that
    /// would silently turn "in a folder" into "top level", or un-delete.
    @Test
    func malformedReservedPayloadMakesTheRecordUnavailable() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: otherFolder)
        let identity = try mintIdentity(sync)
        try sync.setGroupPlacement(identityID: identity.id, parentFolderID: folder.id)
        let bad = SidecarCell(
            value: .object(["field": .string("parentFolder"), "value": .number(42)]),
            modifiedAt: Date(), modifiedBy: "device-Z")

        for key in [folderKey(folder.id), groupKey(identity.id)] {
            let envelope = try #require(try store.read(key))
            var fields = envelope.fields
            fields[GroupHierarchyCells.parentFolderKey] = bad
            try store.write(SidecarEnvelope(entityID: envelope.entityID, fields: fields), at: key)
        }

        let records = try sync.groupHierarchyRecords()
        #expect(records.unavailableKeys == [folderKey(folder.id), groupKey(identity.id)])
        #expect(records.folders.isEmpty)
        #expect(records.groupPlacements.isEmpty)
        #expect(throws: GroupHierarchyError.recordUnavailable(groupKey(identity.id))) {
            try sync.setGroupPlacement(identityID: identity.id, parentFolderID: nil)
        }
        #expect(throws: GroupHierarchyError.recordUnavailable(folderKey(folder.id))) {
            try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil)
        }
    }

    @Test
    func malformedDeletionMarkerIsNeverReadAsALiveFolder() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: nil)
        let key = folderKey(folder.id)
        let envelope = try #require(try store.read(key))
        var fields = envelope.fields
        fields[GroupHierarchyCells.folderDeletedKey] = SidecarCell(
            value: .object(["field": .string("folderDeleted"), "value": .string("yes")]),
            modifiedAt: Date(), modifiedBy: "device-Z")
        try store.write(SidecarEnvelope(entityID: envelope.entityID, fields: fields), at: key)

        #expect(try sync.groupHierarchyRecords().unavailableKeys == [key])
        #expect(try sync.groupHierarchyRecords().folders.isEmpty)
        #expect(throws: GroupHierarchyError.recordUnavailable(key)) {
            try sync.renameGroupFolder(id: folder.id, to: "Still Here")
        }
    }

    // MARK: - Lossy envelopes

    @Test(arguments: ["folderName", "parentFolder", "folderDeleted"], ["field", "type"])
    func unknownReservedMetadataCannotBeReadOrOverwritten(cellKey: String, metadataKey: String) throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: otherFolder)
        let key = folderKey(folder.id)
        let original = try #require(try store.read(key))
        var fields = original.fields
        if cellKey == "folderDeleted" {
            fields[cellKey] = SidecarCell(
                value: GroupHierarchyCells.deletionValue(promotedToFolderID: otherFolder, createdAt: Date()),
                modifiedAt: Date(), modifiedBy: "device-Z")
        }
        let cell = try #require(fields[cellKey])
        guard case .object(var inner) = cell.value else {
            Issue.record("Expected a structured reserved cell")
            return
        }
        // The payload remains valid; only its meaning is unknown to this build.
        for metadata in [JSONValue.string("from-the-future"), .null] {
            inner[metadataKey] = metadata
            for tombstoned in [false, true] {
                fields[cellKey] = SidecarCell(
                    value: .object(inner), modifiedAt: cell.modifiedAt,
                    modifiedBy: cell.modifiedBy, deletedAt: tombstoned ? cell.modifiedAt : nil)
                let unknown = SidecarEnvelope(entityID: original.entityID, fields: fields)
                try store.write(unknown, at: key)

                #expect(try sync.groupHierarchyRecords().unavailableKeys == [key])
                #expect(throws: GroupHierarchyError.recordUnavailable(key)) {
                    try sync.groupFolderRecord(id: folder.id)
                }
                #expect(throws: GroupHierarchyError.recordUnavailable(key)) {
                    try sync.renameGroupFolder(id: folder.id, to: "Changed")
                }
                #expect(throws: GroupHierarchyError.recordUnavailable(key)) {
                    try sync.setGroupFolderParent(id: folder.id, parentFolderID: nil)
                }
                let stored = try #require(try store.read(key))
                #expect(try SidecarEnvelopeCodec.encode(stored) == SidecarEnvelopeCodec.encode(unknown))
            }
        }
    }

    @Test(arguments: ["field", "type"])
    func unknownGroupPlacementMetadataCannotBeOverwritten(metadataKey: String) throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let identity = try mintIdentity(sync)
        let key = groupKey(identity.id)
        try sync.setGroupPlacement(identityID: identity.id, parentFolderID: otherFolder)
        let original = try #require(try store.read(key))
        var fields = original.fields
        let cell = try #require(fields[GroupHierarchyCells.parentFolderKey])
        guard case .object(var inner) = cell.value else { return }
        inner[metadataKey] = .string("from-the-future")
        fields[GroupHierarchyCells.parentFolderKey] = SidecarCell(
            value: .object(inner), modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy)
        try store.write(SidecarEnvelope(entityID: original.entityID, fields: fields), at: key)

        #expect(try sync.groupHierarchyRecords().unavailableKeys == [key])
        #expect(throws: GroupHierarchyError.recordUnavailable(key)) {
            try sync.setGroupPlacement(identityID: identity.id, parentFolderID: nil)
        }
        let stored = try #require(try store.read(key))
        #expect(try SidecarEnvelopeCodec.encode(stored) == SidecarEnvelopeCodec.encode(SidecarEnvelope(entityID: original.entityID, fields: fields)))
    }

    /// Raw envelope bytes whose `fields` hold one good name cell and one cell
    /// malformed at the CELL level (a bad `modifiedAt`), which the codec drops.
    private func lossyFolderBytes(id: String) -> Data {
        Data("""
        {"schemaVersion":1,"entityID":"\(id)","fields":{
          "folderName":{"value":{"field":"folderName","type":"note","value":"Family",
            "createdAt":"2026-01-01T00:00:00.000Z"},
            "modifiedAt":"2026-01-01T00:00:00.000Z","modifiedBy":"device-Z/op"},
          "folderDeleted":{"value":{"field":"folderDeleted","type":"folderDeletion",
            "value":{"promotedTo":null}},
            "modifiedAt":"not a timestamp","modifiedBy":"device-Z/op"}
        }}
        """.utf8)
    }

    /// The dropped cell here is a DELETION MARKER. Reading the envelope as
    /// authoritative would resurrect the folder, and writing through it would
    /// erase the marker for good.
    @Test
    func lossyEnvelopeIsExcludedFromTheTreeAndBlocksEveryWrite() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-lossy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemSidecarStore(root: root, coordinatesUbiquitousAccess: false)
        let sync = makeSync(sidecars: store)
        let folderID = "bbbbbbbb-0000-4000-8000-000000000002"
        let groupID = "cccccccc-0000-4000-8000-000000000003"
        let folderURL = root.appendingPathComponent("group-folders/\(folderID).json")
        let groupURL = root.appendingPathComponent("groups/\(groupID).json")
        try FileManager.default.createDirectory(
            at: folderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: groupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let folderBytes = lossyFolderBytes(id: folderID)
        try folderBytes.write(to: folderURL)
        // A group envelope with a good identity cell and a dropped placement.
        let identity = GroupIdentity(
            id: groupID, name: "work", memberCount: 0, memberHash: "h", hashedMemberCount: 0)
        let identityJSON = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let groupBytes = Data("""
        {"schemaVersion":1,"entityID":"\(groupID)","fields":{
          "groupIdentity":{"value":{"field":"groupIdentity","type":"note","value":"\(identityJSON)",
            "createdAt":"2026-01-01T00:00:00.000Z"},
            "modifiedAt":"2026-01-01T00:00:00.000Z","modifiedBy":"device-Z"},
          "parentFolder":{"value":{"field":"parentFolder","type":"folderReference","value":null},
            "modifiedAt":"garbage","modifiedBy":"device-Z/op"}
        }}
        """.utf8)
        try groupBytes.write(to: groupURL)

        let records = try sync.groupHierarchyRecords()
        #expect(records.unavailableKeys == [folderKey(folderID), groupKey(groupID)])
        #expect(records.folders.isEmpty)
        #expect(records.groupPlacements.isEmpty)
        // The identity itself still READS — only writes are refused.
        #expect(try sync.groupIdentity(id: groupID)?.name == "work")

        #expect(throws: GroupHierarchyError.lossyEnvelope(folderKey(folderID))) {
            try sync.renameGroupFolder(id: folderID, to: "Renamed")
        }
        #expect(throws: GroupHierarchyError.lossyEnvelope(folderKey(folderID))) {
            try sync.setGroupFolderParent(id: folderID, parentFolderID: nil)
        }
        #expect(throws: GroupHierarchyError.lossyEnvelope(folderKey(folderID))) {
            try sync.markGroupFolderDeleted(id: folderID, promotedToFolderID: nil)
        }
        #expect(throws: GroupHierarchyError.lossyEnvelope(folderKey(folderID))) {
            try sync.createGroupFolder(
                name: "Family", parentFolderID: nil, id: try #require(UUID(uuidString: folderID)))
        }
        #expect(throws: GroupHierarchyError.lossyEnvelope(groupKey(groupID))) {
            try sync.setGroupPlacement(identityID: groupID, parentFolderID: nil)
        }
        // Including the identity refresh that shares the group's envelope.
        #expect(throws: GroupHierarchyError.lossyEnvelope(groupKey(groupID))) {
            try sync.writeGroupIdentity(identity)
        }

        #expect(try Data(contentsOf: folderURL) == folderBytes)
        #expect(try Data(contentsOf: groupURL) == groupBytes)
    }

    /// Conflict reconciliation folds versions and then marks them resolved. For
    /// a hierarchy envelope with a dropped cell that would destroy the only
    /// copies, so it must write nothing and keep every version.
    @Test
    func conflictReconcileRefusesALossyHierarchyVersionAndKeepsEverything() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: nil)
        let key = folderKey(folder.id)
        let before = try #require(try store.read(key))
        store.scriptConflict(at: key, versions: [lossyFolderBytes(id: folder.id)])

        let report = try sync.reconcileSidecars()

        let outcome = try #require(report.fileOutcomes.first { $0.key == key })
        #expect(outcome.versionsConsidered == 0)
        #expect(outcome.skippedReasons.contains { $0.contains("lossyEnvelope") })
        #expect(outcome.skippedReasons.contains { $0.contains("dropped 1 malformed cell") })
        #expect(try store.keysWithUnresolvedConflicts() == [key])
        let after = try #require(try store.read(key))
        #expect(after.fields.keys.sorted() == before.fields.keys.sorted())
        #expect(try sync.groupFolderRecord(id: folder.id) == folder)
    }

    /// A clean conflict still merges cell by cell: one version carries the
    /// name, the other the deletion marker, and the result is a deleted folder.
    @Test
    func conflictReconcileMergesCleanHierarchyVersions() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(sidecars: store)
        let folder = try sync.createGroupFolder(name: "Family", parentFolderID: nil)
        let key = folderKey(folder.id)
        let live = try #require(try store.read(key))
        try sync.markGroupFolderDeleted(id: folder.id, promotedToFolderID: otherFolder)
        let deleted = try #require(try store.read(key))
        // Current = the live version; the conflicting version = the deleted one.
        try store.write(live, at: key)
        store.scriptConflict(at: key, versions: [try SidecarEnvelopeCodec.encode(deleted)])

        _ = try sync.reconcileSidecars()

        #expect(try store.keysWithUnresolvedConflicts().isEmpty)
        let merged = try #require(try sync.groupFolderRecord(id: folder.id))
        #expect(merged.isDeleted)
        #expect(merged.deletion?.promotedToFolderID == otherFolder)
        #expect(merged.name == "Family")
    }

    /// A key whose bytes cannot be had right now is UNKNOWN, not gone: the
    /// snapshot says it is incomplete rather than dropping the folder.
    @Test
    func unreadableKeyMakesTheSnapshotIncomplete() throws {
        let inner = InMemorySidecarStore()
        let store = UnreadableKeySidecarStore(wrapping: inner)
        let sync = makeSync(sidecars: store)
        let readable = try sync.createGroupFolder(name: "Family", parentFolderID: nil)
        let pending = try sync.createGroupFolder(name: "Activities", parentFolderID: nil)
        store.unreadable = [folderKey(pending.id)]

        let records = try sync.groupHierarchyRecords()

        #expect(records.folders.map(\.id) == [readable.id])
        #expect(records.unreadableKeys == [folderKey(pending.id)])
        #expect(records.unavailableKeys.isEmpty)
        #expect(records.isComplete == false)
    }
}

/// Test-only sidecar store whose reads of chosen keys fail as though iCloud had
/// not downloaded them yet.
final class UnreadableKeySidecarStore: SidecarStoreProtocol {
    private let inner: InMemorySidecarStore
    var unreadable: Set<SidecarKey> = []

    init(wrapping inner: InMemorySidecarStore) { self.inner = inner }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        if unreadable.contains(key) { throw SidecarStoreError.notYetDownloaded(key) }
        return try inner.read(key)
    }
    func allKeys() throws -> [SidecarKey] { try inner.allKeys() }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws { try inner.write(envelope, at: key) }
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
