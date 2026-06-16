import Foundation
import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync

public final class InMemorySidecarStore: SidecarStoreProtocol {
    private let lock = NSLock()
    private var envelopes: [SidecarKey: SidecarEnvelope] = [:]
    private var scriptedConflicts: [SidecarKey: [Data]] = [:]

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
}

// SPI conformance — the conflict-reconciliation surface is exposed only to
// the orchestrator (via @_spi(ConflictReconcile) import), not to host UI.
@_spi(ConflictReconcile)
extension InMemorySidecarStore: SidecarConflictReconciling {
    public func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        lock.lock()
        defer { lock.unlock() }
        return Array(scriptedConflicts.keys)
    }

    public func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> SidecarEnvelope
    ) throws -> SidecarReconcileReport.FileOutcome? {
        // Capture both the CURRENT envelope and the scripted conflict
        // versions atomically — the FS-store's reconcileConflict equivalent
        // also reads "current + conflicts" in one pass and folds them
        // together. Without including the current envelope, writes that
        // landed before reconcile acquired the lock would be silently
        // overwritten by the merged-conflicts result.
        lock.lock()
        guard let scripted = scriptedConflicts[key] else {
            lock.unlock()
            return nil
        }
        let currentEnvelope = envelopes[key]
        lock.unlock()

        let currentBytes: Data?
        if let currentEnvelope {
            currentBytes = try? JSONEncoder().encode(currentEnvelope)
        } else {
            currentBytes = nil
        }

        let merged: SidecarEnvelope
        do {
            merged = try resolve(currentBytes, scripted)
        } catch {
            return SidecarReconcileReport.FileOutcome(
                key: key,
                mergedVersionCount: 0,
                skippedReasons: [String(describing: error)]
            )
        }

        lock.lock()
        envelopes[key] = merged
        scriptedConflicts.removeValue(forKey: key)
        lock.unlock()

        let mergedVersionCount = (currentBytes != nil ? 1 : 0) + scripted.count
        return SidecarReconcileReport.FileOutcome(
            key: key,
            mergedVersionCount: mergedVersionCount,
            skippedReasons: []
        )
    }
}
