import Foundation
import os.log

/// Resolves the shared directory log files are written into.
///
/// The "one shared place" both the GuessWho app and its Safari Web Extension
/// can reach is the **App Group container** (`<AppGroup>/Logs/`). The caller
/// passes the App Group id so this package stays id-agnostic — the id is
/// resolved per platform/target by the app & extension from their Info.plist.
///
/// If the App Group container is unavailable at runtime (e.g. the entitlement
/// isn't granted), we fall back to the process's Caches directory so logging
/// never crashes. The fallback is announced once via `os.log` — which survives
/// the fallback and is therefore diagnosable. In the fallback state the
/// extension's `extension.log` lands in the appex Caches and the app's exporter
/// (which zips the App Group `Logs/`) won't see it — acceptable degradation.
enum LogDestination {

    /// `os.log` channel for the one-shot fallback breadcrumb. Developer-facing
    /// only; never surfaced in the UI.
    private static let breadcrumbLog = Logger(
        subsystem: "com.milestonemade.guesswho.logging",
        category: "destination"
    )

    /// Resolve `<AppGroup>/Logs/`, creating it if missing. Falls back to
    /// `<Caches>/Logs/` when the App Group container can't be resolved.
    ///
    /// `baseOverride` lets tests inject a temp base directory so they never
    /// touch the real container; when set, `<baseOverride>/Logs/` is used and
    /// no App Group / Caches resolution happens.
    static func logsDirectoryURL(appGroupID: String, baseOverride: URL? = nil) -> URL? {
        if let baseOverride {
            return ensureLogsDir(under: baseOverride)
        }

        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
           let dir = ensureLogsDir(under: container) {
            return dir
        }

        // App Group unavailable — fall back to Caches so logging never crashes.
        breadcrumbLog.error(
            "App Group container unavailable for id=\(appGroupID, privacy: .public); falling back to Caches (extension.log will not reach the app's export in this state)"
        )
        guard let caches = try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            breadcrumbLog.error("Caches directory also unavailable; file logging disabled this run")
            return nil
        }
        return ensureLogsDir(under: caches)
    }

    /// Create (if needed) and return `<base>/Logs/`. Returns nil if the
    /// directory can't be created.
    private static func ensureLogsDir(under base: URL) -> URL? {
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            return logs
        } catch {
            breadcrumbLog.error("Failed to create Logs dir at \(logs.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
