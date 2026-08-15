import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire

/// The CLI's typed process exit codes (§4). Replaces today's degenerate
/// behavior where EVERY failure exits `EX_USAGE` (64) because runtime failures
/// were wrapped in ArgumentParser's `ValidationError` (§3.2). A script can now
/// branch: 69 means "open the app", 1 means the app answered with a real
/// error, 64 means the command line itself was wrong.
///
/// The raw values are the actual process exit codes. Success is 0; the funnel
/// throws `ArgumentParser.ExitCode(code.rawValue)` after writing its own
/// message, so ArgumentParser exits with the code and prints nothing extra.
public enum CLIExitCode: Int32, Sendable {
    /// The command succeeded — including "no data" successes the wire defines
    /// as normal results.
    case success = 0
    /// The app answered with a typed error (`WireResponse.error`); the plain
    /// message is written to stderr, the code name never printed.
    case appError = 1
    /// The user declined the in-app delete confirmation (§6 #1). Not an app
    /// error and not a data result, so it gets a distinct code a script can
    /// branch on. Reserved here for Phase 5's `contacts delete`.
    case declinedDelete = 10
    /// Genuine usage errors only: ArgumentParser validation, malformed
    /// `--json`, or an argument the wire builder rejected as invalid.
    case usage = 64 // EX_USAGE
    /// Transport-level failure: the app isn't running / not ready / timed out
    /// (`RelayConnectionError`), so scripts can tell "open the app" from a
    /// real tool error.
    case transportUnavailable = 69 // EX_UNAVAILABLE

    /// The transport failure code is the same regardless of which
    /// `RelayConnectionError` case occurred — the caller distinguishes them by
    /// the message, not the exit code.
    public static func code(for error: RelayConnectionError) -> CLIExitCode {
        _ = error
        return .transportUnavailable
    }
}

/// A usage-level failure the CLI itself raises before (or instead of) building
/// a wire request — an unreadable/oversize/wrong-type photo input, a photo
/// that can't be written to the requested file. Carries a plain message the
/// funnel writes to stderr, then exits `EX_USAGE` (64). Distinct from
/// `WireRequestError` (the shared builder's rejection) but mapped to the same
/// code, so a caller sees one consistent "your input was wrong" class.
public struct CLIUsageError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
