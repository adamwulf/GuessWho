import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("OrchestratorConcurrency")
struct OrchestratorConcurrencyTests {
    private let deviceID = "device-A"

    private func makeSync(
        sidecars: InMemorySidecarStore = InMemorySidecarStore()
    ) -> (GuessWhoSync, InMemorySidecarStore) {
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: deviceID
        )
        return (sync, sidecars)
    }

    /// Spawns 100 concurrent setField calls on the SAME key, each writing a distinct
    /// field. Without per-key serialization, read-modify-write races cause earlier
    /// writes to be clobbered and the final envelope contains far fewer than 100
    /// fields. With per-key serialization, all 100 fields land.
    @Test
    func concurrentSetFieldOnSameKeyPreservesAllWrites() throws {
        let (sync, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "key-same-A")
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? sync.setField("field-\(i)", value: .number(Double(i)), at: key)
        }

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == count, "expected \(count) fields, got \(envelope.fields.count)")
        for i in 0..<count {
            switch envelope.fields["field-\(i)"] {
            case let .value(v, _, _):
                #expect(v == .number(Double(i)))
            default:
                Issue.record("missing or wrong cell for field-\(i)")
            }
        }
    }

    /// Spawns 100 concurrent setField calls on 100 DIFFERENT keys. Each key should
    /// end up with exactly its one field. Validates that distinct keys do not
    /// serialize against each other (correctness, not timing).
    @Test
    func concurrentSetFieldOnDifferentKeysAllWriteCorrectly() throws {
        let (sync, sidecars) = makeSync()
        let count = 100
        let keys = (0..<count).map {
            SidecarKey(kind: .contact, id: "key-\($0)")
        }

        DispatchQueue.concurrentPerform(iterations: count) { i in
            try? sync.setField("only", value: .number(Double(i)), at: keys[i])
        }

        for i in 0..<count {
            let envelope = try #require(try sidecars.read(keys[i]))
            #expect(envelope.fields.count == 1)
            switch envelope.fields["only"] {
            case let .value(v, _, _):
                #expect(v == .number(Double(i)))
            default:
                Issue.record("missing or wrong cell at key-\(i)")
            }
        }
    }

    /// Reconcile must take the per-key lock around its resolver+write so a
    /// concurrent setField on the SAME key can't land its write between the
    /// store's read-versions and merged-write — that write would be silently
    /// clobbered. A delay-injecting wrapper store widens the race window so
    /// the bug, when present, is detectable in CI rather than only locally.
    @Test
    func concurrentSetFieldDuringReconcileOnSameKeyPreservesAllSets() throws {
        let underlying = InMemorySidecarStore()
        let slowStore = ResolveDelayingSidecarStore(wrapping: underlying)
        let sync = GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: slowStore,
            deviceID: deviceID
        )
        let key = SidecarKey(kind: .contact, id: "key-reconcile-race")
        let writers = 50

        try sync.setField("seed", value: .string("seed"), at: key)

        // Script a conflict at the same key. The wrapper will stall before
        // running the resolver, so the writers must block on the per-key lock
        // rather than slipping a write into the read-modify-write window.
        let scriptedEnvelope = SidecarEnvelope(
            schemaVersion: 1,
            entityID: key.id,
            fields: ["seed": .value(.string("scripted"), modifiedAt: Date(), modifiedBy: "device-X")]
        )
        let scriptedBytes = try JSONEncoder().encode(scriptedEnvelope)
        underlying.scriptConflict(at: key, versions: [scriptedBytes])
        slowStore.delayBeforeResolve = 0.15

        // Kick reconcile in parallel with the writers; the writers are gated
        // on a semaphore so they all release at the same moment.
        let kickoff = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "writers", attributes: .concurrent)
        let group = DispatchGroup()
        for i in 0..<writers {
            group.enter()
            queue.async {
                kickoff.wait()
                try? sync.setField("field-\(i)", value: .number(Double(i)), at: key)
                group.leave()
            }
        }
        let reconcileGroup = DispatchGroup()
        reconcileGroup.enter()
        DispatchQueue.global().async {
            _ = try? sync.reconcileSidecars()
            reconcileGroup.leave()
        }
        for _ in 0..<writers { kickoff.signal() }

        reconcileGroup.wait()
        group.wait()

        let envelope = try #require(try underlying.read(key))
        for i in 0..<writers {
            switch envelope.fields["field-\(i)"] {
            case let .value(v, _, _):
                #expect(v == .number(Double(i)))
            default:
                Issue.record("missing field-\(i) — reconcile clobbered concurrent setField")
            }
        }
    }

    /// Mixes 100 concurrent setField and deleteField calls on the SAME key for
    /// distinct field names — every (set X) and (delete Y) must result in a
    /// final envelope with all 100 cells present (either value or tombstone).
    @Test
    func concurrentSetAndDeleteOnSameKeyPreservesAllCells() throws {
        let (sync, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "key-same-B")
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { i in
            if i.isMultiple(of: 2) {
                try? sync.setField("field-\(i)", value: .number(Double(i)), at: key)
            } else {
                try? sync.deleteField("field-\(i)", at: key)
            }
        }

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == count)
        for i in 0..<count {
            let cell = envelope.fields["field-\(i)"]
            if i.isMultiple(of: 2) {
                switch cell {
                case let .value(v, _, _):
                    #expect(v == .number(Double(i)))
                default:
                    Issue.record("expected value cell for field-\(i)")
                }
            } else {
                switch cell {
                case .tombstone:
                    break
                default:
                    Issue.record("expected tombstone for field-\(i)")
                }
            }
        }
    }
}

/// Wraps an InMemorySidecarStore and lets the test inject a sleep BEFORE the
/// reconcile resolver runs. The widened window surfaces the
/// "concurrent setField clobbered by reconcile" bug deterministically.
private final class ResolveDelayingSidecarStore: SidecarStoreProtocol, @unchecked Sendable {
    private let underlying: InMemorySidecarStore
    var delayBeforeResolve: TimeInterval = 0

    init(wrapping underlying: InMemorySidecarStore) {
        self.underlying = underlying
    }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        try underlying.read(key)
    }

    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        try underlying.write(envelope, at: key)
    }

    func delete(_ key: SidecarKey) throws {
        try underlying.delete(key)
    }

    func allKeys() throws -> [SidecarKey] {
        try underlying.allKeys()
    }

    func reconcileConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome] {
        let delay = delayBeforeResolve
        return try underlying.reconcileConflicts { key, versions in
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            return try resolve(key, versions)
        }
    }

    func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        try underlying.keysWithUnresolvedConflicts()
    }

    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ versions: [Data]) throws -> ConflictResolution
    ) throws -> SidecarReconcileReport.FileOutcome? {
        let delay = delayBeforeResolve
        return try underlying.reconcileConflict(at: key) { versions in
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            return try resolve(versions)
        }
    }
}
