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

    // MARK: - Binary blob payloads (`.blob` field type)
    //
    // A `.blob` sidecar field is a pointer to a separate binary file that
    // lives beside the envelope under the SAME storage root (so it syncs the
    // same way). These four methods are the byte-level I/O for those files;
    // the orchestrator owns the pointer bookkeeping (mint a fresh `blobId`
    // per write, delete-on-overwrite, reference-counting orphan sweep).
    //
    // Backends with no binary storage get default no-op/empty implementations
    // (below), so a third-party conformer compiles unchanged.

    // Write `data` as the blob identified by `blobId` for `key`. Overwrites any
    // existing file at that (key, blobId). The on-disk payload MAY be encrypted
    // by the backend (FileSystemSidecarStore encrypts; the in-memory store does
    // not — the contract is bytes-in / bytes-out).
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws

    // Read the blob bytes for (key, blobId). Returns nil when the blob is not
    // materialized on this device yet (e.g. the `.dat` exists only as an iCloud
    // placeholder) OR is absent — a missing blob is benign ("pending"/"gone"),
    // never an error the caller must special-case.
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data?

    // Delete the blob file for (key, blobId). No-op if it is already gone.
    func deleteBlob(blobId: String, for key: SidecarKey) throws

    // Every blobId that has a `.dat` (or not-yet-downloaded placeholder) on
    // disk for `key`. Used by the orphan sweep to find unreferenced files.
    func blobIds(for key: SidecarKey) throws -> [String]
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
    // **Resolver contract.** The resolver:
    //   - MUST return an envelope whose `entityID == key.id`. The store
    //     MAY assert this (defense-in-depth against a buggy resolver).
    //     A returned envelope with a mismatched entityID would otherwise
    //     write wrong-routed data under this key.
    //   - SHOULD always converge — return a valid envelope even if no input
    //     bytes parsed (e.g. an empty envelope at `entityID = key.id`).
    //     The store does not write recovery siblings.
    //   - MAY throw, in which case the store treats this key as "abort the
    //     pass": no write, no version.remove(). The next reconcile retries
    //     with the same inputs. The throw is surfaced in `skippedReasons`.
    //
    // **Read-failure abort.** If the store cannot read the current bytes
    // or any conflict bytes off disk (transient I/O, not-yet-downloaded,
    // sandbox), it aborts the pass for this key the same way: no write,
    // no remove(), surface the error. Next reconcile retries.
    //
    // **isResolved / remove() ordering on success.** The store calls
    // version.remove() FIRST and only sets version.isResolved = true on
    // success. If remove() throws, isResolved stays false so the next
    // pass retries.
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

    // Default blob I/O: a backend with no binary storage stores nothing, has
    // nothing to read or delete, and lists no blobIds. The two shipping stores
    // (FileSystemSidecarStore, InMemorySidecarStore) override all four.
    func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws {}
    func readBlob(blobId: String, for key: SidecarKey) throws -> Data? { nil }
    func deleteBlob(blobId: String, for key: SidecarKey) throws {}
    func blobIds(for key: SidecarKey) throws -> [String] { [] }
}
