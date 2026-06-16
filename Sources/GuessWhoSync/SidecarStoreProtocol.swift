import Foundation

public protocol SidecarStoreProtocol {
    func read(_ key: SidecarKey) throws -> SidecarEnvelope?
    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws
    func delete(_ key: SidecarKey) throws
    func allKeys() throws -> [SidecarKey]

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

// Conflict-reconcile plumbing is exposed via SPI so the two shipping stores
// (FileSystemSidecarStore, InMemorySidecarStore) can conform from their own
// modules, but a host or UI doing a plain `import GuessWhoSync` never sees
// it — they only see the public SidecarStoreProtocol surface and call
// reconcileSidecars() on the orchestrator. A third-party SidecarStoreProtocol
// conformer that doesn't implement this is silently skipped by
// reconcileSidecars() — fine for backends with no multi-version conflicts.
@_spi(ConflictReconcile)
public protocol SidecarConflictReconciling: SidecarStoreProtocol {
    // Keys that have an unresolved cross-device conflict. The orchestrator
    // drives reconcile by iterating these, acquiring its per-key lock for
    // each one, and calling `reconcileConflict(at:resolve:)`.
    func keysWithUnresolvedConflicts() throws -> [SidecarKey]

    // Reconcile a single key. The resolver receives the current version's
    // bytes (nil when no materialized current exists) and the conflict
    // versions' bytes, and returns the merged envelope. The store
    // overwrites the current with that envelope and marks every conflict
    // version resolved.
    //
    // The resolver is expected to ALWAYS converge — it returns a valid
    // envelope even if no input bytes parsed (e.g. an empty envelope at
    // the right entityID). The store never writes recovery siblings and
    // never refuses to write — every conflict is resolved in one pass.
    //
    // Implementations MUST execute the resolver and the resulting write
    // atomically with respect to other operations the caller may serialize
    // against this key.
    //
    // Returns nil if the key has no conflicts (the caller can ignore it).
    func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> SidecarEnvelope
    ) throws -> SidecarReconcileReport.FileOutcome?
}

// Default implementations for the download API.
//
// The defaults are correct for any backend without a remote tier (the
// common case), and the `downloadStatus` default explicitly maps
// `.notYetDownloaded` to `.notStarted` so a backend that adds a remote
// tier later still gets sensible status reporting without overriding.
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
