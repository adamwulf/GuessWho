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

    // Write tools (plans/cli-mcp.md Phase 2). Every write carries an
    // optional client-supplied `idempotencyToken`: the app dedups a retried
    // token within a host-run-scoped window, so a timeout-then-retry can't
    // double-apply a non-idempotent write.
    case contactsAddNote(helperId: String, messageId: String, contactId: String, body: String, idempotencyToken: String?)
    case contactsEditNote(helperId: String, messageId: String, contactId: String, noteId: String, body: String, idempotencyToken: String?)
    case contactsDeleteNote(helperId: String, messageId: String, contactId: String, noteId: String, idempotencyToken: String?)
    case contactsSetCustomField(helperId: String, messageId: String, contactId: String, name: String, type: String?, value: String, idempotencyToken: String?)
    case contactsDeleteCustomField(helperId: String, messageId: String, contactId: String, fieldId: String, idempotencyToken: String?)
    case contactsAddLinkedContact(helperId: String, messageId: String, contactId: String, personId: String, note: String?, idempotencyToken: String?)
    case contactsAddLinkedOrganization(helperId: String, messageId: String, contactId: String, organizationId: String, note: String?, idempotencyToken: String?)
    case contactsRemoveLinkedContact(helperId: String, messageId: String, linkId: String, idempotencyToken: String?)
    case contactsSetFavorite(helperId: String, messageId: String, contactId: String, favorite: Bool, idempotencyToken: String?)
    case eventsAddTag(helperId: String, messageId: String, eventId: String, text: String, idempotencyToken: String?)
    case eventsEditTag(helperId: String, messageId: String, eventId: String, tagId: String, text: String, idempotencyToken: String?)
    case eventsDeleteTag(helperId: String, messageId: String, eventId: String, tagId: String, idempotencyToken: String?)
    case guidesCreate(helperId: String, messageId: String, name: String, places: [WireNewPlace], idempotencyToken: String?)
    case guidesDelete(helperId: String, messageId: String, guideId: String, idempotencyToken: String?)
    case guidesReorderPlaces(helperId: String, messageId: String, guideId: String, placeIds: [String], idempotencyToken: String?)
    case placesDelete(helperId: String, messageId: String, placeId: String, idempotencyToken: String?)

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
        case .contactsAddNote: return .contactsAddNote
        case .contactsEditNote: return .contactsEditNote
        case .contactsDeleteNote: return .contactsDeleteNote
        case .contactsSetCustomField: return .contactsSetCustomField
        case .contactsDeleteCustomField: return .contactsDeleteCustomField
        case .contactsAddLinkedContact: return .contactsAddLinkedContact
        case .contactsAddLinkedOrganization: return .contactsAddLinkedOrganization
        case .contactsRemoveLinkedContact: return .contactsRemoveLinkedContact
        case .contactsSetFavorite: return .contactsSetFavorite
        case .eventsAddTag: return .eventsAddTag
        case .eventsEditTag: return .eventsEditTag
        case .eventsDeleteTag: return .eventsDeleteTag
        case .guidesCreate: return .guidesCreate
        case .guidesDelete: return .guidesDelete
        case .guidesReorderPlaces: return .guidesReorderPlaces
        case .placesDelete: return .placesDelete
        }
    }

    /// The client-supplied idempotency token, if this is a write request
    /// that carries one. Nil for reads, control messages, and writes the
    /// client didn't token.
    public var idempotencyToken: String? {
        switch self {
        case .contactsAddNote(_, _, _, _, let token),
             .contactsEditNote(_, _, _, _, _, let token),
             .contactsDeleteNote(_, _, _, _, let token),
             .contactsSetCustomField(_, _, _, _, _, _, let token),
             .contactsDeleteCustomField(_, _, _, _, let token),
             .contactsAddLinkedContact(_, _, _, _, _, let token),
             .contactsAddLinkedOrganization(_, _, _, _, _, let token),
             .contactsRemoveLinkedContact(_, _, _, let token),
             .contactsSetFavorite(_, _, _, _, let token),
             .eventsAddTag(_, _, _, _, let token),
             .eventsEditTag(_, _, _, _, _, let token),
             .eventsDeleteTag(_, _, _, _, let token),
             .guidesCreate(_, _, _, _, let token),
             .guidesDelete(_, _, _, let token),
             .guidesReorderPlaces(_, _, _, _, let token),
             .placesDelete(_, _, _, let token):
            return token
        default:
            return nil
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
             .placesList(let helperId, _, _, _, _),
             .contactsAddNote(let helperId, _, _, _, _),
             .contactsEditNote(let helperId, _, _, _, _, _),
             .contactsDeleteNote(let helperId, _, _, _, _),
             .contactsSetCustomField(let helperId, _, _, _, _, _, _),
             .contactsDeleteCustomField(let helperId, _, _, _, _),
             .contactsAddLinkedContact(let helperId, _, _, _, _, _),
             .contactsAddLinkedOrganization(let helperId, _, _, _, _, _),
             .contactsRemoveLinkedContact(let helperId, _, _, _),
             .contactsSetFavorite(let helperId, _, _, _, _),
             .eventsAddTag(let helperId, _, _, _, _),
             .eventsEditTag(let helperId, _, _, _, _, _),
             .eventsDeleteTag(let helperId, _, _, _, _),
             .guidesCreate(let helperId, _, _, _, _),
             .guidesDelete(let helperId, _, _, _),
             .guidesReorderPlaces(let helperId, _, _, _, _),
             .placesDelete(let helperId, _, _, _):
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
             .placesList(_, let messageId, _, _, _),
             .contactsAddNote(_, let messageId, _, _, _),
             .contactsEditNote(_, let messageId, _, _, _, _),
             .contactsDeleteNote(_, let messageId, _, _, _),
             .contactsSetCustomField(_, let messageId, _, _, _, _, _),
             .contactsDeleteCustomField(_, let messageId, _, _, _),
             .contactsAddLinkedContact(_, let messageId, _, _, _, _),
             .contactsAddLinkedOrganization(_, let messageId, _, _, _, _),
             .contactsRemoveLinkedContact(_, let messageId, _, _),
             .contactsSetFavorite(_, let messageId, _, _, _),
             .eventsAddTag(_, let messageId, _, _, _),
             .eventsEditTag(_, let messageId, _, _, _, _),
             .eventsDeleteTag(_, let messageId, _, _, _),
             .guidesCreate(_, let messageId, _, _, _),
             .guidesDelete(_, let messageId, _, _),
             .guidesReorderPlaces(_, let messageId, _, _, _),
             .placesDelete(_, let messageId, _, _):
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

        case .contactsAddNote:
            return .contactsAddNote(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                body: try args.requiredString("body"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsEditNote:
            return .contactsEditNote(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                noteId: try args.requiredString("noteId"),
                body: try args.requiredString("body"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsDeleteNote:
            return .contactsDeleteNote(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                noteId: try args.requiredString("noteId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsSetCustomField:
            return .contactsSetCustomField(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                name: try args.requiredString("name"),
                type: try args.optionalString("type"),
                value: try args.requiredString("value"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsDeleteCustomField:
            return .contactsDeleteCustomField(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                fieldId: try args.requiredString("fieldId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsAddLinkedContact:
            return .contactsAddLinkedContact(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                personId: try args.requiredString("personId"),
                note: try args.optionalString("note"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsAddLinkedOrganization:
            return .contactsAddLinkedOrganization(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                organizationId: try args.requiredString("organizationId"),
                note: try args.optionalString("note"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsRemoveLinkedContact:
            return .contactsRemoveLinkedContact(
                helperId: helperId, messageId: messageId,
                linkId: try args.requiredString("linkId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsSetFavorite:
            return .contactsSetFavorite(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                favorite: try args.requiredBool("favorite"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .eventsAddTag:
            return .eventsAddTag(
                helperId: helperId, messageId: messageId,
                eventId: try args.requiredString("eventId"),
                text: try args.requiredString("text"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .eventsEditTag:
            return .eventsEditTag(
                helperId: helperId, messageId: messageId,
                eventId: try args.requiredString("eventId"),
                tagId: try args.requiredString("tagId"),
                text: try args.requiredString("text"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .eventsDeleteTag:
            return .eventsDeleteTag(
                helperId: helperId, messageId: messageId,
                eventId: try args.requiredString("eventId"),
                tagId: try args.requiredString("tagId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .guidesCreate:
            return .guidesCreate(
                helperId: helperId, messageId: messageId,
                name: try args.requiredString("name"),
                places: try args.optionalNewPlaces("places") ?? [],
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .guidesDelete:
            return .guidesDelete(
                helperId: helperId, messageId: messageId,
                guideId: try args.requiredString("guideId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .guidesReorderPlaces:
            return .guidesReorderPlaces(
                helperId: helperId, messageId: messageId,
                guideId: try args.requiredString("guideId"),
                placeIds: try args.requiredStringArray("placeIds"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .placesDelete:
            return .placesDelete(
                helperId: helperId, messageId: messageId,
                placeId: try args.requiredString("placeId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
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

    func requiredBool(_ name: String) throws -> Bool {
        guard let value = values[name], value != .null else {
            throw WireRequestError.missingArgument(tool: toolName, name: name)
        }
        if let bool = value.boolValue { return bool }
        // Tolerate the string spellings some clients send for booleans.
        if let string = value.stringValue {
            if string == "true" { return true }
            if string == "false" { return false }
        }
        throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "true or false")
    }

    func requiredStringArray(_ name: String) throws -> [String] {
        guard let value = values[name], value != .null else {
            throw WireRequestError.missingArgument(tool: toolName, name: name)
        }
        guard case .array(let items) = value else {
            throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "a list of ids")
        }
        return try items.map { item in
            guard let string = item.stringValue, !string.isEmpty else {
                throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "a list of ids")
            }
            return string
        }
    }

    private func doubleField(_ object: [String: Value], _ key: String) -> Double? {
        guard let value = object[key], value != .null else { return nil }
        if let double = value.doubleValue { return double }
        if let int = value.intValue { return Double(int) }
        return nil
    }

    func optionalNewPlaces(_ name: String) throws -> [WireNewPlace]? {
        guard let value = values[name], value != .null else { return nil }
        guard case .array(let items) = value else {
            throw WireRequestError.invalidArgument(tool: toolName, name: name, expected: "a list of places")
        }
        return try items.map { item in
            guard case .object(let object) = item,
                  let address = object["address"]?.stringValue,
                  !address.isEmpty
            else {
                throw WireRequestError.invalidArgument(
                    tool: toolName, name: name,
                    expected: "a list of places, each with at least an address")
            }
            return WireNewPlace(
                address: address,
                latitude: doubleField(object, "latitude"),
                longitude: doubleField(object, "longitude"))
        }
    }
}
