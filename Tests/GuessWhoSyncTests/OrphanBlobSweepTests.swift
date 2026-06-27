import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
@_spi(ConflictReconcile) import GuessWhoSyncTesting

@Suite("Orphan blob sweep + reconcile race")
struct OrphanBlobSweepTests {
    private func makeOrchestrator() -> (GuessWhoSync, InMemorySidecarStore) {
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-A"
        )
        return (sync, sidecars)
    }

    private let contactKey = SidecarKey(kind: .contact, id: "11111111-1111-1111-1111-111111111111")

    // MARK: - setBlobField fast path

    @Test
    func setBlobFieldWritesPointerAndPayload() throws {
        let (sync, sidecars) = makeOrchestrator()
        let bytes = Data([0x01, 0x02, 0x03])
        let blobId = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: bytes, contentType: "image/jpeg")

        // The payload is retrievable through the field accessor.
        #expect(try sync.blobFieldData(at: contactKey, field: "previousPhoto") == bytes)
        // The pointer cell carries the minted blobId + metadata.
        let fields = try sync.fields(at: contactKey).filter { $0.deletedAt == nil }
        #expect(fields.count == 1)
        let pointer = try #require(BlobPointer(from: fields[0].value))
        #expect(pointer.blobId == blobId)
        #expect(pointer.contentType == "image/jpeg")
        #expect(pointer.byteCount == 3)
        // The `.dat` is on disk for the key.
        #expect(try sidecars.blobIds(for: contactKey) == [blobId])
    }

    @Test
    func setBlobFieldFreshBlobIdPerWrite() throws {
        let (sync, _) = makeOrchestrator()
        let first = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x01]), contentType: "image/jpeg")
        let second = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x02]), contentType: "image/jpeg")
        #expect(first != second)
        #expect(UUID(uuidString: first) != nil)
        #expect(UUID(uuidString: second) != nil)
    }

    @Test
    func setBlobFieldOverwriteDeletesSupersededDatAndRepointsSlot() throws {
        let (sync, sidecars) = makeOrchestrator()
        let firstID = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x01]), contentType: "image/jpeg")
        let secondID = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x02]), contentType: "image/jpeg")

        // Single slot: still exactly ONE live `.blob` field, repointed.
        let live = try sync.fields(at: contactKey).filter { $0.deletedAt == nil }
        #expect(live.count == 1)
        #expect(BlobPointer(from: live[0].value)?.blobId == secondID)

        // Delete-on-overwrite fast path: the superseded `.dat` is gone; only
        // the new one remains.
        let onDisk = try sidecars.blobIds(for: contactKey)
        #expect(onDisk == [secondID])
        #expect(firstID != secondID)
        #expect(try sync.blobFieldData(at: contactKey, field: "previousPhoto") == Data([0x02]))
    }

    @Test
    func setBlobFieldRejectsNonBlobSameNameField() throws {
        let (sync, _) = makeOrchestrator()
        // A same-named field of a different type can't be overwritten by a
        // `.blob` slot.
        _ = try sync.addField(at: contactKey, field: "previousPhoto", type: .note, value: .string("not a blob"))
        #expect(throws: SidecarStoreError.self) {
            _ = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x01]), contentType: "image/jpeg")
        }
    }

    @Test
    func blobFieldDataReturnsNilWhenNoSuchField() throws {
        let (sync, _) = makeOrchestrator()
        #expect(try sync.blobFieldData(at: contactKey, field: "previousPhoto") == nil)
    }

    // MARK: - Orphan sweep

    @Test
    func sweepKeepsReferencedDeletesUnreferenced() throws {
        let (sync, sidecars) = makeOrchestrator()
        let referencedID = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0xaa]), contentType: "image/jpeg")
        // Plant an unreferenced `.dat` directly (no pointer cell references it).
        let orphanID = "99999999-9999-9999-9999-999999999999"
        try sidecars.writeBlob(Data([0xbb]), blobId: orphanID, for: contactKey)
        #expect(Set(try sidecars.blobIds(for: contactKey)) == Set([referencedID, orphanID]))

        let report = try sync.sweepOrphanBlobs()
        #expect(report.deletionSkipped == false)
        #expect(report.deleted.map(\.blobId) == [orphanID])
        // Referenced survives; orphan is gone.
        #expect(try sidecars.blobIds(for: contactKey) == [referencedID])
        #expect(try sync.blobFieldData(at: contactKey, field: "previousPhoto") == Data([0xaa]))
    }

    @Test
    func sweepImmediatelyAfterSetBlobFieldKeepsTheFreshBlob() throws {
        // REGRESSION (write→sweep race): setBlobField writes the `.dat` and
        // commits the pointer atomically under the per-key lock the sweep also
        // takes. So a sweep that runs right after setBlobField returns can never
        // see the fresh `.dat` as a referenced-but-unrepointed orphan. (Before
        // the fix the `.dat` was written OUTSIDE the lock; a sweep interleaving
        // the write→repoint window would delete it — a lost previous photo.)
        let (sync, sidecars) = makeOrchestrator()
        let blobId = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0xaa]), contentType: "image/jpeg")

        let report = try sync.sweepOrphanBlobs()
        #expect(report.deletionSkipped == false)
        #expect(report.deleted.isEmpty)
        #expect(try sidecars.blobIds(for: contactKey) == [blobId])
        #expect(try sync.blobFieldData(at: contactKey, field: "previousPhoto") == Data([0xaa]))
    }

    @Test
    func concurrentSetBlobFieldAndSweepNeverLosesTheLivePhoto() async throws {
        // REGRESSION (write→sweep race), the CONCURRENCY version: the sequential
        // test documents the invariant but would pass even pre-fix. This runs a
        // writer (repeated setBlobField on one key) and a sweeper (repeated
        // sweepOrphanBlobs) truly concurrently. With the `.dat` write moved
        // inside the per-key lock the sweep shares, the live previousPhoto must
        // ALWAYS be readable — never a pointer to a swept `.dat`. Pre-fix, the
        // sweeper could delete a just-written `.dat` in the write→repoint window.
        let (sync, _) = makeOrchestrator()
        let iterations = 200
        // Seed one so the first sweeps have a real reference to protect.
        _ = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x00]), contentType: "image/jpeg")

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Writer: overwrite the single slot repeatedly with distinct bytes.
            group.addTask {
                for i in 0..<iterations {
                    _ = try sync.setBlobField(
                        at: self.contactKey,
                        field: "previousPhoto",
                        data: Data([UInt8(i % 251), 0xAB]),
                        contentType: "image/jpeg"
                    )
                }
            }
            // Sweeper: hammer the orphan sweep in parallel.
            group.addTask {
                for _ in 0..<iterations {
                    _ = try sync.sweepOrphanBlobs()
                    // The live previousPhoto pointer must ALWAYS resolve to bytes
                    // — a nil here means the sweep deleted a referenced `.dat`.
                    let live = try sync.blobFieldData(at: self.contactKey, field: "previousPhoto")
                    #expect(live != nil)
                }
            }
            try await group.waitForAll()
        }

        // Final state is consistent: exactly one live slot, its `.dat` present.
        let final = try sync.blobFieldData(at: contactKey, field: "previousPhoto")
        #expect(final != nil)
    }

    @Test
    func sweepKeepsBlobWhosePointerHasMalformedMetadata() throws {
        // REGRESSION (over-strict harvest): a live `.blob` cell whose pointer has
        // a valid blobId but malformed contentType/byteCount must STILL protect
        // its `.dat` — the sweep's reference-counting keys on the blobId alone
        // (BlobPointer.referencedBlobId), never the full strict decode. A strict
        // harvest would treat the blob as unreferenced and delete it (data loss).
        let (sync, sidecars) = makeOrchestrator()
        let blobId = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0xdd]), contentType: "image/jpeg")

        // Corrupt the pointer's metadata in place (keep the blobId), so the
        // strict BlobPointer(from:) would return nil but referencedBlobId still
        // recovers the blobId.
        let envelope = try #require(try sync.sidecar(at: contactKey))
        let (cellID, cell) = try #require(envelope.fields.first)
        guard case .object(var inner) = cell.value,
              case .object(var pointer) = inner[SidecarField.innerValueKey] ?? .null else {
            Issue.record("unexpected cell shape"); return
        }
        pointer.removeValue(forKey: BlobPointer.contentTypeKey) // malform: drop contentType
        inner[SidecarField.innerValueKey] = .object(pointer)
        var fields = envelope.fields
        fields[cellID] = SidecarCell(value: .object(inner), modifiedAt: cell.modifiedAt, modifiedBy: cell.modifiedBy, deletedAt: nil)
        try sidecars.write(SidecarEnvelope(schemaVersion: 1, entityID: envelope.entityID, fields: fields), at: contactKey)

        // Strict decode now fails, but the sweep must not delete the `.dat`.
        let report = try sync.sweepOrphanBlobs()
        #expect(report.deleted.isEmpty)
        #expect(try sidecars.blobIds(for: contactKey) == [blobId])
    }

    @Test
    func sweepDoesNotDeleteSoftDeletedFieldBlobUntilDereferenced() throws {
        // A soft-deleted `.blob` field no longer counts as a live reference, so
        // its `.dat` becomes orphan and is swept.
        let (sync, sidecars) = makeOrchestrator()
        let blobId = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0xcc]), contentType: "image/jpeg")
        let field = try #require(try sync.fields(at: contactKey).first { $0.field == "previousPhoto" })
        try sync.deleteField(at: contactKey, id: field.id)

        let report = try sync.sweepOrphanBlobs()
        #expect(report.deleted.map(\.blobId) == [blobId])
        #expect(try sidecars.blobIds(for: contactKey).isEmpty)
    }

    @Test
    func sweepIsGlobalAcrossKeys() throws {
        // An orphan `.dat` under one key (whose envelope exists but no longer
        // references it) is deleted even when a DIFFERENT key holds the only
        // referenced blob. keyB has an envelope (so allKeys surfaces it) with
        // no live `.blob` pointing at the planted orphan.
        let (sync, sidecars) = makeOrchestrator()
        let keyB = SidecarKey(kind: .contact, id: "22222222-2222-2222-2222-222222222222")
        let refA = try sync.setBlobField(at: contactKey, field: "previousPhoto", data: Data([0x01]), contentType: "image/jpeg")
        // keyB's envelope references nothing; its lingering `.dat` is orphan.
        try sidecars.write(SidecarEnvelope(entityID: keyB.id, fields: [:]), at: keyB)
        try sidecars.writeBlob(Data([0x02]), blobId: "orphan-under-b", for: keyB)

        let report = try sync.sweepOrphanBlobs()
        #expect(report.deletionSkipped == false)
        #expect(report.deleted.contains(where: { $0.key == keyB && $0.blobId == "orphan-under-b" }))
        #expect(try sidecars.blobIds(for: contactKey) == [refA])
        #expect(try sidecars.blobIds(for: keyB).isEmpty)
    }

    @Test
    func sweepWithNoBlobsIsNoOp() throws {
        let (sync, _) = makeOrchestrator()
        try sync.addField(at: contactKey, field: "note", type: .note, value: .string("x"))
        let report = try sync.sweepOrphanBlobs()
        #expect(report.deleted.isEmpty)
        #expect(report.deletionSkipped == false)
    }

    // MARK: - Cross-device snapshot race (the key scenario)

    @Test
    func crossDeviceRaceMergeKeepsOneBlobSweepDeletesLoser() throws {
        // Two devices each snapshot a DIFFERENT previous photo into the same
        // single-slot `.blob` field. Both `.dat`s exist on disk; the whole-cell
        // LWW merge keeps ONE pointer cell. The sweep must delete the dropped
        // (loser) `.dat` and keep the surviving (winner) one.
        let (sync, sidecars) = makeOrchestrator()
        let winnerBlobId = "aaaaaaaa-0000-0000-0000-000000000001"
        let loserBlobId = "bbbbbbbb-0000-0000-0000-000000000002"

        // Both devices' `.dat` payloads landed (file sync delivered both).
        try sidecars.writeBlob(Data("winner-photo".utf8), blobId: winnerBlobId, for: contactKey)
        try sidecars.writeBlob(Data("loser-photo".utf8), blobId: loserBlobId, for: contactKey)

        // The merged envelope (post whole-cell LWW) references ONLY the winner.
        let fieldID = UUID().uuidString
        let pointer = BlobPointer(blobId: winnerBlobId, contentType: "image/jpeg", byteCount: 12)
        let inner = SidecarField.makeInnerValue(field: "previousPhoto", type: .blob, value: pointer.jsonValue, createdAt: Date())
        let cell = SidecarCell(value: inner, modifiedAt: Date(), modifiedBy: "device-B")
        try sidecars.write(SidecarEnvelope(entityID: contactKey.id, fields: [fieldID: cell]), at: contactKey)

        // Pre-sweep: both `.dat`s present.
        #expect(Set(try sidecars.blobIds(for: contactKey)) == Set([winnerBlobId, loserBlobId]))

        let report = try sync.sweepOrphanBlobs()
        #expect(report.deletionSkipped == false)
        #expect(report.deleted.map(\.blobId) == [loserBlobId])
        // Winner survives, loser swept.
        #expect(try sidecars.blobIds(for: contactKey) == [winnerBlobId])
        #expect(try sync.blobFieldData(at: contactKey, field: "previousPhoto") == Data("winner-photo".utf8))
    }

    // MARK: - Conservatism: not-yet-downloaded envelopes

    @Test
    func sweepSkipsDeletionWhenAnyEnvelopeUnreadable() throws {
        // A referenced blob could be hiding in a not-yet-downloaded envelope.
        // If ANY envelope read throws, the sweep performs NO deletions.
        let store = NotYetDownloadedSidecarStore()
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: store,
            deviceID: "device-A"
        )
        // Key B's envelope is unreadable (pending download); it conceptually
        // references the only blob, which lives under key A on disk.
        let keyA = SidecarKey(kind: .contact, id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let keyB = SidecarKey(kind: .contact, id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        try store.writeBlob(Data([0x01]), blobId: "pending-ref", for: keyA)
        store.markPendingDownload(keyB)

        let report = try sync.sweepOrphanBlobs()
        #expect(report.deletionSkipped == true)
        #expect(report.deleted.isEmpty)
        // The blob is NOT deleted — conservative.
        #expect(try store.blobIds(for: keyA) == ["pending-ref"])
        #expect(report.skippedReasons.contains { $0.contains("envelope read failed") })
    }
}

// A store that can mark specific keys as "not yet downloaded" so read() throws
// `.notYetDownloaded`, exercising the sweep's conservative abort. Wraps an
// InMemorySidecarStore for everything else.
private final class NotYetDownloadedSidecarStore: SidecarStoreProtocol {
    private let backing = InMemorySidecarStore()
    private var pending: Set<SidecarKey> = []

    func markPendingDownload(_ key: SidecarKey) { pending.insert(key) }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        if pending.contains(key) { throw SidecarStoreError.notYetDownloaded(key) }
        return try backing.read(key)
    }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws { try backing.write(envelope, at: key) }
    func delete(_ key: SidecarKey) throws { try backing.delete(key) }
    func allKeys() throws -> [SidecarKey] {
        // Surface both the keys with envelopes AND the pending (download-only)
        // keys, so the sweep sees keyB and tries to read it.
        Array(Set(try backing.allKeys()).union(pending))
    }
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws { try backing.writeBlob(data, blobId: blobId, for: key) }
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? { try backing.readBlob(blobId: blobId, for: key) }
    func deleteBlob(blobId: String, for key: SidecarKey) throws { try backing.deleteBlob(blobId: blobId, for: key) }
    func blobIds(for key: SidecarKey) throws -> [String] { try backing.blobIds(for: key) }
}
