import ArgumentParser
import Darwin
import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import Logging

/// The GuessWho CLI root command tree (plans/cli-command-parity.md). It lives
/// in the package — WITHOUT `@main` — so `swift test` can parse and exercise
/// every subcommand; the app-target `guesswho-cli` shim installs the live
/// `CLIRuntime` and then calls `GuessWhoCLIRoot.main()`.
///
/// `run` hosts the MCP stdio server that bridges an MCP client (Claude
/// Desktop, Cursor, Claude Code…) to the running app over the shared-container
/// channel; `probe` is the packaging diagnostic. The tool commands live under
/// their noun groups (`contacts …`).
///
/// The binary is named `guesswho-cli` (never `guesswho`: on case-insensitive
/// APFS that would collide with the app executable `GuessWho` inside
/// Contents/MacOS). The user-facing `guesswho` command arrives later via the
/// /usr/local/bin symlink.
public struct GuessWhoCLIRoot: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "guesswho-cli",
        abstract: "Command-line access to GuessWho.",
        version: "0.1.0",
        subcommands: [Run.self, Probe.self, ContactsCommand.self]
    )

    public init() {}
}

public struct Run: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the MCP server that connects AI assistants to GuessWho."
    )

    public init() {}

    public func run() async throws {
        // EPIPE must surface as a thrown write error (the reconnect cue),
        // not kill the process.
        signal(SIGPIPE, SIG_IGN)

        let container = try CLIRuntime.current.containerURL()
        let helperId = RequestOrigin.mcp.makeHelperId()
        let logger = Logger(label: "com.milestonemade.guesswho.cli")

        let connection = RelayConnection(
            helperId: helperId, container: container, logger: logger)
        let server = RelayMCPServer(
            helperId: helperId, connection: connection,
            version: "0.1.0", logger: logger)

        // Graceful exit on Ctrl-C: tell the app we're leaving so it drops
        // our session immediately instead of waiting for the reaper.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            Task {
                await server.stop()
                Run.exit()
            }
        }
        signalSource.resume()

        try await server.start()
        try await server.waitUntilComplete()
    }
}

public struct Probe: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Diagnostic: resolve the shared container, verify write access, and signal the running app."
    )

    public init() {}

    public func run() throws {
        let groupID = try CLIRuntime.current.groupID()
        print("app group:  \(groupID)")

        // Exit criterion: the sandboxed helper resolves the group container.
        let container = try CLIRuntime.current.containerURL()
        print("container:  \(container.path)")

        // Exit criterion: the container is actually READ/WRITABLE at
        // runtime. A resolvable-but-unwritable path is a sandbox/entitlement
        // mismatch that would otherwise surface later disguised as an IPC
        // bug (plan Phase 0, crit 2).
        let scratch = container.appendingPathComponent("cli-probe-scratch.txt")
        let payload = "probe pid=\(ProcessInfo.processInfo.processIdentifier) at \(Date())"
        try payload.write(to: scratch, atomically: true, encoding: .utf8)
        let readBack = try String(contentsOf: scratch, encoding: .utf8)
        guard readBack == payload else {
            throw ValidationError("container write/read round-trip mismatch at \(scratch.path)")
        }
        try FileManager.default.removeItem(at: scratch)
        print("read+write: OK")

        // Exit criterion (crit 4's "connected" signal): open the app's
        // diagnostic pipe write-only + non-blocking — the open succeeds
        // only if a reader (the running app, with its diagnostic listener
        // enabled) holds the other end — and write ONE line. The line is
        // well under PIPE_BUF (512 B on Darwin), so the write is atomic.
        let fifo = container.appendingPathComponent(WireEnvironment.probeFIFORelativePath)
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
