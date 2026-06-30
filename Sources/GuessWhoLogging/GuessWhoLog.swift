import Foundation
import Logging
import FellerBuncher

/// Public entry point for file logging. Bootstraps swift-log once per process
/// onto FellerBuncher (a rotating, self-pruning logfmt file destination + an
/// OSLog console echo) and vends labeled loggers.
///
/// FellerBuncher owns the bootstrap and the destination fan-out; there is no
/// custom handler or file writer here anymore. Every `Logger(label:)` in the
/// app and packages routes to the same `<AppGroup>/Logs/<process>.log` file.
///
/// Both the GuessWho app and its Safari Web Extension call `bootstrap(...)` with
/// their own `processName` so each process writes its own file
/// (`<AppGroup>/Logs/app.log`, `<AppGroup>/Logs/extension.log`) — no
/// cross-process file locking.
public enum GuessWhoLog {

    /// swift-log channel for the one-shot bootstrap-failure breadcrumb. Routed
    /// through swift-log (never `os.Logger`) like everything else: FellerBuncher's
    /// `installPreConfigCapture()` runs before this could fire, so even a record
    /// emitted when the file destination couldn't be set up is buffered and
    /// replayed (or, in the total-failure case, kept in the bounded ring).
    /// Developer-facing only; never surfaced in the UI.
    private static let breadcrumbLog = Logger(label: "logging.bootstrap")

    /// Bootstrap swift-log onto FellerBuncher. Idempotent: FellerBuncher's
    /// `bootstrap` returns the existing handle on a second call (it does NOT trap
    /// like a raw `LoggingSystem.bootstrap`), so calling this on every extension
    /// request is safe.
    ///
    /// - Parameters:
    ///   - processName: distinguishes the per-process file. Use `"app"` and
    ///     `"extension"`.
    ///   - appGroupID: the resolved App Group id (caller-provided; the package
    ///     stays id-agnostic).
    ///   - baseOverride: tests inject a temp base dir here so they never touch
    ///     the real container. Production callers leave it nil.
    public static func bootstrap(
        processName: String,
        appGroupID: String,
        baseOverride: URL? = nil
    ) {
        // Install the pre-config capturing handler FIRST so any `Logger(label:)`
        // created before this bootstrap completes isn't lost — FellerBuncher
        // buffers those records and replays them into the file once the real
        // destinations come up. This is the single `LoggingSystem.bootstrap`
        // call; the `bootstrap(...)` below activates the same coordinator rather
        // than bootstrapping again. Idempotent.
        installPreConfigCapture()

        guard let logsDir = LogDestination.logsDirectoryURL(
            appGroupID: appGroupID,
            baseOverride: baseOverride
        ) else {
            // No writable directory at all — the pre-config capture above keeps
            // logging alive (records buffer, then drop oldest), and we announce
            // the degradation once. We do NOT crash: logging is never fatal.
            breadcrumbLog.error("Logs directory unavailable; file logging disabled this run")
            return
        }

        do {
            // Use FellerBuncher's defaults (size-based rotation, keep 5, 7-day
            // retention, OSLog console echo, default logfmt format). Simple by
            // design — the only things we pass are the per-process file name and
            // its directory.
            _ = try FellerBuncher.bootstrap(processName: processName, logDir: logsDir)
        } catch {
            // File destination couldn't be created (e.g. the dir became
            // unwritable between resolution and open). Logging stays alive via
            // the pre-config capture; announce once and carry on.
            breadcrumbLog.error("FellerBuncher bootstrap failed", ["error": error.localizedDescription])
        }
    }

    /// A labeled swift-log `Logger`. Thin wrapper over `Logger(label:)` — kept so
    /// call sites read against this package's facade. With FellerBuncher's
    /// pre-config capture installed in `bootstrap`, a logger built before
    /// bootstrap is no longer lost: its records are buffered and replayed once
    /// the file destination comes up.
    public static func logger(_ label: String) -> Logger {
        Logger(label: label)
    }

    /// The resolved `Logs/` directory URL for the exporter (and diagnostics).
    /// Returns nil only when neither the App Group container nor the Caches
    /// fallback could be resolved.
    public static func logsDirectoryURL(appGroupID: String) -> URL? {
        LogDestination.logsDirectoryURL(appGroupID: appGroupID)
    }
}
