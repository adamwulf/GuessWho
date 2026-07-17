import Foundation
import EasyMacMCP
import MCP

/// Requests sent from a relay helper to the app. One newline-terminated
/// JSON line per request, serialized ONLY through `JSONEncoder` (the
/// framing-injection invariant: a value containing `\n`/`\r` stays one
/// logical message because the encoder escapes it — nothing may ever
/// hand-concatenate JSON onto a pipe).
///
/// Control messages:
/// * `initialize` / `deinitialize` ride the shared ANNOUNCE channel and
///   must stay tiny (≤ PIPE_BUF; see `WireEnvironment`).
/// * `ping` rides the helper's own request pipe; it refreshes the app-side
///   liveness clock so an idle helper isn't reaped, and its reply doubles
///   as the helper's host-is-alive probe.
/// * `initialize` carries a `messageId` so the app's `ready` acknowledgment
///   can echo it through the existing response-matching path.
public enum WireRequest: Codable, Sendable {
    case initialize(helperId: String, messageId: String)
    case deinitialize(helperId: String)
    case ping(helperId: String, messageId: String)
    case listTools(helperId: String, messageId: String)

    case contactsSearch(helperId: String, messageId: String, query: String, limit: Int?, cursor: String?)
    case contactsGet(helperId: String, messageId: String, contactId: String)
    case contactsListNotes(helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?)
    case contactsListCustomFields(helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?)
    case contactsListLinkedContacts(helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?)
    case contactsListLinkedOrganizations(helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?)
    case contactsListFavorites(helperId: String, messageId: String, limit: Int?, cursor: String?)
    case contactsListGroups(helperId: String, messageId: String, limit: Int?, cursor: String?)
    case groupsListMembers(helperId: String, messageId: String, groupId: String, limit: Int?, cursor: String?)
    case eventsList(helperId: String, messageId: String, startDate: String, endDate: String, limit: Int?, cursor: String?)
    case eventsGet(helperId: String, messageId: String, eventId: String)
    case eventsListTags(helperId: String, messageId: String, eventId: String, limit: Int?, cursor: String?)
    case guidesList(helperId: String, messageId: String, limit: Int?, cursor: String?)
    case guidesGet(helperId: String, messageId: String, guideId: String)
    case placesList(helperId: String, messageId: String, guideId: String?, limit: Int?, cursor: String?)

    /// The tool identity for tool-call cases; nil for control messages.
    public var tool: MCPTool? {
        switch self {
        case .initialize, .deinitialize, .ping, .listTools: return nil
        case .contactsSearch: return .contactsSearch
        case .contactsGet: return .contactsGet
        case .contactsListNotes: return .contactsListNotes
        case .contactsListCustomFields: return .contactsListCustomFields
        case .contactsListLinkedContacts: return .contactsListLinkedContacts
        case .contactsListLinkedOrganizations: return .contactsListLinkedOrganizations
        case .contactsListFavorites: return .contactsListFavorites
        case .contactsListGroups: return .contactsListGroups
        case .groupsListMembers: return .groupsListMembers
        case .eventsList: return .eventsList
        case .eventsGet: return .eventsGet
        case .eventsListTags: return .eventsListTags
        case .guidesList: return .guidesList
        case .guidesGet: return .guidesGet
        case .placesList: return .placesList
        }
    }
}

extension WireRequest: MCPRequestProtocol {
    public var helperId: String {
        switch self {
        case .initialize(let helperId, _),
             .deinitialize(let helperId),
             .ping(let helperId, _),
             .listTools(let helperId, _),
             .contactsSearch(let helperId, _, _, _, _),
             .contactsGet(let helperId, _, _),
             .contactsListNotes(let helperId, _, _, _, _),
             .contactsListCustomFields(let helperId, _, _, _, _),
             .contactsListLinkedContacts(let helperId, _, _, _, _),
             .contactsListLinkedOrganizations(let helperId, _, _, _, _),
             .contactsListFavorites(let helperId, _, _, _),
             .contactsListGroups(let helperId, _, _, _),
             .groupsListMembers(let helperId, _, _, _, _),
             .eventsList(let helperId, _, _, _, _, _),
             .eventsGet(let helperId, _, _),
             .eventsListTags(let helperId, _, _, _, _),
             .guidesList(let helperId, _, _, _),
             .guidesGet(let helperId, _, _),
             .placesList(let helperId, _, _, _, _):
            return helperId
        }
    }

    public var messageId: String {
        switch self {
        case .initialize(_, let messageId),
             .ping(_, let messageId),
             .listTools(_, let messageId),
             .contactsSearch(_, let messageId, _, _, _),
             .contactsGet(_, let messageId, _),
             .contactsListNotes(_, let messageId, _, _, _),
             .contactsListCustomFields(_, let messageId, _, _, _),
             .contactsListLinkedContacts(_, let messageId, _, _, _),
             .contactsListLinkedOrganizations(_, let messageId, _, _, _),
             .contactsListFavorites(_, let messageId, _, _),
             .contactsListGroups(_, let messageId, _, _),
             .groupsListMembers(_, let messageId, _, _, _),
             .eventsList(_, let messageId, _, _, _, _),
             .eventsGet(_, let messageId, _),
             .eventsListTags(_, let messageId, _, _, _),
             .guidesList(_, let messageId, _, _),
             .guidesGet(_, let messageId, _),
             .placesList(_, let messageId, _, _, _):
            return messageId
        case .deinitialize(let helperId):
            return "deinit_\(helperId)"
        }
    }

    public var isInitialize: Bool {
        if case .initialize = self { return true }
        return false
    }

    public var isDeinitialize: Bool {
        if case .deinitialize = self { return true }
        return false
    }

    public var isPing: Bool {
        if case .ping = self { return true }
        return false
    }

    public static func makeListToolsRequest(helperId: String, messageId: String) -> WireRequest {
        .listTools(helperId: helperId, messageId: messageId)
    }

    /// Build a tool-call request from MCP call parameters, validating
    /// argument presence and types. Throws `WireRequestError` with a plain,
    /// specific message for anything malformed — that message is what the
    /// agent reads.
    public static func create(
        helperId: String, messageId: String, parameters: MCP.CallTool.Parameters
    ) throws -> WireRequest {
        guard let tool = MCPTool(rawValue: parameters.name) else {
            throw WireRequestError.unknownTool(parameters.name)
        }
        let args = ToolArguments(parameters.arguments, toolName: parameters.name)

        switch tool {
        case .contactsSearch:
            return .contactsSearch(
                helperId: helperId, messageId: messageId,
                query: try args.requiredString("query"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .contactsGet:
            return .contactsGet(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"))
        case .contactsListNotes:
            return .contactsListNotes(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .contactsListCustomFields:
            return .contactsListCustomFields(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .contactsListLinkedContacts:
            return .contactsListLinkedContacts(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .contactsListLinkedOrganizations:
            return .contactsListLinkedOrganizations(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .contactsListFavorites:
            return .contactsListFavorites(
                helperId: helperId, messageId: messageId,
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .contactsListGroups:
            return .contactsListGroups(
                helperId: helperId, messageId: messageId,
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .groupsListMembers:
            return .groupsListMembers(
                helperId: helperId, messageId: messageId,
                groupId: try args.requiredString("groupId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .eventsList:
            return .eventsList(
                helperId: helperId, messageId: messageId,
                startDate: try args.requiredString("startDate"),
                endDate: try args.requiredString("endDate"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .eventsGet:
            return .eventsGet(
                helperId: helperId, messageId: messageId,
                eventId: try args.requiredString("eventId"))
        case .eventsListTags:
            return .eventsListTags(
                helperId: helperId, messageId: messageId,
                eventId: try args.requiredString("eventId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .guidesList:
            return .guidesList(
                helperId: helperId, messageId: messageId,
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        case .guidesGet:
            return .guidesGet(
                helperId: helperId, messageId: messageId,
                guideId: try args.requiredString("guideId"))
        case .placesList:
            return .placesList(
                helperId: helperId, messageId: messageId,
                guideId: try args.optionalString("guideId"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))
        }
    }
}

/// Validation errors from `WireRequest.create`. The description is
/// agent-facing: specific and plain (the `invalidParams` contract).
public enum WireRequestError: Error, CustomStringConvertible {
    case unknownTool(String)
    case missingArgument(tool: String, name: String)
    case invalidArgument(tool: String, name: String, expected: String)

    public var description: String {
        switch self {
        case .unknownTool(let name):
            return "There is no tool named \(name). List tools to see what is available."
        case .missingArgument(let tool, let name):
            return "\(tool) requires the \(name) argument."
        case .invalidArgument(let tool, let name, let expected):
            return "The \(name) argument for \(tool) must be \(expected)."
        }
    }
}

/// Typed accessors over MCP call arguments.
private struct ToolArguments {
    private let values: [String: Value]
    private let toolName: String

    init(_ values: [String: Value]?, toolName: String = "") {
        self.values = values ?? [:]
        self.toolName = toolName
    }

    func requiredString(_ name: String) throws -> String {
        guard let value = values[name], value != .null else {
            throw WireRequestError.missingArgument(tool: toolName, name: name)
        }
        guard let string = value.stringValue, !string.isEmpty else {
            throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "a non-empty string")
        }
        return string
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name], value != .null else { return nil }
        guard let string = value.stringValue else {
            throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "a string")
        }
        return string
    }

    func optionalInt(_ name: String) throws -> Int? {
        guard let value = values[name], value != .null else { return nil }
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double == double.rounded() { return Int(double) }
        if let string = value.stringValue, let int = Int(string) { return int }
        throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "a whole number")
    }
}
