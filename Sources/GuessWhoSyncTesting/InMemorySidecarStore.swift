import Foundation
import GuessWhoSync

public final class InMemorySidecarStore: SidecarStoreProtocol {
    private let lock = NSLock()
    private var envelopes: [SidecarKey: SidecarEnvelope] = [:]
    private var scriptedConflicts: [SidecarKey: [Data]] = [:]
    /// In-memory analogue of §6 step 4's recovery-sibling files. Keyed by a
    /// derived SidecarKey whose id is `"<originalID>.<suffix>"`.
    private var recoverySiblings: [SidecarKey: SidecarEnvelope] = [:]

    public init() {}

    public func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return envelopes[key]
    }

    public func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        lock.lock()
        defer { lock.unlock() }
        envelopes[key] = envelope
    }

    public func delete(_ key: SidecarKey) throws {
        lock.lock()
        defer { lock.unlock() }
        envelopes.removeValue(forKey: key)
        scriptedConflicts.removeValue(forKey: key)
    }

    public func allKeys() throws -> [SidecarKey] {
        lock.lock()
        defer { lock.unlock() }
        return Array(envelopes.keys)
    }

    public func scriptConflict(at key: SidecarKey, versions: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        scriptedConflicts[key] = versions
    }

    public func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        lock.lock()
        defer { lock.unlock() }
        return Array(scriptedConflicts.keys)
    }

    // In-memory storage always has every byte locally, so download status
    // reduces to "do I have an envelope here?" `requestDownload` is a no-op.
    public func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        lock.lock()
        defer { lock.unlock() }
        return envelopes[key] != nil ? .downloaded : .notFound
    }

    public func requestDownload(_ key: SidecarKey) throws {
        // No-op: in-memory storage has all bytes locally already.
    }

    public func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> ConflictResolution
    ) throws -> SidecarReconcileReport.FileOutcome? {
        // Capture both the CURRENT envelope and the scripted conflict
        // versions atomically — the FS-store's reconcileConflict equivalent
        // also reads "current + conflicts" in one pass and folds them
        // together. Without including the current envelope, writes that
        // landed before reconcile acquired the lock would be silently
        // overwritten by the merged-conflicts result.
        //
        // mergedVersionCount accounting: includes the current envelope
        // when present, matching the FS store's `allBytes.count` accounting.
        // Tests that seed a current envelope and inspect mergedVersionCount
        // will see N+1 rather than N (N = number of scripted versions).
        lock.lock()
        guard let scripted = scriptedConflicts[key] else {
            lock.unlock()
            return nil
        }
        let currentEnvelope = envelopes[key]
        lock.unlock()

        // Encode the current envelope (when present) to a Data so the
        // resolver receives it the same way it would from the FS store.
        let currentBytes: Data?
        if let currentEnvelope {
            currentBytes = try? JSONEncoder().encode(currentEnvelope)
        } else {
            currentBytes = nil
        }

        let resolution: ConflictResolution
        do {
            resolution = try resolve(currentBytes, scripted)
        } catch {
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: 0,
                skippedReasons: [String(describing: error)]
            )
        }

        switch resolution {
        case .write(let merged, let skip):
            // Skip-matching considers both current and conflict bytes for
            // symmetry with the FS store (which materializes both before
            // running the resolver).
            var allBytes: [Data] = []
            if let currentBytes { allBytes.append(currentBytes) }
            allBytes.append(contentsOf: scripted)
            let skippedCount = allBytes.reduce(0) { count, bytes in
                skip.contains(bytes) ? count + 1 : count
            }
            lock.lock()
            envelopes[key] = merged
            scriptedConflicts.removeValue(forKey: key)
            lock.unlock()
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: allBytes.count - skippedCount,
                skippedReasons: []
            )
        case .writeRecoverySibling(let merged, let suffix):
            // In-memory analogue of §6 step 4's filesystem sibling write:
            // park the merged envelope under a sibling key so tests can
            // observe that recovery ran without destroying the original.
            // Leave the conflict scripting in place — recovery siblings do
            // NOT mark conflicts resolved.
            let siblingID = "\(key.id).\(suffix)"
            let siblingKey = SidecarKey(kind: key.kind, id: siblingID)
            lock.lock()
            recoverySiblings[siblingKey] = merged
            lock.unlock()
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: 0,
                skippedReasons: ["wrote recovery sibling at \(siblingID)"]
            )
        case .leave:
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: 0,
                skippedReasons: []
            )
        }
    }

    /// Recovery-sibling envelopes parked by `.writeRecoverySibling` (§6 step 4).
    /// Test-only accessor.
    public func recoverySibling(of key: SidecarKey, suffix: String) -> SidecarEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return recoverySiblings[SidecarKey(kind: key.kind, id: "\(key.id).\(suffix)")]
    }
}
