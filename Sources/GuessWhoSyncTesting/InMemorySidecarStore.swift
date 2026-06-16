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
        resolve: (_ versions: [Data]) throws -> ConflictResolution
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

        // Convention with the resolver: versions[0] is always the current
        // version's bytes, even when there's no current envelope (in which
        // case it's empty / unparseable). This lets the resolver branch on
        // §6 step 4 cleanly: current parsed → overwrite; current unparseable
        // but ≥1 conflict parsed → write recovery sibling.
        var versions: [Data] = []
        let currentSlotIsReal: Bool
        if let currentEnvelope, let bytes = try? JSONEncoder().encode(currentEnvelope) {
            versions.append(bytes)
            currentSlotIsReal = true
        } else {
            versions.append(Data())
            currentSlotIsReal = false
        }
        versions.append(contentsOf: scripted)

        let resolution: ConflictResolution
        do {
            resolution = try resolve(versions)
        } catch {
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: 0,
                skippedReasons: [String(describing: error)]
            )
        }

        switch resolution {
        case .write(let merged, let skip):
            let skippedCount = versions.reduce(0) { count, bytes in
                skip.contains(bytes) ? count + 1 : count
            }
            lock.lock()
            envelopes[key] = merged
            scriptedConflicts.removeValue(forKey: key)
            lock.unlock()
            // Don't credit the placeholder for a missing current toward the
            // merged-version count; only real bytes participated.
            let realVersionCount = versions.count - (currentSlotIsReal ? 0 : 1)
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: realVersionCount - skippedCount,
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
