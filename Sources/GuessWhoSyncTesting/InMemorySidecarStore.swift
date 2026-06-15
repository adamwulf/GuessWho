import Foundation
import GuessWhoSync

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

    public func reconcileConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome] {
        lock.lock()
        let pending = scriptedConflicts
        lock.unlock()

        var outcomes: [SidecarReconcileReport.FileOutcome] = []
        for (key, versions) in pending {
            let resolution: ConflictResolution
            do {
                resolution = try resolve(key, versions)
            } catch {
                outcomes.append(
                    SidecarReconcileReport.FileOutcome(
                        key: key,
                        mergedVersionCount: 0,
                        skippedReasons: [String(describing: error)]
                    )
                )
                continue
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
                outcomes.append(
                    SidecarReconcileReport.FileOutcome(
                        key: key,
                        mergedVersionCount: versions.count - skippedCount,
                        skippedReasons: []
                    )
                )
            case .writeRecoverySibling(_, let suffix):
                outcomes.append(
                    SidecarReconcileReport.FileOutcome(
                        key: key,
                        mergedVersionCount: 0,
                        skippedReasons: ["wrote recovery sibling: \(suffix)"]
                    )
                )
            case .leave:
                outcomes.append(
                    SidecarReconcileReport.FileOutcome(
                        key: key,
                        mergedVersionCount: 0,
                        skippedReasons: []
                    )
                )
            }
        }
        return outcomes
    }
}
