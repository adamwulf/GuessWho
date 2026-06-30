import Foundation

/// Zips the shared `Logs/` directory (every dated `app-*.log` and
/// `extension-*.log`) into a single file for the debug-mode "Export Logs"
/// action — so one export captures both processes across all retained days,
/// matching "one place".
///
/// Uses Foundation-only zipping via `NSFileCoordinator` with the `.forUploading`
/// reading intent, which produces a **zip** of the directory at a temporary URL
/// (available iOS 8+ / Mac Catalyst 13.1+ / macOS 10.10+ — covers both targets).
public enum LogExporter {

    public enum ExportError: Error, LocalizedError {
        case logsDirectoryUnavailable
        case coordinationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .logsDirectoryUnavailable:
                return "No logs are available to export yet."
            case .coordinationFailed(let detail):
                return "Couldn't package the logs: \(detail)"
            }
        }
    }

    /// Zip the App Group `Logs/` directory and return a stable temp-file URL to
    /// the zip, named `GuessWho-Logs-<timestamp>.zip`.
    ///
    /// - Parameters:
    ///   - appGroupID: resolved App Group id.
    ///   - timestamp: stamped into the filename (caller passes `Date()`).
    ///   - directoryOverride: tests inject the directory to zip directly,
    ///     bypassing App Group resolution.
    public static func exportLogs(
        appGroupID: String,
        timestamp: Date = Date(),
        directoryOverride: URL? = nil
    ) throws -> URL {
        guard let logsDir = directoryOverride
            ?? GuessWhoLog.logsDirectoryURL(appGroupID: appGroupID) else {
            throw ExportError.logsDirectoryUnavailable
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuessWho-Logs-\(filenameStamp(timestamp)).zip")
        // Remove any stale destination from a prior export so copyItem succeeds.
        try? FileManager.default.removeItem(at: destination)

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: Error?
        var produced: URL?

        coordinator.coordinate(
            readingItemAt: logsDir,
            options: [.forUploading],
            error: &coordinatorError
        ) { zippedURL in
            // S1: copy INSIDE the accessor block. Apple's docs: "The file
            // coordinator unlinks the file after the block returns, rendering it
            // inaccessible through the URL." Copying after the block would
            // dead-URL, so the copy to our stable destination must happen here.
            do {
                try FileManager.default.copyItem(at: zippedURL, to: destination)
                produced = destination
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw ExportError.coordinationFailed(coordinatorError.localizedDescription)
        }
        if let copyError {
            throw ExportError.coordinationFailed(copyError.localizedDescription)
        }
        guard let produced else {
            throw ExportError.coordinationFailed("zip was not produced")
        }
        return produced
    }

    /// `YYYYMMDD-HHmmss` in local time for the filename.
    private static func filenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
