import Foundation
import Testing
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
@_spi(ConflictReconcile) import GuessWhoSyncTesting

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

    // MARK: - §6 happy path (current parseable + conflicts parseable)

    @Test
    func twoConflictVersionsBothParseable_mergesAndClears() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "nickname": SidecarCell(value: .string("Bear"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envB = envelope(fields: [
            "notes": SidecarCell(value: .string("Met at WWDC"), modifiedAt: t2, modifiedBy: "device-B")
        ])
        // Seed current; script B as a conflict version. Current parses + 1 conflict parses → overwrite.
        try store.write(envA, at: key())
        store.scriptConflict(at: key(), versions: [try encode(envB)])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        #expect(outcome.key == key())
        #expect(outcome.versionsConsidered == 2)
        #expect(outcome.skippedReasons.isEmpty)

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["nickname", "notes"])

        let secondPass = try sync.reconcileSidecars()
        #expect(secondPass.fileOutcomes.isEmpty)
    }

    @Test
    func threeWayFold_currentPlusTwoConflictsAllParseable() throws {
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
        try store.write(envA, at: key())
        store.scriptConflict(at: key(), versions: [try encode(envB), try encode(envC)])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        #expect(report.fileOutcomes[0].versionsConsidered == 3)
        #expect(report.fileOutcomes[0].skippedReasons.isEmpty)

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a", "b", "c"])
    }

    @Test
    func oneConflictVersionUnparseable_skippedAndReported() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envB = envelope(fields: [
            "b": SidecarCell(value: .string("beta"), modifiedAt: t2, modifiedBy: "device-B")
        ])
        try store.write(envA, at: key())
        store.scriptConflict(at: key(), versions: [Data("not json".utf8), try encode(envB)])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        // versionsConsidered counts every version slot the resolver saw:
        // current (envA) + 2 conflicts (garbage + envB) = 3. Skipped reasons
        // surface the one unparseable input separately.
        #expect(outcome.versionsConsidered == 3)
        #expect(outcome.skippedReasons.count == 1)
        let reason = outcome.skippedReasons[0].lowercased()
        #expect(reason.contains("json") || reason.contains("parse"))

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a", "b"])
    }

    @Test
    func oneConflictVersionSchemaVersion99_skippedAndReported() throws {
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envFuture = envelope(schemaVersion: 99, fields: [
            "future": SidecarCell(value: .string("nope"), modifiedAt: t2, modifiedBy: "device-X")
        ])
        try store.write(envA, at: key())
        store.scriptConflict(at: key(), versions: [try encode(envFuture)])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        // current (envA) + 1 v99 conflict = 2 slots considered; the v99 one
        // is reported as skipped.
        #expect(outcome.versionsConsidered == 2)
        #expect(outcome.skippedReasons.count == 1)
        #expect(outcome.skippedReasons[0].contains("schemaVersion=99"))

        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a"])
    }

    // MARK: - §6 step 4: current absent but a conflict parses → write the merged result

    @Test
    func currentAbsent_conflictParses_writesMergedAtKey() throws {
        let store = InMemorySidecarStore()
        let envValid = envelope(fields: [
            "only": SidecarCell(value: .string("survivor"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        // No `write` for the current → store passes nil to the resolver.
        store.scriptConflict(at: key(), versions: [try encode(envValid)])

        let report = try makeSync(sidecars: store).reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        // The conflict version participated in the merge; the count includes
        // it but not the absent current.
        #expect(outcome.versionsConsidered == 1)
        #expect(outcome.skippedReasons.isEmpty)

        // The merged envelope is now the current at this key.
        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["only"])
    }

    @Test
    func malformedCellsInEnvelopeAreReportedInSkippedReasons() throws {
        // §5.3 silent cell drops should still be observable: the orchestrator
        // surfaces a non-zero cellsDroppedOnDecode count via skippedReasons.
        let store = InMemorySidecarStore()
        try store.write(envelope(fields: [
            "ok": SidecarCell(value: .string("present"), modifiedAt: t1, modifiedBy: "device-A")
        ]), at: key())
        let brokenConflict = #"""
        {
          "schemaVersion": 1,
          "entityID": "\#(entityID)",
          "fields": {
            "good": { "value": "v", "modifiedAt": "2026-06-14T20:15:00.000Z", "modifiedBy": "device-X" },
            "broken": { "value": "x", "modifiedAt": "nope", "modifiedBy": "d" }
          }
        }
        """#
        store.scriptConflict(at: key(), versions: [brokenConflict.data(using: .utf8)!])

        let report = try makeSync(sidecars: store).reconcileSidecars()
        let outcome = try #require(report.fileOutcomes.first)
        #expect(outcome.skippedReasons.contains { $0.contains("dropped 1 malformed cell") })
    }

    // MARK: - Nothing parses → write empty envelope, conflict is still resolved

    @Test
    func noVersionParses_writesEmptyEnvelopeAndClearsConflict() throws {
        let store = InMemorySidecarStore()
        let g1 = Data("garbage-one".utf8)
        let g2 = Data("garbage-two".utf8)
        let g3 = Data("garbage-three".utf8)
        // No current envelope written; all conflict versions garbage.
        store.scriptConflict(at: key(), versions: [g1, g2, g3])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()

        #expect(report.fileOutcomes.count == 1)
        let outcome = report.fileOutcomes[0]
        // Three garbage conflicts surface as three skip reasons; the count
        // is real (three conflict bytes were considered).
        #expect(outcome.versionsConsidered == 3)
        #expect(outcome.skippedReasons.count == 3)

        // The store now holds an empty envelope — every device converges
        // to the same byte state on next reconcile.
        let merged = try #require(try store.read(key()))
        #expect(merged.fields.isEmpty)
        #expect(merged.entityID == entityID)

        // Conflict is cleared.
        let secondPass = try sync.reconcileSidecars()
        #expect(secondPass.fileOutcomes.isEmpty)
    }

    // MARK: - EntityID guard

    @Test
    func conflictVersionWithMismatchedEntityIDIsDroppedFromFold() throws {
        // A parseable envelope whose entityID doesn't match the file's key
        // is wrong-routed data. It MUST be dropped from the fold; otherwise
        // it would be written back under the wrong key as the new ground truth.
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        try store.write(envA, at: key())
        // Same JSON shape but a totally different entityID — not for this key.
        let foreign = SidecarEnvelope(entityID: "WRONG-ID", fields: [
            "b": SidecarCell(value: .string("beta"), modifiedAt: t2, modifiedBy: "device-X")
        ])
        store.scriptConflict(at: key(), versions: [try encode(foreign)])

        let report = try makeSync(sidecars: store).reconcileSidecars()
        let outcome = try #require(report.fileOutcomes.first)
        // The mismatched envelope is dropped, reported in skippedReasons.
        #expect(outcome.skippedReasons.contains { $0.contains("entityID") })
        // The current's fields survive untouched — the foreign envelope's
        // cells never reached the fold.
        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a"])
    }

    // MARK: - merge failure mid-fold

    @Test
    func mergeFailureMidFoldStillWritesPriorFoldedValueAndClearsConflict() throws {
        // If the §5.3 merge fails partway through the fold (e.g. an envelope
        // with the right entityID but schemaVersion=99 reaches `merge()`),
        // the orchestrator should keep what folded successfully, surface the
        // failure in skippedReasons, and still clear the conflict — never
        // leave a stuck conflict behind.
        //
        // Note: parseEnvelope filters schemaVersion ≠ 1 upstream, so to
        // force a merge() failure mid-fold we'd need a parseable envelope
        // that merges-with-failure. With the current filters, that path is
        // effectively unreachable. We test the OUTCOME instead: a conflict
        // with one parseable v1 + one v99 envelope still converges with
        // the v99 dropped and the conflict cleared.
        let store = InMemorySidecarStore()
        let envA = envelope(fields: [
            "a": SidecarCell(value: .string("alpha"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        let envFuture = envelope(schemaVersion: 99, fields: [
            "future": SidecarCell(value: .string("nope"), modifiedAt: t2, modifiedBy: "device-X")
        ])
        try store.write(envA, at: key())
        store.scriptConflict(at: key(), versions: [try encode(envFuture)])

        let sync = makeSync(sidecars: store)
        let report = try sync.reconcileSidecars()
        let outcome = try #require(report.fileOutcomes.first)
        #expect(outcome.skippedReasons.contains { $0.contains("schemaVersion=99") })

        // The current's fields survive; the v99 envelope was skipped.
        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["a"])

        // Conflict is cleared on the very next pass (no stuck conflict).
        let secondPass = try sync.reconcileSidecars()
        #expect(secondPass.fileOutcomes.isEmpty)
    }

    // MARK: - Meta-property: converges in one pass when bytes are readable

    @Test
    func reconcileConvergesInOnePassWhenBytesAreReadable() throws {
        // PLAN §6 contract: when every conflict version's bytes can be
        // read off disk, ONE reconcileSidecars() call converges every key
        // regardless of input shape (parseable, garbage, schemaVersion
        // mismatch, no current). Read-failure is a different case — §6 step
        // 1-2 says read-failure aborts the pass for that key (see
        // resolverThrowingLeavesConflictForRetry for the parallel case).
        let store = InMemorySidecarStore()

        let entityB = "11111111-1111-1111-1111-111111111111"
        let entityC = "22222222-2222-2222-2222-222222222222"
        let entityD = "33333333-3333-3333-3333-333333333333"
        let keyB = SidecarKey(kind: .contact, id: entityB)
        let keyC = SidecarKey(kind: .contact, id: entityC)
        let keyD = SidecarKey(kind: .contact, id: entityD)

        // Key B: current + parseable conflict (happy path).
        let envB1 = SidecarEnvelope(entityID: entityB, fields: [
            "x": SidecarCell(value: .string("from-B1"), modifiedAt: t1, modifiedBy: "A")
        ])
        let envB2 = SidecarEnvelope(entityID: entityB, fields: [
            "y": SidecarCell(value: .string("from-B2"), modifiedAt: t2, modifiedBy: "B")
        ])
        try store.write(envB1, at: keyB)
        store.scriptConflict(at: keyB, versions: [try encode(envB2)])

        // Key C: no current; conflicts include garbage and v99.
        let envCFuture = SidecarEnvelope(schemaVersion: 99, entityID: entityC, fields: [:])
        store.scriptConflict(at: keyC, versions: [Data("garbage".utf8), try encode(envCFuture)])

        // Key D: all garbage.
        store.scriptConflict(at: keyD, versions: [Data("trash".utf8)])

        let sync = makeSync(sidecars: store)
        _ = try sync.reconcileSidecars()

        // After ONE pass: every conflict is cleared.
        let secondPass = try sync.reconcileSidecars()
        #expect(secondPass.fileOutcomes.isEmpty, "all keys should have converged in one pass")
        #expect(try store.keysWithUnresolvedConflicts().isEmpty)
    }

    // MARK: - Resolver-throws aborts the pass for this key

    @Test
    func resolverThrowingLeavesConflictForRetry() throws {
        // The orchestrator's resolver doesn't throw, but a third-party
        // resolver might. The store's contract: don't clobber, don't remove,
        // surface the throw. Next reconcile retries.
        let store = InMemorySidecarStore()
        let existing = envelope(fields: [
            "x": SidecarCell(value: .string("kept"), modifiedAt: t1, modifiedBy: "device-A")
        ])
        try store.write(existing, at: key())
        store.scriptConflict(at: key(), versions: [Data([0x01])])

        struct Boom: Error {}
        let outcomes = try store.reconcileAllConflicts { _, _, _ in throw Boom() }
        #expect(outcomes.count == 1)
        #expect(outcomes[0].versionsConsidered == 0)
        #expect(outcomes[0].skippedReasons.first?.contains("Boom") == true)

        // Existing envelope at the key is UNCHANGED (no clobber).
        let after = try #require(try store.read(key()))
        #expect(after.fields.keys.sorted() == ["x"])

        // Conflict is STILL THERE for retry (no premature resolve).
        #expect(try store.keysWithUnresolvedConflicts().contains(key()))
    }

    // MARK: - Current-side entityID mismatch

    @Test
    func currentWithMismatchedEntityIDIsDropped() throws {
        // A bug-via-rename or restore-from-backup could leave a file at
        // <key>.json whose envelope's entityID points elsewhere. The
        // orchestrator's resolver MUST drop it from the fold (it's
        // wrong-routed data) just like a conflict envelope. If only
        // conflicts (or nothing) remain to fold, we converge to that.
        let store = InMemorySidecarStore()
        // "Current" with wrong entityID seeded directly.
        let wrongCurrent = SidecarEnvelope(entityID: "SOMEONE-ELSES-KEY", fields: [
            "stale": SidecarCell(value: .string("from-wrong-entity"), modifiedAt: t1, modifiedBy: "X")
        ])
        try store.write(wrongCurrent, at: key())

        // One parseable conflict with the RIGHT entityID.
        let rightConflict = envelope(fields: [
            "right": SidecarCell(value: .string("from-right-entity"), modifiedAt: t2, modifiedBy: "Y")
        ])
        store.scriptConflict(at: key(), versions: [try encode(rightConflict)])

        let report = try makeSync(sidecars: store).reconcileSidecars()
        let outcome = try #require(report.fileOutcomes.first)
        #expect(outcome.skippedReasons.contains { $0.contains("entityID") })

        // Only the right-entityID conflict participates; current's bad
        // cells are dropped.
        let merged = try #require(try store.read(key()))
        #expect(merged.fields.keys.sorted() == ["right"])
        #expect(merged.entityID == entityID)
    }
}
