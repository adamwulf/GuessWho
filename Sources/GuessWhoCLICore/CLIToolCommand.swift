import ArgumentParser
import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import MCP

/// A CLI command that maps one-to-one onto an `MCPTool`. The `tool` static is
/// the parity key (§3.4); `argumentBag()` turns the parsed flags into the MCP
/// parameter bag; and ONE shared `run()` (below) routes every such command
/// through the SAME production funnel the MCP relay uses
/// (`RelayMCPServer.handleCallTool`):
///
///   build:  WireRequest.create(helperId:messageId:parameters:)  — shared
///   send:   CLITransport.send(request, timeout: tool.timeout)     — shared
///   render: WireResponse.asCallToolResult()                       — shared
///
/// Building through `WireRequest.create` means required-field checks, closed
/// field sets, enum validation, and the note-argument rejection are the exact
/// already-tested production path — not a second copy in the CLI.
public protocol CLIToolCommand: AsyncParsableCommand {
    /// The MCP tool this command sends. The parity guard reads it.
    static var tool: MCPTool { get }

    /// Turn parsed flags/positionals into the MCP parameter bag that
    /// `WireRequest.create` consumes. Throw `CLIUsageError` (or let a
    /// `WireRequestError` surface) for input the command itself rejects.
    func argumentBag() throws -> [String: Value]

    /// Render a successful (non-transport-error) response. The default renders
    /// via `WireResponse.asCallToolResult()`; photo commands override for the
    /// bespoke byte path.
    func renderResponse(_ response: WireResponse, to sink: any CLIOutput) throws
}

extension CLIToolCommand {
    /// Default rendering: the shared JSON/ack/error renderer. Throws
    /// `ExitCode` for a non-success outcome so ArgumentParser exits with the
    /// right code (the message is already on stderr).
    public func renderResponse(_ response: WireResponse, to sink: any CLIOutput) throws {
        let code = CLIResponseRenderer.render(response, to: sink)
        if code != .success { throw ExitCode(code.rawValue) }
    }

    /// The ONE shared funnel every tool command runs. Kept as the protocol's
    /// default `run()`, so a conforming command declares only its flags,
    /// `tool`, and `argumentBag()`.
    public func run() async throws {
        let runtime = CLIRuntime.current
        let sink = runtime.output

        // 1. Build the request through the production builder. A rejected
        //    argument (missing/empty/invalid, note-shaped) is a usage error.
        let request: WireRequest
        do {
            let parameters = MCP.CallTool.Parameters(
                name: Self.tool.rawValue, arguments: try argumentBag())
            request = try WireRequest.create(
                helperId: RequestOrigin.cli.makeHelperId(),
                messageId: UUID().uuidString,
                parameters: parameters)
        } catch let error as CLIUsageError {
            sink.writeError(error.message)
            throw ExitCode(CLIExitCode.usage.rawValue)
        } catch let error as WireRequestError {
            sink.writeError(error.description)
            throw ExitCode(CLIExitCode.usage.rawValue)
        }

        // 2. Resolve the container and build the transport.
        let container: URL
        do {
            container = try runtime.containerURL()
        } catch {
            sink.writeError(cliMessage(for: error))
            throw ExitCode(CLIExitCode.transportUnavailable.rawValue)
        }
        let transport = runtime.makeTransport(container)

        // 3. Send through the shared transport with the tool's own timeout
        //    (which gives contacts_delete its 300 s human window for free).
        let response: WireResponse
        do {
            response = try await transport.send(request, timeout: Self.tool.timeout)
        } catch let error as RelayConnectionError {
            sink.writeError(error.description)
            throw ExitCode(CLIExitCode.code(for: error).rawValue)
        }

        // 4. Render (default = shared renderer; photo commands override).
        try renderResponse(response, to: sink)
    }
}

/// A plain message for an environment failure surfaced from the runtime's
/// `containerURL()` closure. The live resolver and the unconfigured default
/// both throw `CustomStringConvertible` errors whose description is the plain
/// message, which is what `String(describing:)` returns for them.
func cliMessage(for error: Error) -> String {
    String(describing: error)
}
