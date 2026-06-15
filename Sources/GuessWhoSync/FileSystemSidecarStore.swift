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
    public var busyHandler: SidecarBusyHandler

    // Per-attempt budget for a single sidecar read/write/delete. If the
    // operation hasn't returned by this point, `busyHandler` is consulted.
    // Defaults to 1 second.
    public var perAttemptTimeout: TimeInterval

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
            try? fm.startDownloadingUbiquitousItem(at: url)
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
        return result
    }

    public func keysWithUnresolvedConflicts() throws -> [SidecarKey] {
        var result: [SidecarKey] = []
        for key in try allKeys() {
            let url = fileURL(for: key)
            if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
               !conflicts.isEmpty {
                result.append(key)
            }
        }
        return result
    }

    public func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        let url = fileURL(for: key)
        let fm = FileManager.default

        // If the materialized file exists, ask URLResourceValues whether it
        // is "current" (fully downloaded) or still downloading. For non-
        // ubiquity files those keys return nil; treat that as downloaded.
        if fm.fileExists(atPath: url.path) {
            if let status = ubiquityDownloadingStatus(for: url) {
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
            if let status = ubiquityDownloadingStatus(for: placeholder),
               status != .notDownloaded {
                return .downloading
            }
            return .notStarted
        }

        return .notFound
    }

    public func requestDownload(_ key: SidecarKey) throws {
        let url = fileURL(for: key)
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // Read the ubiquity downloading-status for a URL. Returns nil if the
    // URL isn't a ubiquity item (e.g. a temp file in tests).
    private func ubiquityDownloadingStatus(
        for url: URL
    ) -> URLUbiquitousItemDownloadingStatus? {
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
        guard let raw = try? url.resourceValues(forKeys: keys).allValues else {
            return nil
        }
        guard let rawStatus = raw[.ubiquitousItemDownloadingStatusKey] as? String else {
            return nil
        }
        return URLUbiquitousItemDownloadingStatus(rawValue: rawStatus)
    }

    public func reconcileConflict(
        at key: SidecarKey,
        resolve: (_ versions: [Data]) throws -> ConflictResolution
    ) throws -> SidecarReconcileReport.FileOutcome? {
        try fileLocks.withLock(forKey: key) { () throws -> SidecarReconcileReport.FileOutcome? in
            let url = fileURL(for: key)
            guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
                  !conflicts.isEmpty else {
                return nil
            }

            // Cache the bytes from the first read pass so the skip-matching
            // pass below never re-reads from disk. A second read can fail
            // (e.g. NSFileVersion's underlying file got swept) and would
            // otherwise produce an empty Data() that fails to match any
            // entry in `skip`, silently deleting a version the resolver
            // explicitly asked to keep.
            //
            // The cache deliberately excludes the CURRENT version: the
            // merged write below replaces the current contents regardless,
            // so even if the resolver returned current bytes in `skip`
            // (e.g. by mistake) the skip pass has nothing to do for them.
            var conflictBytesByVersionID: [(NSFileVersion, Data?)] = []
            var allBytes: [Data] = []
            if let current = NSFileVersion.currentVersionOfItem(at: url),
               let bytes = try? Data(contentsOf: current.url) {
                allBytes.append(bytes)
            }
            for version in conflicts {
                let bytes = try? Data(contentsOf: version.url)
                conflictBytesByVersionID.append((version, bytes))
                if let bytes {
                    allBytes.append(bytes)
                }
            }

            let resolution: ConflictResolution
            do {
                resolution = try resolve(allBytes)
            } catch {
                return SidecarReconcileReport.FileOutcome(
                    key: key,
                    mergedVersionCount: 0,
                    skippedReasons: [String(describing: error)]
                )
            }

            switch resolution {
            case .write(let merged, let skip):
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

                var skippedCount = 0
                for (version, cachedBytes) in conflictBytesByVersionID {
                    // If the first read failed, this version was never a
                    // parseable candidate. Treat it as "not in skip" so the
                    // default removal still applies; the resolver had no way
                    // to request it kept.
                    let bytes = cachedBytes ?? Data()
                    if cachedBytes != nil, skip.contains(bytes) {
                        skippedCount += 1
                    } else {
                        version.isResolved = true
                        try? version.remove()
                    }
                }
                return SidecarReconcileReport.FileOutcome(
                    key: key,
                    mergedVersionCount: allBytes.count - skippedCount,
                    skippedReasons: []
                )

            case .leave:
                return SidecarReconcileReport.FileOutcome(
                    key: key,
                    mergedVersionCount: 0,
                    skippedReasons: []
                )
            }
        }
    }

    // MARK: - Helpers

    private func fileURL(for key: SidecarKey) -> URL {
        root.appendingPathComponent(directoryName(for: key.kind))
            .appendingPathComponent(safeFilename(for: key))
    }

    private func directoryName(for kind: SidecarKind) -> String {
        switch kind {
        case .contact: return "contacts"
        case .event: return "events"
        }
    }

    private func safeFilename(for key: SidecarKey) -> String {
        switch key.kind {
        case .contact:
            // Contact UUIDs are canonicalized to lowercase at every boundary so
            // case-folding filesystems (iCloud Drive on APFS) can't desync the
            // on-disk name from the in-memory key.
            return "\(key.id.lowercased()).json"
        case .event:
            var allowed = CharacterSet(charactersIn: "._-")
            allowed.insert(charactersIn: "A"..."Z")
            allowed.insert(charactersIn: "a"..."z")
            allowed.insert(charactersIn: "0"..."9")
            let encoded = key.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? key.id
            return "\(encoded).json"
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
                try? fm.startDownloadingUbiquitousItem(at: realURL)
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
            case .contact:
                result.append(SidecarKey(kind: .contact, id: basename.lowercased()))
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
    // Internal (not private) so @testable imports can probe the busy-handling
    // behavior without going through the coordinator wrappers.
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
