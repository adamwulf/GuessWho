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
            "nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "notes": .value(.string("Met at WWDC"), modifiedAt: t1, modifiedBy: "device-B"),
        ])
        let merged = try merge(a, b).get()
        #expect(merged.entityID == "e")
        #expect(merged.fields.count == 2)
        try assertValue(merged.fields["nickname"], equals: .string("Bear"), by: "device-A", at: t1)
        try assertValue(merged.fields["notes"], equals: .string("Met at WWDC"), by: "device-B", at: t1)
    }

    @Test
    func laterModifiedAtWinsOnSameField() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("Bear-cub"), modifiedAt: t2, modifiedBy: "device-A"),
        ])
        let merged = try merge(a, b).get()
        try assertValue(merged.fields["nickname"], equals: .string("Bear-cub"), by: "device-A", at: t2)
    }

    @Test
    func tiedModifiedAtPicksLexLargerModifiedBy() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-A"), modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-B"), modifiedAt: t1, modifiedBy: "device-B"),
        ])
        let mergedAB = try merge(a, b).get()
        try assertValue(mergedAB.fields["nickname"], equals: .string("from-B"), by: "device-B", at: t1)

        let mergedBA = try merge(b, a).get()
        try assertValue(mergedBA.fields["nickname"], equals: .string("from-B"), by: "device-B", at: t1)
    }

    @Test
    func tombstoneWinsWhenLater() throws {
        let live = SidecarEnvelope(entityID: "e", fields: [
            "petName": .value(.string("Snuggles"), modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let killed = SidecarEnvelope(entityID: "e", fields: [
            "petName": .tombstone(modifiedAt: t2, modifiedBy: "device-B"),
        ])
        let merged = try merge(live, killed).get()
        guard case .tombstone(let ts, let by) = merged.fields["petName"] else {
            Issue.record("expected tombstone to survive")
            return
        }
        #expect(ts == t2)
        #expect(by == "device-B")
    }

    @Test
    func liveValueWinsWhenLaterThanTombstone() throws {
        let killed = SidecarEnvelope(entityID: "e", fields: [
            "petName": .tombstone(modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let live = SidecarEnvelope(entityID: "e", fields: [
            "petName": .value(.string("Snuggles"), modifiedAt: t2, modifiedBy: "device-B"),
        ])
        let merged = try merge(killed, live).get()
        try assertValue(merged.fields["petName"], equals: .string("Snuggles"), by: "device-B", at: t2)
    }

    @Test
    func associativeAcrossThreeEnvelopes() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-A"), modifiedAt: t1, modifiedBy: "device-A"),
            "notes": .value(.string("note-A"), modifiedAt: t2, modifiedBy: "device-A"),
            "petName": .value(.string("Snuggles"), modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-B"), modifiedAt: t2, modifiedBy: "device-B"),
            "color": .value(.string("blue"), modifiedAt: t1, modifiedBy: "device-B"),
            "petName": .tombstone(modifiedAt: t3, modifiedBy: "device-B"),
        ])
        let c = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-C"), modifiedAt: t2, modifiedBy: "device-C"),
            "notes": .value(.string("note-C"), modifiedAt: t1, modifiedBy: "device-C"),
            "size": .value(.number(42), modifiedAt: t3, modifiedBy: "device-C"),
        ])

        let leftFold = try merge(merge(a, b).get(), c).get()
        let rightFold = try merge(a, merge(b, c).get()).get()
        assertEnvelopesEqual(leftFold, rightFold)
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
            "nickname": .value(.string("Bear"), modifiedAt: t1, modifiedBy: "device-A"),
            "notes": .value(.string("hi"), modifiedAt: t2, modifiedBy: "device-B"),
        ])

        let mergedEF = try merge(empty, full).get()
        #expect(mergedEF.fields.count == 2)
        try assertValue(mergedEF.fields["nickname"], equals: .string("Bear"), by: "device-A", at: t1)
        try assertValue(mergedEF.fields["notes"], equals: .string("hi"), by: "device-B", at: t2)

        let mergedFE = try merge(full, empty).get()
        assertEnvelopesEqual(mergedEF, mergedFE)
    }

    @Test
    func commutativeOnOverlappingFields() throws {
        let a = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-A"), modifiedAt: t2, modifiedBy: "device-A"),
            "notes": .value(.string("note-A"), modifiedAt: t1, modifiedBy: "device-A"),
            "petName": .tombstone(modifiedAt: t1, modifiedBy: "device-A"),
        ])
        let b = SidecarEnvelope(entityID: "e", fields: [
            "nickname": .value(.string("from-B"), modifiedAt: t1, modifiedBy: "device-B"),
            "notes": .value(.string("note-B"), modifiedAt: t1, modifiedBy: "device-B"),
            "petName": .value(.string("Snuggles"), modifiedAt: t2, modifiedBy: "device-B"),
        ])

        let ab = try merge(a, b).get()
        let ba = try merge(b, a).get()
        assertEnvelopesEqual(ab, ba)
    }

    // MARK: - helpers

    private func assertValue(
        _ cell: SidecarCell?,
        equals expected: JSONValue,
        by: String,
        at: Date,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        guard let cell else {
            Issue.record("cell missing", sourceLocation: sourceLocation)
            return
        }
        guard case .value(let v, let ts, let writer) = cell else {
            Issue.record("expected value cell, got \(cell)", sourceLocation: sourceLocation)
            return
        }
        #expect(v == expected, sourceLocation: sourceLocation)
        #expect(writer == by, sourceLocation: sourceLocation)
        #expect(ts == at, sourceLocation: sourceLocation)
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
            switch (x.fields[key], y.fields[key]) {
            case (.value(let xv, let xt, let xb), .value(let yv, let yt, let yb)):
                #expect(xv == yv, "value for \(key)", sourceLocation: sourceLocation)
                #expect(xt == yt, "modifiedAt for \(key)", sourceLocation: sourceLocation)
                #expect(xb == yb, "modifiedBy for \(key)", sourceLocation: sourceLocation)
            case (.tombstone(let xt, let xb), .tombstone(let yt, let yb)):
                #expect(xt == yt, "modifiedAt for \(key)", sourceLocation: sourceLocation)
                #expect(xb == yb, "modifiedBy for \(key)", sourceLocation: sourceLocation)
            default:
                Issue.record("cells differ in kind for \(key): \(String(describing: x.fields[key])) vs \(String(describing: y.fields[key]))", sourceLocation: sourceLocation)
            }
        }
    }
}
