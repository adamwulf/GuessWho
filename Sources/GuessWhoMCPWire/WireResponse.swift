import Foundation
import EasyMacMCP
import MCP

/// Responses sent from the app back to a relay helper. Same newline-JSON
/// framing rules as `WireRequest` (JSONEncoder only, never concatenation).
///
/// `ready` is the handshake acknowledgment: it echoes the `initialize`
/// request's (helperId, messageId) so the helper awaits it through the
/// ordinary response-matching path, and the helper must not open its
/// request pipe until it arrives. The app also answers `ping` with `ready`
/// (same echo semantics: "your session is live").
public enum WireResponse: Codable, Sendable {
    case ready(helperId: String, messageId: String)
    case error(helperId: String, messageId: String, code: WireErrorCode, message: String)
    case toolList(helperId: String, messageId: String, tools: [ToolMetadata], status: String?)

    case contactPage(helperId: String, messageId: String, page: WirePage<WireContactSummary>)
    case contact(helperId: String, messageId: String, contact: WireContact)
    case notePage(helperId: String, messageId: String, page: WirePage<WireNote>)
    case customFieldPage(helperId: String, messageId: String, page: WirePage<WireCustomField>)
    case groupPage(helperId: String, messageId: String, page: WirePage<WireGroup>)
    case eventPage(helperId: String, messageId: String, page: WirePage<WireEventSummary>)
    case event(helperId: String, messageId: String, event: WireEvent)
    case tagPage(helperId: String, messageId: String, page: WirePage<WireTag>)
    case guidePage(helperId: String, messageId: String, page: WirePage<WireGuide>)
    case guide(helperId: String, messageId: String, guide: WireGuide)
    case placePage(helperId: String, messageId: String, page: WirePage<WirePlace>)
    case linkPage(helperId: String, messageId: String, page: WirePage<WireLink>)

    // Write-tool results (plans/cli-mcp.md Phase 2): a write that creates or
    // updates a record echoes the record back (the same allowlisted DTO the
    // read tools use — the write-echo surface the INV-3 tests scan); one with
    // no natural payload (deletes, reorders, favorite flips) answers with a
    // plain fixed acknowledgement text.
    case note(helperId: String, messageId: String, note: WireNote)
    case customField(helperId: String, messageId: String, field: WireCustomField)
    case link(helperId: String, messageId: String, link: WireLink)
    case tag(helperId: String, messageId: String, tag: WireTag)
    case acknowledged(helperId: String, messageId: String, message: String)
}

extension WireResponse: MCPResponseProtocol {
    public var helperId: String {
        switch self {
        case .ready(let helperId, _),
             .error(let helperId, _, _, _),
             .toolList(let helperId, _, _, _),
             .contactPage(let helperId, _, _),
             .contact(let helperId, _, _),
             .notePage(let helperId, _, _),
             .customFieldPage(let helperId, _, _),
             .groupPage(let helperId, _, _),
             .eventPage(let helperId, _, _),
             .event(let helperId, _, _),
             .tagPage(let helperId, _, _),
             .guidePage(let helperId, _, _),
             .guide(let helperId, _, _),
             .placePage(let helperId, _, _),
             .linkPage(let helperId, _, _),
             .note(let helperId, _, _),
             .customField(let helperId, _, _),
             .link(let helperId, _, _),
             .tag(let helperId, _, _),
             .acknowledged(let helperId, _, _):
            return helperId
        }
    }

    public var messageId: String {
        switch self {
        case .ready(_, let messageId),
             .error(_, let messageId, _, _),
             .toolList(_, let messageId, _, _),
             .contactPage(_, let messageId, _),
             .contact(_, let messageId, _),
             .notePage(_, let messageId, _),
             .customFieldPage(_, let messageId, _),
             .groupPage(_, let messageId, _),
             .eventPage(_, let messageId, _),
             .event(_, let messageId, _),
             .tagPage(_, let messageId, _),
             .guidePage(_, let messageId, _),
             .guide(_, let messageId, _),
             .placePage(_, let messageId, _),
             .linkPage(_, let messageId, _),
             .note(_, let messageId, _),
             .customField(_, let messageId, _),
             .link(_, let messageId, _),
             .tag(_, let messageId, _),
             .acknowledged(_, let messageId, _):
            return messageId
        }
    }

    /// The same response re-addressed to a different (helperId, messageId)
    /// pair. The idempotency replay path needs this: a retried write returns
    /// the ORIGINAL call's payload, but the relay matches responses by the
    /// RETRY's message id, so the envelope must be restamped.
    public func readdressed(helperId: String, messageId: String) -> WireResponse {
        switch self {
        case .ready:
            return .ready(helperId: helperId, messageId: messageId)
        case .error(_, _, let code, let message):
            return .error(helperId: helperId, messageId: messageId, code: code, message: message)
        case .toolList(_, _, let tools, let status):
            return .toolList(helperId: helperId, messageId: messageId, tools: tools, status: status)
        case .contactPage(_, _, let page):
            return .contactPage(helperId: helperId, messageId: messageId, page: page)
        case .contact(_, _, let contact):
            return .contact(helperId: helperId, messageId: messageId, contact: contact)
        case .notePage(_, _, let page):
            return .notePage(helperId: helperId, messageId: messageId, page: page)
        case .customFieldPage(_, _, let page):
            return .customFieldPage(helperId: helperId, messageId: messageId, page: page)
        case .groupPage(_, _, let page):
            return .groupPage(helperId: helperId, messageId: messageId, page: page)
        case .eventPage(_, _, let page):
            return .eventPage(helperId: helperId, messageId: messageId, page: page)
        case .event(_, _, let event):
            return .event(helperId: helperId, messageId: messageId, event: event)
        case .tagPage(_, _, let page):
            return .tagPage(helperId: helperId, messageId: messageId, page: page)
        case .guidePage(_, _, let page):
            return .guidePage(helperId: helperId, messageId: messageId, page: page)
        case .guide(_, _, let guide):
            return .guide(helperId: helperId, messageId: messageId, guide: guide)
        case .placePage(_, _, let page):
            return .placePage(helperId: helperId, messageId: messageId, page: page)
        case .linkPage(_, _, let page):
            return .linkPage(helperId: helperId, messageId: messageId, page: page)
        case .note(_, _, let note):
            return .note(helperId: helperId, messageId: messageId, note: note)
        case .customField(_, _, let field):
            return .customField(helperId: helperId, messageId: messageId, field: field)
        case .link(_, _, let link):
            return .link(helperId: helperId, messageId: messageId, link: link)
        case .tag(_, _, let tag):
            return .tag(helperId: helperId, messageId: messageId, tag: tag)
        case .acknowledged(_, _, let message):
            return .acknowledged(helperId: helperId, messageId: messageId, message: message)
        }
    }

    /// The typed error payload if this is an error response.
    public var errorPayload: (code: WireErrorCode, message: String)? {
        if case .error(_, _, let code, let message) = self { return (code, message) }
        return nil
    }

    /// Agent-facing rendering. Data payloads become a JSON text block;
    /// errors become their plain message text ONLY (never the code name,
    /// never a serialized model — INV-3/banned-vocabulary).
    public func asCallToolResult() -> MCP.CallTool.Result {
        switch self {
        case .ready:
            return MCP.CallTool.Result(content: [.text("Ready.")], isError: false)
        case .error(_, _, _, let message):
            return MCP.CallTool.Result(content: [.text(message)], isError: true)
        case .toolList(_, _, let tools, _):
            let text = tools.map(\.name).joined(separator: "\n")
            return MCP.CallTool.Result(content: [.text(text)], isError: false)
        case .contactPage(_, _, let page):
            return Self.jsonResult(page)
        case .contact(_, _, let contact):
            return Self.jsonResult(contact)
        case .notePage(_, _, let page):
            return Self.jsonResult(page)
        case .customFieldPage(_, _, let page):
            return Self.jsonResult(page)
        case .groupPage(_, _, let page):
            return Self.jsonResult(page)
        case .eventPage(_, _, let page):
            return Self.jsonResult(page)
        case .event(_, _, let event):
            return Self.jsonResult(event)
        case .tagPage(_, _, let page):
            return Self.jsonResult(page)
        case .guidePage(_, _, let page):
            return Self.jsonResult(page)
        case .guide(_, _, let guide):
            return Self.jsonResult(guide)
        case .placePage(_, _, let page):
            return Self.jsonResult(page)
        case .linkPage(_, _, let page):
            return Self.jsonResult(page)
        case .note(_, _, let note):
            return Self.jsonResult(note)
        case .customField(_, _, let field):
            return Self.jsonResult(field)
        case .link(_, _, let link):
            return Self.jsonResult(link)
        case .tag(_, _, let tag):
            return Self.jsonResult(tag)
        case .acknowledged(_, _, let message):
            return MCP.CallTool.Result(content: [.text(message)], isError: false)
        }
    }

    public static func makeListToolsResponse(
        helperId: String, messageId: String, tools: [ToolMetadata]
    ) -> WireResponse {
        .toolList(helperId: helperId, messageId: messageId, tools: tools, status: nil)
    }

    public func asListToolsResult() -> MCP.ListTools.Result? {
        guard case .toolList(_, _, let tools, _) = self else { return nil }
        return MCP.ListTools.Result(tools: tools.map { metadata in
            MCP.Tool(
                name: metadata.name,
                description: metadata.description,
                inputSchema: metadata.inputSchema ?? ["type": "object"])
        })
    }

    /// The one agent-facing JSON encoder: stable key order so outputs are
    /// deterministic (and testable), readable indentation for the agent.
    public static let agentJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static func jsonResult<Payload: Encodable>(_ payload: Payload) -> MCP.CallTool.Result {
        do {
            let data = try agentJSONEncoder.encode(payload)
            let text = String(decoding: data, as: UTF8.self)
            return MCP.CallTool.Result(content: [.text(text)], isError: false)
        } catch {
            // Deliberately does NOT interpolate the payload or the error
            // object (either could carry model data).
            return MCP.CallTool.Result(
                content: [.text("Something went wrong preparing that result. Try again.")],
                isError: true)
        }
    }
}
