import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Golden wire fixtures for the group-folder cells (`plans/group-folders.md`,
/// "Hardening the compatibility tests", item 4).
///
/// The literals below are the exact bytes this feature puts in the synced
/// sidecar root, where builds of OTHER versions read them. Two checks run
/// against each: today's decoder reads it to the expected values, and today's
/// encoder reproduces it byte for byte.
///
/// APPEND-ONLY. These bytes are already on users' devices once a build ships.
/// If a format change makes a test here fail, the change is what is wrong —
/// or, when the change is deliberate and compatible, ADD a new fixture for the
/// new shape and keep the old one decoding. Never edit a shipped literal to
/// make a test pass.
@Suite("Group folder wire fixtures")
struct GroupFolderWireFixtureTests {
    private static let deviceID = "device-A"
    private static let folderID = "11111111-2222-4333-8444-555555555555"
    private static let parentID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private static let promotedID = "99999999-8888-4777-8666-555555555555"
    private static let createOperation = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let deleteOperation = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private static let placeOperation = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private static let createdAt = Date(timeIntervalSince1970: 1_789_000_000)
    private static let deletedAt = Date(timeIntervalSince1970: 1_789_000_060.5)

    private func makeSync(_ store: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: Self.deviceID)
    }

    // MARK: - v1: a folder, created inside a parent and later deleted

    static let folderEnvelopeV1 = #"{"entityID":"11111111-2222-4333-8444-555555555555","fields":{"folderDeleted":{"modifiedAt":"2026-09-10T00:27:40.500Z","modifiedBy":"device-A\/00000000-0000-4000-8000-000000000002","value":{"createdAt":"2026-09-10T00:27:40.500Z","field":"folderDeleted","type":"folderDeletion","value":{"promotedTo":"99999999-8888-4777-8666-555555555555"}}},"folderName":{"modifiedAt":"2026-09-10T00:26:40.000Z","modifiedBy":"device-A\/00000000-0000-4000-8000-000000000001","value":{"createdAt":"2026-09-10T00:26:40.000Z","field":"folderName","type":"note","value":"Activities"}},"parentFolder":{"modifiedAt":"2026-09-10T00:26:40.000Z","modifiedBy":"device-A\/00000000-0000-4000-8000-000000000001","value":{"createdAt":"2026-09-10T00:26:40.000Z","field":"parentFolder","type":"folderReference","value":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}}},"schemaVersion":1}"#

    @Test
    func encoderReproducesTheFolderEnvelope() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(store)
        try sync.createGroupFolder(
            name: "Activities",
            parentFolderID: Self.parentID,
            id: try #require(UUID(uuidString: Self.folderID)),
            operationID: Self.createOperation,
            now: Self.createdAt)
        try sync.markGroupFolderDeleted(
            id: Self.folderID,
            promotedToFolderID: Self.promotedID,
            operationID: Self.deleteOperation,
            now: Self.deletedAt)

        let envelope = try #require(try store.read(SidecarKey(kind: .groupFolder, id: Self.folderID)))
        let bytes = String(decoding: try SidecarEnvelopeCodec.encode(envelope), as: UTF8.self)

        #expect(bytes == Self.folderEnvelopeV1)
    }

    @Test
    func decoderReadsTheFolderEnvelope() throws {
        let key = SidecarKey(kind: .groupFolder, id: Self.folderID)
        let envelope = try JSONDecoder().decode(
            SidecarEnvelope.self, from: Data(Self.folderEnvelopeV1.utf8))
        #expect(envelope.cellsDroppedOnDecode == 0)

        let folder = try GroupHierarchyCells.decodeFolder(envelope, key: key)

        #expect(folder.id == Self.folderID)
        #expect(folder.name == "Activities")
        #expect(folder.placement == FolderPlacement(
            parentFolderID: Self.parentID,
            modifiedAt: Self.createdAt,
            modifiedBy: "device-A/00000000-0000-4000-8000-000000000001"))
        #expect(folder.deletion == FolderDeletion(
            promotedToFolderID: Self.promotedID,
            modifiedAt: Self.deletedAt,
            modifiedBy: "device-A/00000000-0000-4000-8000-000000000002"))
    }

    // MARK: - v1: a group's placement cell, beside cells this build does not own

    /// A group envelope as a peer would leave it: the identity cell, the
    /// placement cell, and a cell whose inner `type` no build here knows.
    static let groupEnvelopeV1 = #"{"entityID":"22222222-3333-4444-8555-666666666666","fields":{"futureCell":{"modifiedAt":"2026-09-10T00:26:40.000Z","modifiedBy":"device-Z","value":{"field":"futureCell","payload":[1,"two",true,null],"type":"from-a-newer-build"}},"groupIdentity":{"modifiedAt":"2026-09-10T00:26:40.000Z","modifiedBy":"device-A","value":{"createdAt":"2026-09-10T00:26:40.000Z","field":"groupIdentity","type":"note","value":"{\"deviceLocalIDs\":{\"device-A\":\"local-group-1\"},\"hashedMemberCount\":0,\"id\":\"22222222-3333-4444-8555-666666666666\",\"memberCount\":0,\"memberHash\":\"\",\"name\":\"soccer parents\"}"}},"parentFolder":{"modifiedAt":"2026-09-10T00:26:40.000Z","modifiedBy":"device-A\/00000000-0000-4000-8000-000000000003","value":{"createdAt":"2026-09-10T00:26:40.000Z","field":"parentFolder","type":"folderReference","value":"11111111-2222-4333-8444-555555555555"}}},"schemaVersion":1}"#

    @Test
    func decoderReadsTheGroupEnvelope() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(store)
        let envelope = try JSONDecoder().decode(
            SidecarEnvelope.self, from: Data(Self.groupEnvelopeV1.utf8))
        #expect(envelope.cellsDroppedOnDecode == 0)
        let key = SidecarKey(kind: .group, id: envelope.entityID)
        try store.write(envelope, at: key)

        #expect(try sync.groupIdentity(id: key.id)?.name == "soccer parents")
        #expect(try sync.groupPlacement(identityID: key.id) == FolderPlacement(
            parentFolderID: Self.folderID,
            modifiedAt: Self.createdAt,
            modifiedBy: "device-A/00000000-0000-4000-8000-000000000003"))
        #expect(try sync.groupHierarchyRecords().unavailableKeys.isEmpty)
    }

    /// Moving the group rewrites the placement cell and must hand every other
    /// cell back exactly as it arrived, including the one it cannot interpret.
    @Test
    func encoderReproducesThePlacementCellAndPreservesItsNeighbors() throws {
        let store = InMemorySidecarStore()
        let sync = makeSync(store)
        let original = try JSONDecoder().decode(
            SidecarEnvelope.self, from: Data(Self.groupEnvelopeV1.utf8))
        let key = SidecarKey(kind: .group, id: original.entityID)
        // Start from the same envelope WITHOUT its placement, then place it.
        var fields = original.fields
        fields.removeValue(forKey: GroupHierarchyCells.parentFolderKey)
        try store.write(SidecarEnvelope(entityID: original.entityID, fields: fields), at: key)

        try sync.setGroupPlacement(
            identityID: key.id,
            parentFolderID: Self.folderID,
            operationID: Self.placeOperation,
            now: Self.createdAt)

        let written = try #require(try store.read(key))
        let bytes = String(decoding: try SidecarEnvelopeCodec.encode(written), as: UTF8.self)
        #expect(bytes == Self.groupEnvelopeV1)
    }
}
