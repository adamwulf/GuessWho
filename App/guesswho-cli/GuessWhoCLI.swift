import ArgumentParser
import Foundation

/// The GuessWho relay CLI (plans/cli-mcp.md). Phase 0 ships only the packaging
/// skeleton: a `run` stub (the MCP stdio server lands in Phase 1) and a
/// `probe` diagnostic that proves the Muse-mirrored seam end to end — the
/// embedded native-macOS Mach-O resolves the SAME per-channel App Group
/// container as the app and can signal the running app over a FIFO.
///
/// The binary is named `guesswho-cli` (never `guesswho`: on case-insensitive
/// APFS that would collide with the app executable `GuessWho` inside
/// Contents/MacOS). The user-facing `guesswho` command arrives in Phase 3 via
/// the /usr/local/bin symlink.
@main
struct GuessWhoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guesswho-cli",
        abstract: "Command-line access to GuessWho.",
        version: "0.1.0",
        subcommands: [Run.self, Probe.self]
    )
}

/// Constants shared with the app side of the Phase 0 diagnostic. The app's
/// `CLIProbeListener` (App/GuessWho/Support/CLIProbeListener.swift) creates
/// the FIFO at the same container-relative path; keep the two in sync until
/// Phase 1 folds pipe-path constants into the shared wire module.
enum ProbeConstants {
    /// Container-relative path of the app's diagnostic FIFO.
    static let fifoRelativePath = "Diagnostics/cli-probe.fifo"
    /// Info.plist key carrying the per-channel CLI App Group id (fed by
    /// GUESSWHO_CLI_APP_GROUP through the xcconfig pipeline; INV-4).
    static let appGroupInfoPlistKey = "GuessWhoCLIAppGroup"
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the MCP server (not available yet)."
    )

    func run() throws {
        // Phase 1 lands the MCP stdio server + pipe transport here. Fail
        // loudly rather than pretend: an MCP client pointing at this build
        // should see a clear error, not a silent no-op.
        FileHandle.standardError.write(Data(
            "guesswho-cli: the MCP server is not available in this build.\n".utf8
        ))
        throw ExitCode.failure
    }
}

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Diagnostic: resolve the shared container, verify write access, and signal the running app."
    )

    func run() throws {
        // 1. The App Group id comes from the Info.plist embedded in this
        //    binary's __TEXT,__info_plist section — the same value the app
        //    derives, because both expand the ONE shared build var (INV-4).
        guard
            let groupID = Bundle.main.object(
                forInfoDictionaryKey: ProbeConstants.appGroupInfoPlistKey) as? String,
            !groupID.isEmpty
        else {
            throw ValidationError(
                "\(ProbeConstants.appGroupInfoPlistKey) is missing from the embedded Info.plist — the xcconfig → Info.plist wiring is broken.")
        }
        print("app group:  \(groupID)")

        // 2. Exit criterion: the sandboxed helper resolves the group container.
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID)
        else {
            throw ValidationError(
                "could not resolve the App Group container for \(groupID) — entitlement/group-id mismatch.")
        }
        print("container:  \(container.path)")

        // 3. Exit criterion: the container is actually READ/WRITABLE at
        //    runtime. A resolvable-but-unwritable path is a sandbox/entitlement
        //    mismatch that would otherwise surface later disguised as an IPC
        //    bug (plan Phase 0, crit 2).
        let scratch = container.appendingPathComponent("cli-probe-scratch.txt")
        let payload = "probe pid=\(ProcessInfo.processInfo.processIdentifier) at \(Date())"
        try payload.write(to: scratch, atomically: true, encoding: .utf8)
        let readBack = try String(contentsOf: scratch, encoding: .utf8)
        guard readBack == payload else {
            throw ValidationError("container write/read round-trip mismatch at \(scratch.path)")
        }
        try FileManager.default.removeItem(at: scratch)
        print("read+write: OK")

        // 4. Exit criterion (crit 4's "connected" signal): open the app's
        //    diagnostic FIFO write-only + non-blocking — the open succeeds
        //    only if a reader (the running app, with its diagnostic listener
        //    enabled) holds the other end — and write ONE line. The line is
        //    well under PIPE_BUF (512 B on Darwin), so the write is atomic.
        let fifo = container.appendingPathComponent(ProbeConstants.fifoRelativePath)
        let fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            print("fifo:       not connected at \(fifo.path) (\(reason))")
            print("            Launch GuessWho and enable debug mode in Settings, then re-run.")
            throw ExitCode.failure
        }
        defer { close(fd) }
        let line = "guesswho-cli probe connected pid=\(ProcessInfo.processInfo.processIdentifier)\n"
        let written = line.withCString { write(fd, $0, strlen($0)) }
        guard written == line.utf8.count else {
            throw ValidationError("FIFO write failed: \(String(cString: strerror(errno)))")
        }
        print("fifo:       wrote 1 line to \(fifo.path)")
    }
}
