import Foundation
import EasyMacMCP
import MCP

/// The tool inventory for v1 (plans/cli-mcp.md Phases 1–2) — the single
/// source of truth for tool names, agent-facing descriptions, parameter
/// schemas, permission domain, write classification, and per-tool timeouts.
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

    // Write tools. The Phase 2 set mutates GuessWho's OWN data (notes,
    // fields, links, favorites, tags, guides); Revision 2 adds full
    // Contact Store parity — create/update/delete of the contact record
    // itself, the same power the user has in the app's editor. Every write
    // is rejected per-call unless the origin's access mode is read-write;
    // contacts_delete additionally requires the user to approve an in-app
    // confirmation naming the contact.
    case contactsCreate = "contacts_create"
    case contactsUpdate = "contacts_update"
    case contactsDelete = "contacts_delete"
    case contactsAddNote = "contacts_add_note"
    case contactsEditNote = "contacts_edit_note"
    case contactsDeleteNote = "contacts_delete_note"
    case contactsSetCustomField = "contacts_set_custom_field"
    case contactsDeleteCustomField = "contacts_delete_custom_field"
    case contactsAddLinkedContact = "contacts_add_linked_contact"
    case contactsAddLinkedOrganization = "contacts_add_linked_organization"
    case contactsRemoveLinkedContact = "contacts_remove_linked_contact"
    case contactsSetFavorite = "contacts_set_favorite"
    case eventsAddTag = "events_add_tag"
    case eventsEditTag = "events_edit_tag"
    case eventsDeleteTag = "events_delete_tag"
    case guidesCreate = "guides_create"
    case guidesDelete = "guides_delete"
    case guidesReorderPlaces = "guides_reorder_places"
    case placesDelete = "places_delete"

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
             .contactsListGroups, .groupsListMembers,
             .contactsCreate, .contactsUpdate, .contactsDelete,
             .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsAddLinkedContact, .contactsAddLinkedOrganization,
             .contactsRemoveLinkedContact, .contactsSetFavorite:
            return .contacts
        case .eventsList, .eventsGet, .eventsListTags,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag:
            return .events
        case .guidesList, .guidesGet, .placesList,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete:
            return .none
        }
    }

    /// Whether this tool mutates data. Write tools are hidden from
    /// `listTools` while the origin's read-only toggle is on AND rejected
    /// per-call by the same gate (consent = the toggle, granted once in the
    /// app's settings; writes are OFF by default — plans/cli-mcp.md Phase 2).
    public var isWrite: Bool {
        switch self {
        case .contactsSearch, .contactsGet, .contactsListNotes,
             .contactsListCustomFields, .contactsListLinkedContacts,
             .contactsListLinkedOrganizations, .contactsListFavorites,
             .contactsListGroups, .groupsListMembers,
             .eventsList, .eventsGet, .eventsListTags,
             .guidesList, .guidesGet, .placesList:
            return false
        case .contactsCreate, .contactsUpdate, .contactsDelete,
             .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsAddLinkedContact, .contactsAddLinkedOrganization,
             .contactsRemoveLinkedContact, .contactsSetFavorite,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete:
            return true
        }
    }

    /// Per-tool response timeout, seconds — declarative in metadata so an
    /// interactive tool can opt into a longer window without a global
    /// change, and the relay reads it per request (`request.tool?.timeout`).
    /// contacts_delete waits on a HUMAN answering an in-app confirmation,
    /// so it gets minutes, not seconds — a short helper timeout here is the
    /// safety bug where "the agent saw a timeout" and "the delete happened"
    /// could both be true (the app also re-checks elapsed time before
    /// performing the delete; both sides use THIS constant).
    public var timeout: TimeInterval {
        switch self {
        case .contactsDelete: return 300
        default: return 10
        }
    }

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
    private static let idempotencyDoc =
        "Optional: a unique string of your choosing that identifies this one change. If the call is retried with the same value, the change is applied only once."
    private static let eventIdDoc =
        "An event id returned by events_list."

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

    private static func labeledArray(_ description: String, valueDoc: String) -> Value {
        [
            "type": "array",
            "description": .string(description),
            "items": .object([
                "type": "object",
                "properties": .object([
                    "label": string("Optional label, e.g. \"work\" or \"home\"."),
                    "value": string(valueDoc),
                ]),
                "required": .array([.string("value")]),
            ]),
        ]
    }

    /// The editable contact-card field set shared by contacts_create and
    /// contacts_update. There is deliberately NO note-shaped property here
    /// (notes ride contacts_add_note), and the contact id is never among
    /// the editable fields.
    private static var contactFieldProperties: [String: Value] {
        [
            "namePrefix": string("Name prefix, e.g. \"Dr.\"."),
            "givenName": string("First name."),
            "middleName": string("Middle name."),
            "familyName": string("Last name."),
            "previousFamilyName": string("Previous last name (e.g. a maiden name)."),
            "nameSuffix": string("Name suffix, e.g. \"Jr.\"."),
            "nickname": string("Nickname."),
            "phoneticGivenName": string("Phonetic first name."),
            "phoneticMiddleName": string("Phonetic middle name."),
            "phoneticFamilyName": string("Phonetic last name."),
            "organization": string("Organization or company name."),
            "phoneticOrganization": string("Phonetic organization name."),
            "department": string("Department within the organization."),
            "jobTitle": string("Job title."),
            "phoneNumbers": labeledArray(
                "Phone numbers. Replaces the whole list when passed.",
                valueDoc: "The phone number."),
            "emailAddresses": labeledArray(
                "Email addresses. Replaces the whole list when passed.",
                valueDoc: "The email address."),
            "urlAddresses": labeledArray(
                "Web addresses. Replaces the whole list when passed.",
                valueDoc: "The web address."),
            "postalAddresses": [
                "type": "array",
                "description": .string("Postal addresses. Replaces the whole list when passed."),
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "label": string("Optional label, e.g. \"home\"."),
                        "street": string("Street address (may span lines)."),
                        "subLocality": string("Neighborhood or sub-locality."),
                        "city": string("City."),
                        "subAdministrativeArea": string("County or sub-administrative area."),
                        "state": string("State or province."),
                        "postalCode": string("Postal or ZIP code."),
                        "country": string("Country name."),
                        "isoCountryCode": string("ISO country code, e.g. \"us\"."),
                    ]),
                ]),
            ],
            "birthday": string(
                "Birthday as yyyy-MM-dd, or --MM-dd when the year is unknown. Pass an empty string to clear it."),
            "dates": [
                "type": "array",
                "description": .string("Other labeled dates (anniversaries etc.). Replaces the whole list when passed."),
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "label": string("The date's label, e.g. \"anniversary\"."),
                        "date": string("yyyy-MM-dd, or --MM-dd when the year is unknown."),
                    ]),
                    "required": .array([.string("date")]),
                ]),
            ],
            "socialProfiles": [
                "type": "array",
                "description": .string("Social profiles. Replaces the whole list when passed."),
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "label": string("Optional label."),
                        "service": string("The service name, e.g. \"LinkedIn\"."),
                        "username": string("The username on that service."),
                        "url": string("The profile's web address."),
                    ]),
                ]),
            ],
            "instantMessages": [
                "type": "array",
                "description": .string("Instant-message addresses. Replaces the whole list when passed."),
                "items": .object([
                    "type": "object",
                    "properties": .object([
                        "label": string("Optional label."),
                        "service": string("The messaging service name."),
                        "username": string("The username on that service."),
                    ]),
                    "required": .array([.string("username")]),
                ]),
            ],
            "relatedNames": labeledArray(
                "Name-only related people (e.g. label \"mother\", value \"Ann Doe\"). Replaces the whole list when passed.",
                valueDoc: "The related person's name."),
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

        // MARK: Write tools

        case .contactsCreate:
            var props = Self.contactFieldProperties
            props["kind"] = Self.string(
                "\"person\" (the default) or \"organization\".")
            props["idempotencyToken"] = Self.string(Self.idempotencyDoc)
            return ToolMetadata(
                name: rawValue,
                description: "Create a new contact. Provide at least a name or an organization; any of the other contact fields may be included. Returns the new contact's full card, including its id.",
                inputSchema: Self.schema(props))
        case .contactsUpdate:
            var props = Self.contactFieldProperties
            props["contactId"] = Self.string(Self.contactIdDoc)
            props["idempotencyToken"] = Self.string(Self.idempotencyDoc)
            return ToolMetadata(
                name: rawValue,
                description: "Edit a contact's card. Only the fields you pass change: text fields are replaced (pass an empty string to clear one), and list fields like phoneNumbers are replaced as a whole list (pass the complete new list; pass an empty list to clear it). Returns the updated card.",
                inputSchema: Self.schema(props, required: ["contactId"]))
        case .contactsDelete:
            return ToolMetadata(
                name: rawValue,
                description: "Delete a contact entirely. The user must approve a confirmation in the GuessWho app before anything happens, so this can take a while; if they decline, the result says so and nothing is changed.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId"]))
        case .contactsAddNote:
            return ToolMetadata(
                name: rawValue,
                description: "Add a dated note about a contact. Returns the new note.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "body": Self.string("The note's text."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "body"]))
        case .contactsEditNote:
            return ToolMetadata(
                name: rawValue,
                description: "Replace the text of one of the user's notes about a contact. Returns the updated note.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "noteId": Self.string("A note id returned by contacts_list_notes."),
                    "body": Self.string("The note's new text."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "noteId", "body"]))
        case .contactsDeleteNote:
            return ToolMetadata(
                name: rawValue,
                description: "Delete one of the user's notes about a contact. The user can restore a recently deleted note from the app.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "noteId": Self.string("A note id returned by contacts_list_notes."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "noteId"]))
        case .contactsSetCustomField:
            return ToolMetadata(
                name: rawValue,
                description: "Add or update a named custom field on a contact. If a field with that name exists, its value is replaced; otherwise a new field is created. Returns the field.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "name": Self.string("The field's name, e.g. \"Coffee order\". Some names are reserved for the app's own use and are rejected."),
                    "type": Self.string("The field's type: \"text\", \"multilineNote\", \"date\", or \"checkbox\". Defaults to \"text\"."),
                    "value": Self.string("The field's value: text for text fields, an ISO 8601 date for date fields, \"true\" or \"false\" for checkboxes."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "name", "value"]))
        case .contactsDeleteCustomField:
            return ToolMetadata(
                name: rawValue,
                description: "Delete a custom field from a contact. The user can restore a recently deleted field from the app.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "fieldId": Self.string("A field id returned by contacts_list_custom_fields."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "fieldId"]))
        case .contactsAddLinkedContact:
            return ToolMetadata(
                name: rawValue,
                description: "Add a person to a contact's Linked Contacts, with an optional note about the connection. Returns the new row.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "personId": Self.string("The id of the person to connect (from contacts_search). Must be a person, not an organization."),
                    "note": Self.string("Optional: a short note about the connection, e.g. \"College roommate\"."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "personId"]))
        case .contactsAddLinkedOrganization:
            return ToolMetadata(
                name: rawValue,
                description: "Add an organization to a contact's Linked Organizations, with an optional note about the connection. Returns the new row.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "organizationId": Self.string("The id of the organization to connect (from contacts_search). Must be an organization, not a person."),
                    "note": Self.string("Optional: a short note about the connection, e.g. \"Board seat\"."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "organizationId"]))
        case .contactsRemoveLinkedContact:
            return ToolMetadata(
                name: rawValue,
                description: "Remove a row from a contact's Linked Contacts or Linked Organizations. The user can restore a recently removed row from the app.",
                inputSchema: Self.schema([
                    "linkId": Self.string("A row id returned by contacts_list_linked_contacts or contacts_list_linked_organizations."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["linkId"]))
        case .contactsSetFavorite:
            return ToolMetadata(
                name: rawValue,
                description: "Mark a contact as a favorite, or remove it from favorites.",
                inputSchema: Self.schema([
                    "contactId": Self.string(Self.contactIdDoc),
                    "favorite": [
                        "type": "boolean",
                        "description": .string("true to mark as a favorite, false to remove from favorites."),
                    ],
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["contactId", "favorite"]))
        case .eventsAddTag:
            return ToolMetadata(
                name: rawValue,
                description: "Put a tag on an event. Returns the new tag. Some events must be opened once in the GuessWho app before they can be tagged; the error message will say so.",
                inputSchema: Self.schema([
                    "eventId": Self.string(Self.eventIdDoc),
                    "text": Self.string("The tag's text, e.g. \"fundraiser\"."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["eventId", "text"]))
        case .eventsEditTag:
            return ToolMetadata(
                name: rawValue,
                description: "Replace the text of a tag on an event. Returns the updated tag.",
                inputSchema: Self.schema([
                    "eventId": Self.string(Self.eventIdDoc),
                    "tagId": Self.string("A tag id returned by events_list_tags."),
                    "text": Self.string("The tag's new text."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["eventId", "tagId", "text"]))
        case .eventsDeleteTag:
            return ToolMetadata(
                name: rawValue,
                description: "Delete a tag from an event. The user can restore a recently deleted tag from the app.",
                inputSchema: Self.schema([
                    "eventId": Self.string(Self.eventIdDoc),
                    "tagId": Self.string("A tag id returned by events_list_tags."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["eventId", "tagId"]))
        case .guidesCreate:
            return ToolMetadata(
                name: rawValue,
                description: "Create a new place guide, optionally with an initial list of places. Returns the new guide.",
                inputSchema: Self.schema([
                    "name": Self.string("The guide's name, e.g. \"Coffee Crawl\"."),
                    "places": [
                        "type": "array",
                        "description": .string("Optional: the guide's initial places, in order."),
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "address": Self.string("The place's street address."),
                                "latitude": [
                                    "type": "number",
                                    "description": .string("Optional: the place's latitude."),
                                ],
                                "longitude": [
                                    "type": "number",
                                    "description": .string("Optional: the place's longitude."),
                                ],
                            ]),
                            "required": .array([.string("address")]),
                        ]),
                    ],
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["name"]))
        case .guidesDelete:
            return ToolMetadata(
                name: rawValue,
                description: "Delete a place guide and the places in it.",
                inputSchema: Self.schema([
                    "guideId": Self.string("A guide id returned by guides_list."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["guideId"]))
        case .guidesReorderPlaces:
            return ToolMetadata(
                name: rawValue,
                description: "Reorder the places in a guide. Pass every place id in the guide, in the new order.",
                inputSchema: Self.schema([
                    "guideId": Self.string("A guide id returned by guides_list."),
                    "placeIds": [
                        "type": "array",
                        "description": .string("Every place id in the guide (from places_list), in the desired order."),
                        "items": .object(["type": "string"]),
                    ],
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["guideId", "placeIds"]))
        case .placesDelete:
            return ToolMetadata(
                name: rawValue,
                description: "Delete one place from a guide.",
                inputSchema: Self.schema([
                    "placeId": Self.string("A place id returned by places_list."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["placeId"]))
        }
    }
}
