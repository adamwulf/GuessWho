import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("SidecarReconciler")
struct SidecarReconcilerTests {
    private let entityID = "550e8400-e29b-41d4-a716-446655440000"
    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_000_500)
    private let t3 = Date(timeIntervalSince1970: 1_700_001_000)

    private func makeSync(sidecars: InMemorySidecarStore) -> GuessWhoSync {
        GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
    }

    private func key() -> SidecarKey {
        SidecarKey(kind: .contact, id: entityID)
    }

    private func envelope(
        schemaVersion: Int = 1,
        fields: [String: SidecarCell]
    ) -> SidecarEnvelope {
        SidecarEnvelope(schemaVersion: schemaVersion, entityID: entityID, fields: fields)
    }

    private func encode(_ env: SidecarEnvelope) throws -> Data {
        try JSONEncoder().encode(env)
    }

    // MARK: - §9.5

    @Test
    func twoConflictVersionsBothParseable_mergesAndClears() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envB = envelope(fields: [
            "notes": SidecarCell(value: .string("Met at WWDC"), modifiedAt: t2, modifiedBy: "device-B")
        ])
        store.scriptConflict(at: key(), versions: [try encode(envA), try encode(envB)])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        #expect(outcome.key == key())
        #expect(outcome.mergedVersionCount == 2)
        #expect(outcome.skippedReasons.isEmpty)

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["nickname", "notes"])

        let secondPass = try sync.reconcileSidecars()
        #expect(secondPass.fileOutcomes.isEmpty)
    }

    @Test
    func threeConflictVersionsAllParseable_nWayFold() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envB = envelope(fields: [
            "b": SidecarCell(value: .string("beta"), modifiedAt: t2, modifiedBy: "device-B")
        ])
        let envC = envelope(fields: [
            "c": SidecarCell(value: .string("gamma"), modifiedAt: t3, modifiedBy: "device-C")
        ])
        store.scriptConflict(at: key(), versions: [
            try encode(envA), try encode(envB), try encode(envC)
        ])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        #expect(report.fileOutcomes[0].mergedVersionCount == 3)
        #expect(report.fileOutcomes[0].skippedReasons.isEmpty)

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a", "b", "c"])
    }

    @Test
    func oneVersionUnparseableBytes_skippedAndReported() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envB = envelope(fields: [
            "b": SidecarCell(value: .string("beta"), modifiedAt: t2, modifiedBy: "device-B")
        ])
        let garbage = Data("not json".utf8)
        store.scriptConflict(at: key(), versions: [
            try encode(envA), garbage, try encode(envB)
        ])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        #expect(outcome.mergedVersionCount == 2)
        #expect(outcome.skippedReasons.count == 1)
        let reason = outcome.skippedReasons[0].lowercased()
        #expect(reason.contains("json") || reason.contains("parse"))

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a", "b"])
    }

    @Test
    func oneVersionSchemaVersion99_skippedAndReported() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envFuture = envelope(schemaVersion: 99, fields: [
            "future": SidecarCell(value: .string("nope"), modifiedAt: t2, modifiedBy: "device-X")
        ])
        store.scriptConflict(at: key(), versions: [try encode(envA), try encode(envFuture)])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        #expect(outcome.mergedVersionCount == 1)
        #expect(outcome.skippedReasons.count == 1)
        #expect(outcome.skippedReasons[0].contains("schemaVersion=99"))

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a"])
    }

    @Test
    func unparseableAlongsideOneValid_collapsesToTheValid() throws {
        let store = InMemorySidecarStore()
        let envValid = envelope(fields: [
            "only": SidecarCell(value: .string("survivor"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        store.scriptConflict(at: key(), versions: [Data("garbage".utf8), try encode(envValid)])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        #expect(outcome.mergedVersionCount == 1)
        #expect(outcome.skippedReasons.count == 1)

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["only"])
        let onlyCell = try #require(merged.fields["only"])
        #expect(onlyCell.value == .string("survivor"))
        #expect(onlyCell.deletedAt == nil)
    }

    @Test
    func noVersionParses_leavesAllInConflict() throws {
        let store = InMemorySidecarStore()
        let g1 = Data("garbage-one".utf8)
        let g2 = Data("garbage-two".utf8)
        let g3 = Data("garbage-three".utf8)
        store.scriptConflict(at: key(), versions: [g1, g2, g3])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        #expect(outcome.mergedVersionCount == 0)
        #expect(outcome.skippedReasons.count == 3)

        #expect(try store.read(key()) == nil)

        let secondPass = try sync.reconcileSidecars()
        #expect(secondPass.fileOutcomes.count == 1)
        #expect(secondPass.fileOutcomes[0].mergedVersionCount == 0)
    }
}
