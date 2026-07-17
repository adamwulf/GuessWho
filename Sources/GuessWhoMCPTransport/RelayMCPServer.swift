import Foundation
import EasyMCP
import EasyMacMCP
import GuessWhoMCPWire
import Logging
import MCP

/// The MCP stdio server the `guesswho-cli run` command hosts: a thin
/// bridge from an MCP client (Claude Desktop, Cursor, Claude Code…) to the
/// running app via `RelayConnection`. Mirrors EasyMacMCP's `EasyMCPHelper`
/// with the split-pipe topology's connection manager in place of the
/// single shared request pipe.
///
/// No-host behavior (the most common real state — the client spawns us
/// while the app isn't running): `tools/list` returns a single status tool
/// whose description carries the plain "GuessWho isn't open…" instruction,
/// so the agent has something to relay AND something to poke to re-check.
/// When a later call finds the app again, we emit
/// `notifications/tools/list_changed` so the client re-queries.
public final class RelayMCPServer: @unchecked Sendable {
    /// Local status tool served when the app isn't reachable. Calling it
    /// re-probes and reports, so an agent can follow "open the app" with a
    /// cheap re-check.
    public static let statusToolName = "guesswho_status"

    private let helperId: String
    private let connection: RelayConnection
    private let logger: Logger?
    private let server: MCP.Server
    private var transport: (any MCP.Transport)?
    private var serverTask: Task<Void, Swift.Error>?
    /// Whether the last tools/list we served was the no-host fallback —
    /// drives the list_changed nudge after a successful reconnect.
    private var servedNoHostList = false

    public init(helperId: String, connection: RelayConnection, version: String, logger: Logger? = nil) {
        self.helperId = helperId
        self.connection = connection
        self.logger = logger
        self.server = MCP.Server(
            name: "GuessWho",
            version: version,
            capabilities: MCP.Server.Capabilities(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: true)
            )
        )
    }

    public func start() async throws {
        let stdio = MCP.StdioTransport(logger: logger)
        transport = stdio
        await registerHandlers()

        // Best-effort early connect so the first tools/list is fast; the
        // app being closed is normal and every handler copes.
        try? await connection.connect()

        serverTask = Task { [server, logger] in
            do {
                try await server.start(transport: stdio)
            } catch {
                logger?.error("RELAY_SERVER: failed to start: \(error)")
                throw error
            }
        }
    }

    public func waitUntilComplete() async throws {
        try await serverTask?.value
        await server.waitUntilCompleted()
        await connection.disconnect()
    }

    public func stop() async {
        await connection.disconnect()
        await server.stop()
        serverTask?.cancel()
    }

    // MARK: - Handlers

    private func registerHandlers() async {
        await server.withMethodHandler(MCP.ListTools.self) { [weak self] _ in
            guard let self else { return MCP.ListTools.Result(tools: []) }
            return await self.handleListTools()
        }

        await server.withMethodHandler(MCP.CallTool.self) { [weak self] params in
            guard let self else {
                return MCP.CallTool.Result(
                    content: [.text(WireErrorMessage.notRunning)], isError: true)
            }
            return await self.handleCallTool(params)
        }

        await server.withMethodHandler(MCP.ListPrompts.self) { _ in
            ListPrompts.Result(prompts: [])
        }
        await server.withMethodHandler(MCP.ListResources.self) { _ in
            ListResources.Result(resources: [])
        }
    }

    private func handleListTools() async -> MCP.ListTools.Result {
        do {
            let messageId = UUID().uuidString
            let response = try await connection.send(
                .listTools(helperId: helperId, messageId: messageId), timeout: 10)
            if let result = response.asListToolsResult() {
                servedNoHostList = false
                return result
            }
            // An error response (e.g. capability turned off) still lists as
            // "no tools"; surface its message through the status tool.
            if let payload = response.errorPayload {
                return noHostList(status: payload.message)
            }
            return noHostList(status: WireErrorMessage.noHostStatus)
        } catch {
            logger?.info("RELAY_SERVER: tools/list without host: \(error)")
            return noHostList(status: WireErrorMessage.noHostStatus)
        }
    }

    private func handleCallTool(_ params: MCP.CallTool.Parameters) async -> MCP.CallTool.Result {
        if params.name == Self.statusToolName {
            return await handleStatusTool()
        }

        let request: WireRequest
        do {
            request = try WireRequest.create(
                helperId: helperId, messageId: UUID().uuidString, parameters: params)
        } catch let error as WireRequestError {
            return MCP.CallTool.Result(content: [.text(error.description)], isError: true)
        } catch {
            return MCP.CallTool.Result(
                content: [.text("That tool call couldn't be understood. Check the arguments and try again.")],
                isError: true)
        }

        let timeout = request.tool?.timeout ?? 10
        do {
            let wasConnected = await connection.connected
            let response = try await connection.send(request, timeout: timeout)
            if !wasConnected {
                await nudgeToolListChanged()
            }
            return response.asCallToolResult()
        } catch let error as RelayConnectionError {
            return MCP.CallTool.Result(content: [.text(error.description)], isError: true)
        } catch {
            return MCP.CallTool.Result(content: [.text(WireErrorMessage.hostNotReady)], isError: true)
        }
    }

    private func handleStatusTool() async -> MCP.CallTool.Result {
        do {
            if await !connection.connected {
                try await connection.connect()
            }
            let response = try await connection.send(
                .ping(helperId: helperId, messageId: UUID().uuidString), timeout: 5)
            if response.errorPayload == nil {
                await nudgeToolListChanged()
                return MCP.CallTool.Result(
                    content: [.text("GuessWho is open. List tools again to see what's available.")],
                    isError: false)
            }
            return MCP.CallTool.Result(
                content: [.text(response.errorPayload?.message ?? WireErrorMessage.hostNotReady)],
                isError: true)
        } catch let error as RelayConnectionError {
            return MCP.CallTool.Result(content: [.text(error.description)], isError: true)
        } catch {
            return MCP.CallTool.Result(content: [.text(WireErrorMessage.notRunning)], isError: true)
        }
    }

    private func noHostList(status: String) -> MCP.ListTools.Result {
        servedNoHostList = true
        return MCP.ListTools.Result(tools: [
            MCP.Tool(
                name: Self.statusToolName,
                description: status + " Call this tool to re-check.",
                inputSchema: ["type": "object"])
        ])
    }

    /// After a reconnect that followed a no-host list, tell the client the
    /// tool list changed so it re-queries and swaps the status stub for
    /// the real tools.
    private func nudgeToolListChanged() async {
        guard servedNoHostList else { return }
        servedNoHostList = false
        do {
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            logger?.info("RELAY_SERVER: list_changed nudge failed: \(error)")
        }
    }
}
