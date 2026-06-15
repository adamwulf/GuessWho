import Foundation

/// A registry of per-key locks. Calls bracketed by `withLock(forKey:)` on the
/// same key run serially; calls on distinct keys run independently.
///
/// Used internally by GuessWhoSync to make per-sidecar read-modify-write
/// (e.g. setField/deleteField) safe against concurrent callers while still
/// allowing parallel work on disjoint keys.
final class PerKeyLockTable<Key: Hashable> {
    private let registryLock = NSLock()
    private var locks: [Key: NSLock] = [:]

    init() {}

    func withLock<T>(forKey key: Key, _ body: () throws -> T) rethrows -> T {
        let lock = self.lock(forKey: key)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func lock(forKey key: Key) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key] {
            return existing
        }
        let fresh = NSLock()
        locks[key] = fresh
        return fresh
    }
}
