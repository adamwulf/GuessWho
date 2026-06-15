import Foundation

public protocol SidecarStoreProtocol {
    func read(_ key: SidecarKey) throws -> SidecarEnvelope?
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws
    func delete(_ key: SidecarKey) throws
    func allKeys() throws -> [SidecarKey]

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

// Default implementations for the download API.
//
// The defaults are correct for any backend without a remote tier (the
// common case), and the `downloadStatus` default explicitly maps
// `.notYetDownloaded` to `.notStarted` so a backend that adds a remote
// tier later still gets sensible status reporting without overriding.
//
// Conflict methods (`keysWithUnresolvedConflicts`, `reconcileConflict`)
// are intentionally NOT defaulted: a default returning `[]` / `nil`
// would cause a conformer that forgot to implement them to silently
// no-op on reconcile, which is worse than a compile error.
public extension SidecarStoreProtocol {
    // Default: backends that always have bytes locally report known keys
    // as `.downloaded` and everything else as `.notFound`. A backend that
    // surfaces remote-pending bytes via `.notYetDownloaded` from `read()`
    // gets that mapped to `.notStarted` here, so a partial implementation
    // (override `read()` but not `downloadStatus`) still reports correctly.
    //
    // Override on backends where `read()` is expensive (e.g. requires a
    // coordinated I/O hop) and `downloadStatus` is called in a hot loop.
    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        do {
            return try read(key) != nil ? .downloaded : .notFound
        } catch SidecarStoreError.notYetDownloaded {
            return .notStarted
        } catch {
            return .notFound
        }
    }

    // Default: backends with no remote tier do nothing.
    func requestDownload(_ key: SidecarKey) throws {}
}
