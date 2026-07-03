import Foundation

/// A registry of per-key serial dispatch queues. Work dispatched via
/// `queue(forKey:)` for the same key runs serially in FIFO order; work for
/// distinct keys runs independently.
///
/// Used by `FileSystemSidecarStore` to run NSFileCoordinator calls per key, so
/// a single stuck coordination claim (e.g. cloudd wedged on one syncing file)
/// only stalls that key's operations — every other key proceeds. The sibling
/// of `PerKeyLockTable`, at the same granularity, so the two compose: locks
/// serialize compound read-modify-write per key, queues isolate the blocking
/// coordinator wait per key.
///
/// Queues are retained for the lifetime of the table; eviction isn't needed at
/// the expected key cardinality (per-contact / per-event sidecars), and a
/// dispatch queue is a small allocation.
final class PerKeyQueueTable<Key: Hashable>: @unchecked Sendable {
    private let registryLock = NSLock()
    private var queues: [Key: DispatchQueue] = [:]

    /// Builds each queue's label so a spindump/Instruments trace names the
    /// stuck key. Called once per key, under the registry lock.
    private let label: (Key) -> String

    init(label: @escaping (Key) -> String) {
        self.label = label
    }

    func queue(forKey key: Key) -> DispatchQueue {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = queues[key] {
            return existing
        }
        let fresh = DispatchQueue(label: label(key))
        queues[key] = fresh
        return fresh
    }
}
