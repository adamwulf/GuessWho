import Foundation
import Logging

/// Public entry point for file logging. Bootstraps swift-log once per process
/// onto a logfmt file handler (+ a stderr console echo) and vends labeled
/// loggers.
///
/// Both the GuessWho app and its Safari Web Extension call `bootstrap(...)` with
/// their own `processName` so each process writes its own file
/// (`<AppGroup>/Logs/app.log`, `<AppGroup>/Logs/extension.log`) — no
/// cross-process file locking.
public enum GuessWhoLog {

    /// Guards the one-time `LoggingSystem.bootstrap` call. swift-log's
    /// `LoggingSystem.bootstrap` is genuinely once-per-process and **traps** on
    /// a second call. The extension calls `beginRequest` per request, so this
    /// guard is mandatory and must wrap the `LoggingSystem.bootstrap` call
    /// itself (S4). `NSLock` makes it safe under concurrent `beginRequest`
    /// invocations.
    private static let bootstrapLock = NSLock()
    private static var didBootstrap = false

    /// Bootstrap swift-log onto the logfmt file handler. Idempotent: the first
    /// call wins, every later call is a no-op (so calling it on every extension
    /// request is safe).
    ///
    /// - Parameters:
    ///   - processName: distinguishes the per-process file. Use `"app"` and
    ///     `"extension"`.
    ///   - appGroupID: the resolved App Group id (caller-provided; the package
    ///     stays id-agnostic).
    ///   - consoleEcho: when true (default) records also go to stderr via
    ///     swift-log's `StreamLogHandler.standardError`, so existing Console
    ///     workflows keep working.
    ///   - baseOverride: tests inject a temp base dir here so they never touch
    ///     the real container. Production callers leave it nil.
    public static func bootstrap(
        processName: String,
        appGroupID: String,
        consoleEcho: Bool = true,
        baseOverride: URL? = nil
    ) {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }

        guard !didBootstrap else { return }
        didBootstrap = true

        // Resolve the shared Logs/ dir and build the file handler. If the dir
        // can't be resolved at all, we still bootstrap (console-only) so logging
        // never crashes and not-yet-migrated os.log/NSLog sites keep working.
        let writer = LogDestination.logsDirectoryURL(appGroupID: appGroupID, baseOverride: baseOverride)
            .map { LogFileWriter(directory: $0, processName: processName) }

        LoggingSystem.bootstrap { label in
            var handlers: [LogHandler] = []
            if let writer {
                handlers.append(LogfmtLogHandler(label: label, writer: writer))
            }
            if consoleEcho {
                handlers.append(StreamLogHandler.standardError(label: label))
            }
            // MultiplexLogHandler requires at least one handler; if both the
            // file writer failed AND console echo is off, fall back to the
            // swift-log no-op handler so bootstrap still succeeds.
            if handlers.isEmpty {
                return SwiftLogNoOpLogHandler()
            }
            if handlers.count == 1 {
                return handlers[0]
            }
            return MultiplexLogHandler(handlers)
        }
    }

    /// A labeled swift-log `Logger`. Safe to call before `bootstrap` (swift-log
    /// returns a logger against whatever factory is currently installed), but
    /// callers should bootstrap first so records reach the file.
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
