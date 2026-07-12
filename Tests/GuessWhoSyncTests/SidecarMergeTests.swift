import Foundation
import Testing
@testable import GuessWhoSync

@Suite("SidecarMerge")
struct SidecarMergeTests {
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)
    private let t3 = Date(timeIntervalSince1970: 1_700_001_000)

    @Test
    func disjointFieldsBothSurvive() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("Bear"), at: t1, by: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "notes": live(.string("Met at WWDC"), at: t1, by: "device-B"),
        ])
        let merged = try merge(a, b).get()
        #expect(merged.entityID == "e")
        #expect(merged.fields.count == 2)
        try assertLive(merged.fields["nickname"], equals: .string("Bear"), by: "device-A", at: t1)
        try assertLive(merged.fields["notes"], equals: .string("Met at WWDC"), by: "device-B", at: t1)
    }

    @Test
    func laterModifiedAtWinsOnSameField() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("Bear"), at: t1, by: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("Bear-cub"), at: t2, by: "device-A"),
        ])
        let merged = try merge(a, b).get()
        try assertLive(merged.fields["nickname"], equals: .string("Bear-cub"), by: "device-A", at: t2)
    }

    @Test
    func tiedModifiedAtPicksLexLargerModifiedBy() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-A"), at: t1, by: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-B"), at: t1, by: "device-B"),
        ])
        let mergedAB = try merge(a, b).get()
        try assertLive(mergedAB.fields["nickname"], equals: .string("from-B"), by: "device-B", at: t1)
        let mergedBA = try merge(b, a).get()
        try assertLive(mergedBA.fields["nickname"], equals: .string("from-B"), by: "device-B", at: t1)
    }

    @Test
    func deletedWinsWhenLater() throws {
        let aLive = SidecarEnvelope(entityID: "e", fields: [
            "petName": live(.string("Snuggles"), at: t1, by: "device-A"),
        ])
        let bDeleted = SidecarEnvelope(entityID: "e", fields: [
            "petName": deleted(.string("Snuggles"), at: t2, by: "device-B"),
        ])
        let merged = try merge(aLive, bDeleted).get()
        let cell = try #require(merged.fields["petName"])
        #expect(cell.deletedAt != nil)
        #expect(cell.modifiedBy == "device-B")
    }

    @Test
    func liveValueWinsWhenLaterThanDeleted() throws {
        let bDeleted = SidecarEnvelope(entityID: "e", fields: [
            "petName": deleted(.string("old"), at: t1, by: "device-A"),
        ])
        let aLive = SidecarEnvelope(entityID: "e", fields: [
            "petName": live(.string("Snuggles"), at: t2, by: "device-B"),
        ])
        let merged = try merge(bDeleted, aLive).get()
        try assertLive(merged.fields["petName"], equals: .string("Snuggles"), by: "device-B", at: t2)
    }

    @Test
    func associativeAcrossThreeEnvelopes() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-A"), at: t1, by: "device-A"),
            "notes": live(.string("note-A"), at: t2, by: "device-A"),
            "petName": live(.string("Snuggles"), at: t1, by: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-B"), at: t2, by: "device-B"),
            "color": live(.string("blue"), at: t1, by: "device-B"),
            "petName": deleted(.string("Snuggles"), at: t3, by: "device-B"),
        ])
        let c = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-C"), at: t2, by: "device-C"),
            "notes": live(.string("note-C"), at: t1, by: "device-C"),
            "size": live(.number(42), at: t3, by: "device-C"),
        ])

        let leftFold = try merge(merge(a, b).get(), c).get()
        let rightFold = try merge(a, merge(b, c).get()).get()
        assertEnvelopesEqual(leftFold, rightFold)
    }

    @Test
    func equivalentConflictFoldsProduceCanonicalIdenticalBytes() throws {
        let current = SidecarEnvelope(entityID: "e", fields: [
            "zulu": live(.string("current-z"), at: t1, by: "device-A"),
            "alpha": live(.string("current-a"), at: t1, by: "device-A"),
        ])
        let conflict = SidecarEnvelope(entityID: "e", fields: [
            "yankee": live(.string("conflict-y"), at: t2, by: "device-B"),
            "alpha": live(.string("conflict-a"), at: t2, by: "device-B"),
        ])

        // Devices can receive the same NSFileVersion set in a different fold
        // order. Per-cell LWW already makes the logical result commutative;
        // canonical encoding must also make the bytes identical or iCloud can
        // immediately create another conflict from the two merged writes.
        let currentFirst = try merge(current, conflict).get()
        let conflictFirst = try merge(conflict, current).get()
        let currentFirstBytes = try SidecarEnvelopeCodec.encode(currentFirst)
        let conflictFirstBytes = try SidecarEnvelopeCodec.encode(conflictFirst)

        #expect(currentFirstBytes == conflictFirstBytes)
        #expect(try JSONDecoder().decode(SidecarEnvelope.self, from: currentFirstBytes).fields.count == 3)
    }

    @Test
    func entityIDMismatchFails() {
        let a = SidecarEnvelope(entityID: "alpha", fields: [:])
        let b = SidecarEnvelope(entityID: "beta", fields: [:])
        guard case .failure(let err) = merge(a, b) else {
            Issue.record("expected failure")
            return
        }
        guard case .entityIDMismatch = err else {
            Issue.record("expected .entityIDMismatch, got \(err)")
            return
        }
    }

    @Test
    func schemaVersionMismatchOnAFails() {
        let a = SidecarEnvelope(schemaVersion: 2, entityID: "e", fields: [:])
        let b = SidecarEnvelope(entityID: "e", fields: [:])
        guard case .failure(let err) = merge(a, b) else {
            Issue.record("expected failure")
            return
        }
        guard case .schemaVersionMismatch = err else {
            Issue.record("expected .schemaVersionMismatch, got \(err)")
            return
        }
    }

    @Test
    func schemaVersionMismatchOnBFails() {
        let a = SidecarEnvelope(entityID: "e", fields: [:])
        let b = SidecarEnvelope(schemaVersion: 99, entityID: "e", fields: [:])
        guard case .failure(let err) = merge(a, b) else {
            Issue.record("expected failure")
            return
        }
        guard case .schemaVersionMismatch = err else {
            Issue.record("expected .schemaVersionMismatch, got \(err)")
            return
        }
    }

    @Test
    func emptyMergedIntoNonEmptyPreservesFields() throws {
        let empty = SidecarEnvelope(entityID: "e", fields: [:])
        let full = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("Bear"), at: t1, by: "device-A"),
            "notes": live(.string("hi"), at: t2, by: "device-B"),
        ])
        let mergedEF = try merge(empty, full).get()
        #expect(mergedEF.fields.count == 2)
        try assertLive(mergedEF.fields["nickname"], equals: .string("Bear"), by: "device-A", at: t1)
        try assertLive(mergedEF.fields["notes"], equals: .string("hi"), by: "device-B", at: t2)
        let mergedFE = try merge(full, empty).get()
        assertEnvelopesEqual(mergedEF, mergedFE)
    }

    @Test
    func commutativeOnOverlappingFields() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-A"), at: t2, by: "device-A"),
            "notes": live(.string("note-A"), at: t1, by: "device-A"),
            "petName": deleted(.string("old"), at: t1, by: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": live(.string("from-B"), at: t1, by: "device-B"),
            "notes": live(.string("note-B"), at: t1, by: "device-B"),
            "petName": live(.string("Snuggles"), at: t2, by: "device-B"),
        ])

        let ab = try merge(a, b).get()
        let ba = try merge(b, a).get()
        assertEnvelopesEqual(ab, ba)
    }

    // MARK: - helpers

    // The cross-device previous-photo race: the SAME single-slot `.blob`
    // field-instance cell is repointed on two devices to DIFFERENT blobIds.
    // Whole-cell LWW must keep exactly the winner's pointer intact and never
    // resurrect or blend in the loser's blobId (which the sweep then reclaims).
    @Test
    func blobPointerWholeCellLWWKeepsWinnerPointer() throws {
        func blobCell(blobId: String, at: Date, by: String) -> SidecarCell {
            let inner = SidecarField.makeInnerValue(
                field: "previousPhoto",
                type: .blob,
                value: BlobPointer(blobId: blobId, contentType: "image/jpeg", byteCount: 10).jsonValue,
                createdAt: t1
            )
            return SidecarCell(value: inner, modifiedAt: at, modifiedBy: by)
        }
        let cellKey = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let older = SidecarEnvelope(entityID: "e", fields: [cellKey: blobCell(blobId: "blob-OLD", at: t1, by: "device-A")])
        let newer = SidecarEnvelope(entityID: "e", fields: [cellKey: blobCell(blobId: "blob-NEW", at: t2, by: "device-B")])

        let merged = try merge(older, newer).get()
        let cell = try #require(merged.fields[cellKey])
        let decoded = try #require(SidecarField.decode(id: UUID(uuidString: cellKey)!, from: cell))
        let pointer = try #require(BlobPointer(from: decoded.value))
        // Winner (newer) pointer survives intact; loser's blobId is gone.
        #expect(pointer.blobId == "blob-NEW")
        #expect(cell.modifiedBy == "device-B")
    }

    private func live(_ value: JSONValue, at: Date, by: String) -> SidecarCell {
        SidecarCell(value: value, modifiedAt: at, modifiedBy: by)
    }

    private func deleted(_ value: JSONValue, at: Date, by: String) -> SidecarCell {
        SidecarCell(value: value, modifiedAt: at, modifiedBy: by, deletedAt: at)
    }

    private func assertLive(
        _ cell: SidecarCell?,
        equals expected: JSONValue,
        by: String,
        at: Date,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let cell = try #require(cell, sourceLocation: sourceLocation)
        #expect(cell.deletedAt == nil, sourceLocation: sourceLocation)
        #expect(cell.value == expected, sourceLocation: sourceLocation)
        #expect(cell.modifiedBy == by, sourceLocation: sourceLocation)
        #expect(cell.modifiedAt == at, sourceLocation: sourceLocation)
    }

    private func assertEnvelopesEqual(
        _ x: SidecarEnvelope,
        _ y: SidecarEnvelope,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(x.entityID == y.entityID, sourceLocation: sourceLocation)
        #expect(x.schemaVersion == y.schemaVersion, sourceLocation: sourceLocation)
        #expect(x.fields.keys.sorted() == y.fields.keys.sorted(), sourceLocation: sourceLocation)
        for key in x.fields.keys {
            guard let xc = x.fields[key], let yc = y.fields[key] else {
                Issue.record("missing cell for \(key)", sourceLocation: sourceLocation)
                continue
            }
            #expect(xc.value == yc.value, "value for \(key)", sourceLocation: sourceLocation)
            #expect(xc.modifiedAt == yc.modifiedAt, "modifiedAt for \(key)", sourceLocation: sourceLocation)
            #expect(xc.modifiedBy == yc.modifiedBy, "modifiedBy for \(key)", sourceLocation: sourceLocation)
            #expect(xc.deletedAt == yc.deletedAt, "deletedAt for \(key)", sourceLocation: sourceLocation)
        }
    }
}
