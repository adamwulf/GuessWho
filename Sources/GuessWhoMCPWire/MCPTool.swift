import Foundation
import EasyMacMCP
import MCP

/// The read-tool inventory for v1 (plans/cli-mcp.md Phase 1) — the single
/// source of truth for tool names, agent-facing descriptions, parameter
/// schemas, permission domain, and per-tool timeouts.
///
/// Naming: tool names use underscores (`contacts_search`), not the dotted
/// names the plan sketches (`contacts.search`) — MCP clients and the
/// Anthropic API restrict tool names to `[a-zA-Z0-9_-]`, so dots would be
/// rejected or silently rewritten by clients.
///
/// Every description and parameter doc here is agent-facing and MUST stay
/// plain-language: no seam words (sidecar, unlink, EventKit, reconcile…),
/// no implementation vocabulary (pipes, groups-of-apps, helper ids…). The
/// banned-vocabulary test in GuessWhoMCPCoreTests serializes this whole
/// inventory and enforces the ban — see plans/cli-mcp.md Phase 1 exit
/// criteria.
public enum MCPTool: String, CaseIterable, Sendable {
    case contactsSearch = "contacts_search"
    case contactsGet = "contacts_get"
    case contactsListNotes = "contacts_list_notes"
    case contactsListCustomFields = "contacts_list_custom_fields"
    case contactsListLinkedContacts = "contacts_list_linked_contacts"
    case contactsListLinkedOrganizations = "contacts_list_linked_organizations"
    case contactsListFavorites = "contacts_list_favorites"
    case contactsListGroups = "contacts_list_groups"
    case groupsListMembers = "groups_list_members"
    case eventsList = "events_list"
    case eventsGet = "events_get"
    case eventsListTags = "events_list_tags"
    case guidesList = "guides_list"
    case guidesGet = "guides_get"
    case placesList = "places_list"

    /// Which system permission this tool's data depends on. Tools whose
    /// domain permission has not been granted are hidden from `listTools`
    /// AND rejected per-call (hiding is UX, the per-call gate is the
    /// enforcement — plans/cli-mcp.md Phase 1).
    public enum PermissionDomain: Sendable {
        case contacts
        case events
        /// Guide/place data is GuessWho's own storage; no system permission.
        case none
    }

    public var permissionDomain: PermissionDomain {
        switch self {
        case .contactsSearch, .contactsGet, .contactsListNotes,
             .contactsListCustomFields, .contactsListLinkedContacts,
             .contactsListLinkedOrganizations, .contactsListFavorites,
             .contactsListGroups, .groupsListMembers:
            return .contacts
        case .eventsList, .eventsGet, .eventsListTags:
            return .events
        case .guidesList, .guidesGet, .placesList:
            return .none
        }
    }

    /// Per-tool response timeout, seconds — declarative in metadata (plan
    /// design note) so a future interactive tool can opt into a longer
    /// window without a global change. All v1 reads use the same 10s.
    public var timeout: TimeInterval { 10 }

    // MARK: - Agent-facing schema

    /// Shared parameter docs. "id" language only — never internal identity
    /// vocabulary. Ids are opaque per-session strings minted by the app; the
    /// agent gets them from search/list results and hands them back.
    private static let contactIdDoc =
        "A contact id returned by contacts_search or another contacts tool. Ids can go out of date; if a call reports that, search again for a fresh one."
    private static let limitDoc =
        "Maximum number of items to return in one page (default 50, max 200)."
    private static let cursorDoc =
        "Opaque paging cursor from a previous page's nextCursor. Omit for the first page."

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { Value.string($0) })
        }
        return .object(object)
    }

    private static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    private static func integer(_ description: String) -> Value {
        ["type": "integer", "description": .string(description)]
    }

    private static var pagingProperties: [String: Value] {
        [
            "limit": integer(limitDoc),
            "cursor": string(cursorDoc),
        ]
    }

    public var metadata: ToolMetadata {
        switch self {
        case .contactsSearch:
            var props = Self.pagingProperties
            props["query"] = Self.string(
                "Text to search for. Matches names, organization, department, job title, email addresses, phone numbers, and web addresses. At least 2 characters.")
            return ToolMetadata(
                name: rawValue,
                description: "Search the user's contacts. Returns a page of matching contacts, each with an id usable with the other contacts tools.",
                inputSchema: Self.schema(props, required: ["query"]))
        case .contactsGet:
            return ToolMetadata(
                name: rawValue,
                description: "Get a contact's full card: name, organization, job title, phone numbers, email addresses, postal and web addresses, and dates.",
                inputSchema: Self.schema(["contactId": Self.string(Self.contactIdDoc)], required: ["contactId"]))
        case .contactsListNotes:
            var props = Self.pagingProperties
            props["contactId"] = Self.string(Self.contactIdDoc)
            return ToolMetadata(
                name: rawValue,
                description: "List the dated notes the user has written about a contact.",
                inputSchema: Self.schema(props, required: ["contactId"]))
        case .contactsListCustomFields:
            var props = Self.pagingProperties
            props["contactId"] = Self.string(Self.contactIdDoc)
            return ToolMetadata(
                name: rawValue,
                description: "List the custom fields the user has added to a contact (text, dates, and checkboxes).",
                inputSchema: Self.schema(props, required: ["contactId"]))
        case .contactsListLinkedContacts:
            var props = Self.pagingProperties
            props["contactId"] = Self.string(Self.contactIdDoc)
            return ToolMetadata(
                name: rawValue,
                description: "List a contact's Linked Contacts — the people the user has connected to this contact, with an optional note about each connection.",
                inputSchema: Self.schema(props, required: ["contactId"]))
        case .contactsListLinkedOrganizations:
            var props = Self.pagingProperties
            props["contactId"] = Self.string(Self.contactIdDoc)
            return ToolMetadata(
                name: rawValue,
                description: "List a contact's Linked Organizations — the organizations the user has connected to this contact, with an optional note about each connection.",
                inputSchema: Self.schema(props, required: ["contactId"]))
        case .contactsListFavorites:
            return ToolMetadata(
                name: rawValue,
                description: "List the contacts the user has marked as favorites.",
                inputSchema: Self.schema(Self.pagingProperties))
        case .contactsListGroups:
            return ToolMetadata(
                name: rawValue,
                description: "List the user's contact groups.",
                inputSchema: Self.schema(Self.pagingProperties))
        case .groupsListMembers:
            var props = Self.pagingProperties
            props["groupId"] = Self.string("A group id returned by contacts_list_groups.")
            return ToolMetadata(
                name: rawValue,
                description: "List the contacts in a group.",
                inputSchema: Self.schema(props, required: ["groupId"]))
        case .eventsList:
            var props = Self.pagingProperties
            props["startDate"] = Self.string("Start of the date window, ISO 8601 (for example 2026-07-01T00:00:00Z).")
            props["endDate"] = Self.string("End of the date window, ISO 8601. The window may span at most one year.")
            return ToolMetadata(
                name: rawValue,
                description: "List the user's events within a date window. Returns a page of events, each with an id usable with the other events tools.",
                inputSchema: Self.schema(props, required: ["startDate", "endDate"]))
        case .eventsGet:
            return ToolMetadata(
                name: rawValue,
                description: "Get an event's details: title, dates, location, attendees, and notes.",
                inputSchema: Self.schema(["eventId": Self.string("An event id returned by events_list.")], required: ["eventId"]))
        case .eventsListTags:
            var props = Self.pagingProperties
            props["eventId"] = Self.string("An event id returned by events_list.")
            return ToolMetadata(
                name: rawValue,
                description: "List the tags the user has put on an event.",
                inputSchema: Self.schema(props, required: ["eventId"]))
        case .guidesList:
            return ToolMetadata(
                name: rawValue,
                description: "List the user's saved place guides (collections of places imported from Maps).",
                inputSchema: Self.schema(Self.pagingProperties))
        case .guidesGet:
            return ToolMetadata(
                name: rawValue,
                description: "Get one saved place guide by id.",
                inputSchema: Self.schema(["guideId": Self.string("A guide id returned by guides_list.")], required: ["guideId"]))
        case .placesList:
            var props = Self.pagingProperties
            props["guideId"] = Self.string("Optional: a guide id returned by guides_list, to list only that guide's places.")
            return ToolMetadata(
                name: rawValue,
                description: "List saved places, optionally within one guide. Each place has a name, address, and map coordinates when known.",
                inputSchema: Self.schema(props))
        }
    }
}
