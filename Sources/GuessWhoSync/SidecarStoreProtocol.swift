import Foundation

public protocol SidecarStoreProtocol {
    func read(_ key: SidecarKey) throws -> SidecarEnvelope?
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws
    func delete(_ key: SidecarKey) throws
    func allKeys() throws -> [SidecarKey]

    // Bulk conflict reconciliation. The default implementation invokes
    // `keysWithUnresolvedConflicts()` then `reconcileConflict(at:resolve:)`
    // for each key, which lets the orchestrator drive per-key locking.
    func reconcileConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome]

    // Keys that have an unresolved cross-device conflict. The orchestrator
    // drives reconcile by iterating these, acquiring its per-key lock for
    // each one, and calling `reconcileConflict(at:resolve:)`. Implementations
    // backed by storage with no notion of conflicts (e.g. in-memory test
    // doubles) may return any keys for which the resolver should be invoked.
    func keysWithUnresolvedConflicts() throws -> [SidecarKey]

    // Reconcile a single key. The resolver is invoked with every version's
    // bytes (current + conflict versions). Implementations MUST execute the
    // resolver and its resulting write/delete atomically with respect to
    // other operations the caller may serialize against this key.
    //
    // Returns nil if the key has no conflicts (the caller can ignore it).
    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ versions: [Data]) throws -> ConflictResolution
    ) throws -> SidecarReconcileReport.FileOutcome?

    // Storage backends that may not have all bytes resident on this device
    // throw `.notYetDownloaded` from `read()`. Call `requestDownload(_:)`
    // to initiate a fetch, then poll `downloadStatus(_:)` to observe
    // progress.
    //
    // Backends that always have bytes locally return `.downloaded` for any
    // known key and `.notFound` otherwise.
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus

    // Initiate a fetch of `key`'s bytes onto local storage. No-op for
    // backends that always have bytes locally.
    func requestDownload(_ key: SidecarKey) throws
}

// Default implementations. New protocol requirements default to behavior
// that's correct for backends with no remote tier and no notion of
// conflicts — so a host-app implementer who only conformed to v1's surface
// keeps compiling and behaving sensibly on this branch.
public extension SidecarStoreProtocol {
    // Default `reconcileConflicts` implemented in terms of the per-key API
    // so implementers can opt into per-key locking by only overriding the
    // per-key method.
    func reconcileConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome] {
        var outcomes: [SidecarReconcileReport.FileOutcome] = []
        for key in try keysWithUnresolvedConflicts() {
            if let outcome = try reconcileConflict(at: key, resolve: { versions in
                try resolve(key, versions)
            }) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    // Default: backends with no notion of conflicts report no keys.
    func keysWithUnresolvedConflicts() throws -> [SidecarKey] { [] }

    // Default: backends with no notion of conflicts return nil so the
    // orchestrator skips this key. Override on backends that DO surface
    // conflicts (e.g. file-system-backed stores with cross-device sync).
    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ versions: [Data]) throws -> ConflictResolution
    ) throws -> SidecarReconcileReport.FileOutcome? { nil }

    // Default: backends that always have bytes locally report known keys
    // as `.downloaded` and everything else as `.notFound`. Errors from
    // `read()` map to `.notFound` — this default is intentionally
    // best-effort.
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        do {
            return try read(key) != nil ? .downloaded : .notFound
        } catch {
            return .notFound
        }
    }

    // Default: backends with no remote tier do nothing.
    func requestDownload(_ key: SidecarKey) throws {}
}
