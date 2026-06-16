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

    /// Spawns 100 concurrent addField calls on the SAME key. Without per-key
    /// serialization, read-modify-write races cause earlier writes to be
    /// clobbered and the final envelope contains far fewer than 100 cells.
    /// With per-key serialization, all 100 cells land.
    @Test
    func concurrentAddFieldOnSameKeyPreservesAllWrites() throws {
        let (sync, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "key-same-A")
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { i in
            _ = try? sync.addField(at: key, field: "field-\(i)", type: .note, value: .string("v-\(i)"))
        }

        let envelope = try #require(try sidecars.read(key))
        #expect(envelope.fields.count == count, "expected \(count) cells, got \(envelope.fields.count)")

        let all = try sync.fields(at: key)
        let names = Set(all.map(\.field))
        for i in 0..<count {
            #expect(names.contains("field-\(i)"), "missing field-\(i)")
        }
    }

    /// Spawns 100 concurrent addField calls on 100 DIFFERENT keys. Each key
    /// should end up with exactly its one cell. Validates that distinct keys
    /// do not serialize against each other (correctness, not timing).
    @Test
    func concurrentAddFieldOnDifferentKeysAllWriteCorrectly() throws {
        let (sync, sidecars) = makeSync()
        let count = 100
        let keys = (0..<count).map {
            SidecarKey(kind: .contact, id: "key-\($0)")
        }

        DispatchQueue.concurrentPerform(iterations: count) { i in
            _ = try? sync.addField(at: keys[i], field: "only", type: .note, value: .string("v-\(i)"))
        }

        for i in 0..<count {
            let envelope = try #require(try sidecars.read(keys[i]))
            #expect(envelope.fields.count == 1)
            let all = try sync.fields(at: keys[i])
            #expect(all.count == 1)
            #expect(all[0].field == "only")
            #expect(all[0].value == .string("v-\(i)"))
        }
    }

    /// Reconcile must take the per-key lock around its resolver+write so a
    /// concurrent addField on the SAME key can't land its write between the
    /// store's read-versions and merged-write — that write would be silently
    /// clobbered. A delay-injecting wrapper store widens the race window so
    /// the bug, when present, is detectable in CI rather than only locally.
    @Test
    func concurrentAddFieldDuringReconcileOnSameKeyPreservesAllAdds() throws {
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

        let seedID = try sync.addField(at: key, field: "seed", type: .note, value: .string("seed"))

        // Script a conflict at the same key. The wrapper will stall before
        // running the resolver, so the writers must block on the per-key lock
        // rather than slipping a write into the read-modify-write window.
        let scriptedEnvelope = SidecarEnvelope(
            schemaVersion: 1,
            entityID: key.id,
            fields: [
                seedID.uuidString: SidecarCell(
                    value: SidecarField.makeInnerValue(
                        field: "seed",
                        type: .note,
                        value: .string("scripted"),
                        createdAt: Date()
                    ),
                    modifiedAt: Date(),
                    modifiedBy: "device-X"
                ),
            ]
        )
        let scriptedBytes = try JSONEncoder().encode(scriptedEnvelope)
        underlying.scriptConflict(at: key, versions: [scriptedBytes])
        slowStore.delayBeforeResolve = 0.15

        // Kick reconcile in parallel with the writers; the writers are gated
        // on a semaphore so they all release at the same moment.
        let kickoff = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "writers", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var addedIDs: [UUID] = []
        for i in 0..<writers {
            group.enter()
            queue.async {
                kickoff.wait()
                if let id = try? sync.addField(at: key, field: "field-\(i)", type: .note, value: .string("v-\(i)")) {
                    lock.lock()
                    addedIDs.append(id)
                    lock.unlock()
                }
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
        for id in addedIDs {
            #expect(envelope.fields[id.uuidString] != nil,
                    "reconcile clobbered concurrent addField for \(id)")
        }
    }

    /// Mixes 100 concurrent addField and deleteField calls on the SAME key —
    /// every (add X) and (delete Y) must result in cells present (live or
    /// soft-deleted). Validates the per-key lock covers both code paths.
    @Test
    func concurrentAddAndDeleteOnSameKeyPreservesAllCells() throws {
        let (sync, sidecars) = makeSync()
        let key = SidecarKey(kind: .contact, id: "key-same-B")
        let count = 100

        // Pre-seed half the cells so the delete operations have targets.
        var seeded: [UUID] = []
        for i in 0..<count where !i.isMultiple(of: 2) {
            let id = try sync.addField(at: key, field: "seed-\(i)", type: .note, value: .string("seed-\(i)"))
            seeded.append(id)
        }
        let seededIDs = seeded

        let lock = NSLock()
        var addedIDs: [UUID] = []
        DispatchQueue.concurrentPerform(iterations: count) { i in
            if i.isMultiple(of: 2) {
                if let id = try? sync.addField(at: key, field: "field-\(i)", type: .note, value: .string("v-\(i)")) {
                    lock.lock()
                    addedIDs.append(id)
                    lock.unlock()
                }
            } else {
                let idx = (i - 1) / 2
                if idx < seededIDs.count {
                    try? sync.deleteField(at: key, id: seededIDs[idx])
                }
            }
        }

        let envelope = try #require(try sidecars.read(key))
        // All seeded cells survive (now soft-deleted), all added cells are present.
        let expectedTotal = seededIDs.count + addedIDs.count
        #expect(envelope.fields.count == expectedTotal)
        for id in addedIDs {
            let cell = try #require(envelope.fields[id.uuidString])
            #expect(cell.deletedAt == nil)
        }
        for id in seededIDs {
            let cell = try #require(envelope.fields[id.uuidString])
            #expect(cell.deletedAt != nil, "expected soft-delete for \(id)")
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

    func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        try underlying.keysWithUnresolvedConflicts()
    }

    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> ConflictResolution
    ) throws -> SidecarReconcileReport.FileOutcome? {
        let delay = delayBeforeResolve
        return try underlying.reconcileConflict(at: key) { currentBytes, conflictBytes in
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            return try resolve(currentBytes, conflictBytes)
        }
    }

    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        underlying.downloadStatus(key)
    }

    func requestDownload(_ key: SidecarKey) throws {
        try underlying.requestDownload(key)
    }
}
