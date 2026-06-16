import Foundation
@testable import GuessWhoSync
@_spi(ConflictReconcile) import GuessWhoSync
import GuessWhoSyncTesting
@_spi(ConflictReconcile) import GuessWhoSyncTesting

/// Test-only wrapper around InMemorySidecarStore that counts writes per
/// key. Used to assert "exactly one envelope write per affected link"
/// in §13.4 multi-Case-D tests.
final class CountingSidecarStore: SidecarStoreProtocol {
    private let inner: InMemorySidecarStore
    private let lock = NSLock()
    private(set) var writeCount: Int = 0
    private(set) var writeCounts: [SidecarKey: Int] = [:]

    init(wrapping inner: InMemorySidecarStore) {
        self.inner = inner
    }

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? { try inner.read(key) }
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        lock.lock()
        writeCount += 1
        writeCounts[key, default: 0] += 1
        lock.unlock()
        try inner.write(envelope, at: key)
    }
    func delete(_ key: SidecarKey) throws { try inner.delete(key) }
    func allKeys() throws -> [SidecarKey] { try inner.allKeys() }
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus { inner.downloadStatus(key) }
    func requestDownload(_ key: SidecarKey) throws { try inner.requestDownload(key) }
}

@_spi(ConflictReconcile)
extension CountingSidecarStore: SidecarConflictReconciling {
    func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        try inner.keysWithUnresolvedConflicts()
    }

    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> SidecarEnvelope
    ) throws -> SidecarReconcileReport.FileOutcome? {
        try inner.reconcileConflict(at: key, resolve: resolve)
    }
}
