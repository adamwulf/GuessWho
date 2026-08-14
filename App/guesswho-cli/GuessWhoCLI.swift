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
///   2. read the shared-container id from THIS binary's embedded Info.plist
///      (`CLIEnvironment`, below);
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

/// Shared environment resolution: the per-channel shared-container id comes
/// from the Info.plist embedded in this binary's __TEXT,__info_plist section —
/// the same value the app derives, because both expand the ONE shared build
/// var (INV-4). This MUST stay in the executable: it reads `Bundle.main`'s
/// embedded Info.plist, which only exists in the built helper.
enum CLIEnvironment {
    static func groupID() throws -> String {
        guard
            let groupID = Bundle.main.object(
                forInfoDictionaryKey: WireEnvironment.containerInfoPlistKey) as? String,
            !groupID.isEmpty
        else {
            throw CLIEnvironmentError(
                "\(WireEnvironment.containerInfoPlistKey) is missing from the embedded Info.plist — the xcconfig → Info.plist wiring is broken.")
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
