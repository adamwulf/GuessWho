import Foundation

/// Where the relay↔app channel lives on disk, and the sizing rule the
/// shared announce channel must respect forever.
///
/// ## Channel topology (plans/cli-mcp.md Phase 1 transport change)
///
/// * ONE central **announce** FIFO (fixed path, the app pre-opens its reader
///   at listen time). It carries ONLY the tiny `initialize` / `deinitialize`
///   control messages. It is a many-writers→one-reader shared FIFO, which is
///   safe ONLY because those messages stay small: POSIX guarantees write
///   atomicity solely for writes ≤ PIPE_BUF, and **PIPE_BUF is 512 bytes on
///   Darwin** (`sys/syslimits.h`; it is 4096 on Linux — the 65536 figure
///   sometimes quoted is Linux's default pipe *capacity*, a different
///   thing). DESIGN RULE: no field of `initialize`/`deinitialize` may ever
///   grow unboundedly — do NOT add capability/metadata blobs to them, or
///   interleaving corruption re-arms on the control channel.
/// * One **request** FIFO per helper id (helper writes, app reads). Exactly
///   one writer per pipe makes interleaving structurally impossible at any
///   size, so large payloads (multi-KB notes) are safe without length
///   framing.
/// * One **response** FIFO per helper id (app writes, helper reads) — the
///   inherited design, unchanged.
///
/// The `ready` acknowledgement rides the helper's RESPONSE pipe, echoing
/// the `initialize` message id, so it needs no path of its own.
public enum WireEnvironment {
    /// POSIX-guaranteed atomic write ceiling for a shared FIFO on Darwin.
    public static let darwinPipeBuf = 512

    /// Hard cap on a single request line (bytes). The reader enforces this
    /// DURING line assembly — an oversize line is discarded as it streams,
    /// never buffered whole — so a runaway payload cannot exhaust host
    /// memory. Generous vs. any legitimate v1 request.
    public static let maxRequestLineBytes = 1_048_576

    /// Cap on one tool response's encoded payload (bytes). A page that would
    /// exceed this returns the typed `tooLarge` error with guidance, never a
    /// silent truncation (plans/cli-mcp.md bounded reads).
    public static let maxResponsePayloadBytes = 262_144

    /// The Info.plist key both processes read their shared container id
    /// from. The value is derived per-channel from ONE shared build variable
    /// (App/Config/CLIAppGroup-*.xcconfig, INV-4) — never hardcode it.
    public static let containerInfoPlistKey = "GuessWhoCLIAppGroup"

    public static func announcePipePath(container: URL) -> URL {
        container.appendingPathComponent("mcp_announce_pipe")
    }

    public static func requestPipePath(container: URL, helperId: String) -> URL {
        container.appendingPathComponent("mcp_request_pipe_\(helperId)")
    }

    public static func responsePipePath(container: URL, helperId: String) -> URL {
        container.appendingPathComponent("mcp_response_pipe_\(helperId)")
    }

    /// Filename prefixes for the per-helper FIFOs, for the optional launch
    /// sweep of orphans. Live helpers survive a sweep because they re-run
    /// the announce handshake (and re-create their FIFOs) on the next write
    /// failure — see the reconnect design in GuessWhoMCPTransport.
    public static let perHelperPipePrefixes = ["mcp_request_pipe_", "mcp_response_pipe_"]

    /// Resolves the shared container for a given group id.
    public static func containerURL(groupID: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
}

/// Which front door a request came through — the long-lived MCP stdio
/// bridge or a one-shot terminal command. Mirrors the shipped Muse design:
/// the origin rides as a prefix on the helper id so the app can pick the
/// matching enable/read-only gates without widening the wire schema.
public enum RequestOrigin: String, Sendable {
    case cli
    case mcp

    private var prefix: String { rawValue + "-" }

    /// Mint a fresh helper id for this origin. The token is UNGUESSABLE
    /// random (plans/cli-mcp.md threat model): 128 bits from the system
    /// CSPRNG, hex-encoded. Never sequential, never pid-derived — response
    /// isolation between helpers rests on nobody being able to guess
    /// another helper's id.
    public func makeHelperId() -> String {
        var generator = SystemRandomNumberGenerator()
        let hi = generator.next()
        let lo = generator.next()
        return prefix + String(format: "%016lx%016lx", hi, lo)
    }

    /// Recover the origin embedded in a helper id. `nil` for unrecognized
    /// prefixes — callers treat that as `.mcp` (the stricter surface) and
    /// log it.
    public static func from(helperId: String) -> RequestOrigin? {
        if helperId.hasPrefix(RequestOrigin.cli.prefix) { return .cli }
        if helperId.hasPrefix(RequestOrigin.mcp.prefix) { return .mcp }
        return nil
    }
}

/// The master-toggle keys in the shared-container UserDefaults. All OFF by
/// default; the user opts in via the app's settings. The app enforces them
/// PER-CALL server-side — hiding tools from listTools is UX, not the gate.
public enum MCPToggleKeys {
    public static let isMCPEnabled = "isMCPEnabled"
    public static let isCLIEnabled = "isCLIEnabled"
    public static let isMCPReadOnly = "isMCPReadOnly"
    public static let isCLIReadOnly = "isCLIReadOnly"
}
