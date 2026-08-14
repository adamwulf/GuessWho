import Foundation
import GuessWhoMCPWire

/// The injected environment the command tree runs against. ArgumentParser
/// commands are value types materialized by `parse`, so there is nowhere to
/// pass dependencies through an initializer — the standard ArgumentParser
/// testing seam is a settable static the entry point populates with live
/// values and tests overwrite with fakes.
///
/// The live values are wired by the app-target `@main` shim
/// (App/guesswho-cli), which alone can read the executable's embedded
/// Info.plist (the shared-container id). The core never reads the Info.plist —
/// it only calls these closures.
public struct CLIRuntime: Sendable {
    /// Resolves the shared container the relay channel lives in. Live: derived
    /// from the embedded Info.plist's app-group id.
    public var containerURL: @Sendable () throws -> URL
    /// The shared-container id string, for the `probe` diagnostic's report
    /// line. Live: read straight from the embedded Info.plist.
    public var groupID: @Sendable () throws -> String
    /// Builds the transport for one command send, over an already-resolved
    /// container. Live: `RelayCLITransport`; tests: a fake.
    public var makeTransport: @Sendable (_ container: URL) -> any CLITransport
    /// Where command output goes. Live: stdout/stderr; tests: a capturing sink.
    public var output: any CLIOutput

    public init(
        containerURL: @escaping @Sendable () throws -> URL,
        groupID: @escaping @Sendable () throws -> String,
        makeTransport: @escaping @Sendable (_ container: URL) -> any CLITransport,
        output: any CLIOutput
    ) {
        self.containerURL = containerURL
        self.groupID = groupID
        self.makeTransport = makeTransport
        self.output = output
    }

    /// The active runtime. The `@main` shim installs the live values before
    /// dispatching; tests overwrite it. The default is unconfigured: its
    /// environment closures throw and its transport factory yields a transport
    /// that throws, so a missing install surfaces as a clear error rather than
    /// silent misbehavior.
    ///
    /// `nonisolated(unsafe)`: this is the ArgumentParser testing seam — a
    /// settable static, written exactly once at startup (the `@main` shim,
    /// before any command runs) and read serially thereafter. There is no
    /// concurrent access to protect against, so the manual opt-out is correct
    /// and keeps the Swift 6 app target (which consumes this from strict-
    /// concurrency code) building.
    nonisolated(unsafe) public static var current = CLIRuntime(
        containerURL: { throw CLIRuntimeError.notConfigured },
        groupID: { throw CLIRuntimeError.notConfigured },
        makeTransport: { _ in UnconfiguredCLITransport() },
        output: StandardCLIOutput()
    )
}

/// Raised when a command runs before the runtime is installed — only possible
/// through misuse (a live binary always installs it in `@main`; a test always
/// sets `CLIRuntime.current`).
public enum CLIRuntimeError: Error, CustomStringConvertible {
    case notConfigured
    public var description: String { "The CLI runtime was not configured." }
}

private struct UnconfiguredCLITransport: CLITransport {
    func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse {
        throw CLIRuntimeError.notConfigured
    }
}
