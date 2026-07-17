import ArgumentParser
import Darwin
import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import Logging

/// The GuessWho relay CLI (plans/cli-mcp.md). `run` hosts the MCP stdio
/// server that bridges an MCP client (Claude Desktop, Cursor, Claude
/// Code…) to the running app over the shared-container channel; `probe`
/// is the Phase 0 packaging diagnostic.
///
/// The binary is named `guesswho-cli` (never `guesswho`: on case-insensitive
/// APFS that would collide with the app executable `GuessWho` inside
/// Contents/MacOS). The user-facing `guesswho` command arrives in Phase 3 via
/// the /usr/local/bin symlink.
@main
struct GuessWhoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guesswho-cli",
        abstract: "Command-line access to GuessWho.",
        version: "0.1.0",
        subcommands: [Run.self, Probe.self]
    )

    /// Bootstrap swift-log to STDERR before ArgumentParser dispatches:
    /// stdout carries the MCP protocol stream under `run`, so any library
    /// log reaching stdout would corrupt it.
    static func main() async {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .warning
            return handler
        }
        await Self.main(nil)
    }
}

/// Shared environment resolution for the subcommands: the per-channel
/// shared-container id comes from the Info.plist embedded in this binary's
/// __TEXT,__info_plist section — the same value the app derives, because
/// both expand the ONE shared build var (INV-4).
enum CLIEnvironment {
    static func groupID() throws -> String {
        guard
            let groupID = Bundle.main.object(
                forInfoDictionaryKey: WireEnvironment.containerInfoPlistKey) as? String,
            !groupID.isEmpty
        else {
            throw ValidationError(
                "\(WireEnvironment.containerInfoPlistKey) is missing from the embedded Info.plist — the xcconfig → Info.plist wiring is broken.")
        }
        return groupID
    }

    static func container() throws -> URL {
        let groupID = try groupID()
        guard let container = WireEnvironment.containerURL(groupID: groupID) else {
            throw ValidationError(
                "could not resolve the shared container for \(groupID) — entitlement/group-id mismatch.")
        }
        return container
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the MCP server that connects AI assistants to GuessWho."
    )

    func run() async throws {
        // EPIPE must surface as a thrown write error (the reconnect cue),
        // not kill the process.
        signal(SIGPIPE, SIG_IGN)

        let container = try CLIEnvironment.container()
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

/// Constants shared with the app side of the Phase 0 diagnostic. The app's
/// `CLIProbeListener` (App/GuessWho/Support/CLIProbeListener.swift) creates
/// the FIFO at the same container-relative path.
enum ProbeConstants {
    /// Container-relative path of the app's diagnostic FIFO.
    static let fifoRelativePath = "Diagnostics/cli-probe.fifo"
}

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Diagnostic: resolve the shared container, verify write access, and signal the running app."
    )

    func run() throws {
        let groupID = try CLIEnvironment.groupID()
        print("app group:  \(groupID)")

        // Exit criterion: the sandboxed helper resolves the group container.
        let container = try CLIEnvironment.container()
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
        // diagnostic FIFO write-only + non-blocking — the open succeeds
        // only if a reader (the running app, with its diagnostic listener
        // enabled) holds the other end — and write ONE line. The line is
        // well under PIPE_BUF (512 B on Darwin), so the write is atomic.
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
