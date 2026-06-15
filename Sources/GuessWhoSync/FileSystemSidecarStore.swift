import Foundation

public final class FileSystemSidecarStore: SidecarStoreProtocol {
    private let root: URL
    private let writeLock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    public func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SidecarEnvelope.self, from: data)
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
        try data.write(to: url, options: [.atomic])
    }

    public func delete(_ key: SidecarKey) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
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
                writeLock.lock()
                try mergedData.write(to: url, options: [.atomic])
                writeLock.unlock()

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
                writeLock.lock()
                try mergedData.write(to: siblingURL, options: [.atomic])
                writeLock.unlock()
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
            return "\(key.id).json"
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
        for entry in entries {
            guard entry.pathExtension == "json" else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
            switch kind {
            case .contact:
                result.append(SidecarKey(kind: .contact, id: basename))
            case .event:
                let decoded = basename.removingPercentEncoding ?? basename
                result.append(SidecarKey(kind: .event, id: decoded))
            }
        }
        return result
    }

    // Original `abc.json` → sibling `abc.recovered.<suffix>.json` (same directory).
    private func recoverySiblingURL(for original: URL, suffix: String) -> URL {
        let directory = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(stem).recovered.\(suffix).json")
    }
}
