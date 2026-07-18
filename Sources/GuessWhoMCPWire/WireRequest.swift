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
    case contactsList(helperId: String, messageId: String, type: String?, limit: Int?, cursor: String?)
    case contactsGet(helperId: String, messageId: String, contactId: String)
    case contactsListNotes(helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?)
    case contactsListCustomFields(helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?)
    case contactsListFavorites(helperId: String, messageId: String, limit: Int?, cursor: String?)
    case contactsListGroups(helperId: String, messageId: String, limit: Int?, cursor: String?)
    case groupsListMembers(helperId: String, messageId: String, groupId: String, limit: Int?, cursor: String?)
    case eventsList(helperId: String, messageId: String, startDate: String, endDate: String, limit: Int?, cursor: String?)
    case eventsGet(helperId: String, messageId: String, eventId: String)
    case eventsListTags(helperId: String, messageId: String, eventId: String, limit: Int?, cursor: String?)
    case guidesList(helperId: String, messageId: String, limit: Int?, cursor: String?)
    case guidesGet(helperId: String, messageId: String, guideId: String)
    case placesList(helperId: String, messageId: String, guideId: String?, limit: Int?, cursor: String?)
    case linksList(helperId: String, messageId: String, id: String, kind: String, limit: Int?, cursor: String?)

    // Write tools (plans/cli-mcp.md Phase 2). Every write carries an
    // optional client-supplied `idempotencyToken`: the app dedups a retried
    // token within a host-run-scoped window, so a timeout-then-retry can't
    // double-apply a non-idempotent write.
    // Contact-record writes (Revision 2: full Contact Store parity).
    // `fields` is a PATCH — only supplied fields apply. contacts_update is
    // SCALARS-ONLY (Phase 7): its field set structurally has no list
    // members, so a whole-list bulk edit can't ride an update; the lists
    // change one entry at a time through the cases below. contacts_delete
    // is additionally gated on an in-app user confirmation.
    case contactsCreate(helperId: String, messageId: String, kind: String?, fields: WireContactFields, idempotencyToken: String?)
    case contactsUpdate(helperId: String, messageId: String, contactId: String, fields: WireContactScalarFields, idempotencyToken: String?)
    case contactsDelete(helperId: String, messageId: String, contactId: String, idempotencyToken: String?)
    // Single-entry list edits (plans/cli-mcp.md Phase 7): one entry per
    // call, matched by exact value — 0 matches answers notFound, more
    // than one answers ambiguous, and nothing changes on either.
    case contactsAddValue(helperId: String, messageId: String, contactId: String, field: String, value: String, label: String?, idempotencyToken: String?)
    case contactsRemoveValue(helperId: String, messageId: String, contactId: String, field: String, value: String, idempotencyToken: String?)
    case contactsEditValue(helperId: String, messageId: String, contactId: String, field: String, currentValue: String, newValue: String, newLabel: String?, idempotencyToken: String?)
    case contactsAddNote(helperId: String, messageId: String, contactId: String, body: String, idempotencyToken: String?)
    case contactsEditNote(helperId: String, messageId: String, contactId: String, noteId: String, body: String, idempotencyToken: String?)
    case contactsDeleteNote(helperId: String, messageId: String, contactId: String, noteId: String, idempotencyToken: String?)
    case contactsSetCustomField(helperId: String, messageId: String, contactId: String, name: String, type: String?, value: String, idempotencyToken: String?)
    case contactsDeleteCustomField(helperId: String, messageId: String, contactId: String, fieldId: String, idempotencyToken: String?)
    case contactsSetFavorite(helperId: String, messageId: String, contactId: String, favorite: Bool, idempotencyToken: String?)
    case eventsAddTag(helperId: String, messageId: String, eventId: String, text: String, idempotencyToken: String?)
    case eventsEditTag(helperId: String, messageId: String, eventId: String, tagId: String, text: String, idempotencyToken: String?)
    case eventsDeleteTag(helperId: String, messageId: String, eventId: String, tagId: String, idempotencyToken: String?)
    case guidesCreate(helperId: String, messageId: String, name: String, places: [WireNewPlace], idempotencyToken: String?)
    case guidesDelete(helperId: String, messageId: String, guideId: String, idempotencyToken: String?)
    case guidesReorderPlaces(helperId: String, messageId: String, guideId: String, placeIds: [String], idempotencyToken: String?)
    case placesDelete(helperId: String, messageId: String, placeId: String, idempotencyToken: String?)
    case linksCreate(helperId: String, messageId: String, fromId: String, fromKind: String, toId: String, toKind: String, note: String?, idempotencyToken: String?)
    case linksRemove(helperId: String, messageId: String, linkId: String, idempotencyToken: String?)

    /// The tool identity for tool-call cases; nil for control messages.
    public var tool: MCPTool? {
        switch self {
        case .initialize, .deinitialize, .ping, .listTools: return nil
        case .contactsSearch: return .contactsSearch
        case .contactsList: return .contactsList
        case .contactsGet: return .contactsGet
        case .contactsListNotes: return .contactsListNotes
        case .contactsListCustomFields: return .contactsListCustomFields
        case .contactsListFavorites: return .contactsListFavorites
        case .contactsListGroups: return .contactsListGroups
        case .groupsListMembers: return .groupsListMembers
        case .eventsList: return .eventsList
        case .eventsGet: return .eventsGet
        case .eventsListTags: return .eventsListTags
        case .guidesList: return .guidesList
        case .guidesGet: return .guidesGet
        case .placesList: return .placesList
        case .linksList: return .linksList
        case .contactsCreate: return .contactsCreate
        case .contactsUpdate: return .contactsUpdate
        case .contactsDelete: return .contactsDelete
        case .contactsAddValue: return .contactsAddValue
        case .contactsRemoveValue: return .contactsRemoveValue
        case .contactsEditValue: return .contactsEditValue
        case .contactsAddNote: return .contactsAddNote
        case .contactsEditNote: return .contactsEditNote
        case .contactsDeleteNote: return .contactsDeleteNote
        case .contactsSetCustomField: return .contactsSetCustomField
        case .contactsDeleteCustomField: return .contactsDeleteCustomField
        case .contactsSetFavorite: return .contactsSetFavorite
        case .eventsAddTag: return .eventsAddTag
        case .eventsEditTag: return .eventsEditTag
        case .eventsDeleteTag: return .eventsDeleteTag
        case .guidesCreate: return .guidesCreate
        case .guidesDelete: return .guidesDelete
        case .guidesReorderPlaces: return .guidesReorderPlaces
        case .placesDelete: return .placesDelete
        case .linksCreate: return .linksCreate
        case .linksRemove: return .linksRemove
        }
    }

    /// The client-supplied idempotency token, if this is a write request
    /// that carries one. Nil for reads, control messages, and writes the
    /// client didn't token.
    public var idempotencyToken: String? {
        switch self {
        case .contactsCreate(_, _, _, _, let token),
             .contactsUpdate(_, _, _, _, let token),
             .contactsDelete(_, _, _, let token),
             .contactsAddValue(_, _, _, _, _, _, let token),
             .contactsRemoveValue(_, _, _, _, _, let token),
             .contactsEditValue(_, _, _, _, _, _, _, let token),
             .contactsAddNote(_, _, _, _, let token),
             .contactsEditNote(_, _, _, _, _, let token),
             .contactsDeleteNote(_, _, _, _, let token),
             .contactsSetCustomField(_, _, _, _, _, _, let token),
             .contactsDeleteCustomField(_, _, _, _, let token),
             .contactsSetFavorite(_, _, _, _, let token),
             .eventsAddTag(_, _, _, _, let token),
             .eventsEditTag(_, _, _, _, _, let token),
             .eventsDeleteTag(_, _, _, _, let token),
             .guidesCreate(_, _, _, _, let token),
             .guidesDelete(_, _, _, let token),
             .guidesReorderPlaces(_, _, _, _, let token),
             .placesDelete(_, _, _, let token),
             .linksCreate(_, _, _, _, _, _, _, let token),
             .linksRemove(_, _, _, let token):
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
             .contactsList(let helperId, _, _, _, _),
             .contactsGet(let helperId, _, _),
             .contactsListNotes(let helperId, _, _, _, _),
             .contactsListCustomFields(let helperId, _, _, _, _),
             .contactsListFavorites(let helperId, _, _, _),
             .contactsListGroups(let helperId, _, _, _),
             .groupsListMembers(let helperId, _, _, _, _),
             .eventsList(let helperId, _, _, _, _, _),
             .eventsGet(let helperId, _, _),
             .eventsListTags(let helperId, _, _, _, _),
             .guidesList(let helperId, _, _, _),
             .guidesGet(let helperId, _, _),
             .placesList(let helperId, _, _, _, _),
             .contactsCreate(let helperId, _, _, _, _),
             .contactsUpdate(let helperId, _, _, _, _),
             .contactsDelete(let helperId, _, _, _),
             .contactsAddValue(let helperId, _, _, _, _, _, _),
             .contactsRemoveValue(let helperId, _, _, _, _, _),
             .contactsEditValue(let helperId, _, _, _, _, _, _, _),
             .contactsAddNote(let helperId, _, _, _, _),
             .contactsEditNote(let helperId, _, _, _, _, _),
             .contactsDeleteNote(let helperId, _, _, _, _),
             .contactsSetCustomField(let helperId, _, _, _, _, _, _),
             .contactsDeleteCustomField(let helperId, _, _, _, _),
             .contactsSetFavorite(let helperId, _, _, _, _),
             .eventsAddTag(let helperId, _, _, _, _),
             .eventsEditTag(let helperId, _, _, _, _, _),
             .eventsDeleteTag(let helperId, _, _, _, _),
             .guidesCreate(let helperId, _, _, _, _),
             .guidesDelete(let helperId, _, _, _),
             .guidesReorderPlaces(let helperId, _, _, _, _),
             .placesDelete(let helperId, _, _, _),
             .linksList(let helperId, _, _, _, _, _),
             .linksCreate(let helperId, _, _, _, _, _, _, _),
             .linksRemove(let helperId, _, _, _):
            return helperId
        }
    }

    public var messageId: String {
        switch self {
        case .initialize(_, let messageId),
             .ping(_, let messageId),
             .listTools(_, let messageId),
             .contactsSearch(_, let messageId, _, _, _),
             .contactsList(_, let messageId, _, _, _),
             .contactsGet(_, let messageId, _),
             .contactsListNotes(_, let messageId, _, _, _),
             .contactsListCustomFields(_, let messageId, _, _, _),
             .contactsListFavorites(_, let messageId, _, _),
             .contactsListGroups(_, let messageId, _, _),
             .groupsListMembers(_, let messageId, _, _, _),
             .eventsList(_, let messageId, _, _, _, _),
             .eventsGet(_, let messageId, _),
             .eventsListTags(_, let messageId, _, _, _),
             .guidesList(_, let messageId, _, _),
             .guidesGet(_, let messageId, _),
             .placesList(_, let messageId, _, _, _),
             .contactsCreate(_, let messageId, _, _, _),
             .contactsUpdate(_, let messageId, _, _, _),
             .contactsDelete(_, let messageId, _, _),
             .contactsAddValue(_, let messageId, _, _, _, _, _),
             .contactsRemoveValue(_, let messageId, _, _, _, _),
             .contactsEditValue(_, let messageId, _, _, _, _, _, _),
             .contactsAddNote(_, let messageId, _, _, _),
             .contactsEditNote(_, let messageId, _, _, _, _),
             .contactsDeleteNote(_, let messageId, _, _, _),
             .contactsSetCustomField(_, let messageId, _, _, _, _, _),
             .contactsDeleteCustomField(_, let messageId, _, _, _),
             .contactsSetFavorite(_, let messageId, _, _, _),
             .eventsAddTag(_, let messageId, _, _, _),
             .eventsEditTag(_, let messageId, _, _, _, _),
             .eventsDeleteTag(_, let messageId, _, _, _),
             .guidesCreate(_, let messageId, _, _, _),
             .guidesDelete(_, let messageId, _, _),
             .guidesReorderPlaces(_, let messageId, _, _, _),
             .placesDelete(_, let messageId, _, _),
             .linksList(_, let messageId, _, _, _, _),
             .linksCreate(_, let messageId, _, _, _, _, _, _),
             .linksRemove(_, let messageId, _, _):
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
        case .contactsList:
            return .contactsList(
                helperId: helperId, messageId: messageId,
                type: try args.optionalString("type"),
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
        case .linksList:
            return .linksList(
                helperId: helperId, messageId: messageId,
                id: try args.requiredString("id"),
                kind: try args.requiredString("kind"),
                limit: try args.optionalInt("limit"), cursor: try args.optionalString("cursor"))

        case .contactsCreate:
            return .contactsCreate(
                helperId: helperId, messageId: messageId,
                kind: try args.optionalString("kind"),
                fields: try args.contactFields(),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsUpdate:
            return .contactsUpdate(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                fields: try args.contactScalarFields(),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsAddValue:
            return .contactsAddValue(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                field: try args.requiredContactListField(),
                value: try args.requiredString("value"),
                label: try args.optionalString("label"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsRemoveValue:
            return .contactsRemoveValue(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                field: try args.requiredContactListField(),
                value: try args.requiredString("value"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsEditValue:
            return .contactsEditValue(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                field: try args.requiredContactListField(),
                currentValue: try args.requiredString("currentValue"),
                newValue: try args.requiredString("newValue"),
                newLabel: try args.optionalString("newLabel"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .contactsDelete:
            return .contactsDelete(
                helperId: helperId, messageId: messageId,
                contactId: try args.requiredString("contactId"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
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
        case .linksCreate:
            return .linksCreate(
                helperId: helperId, messageId: messageId,
                fromId: try args.requiredString("fromId"),
                fromKind: try args.requiredString("fromKind"),
                toId: try args.requiredString("toId"),
                toKind: try args.requiredString("toKind"),
                note: try args.optionalString("note"),
                idempotencyToken: try args.optionalString("idempotencyToken"))
        case .linksRemove:
            return .linksRemove(
                helperId: helperId, messageId: messageId,
                linkId: try args.requiredString("linkId"),
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
    /// An argument that must be rejected with a specific fixed message
    /// (e.g. a note-shaped argument on a contact-card write — the Apple
    /// note is never writable over this channel).
    case unsupportedArgument(message: String)

    public var description: String {
        switch self {
        case .unknownTool(let name):
            return "There is no tool named \(name). List tools to see what is available."
        case .missingArgument(let tool, let name):
            return "\(tool) requires the \(name) argument."
        case .invalidArgument(let tool, let name, let expected):
            return "The \(name) argument for \(tool) must be \(expected)."
        case .unsupportedArgument(let message):
            return message
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

    func requiredContactListField() throws -> String {
        guard let value = values["field"], value != .null else {
            throw WireRequestError.missingArgument(tool: toolName, name: "field")
        }
        guard let field = value.stringValue,
              ["phone", "email", "url", "related_name", "date"].contains(field)
        else {
            throw WireRequestError.unsupportedArgument(
                message: WireErrorMessage.invalidContactListField)
        }
        return field
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

    /// Rejects any note-shaped argument up front — the Apple contact note
    /// is never writable over the wire, and silently ignoring it would let
    /// an agent believe a note was saved.
    private func rejectNoteArguments() throws {
        for key in ["note", "notes"] where values[key] != nil && values[key] != .null {
            throw WireRequestError.unsupportedArgument(
                message: WireErrorMessage.contactNoteNotAccepted)
        }
    }

    /// The contacts_create field set. A PATCH over a blank card: absent
    /// keys stay nil (untouched). Accepts the multi-value lists — safe at
    /// create, where there is nothing to clobber.
    func contactFields() throws -> WireContactFields {
        try rejectNoteArguments()
        var fields = WireContactFields()
        fields.namePrefix = try optionalString("namePrefix")
        fields.givenName = try optionalString("givenName")
        fields.middleName = try optionalString("middleName")
        fields.familyName = try optionalString("familyName")
        fields.previousFamilyName = try optionalString("previousFamilyName")
        fields.nameSuffix = try optionalString("nameSuffix")
        fields.nickname = try optionalString("nickname")
        fields.phoneticGivenName = try optionalString("phoneticGivenName")
        fields.phoneticMiddleName = try optionalString("phoneticMiddleName")
        fields.phoneticFamilyName = try optionalString("phoneticFamilyName")
        fields.organization = try optionalString("organization")
        fields.phoneticOrganization = try optionalString("phoneticOrganization")
        fields.department = try optionalString("department")
        fields.jobTitle = try optionalString("jobTitle")
        fields.phoneNumbers = try optionalLabeledValues("phoneNumbers")
        fields.emailAddresses = try optionalLabeledValues("emailAddresses")
        fields.urlAddresses = try optionalLabeledValues("urlAddresses")
        fields.postalAddresses = try optionalPostalAddresses("postalAddresses")
        fields.birthday = try optionalString("birthday")
        fields.dates = try optionalLabeledDates("dates")
        fields.socialProfiles = try optionalSocialProfiles("socialProfiles")
        fields.instantMessages = try optionalInstantMessages("instantMessages")
        fields.relatedNames = try optionalLabeledValues("relatedNames")
        return fields
    }

    /// The contacts_update field set — SCALARS ONLY (Phase 7). Any
    /// list-shaped argument is rejected LOUDLY with a pointer to the
    /// dedicated single-entry tools (or to contacts_create, for the lists
    /// that have none yet): a silently dropped list would let an agent
    /// believe a bulk edit was saved.
    func contactScalarFields() throws -> WireContactScalarFields {
        try rejectNoteArguments()
        for key in ["phoneNumbers", "emailAddresses", "urlAddresses", "relatedNames", "dates"]
        where values[key] != nil && values[key] != .null {
            throw WireRequestError.unsupportedArgument(
                message: WireErrorMessage.listArgumentNotAccepted)
        }
        for key in ["postalAddresses", "socialProfiles", "instantMessages"]
        where values[key] != nil && values[key] != .null {
            throw WireRequestError.unsupportedArgument(
                message: WireErrorMessage.createOnlyListArgumentNotAccepted)
        }
        var fields = WireContactScalarFields()
        fields.namePrefix = try optionalString("namePrefix")
        fields.givenName = try optionalString("givenName")
        fields.middleName = try optionalString("middleName")
        fields.familyName = try optionalString("familyName")
        fields.previousFamilyName = try optionalString("previousFamilyName")
        fields.nameSuffix = try optionalString("nameSuffix")
        fields.nickname = try optionalString("nickname")
        fields.phoneticGivenName = try optionalString("phoneticGivenName")
        fields.phoneticMiddleName = try optionalString("phoneticMiddleName")
        fields.phoneticFamilyName = try optionalString("phoneticFamilyName")
        fields.organization = try optionalString("organization")
        fields.phoneticOrganization = try optionalString("phoneticOrganization")
        fields.department = try optionalString("department")
        fields.jobTitle = try optionalString("jobTitle")
        fields.birthday = try optionalString("birthday")
        return fields
    }

    private func objectItems(_ name: String) throws -> [[String: Value]]? {
        guard let value = values[name], value != .null else { return nil }
        guard case .array(let items) = value else {
            throw WireRequestError.invalidArgument(
                tool: toolName, name: name, expected: "a list")
        }
        return try items.map { item in
            guard case .object(let object) = item else {
                throw WireRequestError.invalidArgument(
                    tool: toolName, name: name, expected: "a list of objects")
            }
            return object
        }
    }

    private func stringField(_ object: [String: Value], _ key: String) -> String? {
        guard let value = object[key], value != .null else { return nil }
        return value.stringValue
    }

    func optionalLabeledValues(_ name: String) throws -> [WireLabeledValue]? {
        guard let items = try objectItems(name) else { return nil }
        return try items.map { object in
            guard let value = stringField(object, "value"), !value.isEmpty else {
                throw WireRequestError.invalidArgument(
                    tool: toolName, name: name,
                    expected: "a list of entries, each with a non-empty value")
            }
            return WireLabeledValue(label: stringField(object, "label"), value: value)
        }
    }

    func optionalPostalAddresses(_ name: String) throws -> [WirePostalAddress]? {
        guard let items = try objectItems(name) else { return nil }
        return items.map { object in
            WirePostalAddress(
                label: stringField(object, "label"),
                street: stringField(object, "street") ?? "",
                subLocality: stringField(object, "subLocality"),
                city: stringField(object, "city") ?? "",
                subAdministrativeArea: stringField(object, "subAdministrativeArea"),
                state: stringField(object, "state") ?? "",
                postalCode: stringField(object, "postalCode") ?? "",
                country: stringField(object, "country") ?? "",
                isoCountryCode: stringField(object, "isoCountryCode"))
        }
    }

    func optionalLabeledDates(_ name: String) throws -> [WireLabeledDate]? {
        guard let items = try objectItems(name) else { return nil }
        return try items.map { object in
            guard let date = stringField(object, "date"), !date.isEmpty else {
                throw WireRequestError.invalidArgument(
                    tool: toolName, name: name,
                    expected: "a list of entries, each with a date like 2026-08-01 or --08-01")
            }
            return WireLabeledDate(label: stringField(object, "label"), date: date)
        }
    }

    func optionalSocialProfiles(_ name: String) throws -> [WireSocialProfile]? {
        guard let items = try objectItems(name) else { return nil }
        return items.map { object in
            WireSocialProfile(
                label: stringField(object, "label"),
                service: stringField(object, "service"),
                username: stringField(object, "username"),
                url: stringField(object, "url"))
        }
    }

    func optionalInstantMessages(_ name: String) throws -> [WireInstantMessage]? {
        guard let items = try objectItems(name) else { return nil }
        return try items.map { object in
            guard let username = stringField(object, "username"), !username.isEmpty else {
                throw WireRequestError.invalidArgument(
                    tool: toolName, name: name,
                    expected: "a list of entries, each with a non-empty username")
            }
            return WireInstantMessage(
                label: stringField(object, "label"),
                service: stringField(object, "service"),
                username: username)
        }
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
