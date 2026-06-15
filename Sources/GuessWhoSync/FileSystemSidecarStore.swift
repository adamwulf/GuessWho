import Foundation

public final class FileSystemSidecarStore: SidecarStoreProtocol {
    private let root: URL
    private let writeLock = NSLock()

    public init(root: URL) {
        self.root = root
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
        try coordinatedRead(at: url) { safeURL in
            if fm.fileExists(atPath: safeURL.path) {
                do {
                    outcome = .bytes(try Data(contentsOf: safeURL))
                } catch {
                    outcome = .failed(error)
                }
            } else if fm.fileExists(atPath: placeholderURL(for: safeURL).path) {
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
        writeLock.lock()
        defer { writeLock.unlock() }

        let url = fileURL(for: key)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(envelope)

        var writeError: Error?
        try coordinatedWrite(at: url) { safeURL in
            do {
                try data.write(to: safeURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
    }

    public func delete(_ key: SidecarKey) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var deleteError: Error?
        try coordinatedDelete(at: url) { safeURL in
            do {
                try FileManager.default.removeItem(at: safeURL)
            } catch {
                deleteError = error
            }
        }
        if let deleteError { throw deleteError }
    }

    public func allKeys() throws -> [SidecarKey] {
        var result: [SidecarKey] = []
        result.append(contentsOf: try listKeys(in: root.appendingPathComponent("contacts"), kind: .contact))
        result.append(contentsOf: try listKeys(in: root.appendingPathComponent("events"), kind: .event))
        return result
    }

    public func reconcileConflicts(
        _ resolve: (_ key: SidecarKey, _ versions: [Data]) throws -> ConflictResolution
    ) throws -> [SidecarReconcileReport.FileOutcome] {
        var outcomes: [SidecarReconcileReport.FileOutcome] = []

        for key in try allKeys() {
            let url = fileURL(for: key)
            guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
                  !conflicts.isEmpty else {
                continue
            }

            // Current is NOT in `conflicts`; gather it explicitly so the closure sees every version.
            var allBytes: [Data] = []
            if let current = NSFileVersion.currentVersionOfItem(at: url),
               let bytes = try? Data(contentsOf: current.url) {
                allBytes.append(bytes)
            }
            for version in conflicts {
                if let bytes = try? Data(contentsOf: version.url) {
                    allBytes.append(bytes)
                }
            }

            let resolution: ConflictResolution
            do {
                resolution = try resolve(key, allBytes)
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
                let mergedData = try JSONEncoder().encode(merged)
                try withWriteLock {
                    var mergedWriteError: Error?
                    try coordinatedWrite(at: url) { safeURL in
                        do {
                            try mergedData.write(to: safeURL, options: [.atomic])
                        } catch {
                            mergedWriteError = error
                        }
                    }
                    if let mergedWriteError { throw mergedWriteError }
                }

                var skippedCount = 0
                for version in conflicts {
                    let bytes = (try? Data(contentsOf: version.url)) ?? Data()
                    if skip.contains(bytes) {
                        skippedCount += 1
                    } else {
                        version.isResolved = true
                        try? version.remove()
                    }
                }
                outcomes.append(
                    SidecarReconcileReport.FileOutcome(
                        key: key,
                        mergedVersionCount: allBytes.count - skippedCount,
                        skippedReasons: []
                    )
                )

            case .writeRecoverySibling(let merged, let suffix):
                let mergedData = try JSONEncoder().encode(merged)
                let siblingURL = recoverySiblingURL(for: url, suffix: suffix)
                try withWriteLock {
                    var siblingWriteError: Error?
                    try coordinatedWrite(at: siblingURL) { safeURL in
                        do {
                            try mergedData.write(to: safeURL, options: [.atomic])
                        } catch {
                            siblingWriteError = error
                        }
                    }
                    if let siblingWriteError { throw siblingWriteError }
                }
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

    // Original `abc.json` → sibling `abc.recovered.<suffix>.json` (same directory).
    private func recoverySiblingURL(for original: URL, suffix: String) -> URL {
        let directory = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(stem).recovered.\(suffix).json")
    }

    // Acquire writeLock for the duration of `body`. Using `defer` to unlock
    // means a throw from inside the coordinated-write block still releases
    // the lock — without this, an iCloud coordinator error would leak the
    // lock and deadlock every subsequent write/delete/reconcile.
    private func withWriteLock(_ body: () throws -> Void) rethrows {
        writeLock.lock()
        defer { writeLock.unlock() }
        try body()
    }

    // MARK: - NSFileCoordinator wrappers

    // On Apple platforms cloudd reads and writes ubiquity-container files in
    // a separate process. Without coordination it can observe partial state
    // mid-write or race deletes. NSFileCoordinator serializes our access
    // against cloudd; the closure receives the URL it should actually use
    // (the coordinator may substitute, e.g., a temporary).
    private func coordinatedRead(at url: URL, _ body: (URL) -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { safeURL in
            body(safeURL)
        }
        if let coordError { throw coordError }
    }

    private func coordinatedWrite(at url: URL, _ body: (URL) -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { safeURL in
            body(safeURL)
        }
        if let coordError { throw coordError }
    }

    private func coordinatedDelete(at url: URL, _ body: (URL) -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { safeURL in
            body(safeURL)
        }
        if let coordError { throw coordError }
    }
}
