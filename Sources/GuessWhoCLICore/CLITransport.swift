import Foundation
import GuessWhoMCPTransport
import GuessWhoMCPWire
import Logging

/// The one send step of the shared funnel, behind a protocol so tests can
/// substitute a fake (a canned response, or a throwing `RelayConnectionError`)
/// without a running app. The live conformance wraps `RelayConnection`,
/// exactly the same object the MCP relay sends through.
public protocol CLITransport: Sendable {
    /// Send one request and await its response. Throws `RelayConnectionError`
    /// for a transport-level failure — the funnel maps that to exit 69.
    func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse
}

/// Live transport: one `RelayConnection` per command invocation over the
/// shared container, minted with the request's own helper id so responses
/// route back to us. Generalizes the retired `CLICommandClient`
/// (App/guesswho-cli/ContactsCommand.swift): it connects on send, awaits the
/// response, then disconnects so the app drops our session immediately.
public struct RelayCLITransport: CLITransport {
    private let container: URL

    public init(container: URL) {
        self.container = container
    }

    public func send(_ request: WireRequest, timeout: TimeInterval) async throws -> WireResponse {
        let connection = RelayConnection(
            helperId: request.helperId,
            container: container,
            logger: Logger(label: "com.milestonemade.guesswho.cli.command")
        )
        do {
            let response = try await connection.send(request, timeout: timeout)
            await connection.disconnect()
            return response
        } catch {
            await connection.disconnect()
            // RelayConnectionError propagates verbatim; the funnel renders its
            // description and maps it to the transport exit code.
            throw error
        }
    }
}
