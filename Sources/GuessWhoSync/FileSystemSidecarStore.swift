import Foundation

public final class FileSystemSidecarStore: SidecarStoreProtocol {
    private let root: URL

    // Per-key locks for write/delete/reconcile. Direct users of this store
    // (without going through GuessWhoSync) get correctness on writes/deletes
    // to distinct keys running independently and concurrent operations on the
    // SAME key serializing. GuessWhoSync layers its own per-key lock on top
    // for read-modify-write atomicity; both layers locking per-key is
    // redundant but correct.
    private let fileLocks = PerKeyLockTable<SidecarKey>()

    // Closure consulted when a sidecar operation exceeds `perAttemptTimeout`.
    // Default: 3 retries, exponential backoff from 250ms, then fail. See
    // `SidecarBusyHandler` for the contract.
    public let busyHandler: SidecarBusyHandler

    // Per-attempt budget for a single sidecar read/write/delete. If the
    // operation hasn't returned by this point, `busyHandler` is consulted.
    // Defaults to 1 second.
    public let perAttemptTimeout: TimeInterval

    // Seam over the iCloud-facing OS APIs (NSFileVersion + ubiquity download).
    // Production callers get ProductionUbiquityProvider by default; tests
    // pass an in-memory fake to exercise conflict + download logic that
    // cannot be triggered against a local filesystem.
    private let ubiquity: SidecarUbiquityProvider

    // Seam over `.blob` `.dat` payload encryption. Production uses a key from
    // the iCloud-synchronizable keychain (KeychainBlobCrypto); tests inject a
    // deterministic in-memory key (InMemoryBlobCrypto) so unit tests exercise
    // encrypt/decrypt end-to-end WITHOUT touching the real keychain.
    private let blobCrypto: SidecarBlobCrypto

    // Background queue the coordinator runs on so the calling thread can
    // wait with a timeout. One serial queue per store instance — coordinator
    // calls are coarse-grained and don't need parallel dispatch.
    //
    // NOTE: the queue is shared across keys, which means a single stuck
    // operation (e.g. a key whose backing file is still syncing) can delay
    // siblings dispatched after it. Per-attempt wait time accumulates from
    // the moment the operation is queued, not when it begins executing, so
    // siblings can see `.timedOut` while waiting in line behind a stuck
    // operation. A per-key dispatch queue would compose with the per-key
    // `fileLocks` if this becomes a problem in practice.
    private let coordinatorQueue = DispatchQueue(
        label: "GuessWhoSync.FileSystemSidecarStore.coordinator"
    )

    public init(
        root: URL,
        busyHandler: @escaping SidecarBusyHandler = defaultSidecarBusyHandler,
        perAttemptTimeout: TimeInterval = 1.0
    ) {
        self.root = root
        self.busyHandler = busyHandler
        self.perAttemptTimeout = perAttemptTimeout
        self.ubiquity = ProductionUbiquityProvider()
        self.blobCrypto = Self.defaultProductionBlobCrypto()
    }

    // SPI-gated constructor that lets tests inject a fake ubiquity provider.
    // Shares the SPI with the conflict-reconcile plumbing so the public
    // surface for plain `import GuessWhoSync` consumers remains unchanged.
    @_spi(ConflictReconcile)
    public init(
        root: URL,
        ubiquity: SidecarUbiquityProvider,
        blobCrypto: SidecarBlobCrypto? = nil,
        busyHandler: @escaping SidecarBusyHandler = defaultSidecarBusyHandler,
        perAttemptTimeout: TimeInterval = 1.0
    ) {
        self.root = root
        self.busyHandler = busyHandler
        self.perAttemptTimeout = perAttemptTimeout
        self.ubiquity = ubiquity
        self.blobCrypto = blobCrypto ?? Self.defaultProductionBlobCrypto()
    }

    // The production blob-crypto seam: a keychain-backed AES-GCM key where
    // Security is available, else a throwing placeholder (no Apple platform we
    // ship on lacks Security, but keep the type total for SwiftPM linux CI).
    private static func defaultProductionBlobCrypto() -> SidecarBlobCrypto {
        #if canImport(Security)
        return KeychainBlobCrypto()
        #else
        return UnavailableBlobCrypto()
        #endif
    }

    public func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        let url = fileURL(for: key)
        let fm = FileManager.default

        // Coordinated existence + read in one pass: NSFileCoordinator
        // serializes us against cloudd, which may otherwise be mid-rename
        // between `.<name>.icloud` and the materialized `<name>` when we
        // probe. Inside the coordinated block, the filesystem state is
        // stable enough to decide between materialized / placeholder /
        // truly-absent.
        enum Outcome {
            case bytes(Data)
            case placeholderPresent
            case missing
            case failed(Error)
        }
        var outcome: Outcome = .missing
        try coordinatedRead(key: key, at: url) { safeURL in
            if fm.fileExists(atPath: safeURL.path) {
                do {
                    outcome = .bytes(try Data(contentsOf: safeURL))
                } catch {
                    outcome = .failed(error)
                }
            } else if fm.fileExists(atPath: self.placeholderURL(for: safeURL).path) {
                outcome = .placeholderPresent
            } else {
                outcome = .missing
            }
        }

        switch outcome {
        case .bytes(let data):
            return try JSONDecoder().decode(SidecarEnvelope.self, from: data)
        case .placeholderPresent:
            // Request the download and tell the caller to retry later.
            try? ubiquity.startDownloading(at: url)
            throw SidecarStoreError.notYetDownloaded(key)
        case .missing:
            return nil
        case .failed(let error):
            throw error
        }
    }

    public func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        try fileLocks.withLock(forKey: key) {
            let url = fileURL(for: key)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(envelope)

            var writeError: Error?
            try coordinatedWrite(key: key, at: url) { safeURL in
                do {
                    try data.write(to: safeURL, options: [.atomic])
                } catch {
                    writeError = error
                }
            }
            if let writeError { throw writeError }
        }
    }

    public func delete(_ key: SidecarKey) throws {
        try fileLocks.withLock(forKey: key) {
            // Cascade-delete this key's `.dat` payloads FIRST so deleting the
            // record self-cleans its blobs (the global orphan sweep is the
            // backstop for the cross-device LWW race where the envelope still
            // exists; envelope-delete cleans its own blobs here). Best-effort:
            // a failure to remove a stray `.dat` must not block the envelope
            // delete — the sweep reclaims it later.
            if let blobIds = try? blobIds(for: key) {
                for blobId in blobIds {
                    let blobURL = blobURL(for: key, blobId: blobId)
                    guard FileManager.default.fileExists(atPath: blobURL.path) else { continue }
                    try? coordinatedDelete(key: key, at: blobURL) { safeURL in
                        try? FileManager.default.removeItem(at: safeURL)
                    }
                }
            }

            let url = fileURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else { return }

            var deleteError: Error?
            try coordinatedDelete(key: key, at: url) { safeURL in
                do {
                    try FileManager.default.removeItem(at: safeURL)
                } catch {
                    deleteError = error
                }
            }
            if let deleteError { throw deleteError }
        }
    }

    public func allKeys() throws -> [SidecarKey] {
        var result: [SidecarKey] = []
        result.append(contentsOf: try listKeys(in: root.appendingPathComponent("contacts"), kind: .contact))
        result.append(contentsOf: try listKeys(in: root.appendingPathComponent("events"), kind: .event))
        result.append(contentsOf: try listKeys(in: root.appendingPathComponent("links"), kind: .link))
        return result
    }

    @_spi(ConflictReconcile)
    public func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        var result: [SidecarKey] = []
        for key in try allKeys() {
            let url = fileURL(for: key)
            if let conflicts = ubiquity.unresolvedConflictVersions(at: url),
               !conflicts.isEmpty {
                result.append(key)
            }
        }
        return result
    }

    public func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        let url = fileURL(for: key)
        let fm = FileManager.default

        // If the materialized file exists, ask the ubiquity provider whether
        // it is "current" (fully downloaded) or still downloading. For non-
        // ubiquity files the provider returns nil; treat that as downloaded.
        if fm.fileExists(atPath: url.path) {
            if let status = ubiquity.downloadingStatus(for: url) {
                switch status {
                case .current, .downloaded:
                    return .downloaded
                case .notDownloaded:
                    return .notStarted
                default:
                    return .downloading
                }
            }
            return .downloaded
        }

        // No materialized file. A `.icloud` placeholder sibling signals "exists
        // remotely, not yet downloaded." Inspect that placeholder for any
        // downloading-in-progress signal.
        let placeholder = placeholderURL(for: url)
        if fm.fileExists(atPath: placeholder.path) {
            if let status = ubiquity.downloadingStatus(for: placeholder),
               status != .notDownloaded {
                return .downloading
            }
            return .notStarted
        }

        return .notFound
    }

    public func requestDownload(_ key: SidecarKey) throws {
        let url = fileURL(for: key)
        try ubiquity.startDownloading(at: url)
    }

    // MARK: - Blob payload I/O

    // Encrypt `data` and write it to `<key.id>.<blobId>.dat` in the same
    // per-kind directory as the envelope, under the SAME iCloud root so it
    // syncs. Reuses the coordinated-write + busy-handler machinery (those
    // compose for any URL).
    public func writeBlob(_ data: Data, blobId: String, for key: SidecarKey) throws {
        let sealed = try blobCrypto.encrypt(data)
        try fileLocks.withLock(forKey: key) {
            let url = blobURL(for: key, blobId: blobId)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var writeError: Error?
            try coordinatedWrite(key: key, at: url) { safeURL in
                do {
                    try sealed.write(to: safeURL, options: [.atomic])
                } catch {
                    writeError = error
                }
            }
            if let writeError { throw writeError }
        }
    }

    // Read + decrypt the blob for (key, blobId). Returns nil when the `.dat`
    // is not materialized on this device yet — either truly absent, or present
    // only as an iCloud `.<name>.dat.icloud` placeholder. In the placeholder
    // case we kick off a download (best-effort) and still return nil, so a
    // referenced-but-not-yet-downloaded blob reads as "pending," NOT an error.
    // (This mirrors how `read()` treats a `.json` placeholder, but returns nil
    // instead of throwing — a missing previous-photo is benign.)
    public func readBlob(blobId: String, for key: SidecarKey) throws -> Data? {
        let url = blobURL(for: key, blobId: blobId)
        let fm = FileManager.default

        enum Outcome {
            case bytes(Data)
            case placeholderPresent
            case missing
            case failed(Error)
        }
        var outcome: Outcome = .missing
        try coordinatedRead(key: key, at: url) { safeURL in
            if fm.fileExists(atPath: safeURL.path) {
                do {
                    outcome = .bytes(try Data(contentsOf: safeURL))
                } catch {
                    outcome = .failed(error)
                }
            } else if fm.fileExists(atPath: self.placeholderURL(for: safeURL).path) {
                outcome = .placeholderPresent
            } else {
                outcome = .missing
            }
        }

        switch outcome {
        case .bytes(let sealed):
            return try blobCrypto.decrypt(sealed)
        case .placeholderPresent:
            // Materialized bytes aren't here yet; ask iCloud to fetch them and
            // report "pending" (nil), not "gone" — the caller retries later.
            try? ubiquity.startDownloading(at: url)
            return nil
        case .missing:
            return nil
        case .failed(let error):
            throw error
        }
    }

    public func deleteBlob(blobId: String, for key: SidecarKey) throws {
        try fileLocks.withLock(forKey: key) {
            let url = blobURL(for: key, blobId: blobId)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var deleteError: Error?
            try coordinatedDelete(key: key, at: url) { safeURL in
                do {
                    try FileManager.default.removeItem(at: safeURL)
                } catch {
                    deleteError = error
                }
            }
            if let deleteError { throw deleteError }
        }
    }

    // List the per-kind directory and return the blobId of every `.dat` (or
    // its `.icloud` placeholder) belonging to `key`. A `.dat` is named
    // `<key.id>.<blobId>.dat`; a not-yet-downloaded one is `.<that>.icloud`.
    // This is `.dat`-specific on purpose: `allKeys()`/`listKeys` stay
    // `.json`-only so envelope enumeration is unaffected.
    public func blobIds(for key: SidecarKey) throws -> [String] {
        let fm = FileManager.default
        let directory = root.appendingPathComponent(directoryName(for: key.kind))
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        let prefix = "\(key.id.lowercased())."
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let fullName = entry.lastPathComponent
            // Recover the real `<id>.<blobId>.dat` name from a placeholder, or
            // take the name as-is for a materialized `.dat`.
            let realName: String
            if fullName.hasSuffix(".dat") {
                realName = fullName
            } else if let recovered = realBlobNameFromPlaceholder(fullName) {
                let realURL = directory.appendingPathComponent(recovered)
                // Surface the blob now so the orphan sweep counts it; kick off
                // a download so a later read can succeed.
                try? ubiquity.startDownloading(at: realURL)
                realName = recovered
            } else {
                continue
            }
            // Match this key's blobs only: `<id>.<blobId>.dat`.
            guard realName.hasPrefix(prefix), realName.hasSuffix(".dat") else { continue }
            let middle = realName.dropFirst(prefix.count).dropLast(".dat".count)
            let blobId = String(middle)
            guard !blobId.isEmpty else { continue }
            guard seen.insert(blobId).inserted else { continue }
            result.append(blobId)
        }
        return result
    }

    @_spi(ConflictReconcile)
    public func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ current: Data?, _ conflicts: [Data]) throws -> SidecarEnvelope
    ) throws -> SidecarReconcileReport.FileOutcome? {
        try fileLocks.withLock(forKey: key) { () throws -> SidecarReconcileReport.FileOutcome? in
            let url = fileURL(for: key)
            guard let conflicts = ubiquity.unresolvedConflictVersions(at: url),
                  !conflicts.isEmpty else {
                return nil
            }

            var skipped: [String] = []

            // Read current's bytes:
            //   - no current version on disk          → pass nil to resolver.
            //   - current version exists, read OK     → pass the bytes.
            //   - current version exists, read FAILS  → abort this pass.
            //     We can't tell what was on disk and we MUST NOT clobber it
            //     with a fold of conflict-only inputs. Surface the error in
            //     skippedReasons; next reconcile retries.
            let currentBytes: Data?
            do {
                currentBytes = try ubiquity.currentVersionBytes(at: url)
            } catch {
                return SidecarReconcileReport.FileOutcome(
                    key: key,
                    versionsConsidered: 0,
                    skippedReasons: ["current: read failed: \(error)"]
                )
            }

            // Conflict-version reads: a read failure (I/O, file not yet
            // downloaded, sandbox, etc.) is NOT the same as "unparseable
            // bytes." We don't know what's in those bytes; we MUST NOT
            // converge without considering them. Abort the pass; next
            // reconcile retries.
            var conflictBytes: [Data] = []
            for version in conflicts {
                do {
                    conflictBytes.append(try version.bytes())
                } catch {
                    return SidecarReconcileReport.FileOutcome(
                        key: key,
                        versionsConsidered: 0,
                        skippedReasons: ["conflict: read failed: \(error)"]
                    )
                }
            }

            // The orchestrator's resolver does not throw. A third-party
            // resolver that does throw produces no merged envelope to write
            // — so we leave the conflict surface intact (no write, no
            // remove) and surface the failure. The next pass retries with
            // the same inputs. This is the same shape as the read-failure
            // abort above: when in doubt, don't clobber.
            let merged: SidecarEnvelope
            do {
                merged = try resolve(currentBytes, conflictBytes)
            } catch {
                skipped.append("resolver threw: \(error)")
                return SidecarReconcileReport.FileOutcome(
                    key: key,
                    versionsConsidered: 0,
                    skippedReasons: skipped
                )
            }

            // Defense-in-depth against a buggy resolver: refuse to write an
            // envelope whose entityID doesn't match this key. The
            // orchestrator's resolver enforces this in the fold, but a
            // third-party resolver could violate the contract and produce
            // wrong-routed data. Abort the pass and surface the violation.
            guard merged.entityID == key.id else {
                skipped.append("resolver returned mismatched entityID: \(merged.entityID) ≠ key \(key.id)")
                return SidecarReconcileReport.FileOutcome(
                    key: key,
                    versionsConsidered: 0,
                    skippedReasons: skipped
                )
            }

            let mergedData = try JSONEncoder().encode(merged)
            var mergedWriteError: Error?
            try coordinatedWrite(key: key, at: url) { safeURL in
                do {
                    try mergedData.write(to: safeURL, options: [.atomic])
                } catch {
                    mergedWriteError = error
                }
            }
            if let mergedWriteError { throw mergedWriteError }

            // Mark every conflict version resolved — the merged write is the
            // new ground truth. If a remove() fails, leave isResolved=false
            // and surface the failure so the next pass retries this key
            // (rather than silently claiming we converged).
            for version in conflicts {
                do {
                    try version.remove()
                    version.isResolved = true
                } catch {
                    skipped.append("version.remove failed: \(error)")
                }
            }

            return SidecarReconcileReport.FileOutcome(
                key: key,
                versionsConsidered: (currentBytes != nil ? 1 : 0) + conflictBytes.count,
                skippedReasons: skipped
            )
        }
    }

    // MARK: - Helpers

    private func fileURL(for key: SidecarKey) -> URL {
        root.appendingPathComponent(directoryName(for: key.kind))
            .appendingPathComponent(safeFilename(for: key))
    }

    // The `.dat` payload URL for (key, blobId): `<id>.<blobId>.dat` in the
    // same per-kind directory as the envelope `.json`, so it syncs the same
    // way. Mirrors `fileURL(for:)`/`safeFilename(for:)`; the id is lowercased
    // to match the canonical filename casing used everywhere else.
    private func blobURL(for key: SidecarKey, blobId: String) -> URL {
        root.appendingPathComponent(directoryName(for: key.kind))
            .appendingPathComponent("\(key.id.lowercased()).\(blobId).dat")
    }

    // `.dat` sibling of `realNameFromPlaceholder` (which is `.json`-only).
    // Recovers a `<id>.<blobId>.dat` filename from its `.<that>.icloud` stub;
    // returns nil when the entry is not a `.dat` placeholder.
    private func realBlobNameFromPlaceholder(_ fullName: String) -> String? {
        guard fullName.hasPrefix("."), fullName.hasSuffix(".icloud") else { return nil }
        let withoutDot = fullName.dropFirst()
        let withoutSuffix = withoutDot.dropLast(".icloud".count)
        guard withoutSuffix.hasSuffix(".dat") else { return nil }
        return String(withoutSuffix)
    }

    private func directoryName(for kind: SidecarKind) -> String {
        switch kind {
        case .contact: return "contacts"
        case .event: return "events"
        case .link: return "links"
        }
    }

    private func safeFilename(for key: SidecarKey) -> String {
        switch key.kind {
        case .contact, .link, .event:
            // All sidecar kinds are UUID-keyed and canonicalized to
            // lowercase at every boundary so case-folding filesystems (iCloud
            // Drive on APFS) can't desync the on-disk name from the in-memory
            // key. (A UUID happens to percent-encode to itself, so legacy
            // event filenames named with percent-encoded externalIDs that may
            // briefly coexist with this lowercased path until migration
            // deletes them are still writable. New writes go through this
            // branch.)
            return "\(key.id.lowercased()).json"
        }
    }

    private func listKeys(in directory: URL, kind: SidecarKind) throws -> [SidecarKey] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [SidecarKey] = []
        var seen = Set<String>()
        for entry in entries {
            let fullName = entry.lastPathComponent
            let realName: String
            if entry.pathExtension == "json" {
                realName = fullName
            } else if let placeholderName = realNameFromPlaceholder(fullName) {
                // iCloud has not yet downloaded this sidecar. Kick off a
                // download so subsequent reads can succeed; surface the key
                // now so the orchestrator knows the sidecar exists.
                let realURL = directory.appendingPathComponent(placeholderName)
                try? ubiquity.startDownloading(at: realURL)
                realName = placeholderName
            } else {
                continue
            }
            // If both a real .json and its placeholder are present (rare
            // transitional state), de-dup so we only emit one key.
            guard !seen.contains(realName) else { continue }
            seen.insert(realName)

            let basename = (realName as NSString).deletingPathExtension
            switch kind {
            case .contact, .link:
                result.append(SidecarKey(kind: kind, id: basename.lowercased()))
            case .event:
                let decoded = basename.removingPercentEncoding ?? basename
                result.append(SidecarKey(kind: .event, id: decoded))
            }
        }
        return result
    }

    // iCloud Drive represents a not-yet-downloaded item at `name.ext` as a
    // sibling stub at `.name.ext.icloud` (leading dot, trailing `.icloud`).
    // Recover the real filename from such a stub; return nil if the entry
    // is not a placeholder.
    private func realNameFromPlaceholder(_ fullName: String) -> String? {
        guard fullName.hasPrefix("."), fullName.hasSuffix(".icloud") else { return nil }
        let withoutDot = fullName.dropFirst()
        let withoutSuffix = withoutDot.dropLast(".icloud".count)
        guard withoutSuffix.hasSuffix(".json") else { return nil }
        return String(withoutSuffix)
    }

    // The placeholder sibling URL for a sidecar file URL. Used to detect
    // not-yet-downloaded files at read time.
    private func placeholderURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let placeholderName = ".\(url.lastPathComponent).icloud"
        return directory.appendingPathComponent(placeholderName)
    }

    // MARK: - NSFileCoordinator wrappers

    // On Apple platforms cloudd reads and writes ubiquity-container files in
    // a separate process. Without coordination it can observe partial state
    // mid-write or race deletes. NSFileCoordinator serializes our access
    // against cloudd; the closure receives the URL it should actually use
    // (the coordinator may substitute, e.g., a temporary).
    //
    // The coordinator call runs on `coordinatorQueue` so the caller can wait
    // with a per-attempt timeout. If the wait expires, the busy handler
    // decides whether to retry, sleep+retry, or fail with `.timedOut(key)`.
    // A coordinator call that eventually finishes after we've moved on is
    // left to run to completion in the background — see `runWithBusyHandling`
    // for the leak discussion.
    private func coordinatedRead(key: SidecarKey, at url: URL, _ body: @escaping (URL) -> Void) throws {
        try runWithBusyHandling(key: key) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { safeURL in
                body(safeURL)
            }
            if let coordError { throw coordError }
        }
    }

    private func coordinatedWrite(key: SidecarKey, at url: URL, _ body: @escaping (URL) -> Void) throws {
        try runWithBusyHandling(key: key) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { safeURL in
                body(safeURL)
            }
            if let coordError { throw coordError }
        }
    }

    private func coordinatedDelete(key: SidecarKey, at url: URL, _ body: @escaping (URL) -> Void) throws {
        try runWithBusyHandling(key: key) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { safeURL in
                body(safeURL)
            }
            if let coordError { throw coordError }
        }
    }

    // Run `operation` on `coordinatorQueue` with a per-attempt wait of
    // `perAttemptTimeout`. The operation is dispatched ONCE; we never
    // re-issue. On wait-timeout we consult the busy handler:
    //   .retry          → keep waiting (next per-attempt slice).
    //   .retryAfter(t)  → sleep, then keep waiting.
    //   .fail           → throw `.timedOut(key)` and abandon the operation.
    //
    // Re-issuing was rejected as a design: NSFileCoordinator has no
    // cancellation, so a stuck coordinator call sits there forever, and
    // launching parallel attempts just multiplies stuck calls without
    // freeing the resource. "Block forever" still works (install a handler
    // that returns `.retry` forever); "best effort, eventually fail" still
    // works (default handler).
    //
    // If the operation eventually completes after we threw `.timedOut`, its
    // body still runs on the background queue — captures live in
    // `ResultBox` (heap) so a late completion never writes to a dead
    // stack frame. The captured box is then released by ARC; the
    // coordinator queue is reused for the next call.
    // Internal so @testable tests can drive busy handling directly,
    // bypassing the coordinator wrappers.
    func runWithBusyHandling(
        key: SidecarKey,
        operation: @escaping () throws -> Void
    ) throws {
        let started = SidecarMonotonicClock.now()
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        coordinatorQueue.async {
            do {
                try operation()
                resultBox.error = nil
            } catch {
                resultBox.error = error
            }
            resultBox.didComplete = true
            semaphore.signal()
        }

        var attempt = 0
        while true {
            let outcome = semaphore.wait(timeout: .now() + perAttemptTimeout)
            switch outcome {
            case .success:
                if let error = resultBox.error { throw error }
                return
            case .timedOut:
                let elapsed = SidecarMonotonicClock.now() - started
                switch busyHandler(key, attempt, elapsed) {
                case .retry:
                    attempt += 1
                    continue
                case .retryAfter(let delay):
                    if delay > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                    attempt += 1
                    continue
                case .fail:
                    throw SidecarStoreError.timedOut(key)
                }
            }
        }
    }
}

// Box for the bg worker to write its outcome; read by the waiter after the
// semaphore signals. Heap-allocated so a late completion can write to it
// even after the waiter threw `.timedOut` and returned.
private final class ResultBox {
    var error: Error?
    var didComplete: Bool = false
}

// Monotonic clock for elapsed-time measurement. Avoids wall-clock skew if
// the system time jumps mid-operation.
private enum SidecarMonotonicClock {
    static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

// Conflict-reconciliation is wired up via this internal protocol so the
// public surface area never exposes the conflict-resolver plumbing. The
// orchestrator's reconcileSidecars() casts its store to this protocol and
// drives the loop; the conformance witnesses are the keysWithUnresolvedConflicts
// and reconcileConflict methods on the class above.
@_spi(ConflictReconcile)
extension FileSystemSidecarStore: SidecarConflictReconciling {}
