import Foundation
import GuessWhoCLICore
import GuessWhoMCPWire
import Logging

/// The GuessWho relay CLI executable — a thin `@main` shim (Phase 1). The
/// entire ArgumentParser command tree lives in the package target
/// `GuessWhoCLICore` (`GuessWhoCLIRoot`, which has NO `@main`) so `swift test`
/// exercises it; this shim only does what must run inside the executable:
///
///   1. bootstrap swift-log to STDERR (stdout carries the MCP stream);
///   2. resolve the shared-container id from the compiled-in `BuildSettings`
///      constant (`CLIEnvironment`, below);
///   3. install the live `CLIRuntime` (real container + transport + output);
///   4. dispatch to `GuessWhoCLIRoot.main()`.
///
/// The binary is named `guesswho-cli` (never `guesswho`: on case-insensitive
/// APFS that would collide with the app executable `GuessWho` inside
/// Contents/MacOS). The user-facing `guesswho` command arrives later via the
/// /usr/local/bin symlink.
@main
struct GuessWhoCLIMain {
    static func main() async {
        // Bootstrap swift-log to STDERR before ArgumentParser dispatches:
        // stdout carries the MCP protocol stream under `run`, so any library
        // log reaching stdout would corrupt it.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .warning
            return handler
        }

        // Install the live runtime the package command tree runs against.
        CLIRuntime.current = CLIRuntime(
            containerURL: { try CLIEnvironment.container() },
            groupID: { try CLIEnvironment.groupID() },
            makeTransport: { container in RelayCLITransport(container: container) },
            output: StandardCLIOutput()
        )

        await GuessWhoCLIRoot.main()
    }
}

/// Shared environment resolution: the per-channel shared-container id is a
/// build-time constant compiled into this binary — `BuildSettings`, generated
/// by the "Generate BuildSettings.swift" run-script phase in
/// guesswho-cli.xcodeproj from `$(GUESSWHO_CLI_APP_GROUP)` (the ONE shared
/// build var, INV-4), the same value the app derives.
///
/// It is deliberately NOT read from the Info.plist via `Bundle.main`: the
/// user-facing `guesswho` command always runs through the /usr/local/bin
/// symlink, and under a symlinked launch `Bundle.main` mis-resolves the main
/// bundle so the embedded Info.plist key comes back nil (the CLI then died
/// with "GuessWhoCLIAppGroup is missing from the embedded Info.plist"). A
/// plain compiled-in constant is invariant to how the process was launched.
enum CLIEnvironment {
    static func groupID() throws -> String {
        let groupID = BuildSettings.GUESSWHO_CLI_APP_GROUP
        guard !groupID.isEmpty else {
            throw CLIEnvironmentError(
                "the CLI App Group id is empty — BuildSettings.swift was generated without $(GUESSWHO_CLI_APP_GROUP); the guesswho-cli target's xcconfig must #include Config/CLIAppGroup-<config>.xcconfig (INV-4).")
        }
        return groupID
    }

    static func container() throws -> URL {
        let groupID = try groupID()
        guard let container = WireEnvironment.containerURL(groupID: groupID) else {
            throw CLIEnvironmentError(
                "could not resolve the shared container for \(groupID) — entitlement/group-id mismatch.")
        }
        return container
    }
}

/// A plain, self-describing environment failure. `CustomStringConvertible` so
/// the core's funnel prints its message to stderr, and ArgumentParser prints
/// it for `run`/`probe`.
struct CLIEnvironmentError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
