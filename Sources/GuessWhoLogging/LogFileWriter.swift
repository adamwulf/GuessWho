import Foundation
import os.log

/// Serial, thread-safe append writer for one process's log file.
///
/// **Why a class guarded by a serial `DispatchQueue`, not an actor (N3):**
/// swift-log's `LogHandler.log(...)` is synchronous and non-`async`. An actor
/// would force `await` hops that can't be made from inside `log`, so the
/// correct fit for the synchronous `LogHandler` contract is a class whose
/// mutable state is confined to a private serial queue. The queue keeps writes
/// ordered and off the caller's thread.
///
/// Owns one base file (e.g. `app.log`) named from a `processName`. Appends each
/// formatted line + `\n`. Rotates at 10 MB (keeping a capped number of rotated
/// siblings) and prunes any file in the directory older than 7 days. Every file
/// op is wrapped so an I/O error degrades to console logging — never a crash.
///
/// `@unchecked Sendable` (SF5): swift-log's `LogHandler` is `Sendable`, so the
/// `LogfmtLogHandler` that captures this writer must be too. All mutable state
/// (`handle`, `lastPruneUptime`) is confined to the private serial queue — the
/// queue *is* the synchronization mechanism — so the unchecked conformance is
/// correct and future-proofs the package against Swift 6 / strict concurrency.
final class LogFileWriter: @unchecked Sendable {

    /// Rotate the active file once it reaches this size.
    private static let maxFileBytes: UInt64 = 10 * 1024 * 1024

    /// How many rotated siblings to keep (`app-1.log` … `app-5.log`). The oldest
    /// is deleted when a rotation would exceed this.
    private static let rotatedFilesToKeep = 5

    /// Files whose modification date is older than this are pruned.
    private static let maxFileAge: TimeInterval = 7 * 24 * 60 * 60

    /// Prune at most this often (cheap re-check guard so we don't stat the whole
    /// directory on every single write).
    private static let pruneInterval: TimeInterval = 60 * 60

    /// `os.log` channel for write-path degradation breadcrumbs. Developer-facing.
    private static let breadcrumbLog = Logger(
        subsystem: "com.milestonemade.guesswho.logging",
        category: "writer"
    )

    private let directory: URL
    private let baseName: String
    private let activeURL: URL

    /// All state below is confined to this serial queue.
    private let queue: DispatchQueue
    private var handle: FileHandle?
    /// Monotonic clock reading of the last prune, in seconds. nil = never pruned.
    private var lastPruneUptime: TimeInterval?

    /// - Parameters:
    ///   - directory: the resolved `Logs/` directory.
    ///   - processName: e.g. `"app"` or `"extension"`; the base file is
    ///     `<processName>.log`.
    init(directory: URL, processName: String) {
        self.directory = directory
        self.baseName = processName
        self.activeURL = directory.appendingPathComponent("\(processName).log")
        self.queue = DispatchQueue(label: "com.milestonemade.guesswho.logging.writer.\(processName)")

        // Prune stale files (incl. the other process's) and open the handle up
        // front so the first real log line doesn't pay for it.
        queue.async { [weak self] in
            guard let self else { return }
            self.pruneIfNeeded(force: true)
            self.openHandleIfNeeded()
        }
    }

    deinit {
        // No queue hop in deinit (the instance is going away); close directly.
        try? handle?.close()
    }

    /// Append one already-formatted log line (a trailing `\n` is added here).
    /// The caller guarantees `line` contains no embedded newlines.
    func write(_ line: String) {
        queue.async { [weak self] in
            self?.performWrite(line)
        }
    }

    /// Synchronously drain the serial write queue. Test-only — production
    /// callers fire-and-forget via `write`. Blocks until every previously
    /// enqueued write (and the init-time prune/open) has completed.
    func flush() {
        queue.sync {}
    }

    // MARK: - Queue-confined implementation

    private func performWrite(_ line: String) {
        pruneIfNeeded(force: false)
        rotateIfNeeded()
        openHandleIfNeeded()

        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Degrade to console; drop the file handle so the next write retries
            // a fresh open rather than reusing a broken one.
            Self.breadcrumbLog.error("write failed: \(error.localizedDescription, privacy: .public)")
            try? handle.close()
            self.handle = nil
        }
    }

    /// Open the append handle if not already open, seeking to end. Creates the
    /// file if it doesn't exist. Any failure leaves `handle == nil` and logs.
    private func openHandleIfNeeded() {
        guard handle == nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: activeURL.path) {
            fm.createFile(atPath: activeURL.path, contents: nil)
        }
        do {
            let h = try FileHandle(forWritingTo: activeURL)
            try h.seekToEnd()
            handle = h
        } catch {
            Self.breadcrumbLog.error("open failed for \(self.activeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            handle = nil
        }
    }

    /// Roll the active file when it reaches the size cap:
    /// `app-(n).log` → `app-(n+1).log` (oldest deleted), then `app.log` →
    /// `app-1.log`, then a fresh empty `app.log` is opened on the next write.
    ///
    /// SF1: rotation is checked *before* each write, so the active file can
    /// overshoot the cap by at most the one record being written before the next
    /// write rolls it. That bounded overshoot is intentional — re-stating the
    /// size after every write would double the `stat` cost for no real benefit.
    private func rotateIfNeeded() {
        guard currentActiveSize() >= Self.maxFileBytes else { return }

        // Close the active handle before moving the file out from under it.
        try? handle?.close()
        handle = nil

        let fm = FileManager.default

        // Drop the oldest if keeping it would exceed the cap.
        let oldest = rotatedURL(index: Self.rotatedFilesToKeep)
        try? fm.removeItem(at: oldest)

        // Shift app-(n) → app-(n+1) from the top down so we never clobber.
        var index = Self.rotatedFilesToKeep - 1
        while index >= 1 {
            let from = rotatedURL(index: index)
            let to = rotatedURL(index: index + 1)
            if fm.fileExists(atPath: from.path) {
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
            }
            index -= 1
        }

        // app.log → app-1.log. A fresh app.log is created lazily on next open.
        let firstRotated = rotatedURL(index: 1)
        try? fm.removeItem(at: firstRotated)
        do {
            try fm.moveItem(at: activeURL, to: firstRotated)
        } catch {
            // SF2: if the rename fails, the oversized active file would otherwise
            // stay in place and trip rotateIfNeeded on every subsequent write,
            // growing past the cap indefinitely. Fall back to truncating the
            // active file in place so the 10 MB bound still holds. (Truncation
            // loses the over-cap tail rather than preserving it as a rotated
            // sibling — an acceptable degradation when the filesystem won't let
            // us rename.)
            Self.breadcrumbLog.error("rotation move failed, truncating in place: \(error.localizedDescription, privacy: .public)")
            if let truncating = try? FileHandle(forWritingTo: activeURL) {
                try? truncating.truncate(atOffset: 0)
                try? truncating.close()
            }
        }
    }

    private func currentActiveSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: activeURL.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func rotatedURL(index: Int) -> URL {
        directory.appendingPathComponent("\(baseName)-\(index).log")
    }

    /// Delete any file in `Logs/` whose modification date is older than 7 days.
    /// Per-directory so it also cleans the *other* process's stale files
    /// harmlessly (modification-date based, no content parsing).
    ///
    /// N4: pruning a file another process holds open is benign on APFS — the
    /// file is unlinked but stays valid for the holder until it closes. This is
    /// intentional; we never coordinate cross-process file ownership for prune.
    ///
    /// SF3: we must NOT prune our *own* active file, however. A process running
    /// continuously for >7 days writing to an un-rotated `app.log` would
    /// otherwise unlink the file out from under its own open handle — on APFS the
    /// handle stays valid (unlinked-but-open) so writes keep "succeeding" into an
    /// inode no longer reachable through `app.log`, silently losing that data on
    /// close. So we skip `activeURL` here. As a belt-and-suspenders guard, if the
    /// active file no longer exists after pruning (e.g. deleted externally), drop
    /// the stale handle so the next write reopens a fresh `app.log`.
    private func pruneIfNeeded(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let last = lastPruneUptime, now - last < Self.pruneInterval {
            return
        }
        lastPruneUptime = now

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Self.maxFileAge)
        for url in entries where url.pathExtension == "log" {
            // Never prune our own active file (SF3).
            if url.standardizedFileURL == activeURL.standardizedFileURL { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values?.contentModificationDate else { continue }
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }

        // If the active file vanished (external deletion), the held handle now
        // points at an unlinked inode — drop it so the next write recreates it.
        if handle != nil, !fm.fileExists(atPath: activeURL.path) {
            try? handle?.close()
            handle = nil
        }
    }
}
