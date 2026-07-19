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
    case contactsList = "contacts_list"
    case contactsGet = "contacts_get"
    case contactsListNotes = "contacts_list_notes"
    case contactsListCustomFields = "contacts_list_custom_fields"
    case contactsListGroups = "contacts_list_groups"
    case eventsList = "events_list"
    case eventsGet = "events_get"
    case eventsListTags = "events_list_tags"
    case guidesList = "guides_list"
    case guidesGet = "guides_get"
    case placesList = "places_list"
    case linksList = "links_list"

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
    // Single-entry list edits (plans/cli-mcp.md Phase 7). contacts_update
    // is scalars-only — these are the ONLY way to change a contact's
    // multi-value lists, one entry per call, matched by exact value so a
    // model can never bulk-replace a list believing it edited one item.
    // Postal addresses, social profiles, and instant messages have no
    // single-entry tools yet (their identity spans several subfields);
    // they can only be provided at create.
    case contactsAddValue = "contacts_add_value"
    case contactsDeleteValue = "contacts_delete_value"
    case contactsEditValue = "contacts_edit_value"
    case contactsAddNote = "contacts_add_note"
    case contactsEditNote = "contacts_edit_note"
    case contactsDeleteNote = "contacts_delete_note"
    case contactsSetCustomField = "contacts_set_custom_field"
    case contactsDeleteCustomField = "contacts_delete_custom_field"
    case contactsSetFavorite = "contacts_set_favorite"
    case eventsAddTag = "events_add_tag"
    case eventsEditTag = "events_edit_tag"
    case eventsDeleteTag = "events_delete_tag"
    case guidesCreate = "guides_create"
    case guidesDelete = "guides_delete"
    case guidesReorderPlaces = "guides_reorder_places"
    case placesDelete = "places_delete"
    // Generic connections between records (contacts, events, places) — the
    // same kind pairs the app's detail views can create, and the single
    // linking surface: links_create / links_delete are writes, links_list
    // the read.
    case linksCreate = "links_create"
    case linksDelete = "links_delete"

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
        case .contactsSearch, .contactsList, .contactsGet, .contactsListNotes,
             .contactsListCustomFields, .contactsListGroups,
             .contactsCreate, .contactsUpdate, .contactsDelete,
             .contactsAddValue, .contactsDeleteValue, .contactsEditValue,
             .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsSetFavorite:
            return .contacts
        case .eventsList, .eventsGet, .eventsListTags,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag:
            return .events
        case .guidesList, .guidesGet, .placesList,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete:
            return .none
        case .linksList, .linksCreate, .linksDelete:
            // Connection storage is GuessWho's own; no single system
            // permission covers a tool whose endpoints span kinds. The
            // dispatcher additionally gates per call on each referenced
            // endpoint kind's system permission (contacts / events).
            return .none
        }
    }

    /// Whether this tool mutates data. Write tools are hidden from
    /// `listTools` while the origin's read-only toggle is on AND rejected
    /// per-call by the same gate (consent = the toggle, granted once in the
    /// app's settings; writes are OFF by default — plans/cli-mcp.md Phase 2).
    public var isWrite: Bool {
        switch self {
        case .contactsSearch, .contactsList, .contactsGet, .contactsListNotes,
             .contactsListCustomFields, .contactsListGroups,
             .eventsList, .eventsGet, .eventsListTags,
             .guidesList, .guidesGet, .placesList, .linksList:
            return false
        case .contactsCreate, .contactsUpdate, .contactsDelete,
             .contactsAddValue, .contactsDeleteValue, .contactsEditValue,
             .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsSetFavorite,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete,
             .linksCreate, .linksDelete:
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
        "A contact id — from contacts_search, contacts_list, or the otherId of a links_list row whose kind is person or organization. Ids can go out of date; if a call reports that, search again for a fresh one."
    private static let limitDoc =
        "Maximum number of items to return in one page (default 50, max 200)."
    private static let cursorDoc =
        "Opaque paging cursor from a previous page's nextCursor. Omit for the first page."
    private static let idempotencyDoc =
        "Optional: a unique string of your choosing that identifies this one change. If the call is retried with the same value, the change is applied only once."
    private static let eventIdDoc =
        "An event id — from events_list, or the otherId of a links_list row whose kind is event."
    private static let linkKindDoc =
        "\"person\", \"organization\", \"event\", or \"place\" — what kind of record the id refers to. For a contact, use the kind value that contacts_search / contacts_list reported for it (person or organization) — they share one id space but the kind must match."

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

    private static func stringEnum(_ values: [String], description: String) -> Value {
        [
            "type": "string",
            "enum": .array(values.map(Value.string)),
            "description": .string(description),
        ]
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

    // Shared metadata for the single-entry list tools: one entry per call,
    // matched by exact value, never a whole-list replacement. The
    // descriptions spell out the 0-match / many-match behavior so a model
    // knows an unmatched or ambiguous call changed nothing.
    private static var listFieldValues: [String] {
        WireContactListField.allCases.map(\.rawValue)
    }
    private static let listFieldDoc =
        "Which contact-card list to change: phone, email, url, related_name, or date."
    private static let listValueDoc =
        "The phone number, email address, web address, or related person's name. For date, use yyyy-MM-dd, or --MM-dd when the year is unknown. A birthday is a contacts_update field, not a date entry."
    private static let listLabelDoc =
        "Optional custom label, e.g. mobile, work, homepage, mother, manager, or anniversary."

    private static func listAddMetadata(name: String) -> ToolMetadata {
        ToolMetadata(
            name: name,
            description: "Add exactly ONE phone number, email address, web address, related name, or labeled date to a contact, with an optional label. The rest of that list is untouched. For field date, use yyyy-MM-dd or --MM-dd; a birthday is a contacts_update field, not a date entry. Returns the updated card.",
            inputSchema: schema([
                "contactId": string(contactIdDoc),
                "field": stringEnum(listFieldValues, description: listFieldDoc),
                "value": string(listValueDoc),
                "label": string(listLabelDoc),
                "idempotencyToken": string(idempotencyDoc),
            ], required: ["contactId", "field", "value"]))
    }

    private static func listRemoveMetadata(name: String) -> ToolMetadata {
        ToolMetadata(
            name: name,
            description: "Remove exactly ONE entry from a contact's phone, email, url, related-name, or date list — the single entry whose value exactly matches. The rest of that list is untouched. If no entry matches, the result is notFound; if more than one matches, the result is ambiguous; in either case nothing is removed. Date values use canonical yyyy-MM-dd or --MM-dd matching, and a birthday is a contacts_update field, not a date entry. Returns the updated card.",
            inputSchema: schema([
                "contactId": string(contactIdDoc),
                "field": stringEnum(listFieldValues, description: listFieldDoc),
                "value": string("The exact value to remove, as it appears on the contact's card. " + listValueDoc),
                "idempotencyToken": string(idempotencyDoc),
            ], required: ["contactId", "field", "value"]))
    }

    private static func listEditMetadata(name: String) -> ToolMetadata {
        ToolMetadata(
            name: name,
            description: "Change exactly ONE entry in a contact's phone, email, url, related-name, or date list — the single entry whose value exactly matches currentValue is replaced with newValue (and newLabel, if given). The rest of that list is untouched. If no entry matches, the result is notFound; if more than one matches, the result is ambiguous; in either case nothing is changed. Date values use canonical yyyy-MM-dd or --MM-dd matching, and a birthday is a contacts_update field, not a date entry. Returns the updated card.",
            inputSchema: schema([
                "contactId": string(contactIdDoc),
                "field": stringEnum(listFieldValues, description: listFieldDoc),
                "currentValue": string("The exact value to change, as it appears on the contact's card. " + listValueDoc),
                "newValue": string("The replacement value. " + listValueDoc),
                "newLabel": string("Optional custom replacement label. Omit to keep the current label."),
                "idempotencyToken": string(idempotencyDoc),
            ], required: ["contactId", "field", "currentValue", "newValue"]))
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

    /// The single-value contact-card fields — the full contacts_update
    /// surface, and the scalar half of contacts_create. There is
    /// deliberately NO note-shaped property here (notes ride
    /// contacts_add_note), and the contact id is never among the editable
    /// fields.
    private static var contactScalarFieldProperties: [String: Value] {
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
            "birthday": string(
                "Birthday as yyyy-MM-dd, or --MM-dd when the year is unknown. Pass an empty string to clear it."),
        ]
    }

    /// The full contact-card field set contacts_create accepts: the
    /// scalars plus the multi-value lists (safe to take whole here — a new
    /// card has no existing entries to clobber; after creation, lists
    /// change one entry at a time through the dedicated tools).
    private static var contactFieldProperties: [String: Value] {
        var properties = contactScalarFieldProperties
        for (name, value) in contactListFieldProperties {
            properties[name] = value
        }
        return properties
    }

    private static var contactListFieldProperties: [String: Value] {
        [
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
        case .contactsList:
            var props = Self.pagingProperties
            props["kind"] = Self.string(
                "Optional: \"person\" or \"organization\" to list only that kind of contact. Omit to list both.")
            props["favoritesOnly"] = [
                "type": "boolean",
                "description": .string("Only contacts the user has marked favorite."),
            ]
            props["groupId"] = Self.string(
                "Only members of this group; pass an id from contacts_list_groups.")
            return ToolMetadata(
                name: rawValue,
                description: "List all the user's contacts, ordered by name — optionally only people or only organizations, only favorites, or only one group's members (the filters combine). Returns a page of contacts, each with an id usable with the other contacts tools; pass nextCursor back to get the next page.",
                inputSchema: Self.schema(props))
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
        case .contactsListGroups:
            return ToolMetadata(
                name: rawValue,
                description: "List the user's contact groups.",
                inputSchema: Self.schema(Self.pagingProperties))
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
        case .linksList:
            var props = Self.pagingProperties
            props["id"] = Self.string(
                "The record whose connections to list — a contact id, an event id from events_list, or a place id from places_list.")
            props["kind"] = Self.string(Self.linkKindDoc)
            return ToolMetadata(
                name: rawValue,
                description: "List every connection on a record — the people, organizations, events, and places the user has connected to it, each with an optional note. Each entry carries the other record's id and kind, usable with the matching read tool.",
                inputSchema: Self.schema(props, required: ["id", "kind"]))

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
            var props = Self.contactScalarFieldProperties
            props["contactId"] = Self.string(Self.contactIdDoc)
            props["idempotencyToken"] = Self.string(Self.idempotencyDoc)
            return ToolMetadata(
                name: rawValue,
                description: "Edit a contact's single-value fields: names and phonetics, nickname, organization, department, job title, and birthday. Only the fields you pass change; pass an empty string to clear one. Phone numbers, email addresses, web addresses, related names, and dates are NOT accepted here — change those one entry at a time with contacts_add_value, contacts_edit_value, or contacts_delete_value and the matching field value. Returns the updated card.",
                inputSchema: Self.schema(props, required: ["contactId"]))
        case .contactsAddValue:
            return Self.listAddMetadata(name: rawValue)
        case .contactsDeleteValue:
            return Self.listRemoveMetadata(name: rawValue)
        case .contactsEditValue:
            return Self.listEditMetadata(name: rawValue)
        case .contactsDelete:
            return ToolMetadata(
                name: rawValue,
                description: "Delete a contact entirely. The user must approve a confirmation in the GuessWho app before anything happens, so this can take a while; if they decline, the result says so and nothing is changed. The notes, custom fields, tags, and connections saved for this contact go away with it — they're no longer available once the contact is deleted.",
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
                    "type": Self.stringEnum(
                        ["text", "multilineNote", "date", "checkbox"],
                        description: "The field's type. \"text\" is a single line; \"multilineNote\" is a longer note. Defaults to \"text\"."),
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
        case .linksCreate:
            return ToolMetadata(
                name: rawValue,
                description: "Connect two records, with an optional note about the connection. People, organizations, events, and places can be connected in any combination except place with place. Returns the new connection, described from the first record's side.",
                inputSchema: Self.schema([
                    "fromId": Self.string(
                        "The first record's id — a contact id, an event id from events_list, or a place id from places_list."),
                    "fromKind": Self.string(Self.linkKindDoc),
                    "toId": Self.string(
                        "The second record's id — a contact id, an event id from events_list, or a place id from places_list."),
                    "toKind": Self.string(Self.linkKindDoc),
                    "note": Self.string(
                        "Optional: a short note about the connection, e.g. \"Met at this cafe\"."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["fromId", "fromKind", "toId", "toKind"]))
        case .linksDelete:
            return ToolMetadata(
                name: rawValue,
                description: "Remove a connection between two records. The user can restore a recently removed connection from the app.",
                inputSchema: Self.schema([
                    "linkId": Self.string("A connection id returned by links_list or links_create."),
                    "idempotencyToken": Self.string(Self.idempotencyDoc),
                ], required: ["linkId"]))
        }
    }
}
