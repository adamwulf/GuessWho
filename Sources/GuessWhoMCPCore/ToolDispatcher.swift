import Foundation
import GuessWhoSync
import GuessWhoMCPWire

/// The per-tool dispatch core (plans/cli-mcp.md Phase 1).
///
/// One entry point — `handle(_:)` — takes a decoded wire request and
/// returns the wire response. The app's host adapter feeds it requests off
/// the pipes; tests feed it requests directly against fakes.
///
/// Dispatch model (the 2026-07-02 hang guard): every repository/engine
/// read happens in a single hop to the main actor per tool call, returning
/// Sendable model values. Handle minting, DTO mapping, pagination, and
/// size-capping all run here, OFF the main actor, so agent bursts and
/// large encodes never contend with the UI.
///
/// Gates are enforced PER-CALL here — an MCP client can call a tool that
/// `listTools` hid, so hiding is UX and this is the enforcement.
public actor ToolDispatcher {
    private let contacts: MCPContactSource
    private let events: MCPEventSource
    private let guides: MCPGuideSource
    private let gates: MCPGateSource
    private let registry: HandleRegistry

    /// Sliding-window rate limit for contacts_search, global across ALL
    /// helpers for the host run (a per-helper budget would reset on the
    /// cheap automatic re-handshake). `matches()` is linear over the whole
    /// cached book on the main actor, so unbounded search bursts would
    /// starve the UI.
    private var searchWindow: [Date] = []
    private let searchLimitPerWindow: Int
    private let searchWindowSeconds: TimeInterval

    /// Sliding-window WRITE budget — same keying as the search window: per
    /// HOST RUN, global across all helpers, never per-helper (re-announce is
    /// cheap and automatic, so a per-helper budget would reset on every
    /// reconnect). Every admitted write is a real coordinated sidecar write
    /// pushed to iCloud, so this is the blast-radius bound (plans/cli-mcp.md
    /// Phase 2).
    private var writeWindow: [Date] = []
    private let writeLimitPerWindow: Int
    private let writeWindowSeconds: TimeInterval

    /// Host-run-scoped idempotency dedup: (helper, client token) → the
    /// response the original attempt produced. A retried write with the same
    /// token within the window replays that response (re-addressed to the
    /// retry's message id) instead of re-applying a non-idempotent write.
    private var idempotencyCache: [String: (recordedAt: Date, response: WireResponse)] = [:]
    private let idempotencyWindowSeconds: TimeInterval

    /// Device-local agent-activity log; appended AFTER each engine write
    /// returns. Optional so read-only deployments and most tests can omit it.
    private let audit: MCPAuditLog?

    /// Per-key (contact localID) write serialization — the host-side
    /// single-flight that closes the double-mint race for agent writes
    /// (see resolveOrMintGuessWhoID's accepted race in GuessWhoSync and
    /// plans/cli-mcp.md Phase 2). Keys are held across the whole
    /// resolve→write→verify sequence; acquisition is in sorted order so
    /// multi-key writes (linking two contacts) can't deadlock.
    private var lockedWriteKeys: Set<String> = []
    private var writeKeyWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private static let defaultLimit = 50
    private static let maxLimit = 200

    public init(
        contacts: MCPContactSource,
        events: MCPEventSource,
        guides: MCPGuideSource,
        gates: MCPGateSource,
        registry: HandleRegistry = HandleRegistry(),
        audit: MCPAuditLog? = nil,
        searchLimitPerWindow: Int = 30,
        searchWindowSeconds: TimeInterval = 60,
        writeLimitPerWindow: Int = 30,
        writeWindowSeconds: TimeInterval = 60,
        idempotencyWindowSeconds: TimeInterval = 600
    ) {
        self.contacts = contacts
        self.events = events
        self.guides = guides
        self.gates = gates
        self.registry = registry
        self.audit = audit
        self.searchLimitPerWindow = searchLimitPerWindow
        self.searchWindowSeconds = searchWindowSeconds
        self.writeLimitPerWindow = writeLimitPerWindow
        self.writeWindowSeconds = writeWindowSeconds
        self.idempotencyWindowSeconds = idempotencyWindowSeconds
    }

    // MARK: - Entry point

    public func handle(_ request: WireRequest) async -> WireResponse {
        let helperId = request.helperId
        let messageId = request.messageId

        if case .listTools = request {
            return await listTools(helperId: helperId, messageId: messageId)
        }

        guard let tool = request.tool else {
            // Control messages are the transport's business; answering one
            // here means a wiring bug, not an agent mistake.
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        }

        if let gateError = await gateCheck(tool: tool, helperId: helperId, messageId: messageId) {
            return gateError
        }

        if tool.isWrite {
            return capped(await handleWrite(request, helperId: helperId, messageId: messageId))
        }

        let response: WireResponse
        switch request {
        case .contactsSearch(_, _, let query, let limit, let cursor):
            response = await contactsSearch(
                helperId: helperId, messageId: messageId,
                query: query, limit: limit, cursor: cursor)
        case .contactsGet(_, _, let contactId):
            response = await contactsGet(
                helperId: helperId, messageId: messageId, contactId: contactId)
        case .contactsListNotes(_, _, let contactId, let limit, let cursor):
            response = await contactsListNotes(
                helperId: helperId, messageId: messageId,
                contactId: contactId, limit: limit, cursor: cursor)
        case .contactsListCustomFields(_, _, let contactId, let limit, let cursor):
            response = await contactsListCustomFields(
                helperId: helperId, messageId: messageId,
                contactId: contactId, limit: limit, cursor: cursor)
        case .contactsListLinkedContacts(_, _, let contactId, let limit, let cursor):
            response = await contactsListLinked(
                helperId: helperId, messageId: messageId,
                contactId: contactId, kind: "person", limit: limit, cursor: cursor)
        case .contactsListLinkedOrganizations(_, _, let contactId, let limit, let cursor):
            response = await contactsListLinked(
                helperId: helperId, messageId: messageId,
                contactId: contactId, kind: "organization", limit: limit, cursor: cursor)
        case .contactsListFavorites(_, _, let limit, let cursor):
            response = await contactsListFavorites(
                helperId: helperId, messageId: messageId, limit: limit, cursor: cursor)
        case .contactsListGroups(_, _, let limit, let cursor):
            response = await contactsListGroups(
                helperId: helperId, messageId: messageId, limit: limit, cursor: cursor)
        case .groupsListMembers(_, _, let groupId, let limit, let cursor):
            response = await groupsListMembers(
                helperId: helperId, messageId: messageId,
                groupId: groupId, limit: limit, cursor: cursor)
        case .eventsList(_, _, let startDate, let endDate, let limit, let cursor):
            response = await eventsList(
                helperId: helperId, messageId: messageId,
                startDate: startDate, endDate: endDate, limit: limit, cursor: cursor)
        case .eventsGet(_, _, let eventId):
            response = await eventsGet(helperId: helperId, messageId: messageId, eventId: eventId)
        case .eventsListTags(_, _, let eventId, let limit, let cursor):
            response = await eventsListTags(
                helperId: helperId, messageId: messageId,
                eventId: eventId, limit: limit, cursor: cursor)
        case .guidesList(_, _, let limit, let cursor):
            response = await guidesList(helperId: helperId, messageId: messageId, limit: limit, cursor: cursor)
        case .guidesGet(_, _, let guideId):
            response = await guidesGet(helperId: helperId, messageId: messageId, guideId: guideId)
        case .placesList(_, _, let guideId, let limit, let cursor):
            response = await placesList(
                helperId: helperId, messageId: messageId,
                guideId: guideId, limit: limit, cursor: cursor)
        case .initialize, .deinitialize, .ping, .listTools:
            response = .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        case .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsAddLinkedContact, .contactsAddLinkedOrganization,
             .contactsRemoveLinkedContact, .contactsSetFavorite,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete:
            // Unreachable: every write case dispatched through handleWrite
            // above (tool.isWrite). Kept explicit so a new write case that
            // forgets its isWrite classification fails a test, not silently.
            response = .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        }
        return capped(response)
    }

    // MARK: - Gates

    /// Tools visible to `listTools`, given the live gates. Empty when the
    /// origin's master toggle is off — with the status string riding along
    /// so the agent relays something actionable instead of "no tools".
    private func listTools(helperId: String, messageId: String) async -> WireResponse {
        let origin = RequestOrigin.from(helperId: helperId) ?? .mcp
        let (enabled, readOnly, contactsOK, eventsOK) = await MainActor.run {
            (
                origin == .cli ? gates.isCLIEnabled : gates.isMCPEnabled,
                origin == .cli ? gates.isCLIReadOnly : gates.isMCPReadOnly,
                gates.contactsAuthorized,
                gates.eventsAuthorized
            )
        }
        guard enabled else {
            return .toolList(
                helperId: helperId, messageId: messageId,
                tools: [], status: WireErrorMessage.disabled)
        }
        let tools = MCPTool.allCases.filter { tool in
            if tool.isWrite && readOnly { return false }
            switch tool.permissionDomain {
            case .contacts: return contactsOK
            case .events: return eventsOK
            case .none: return true
            }
        }
        return .toolList(
            helperId: helperId, messageId: messageId,
            tools: tools.map(\.metadata), status: nil)
    }

    /// The per-call server-side gate: master toggle by origin, then the
    /// origin's read-only toggle for write tools (THE consent gate — writes
    /// are off by default, no per-call dialogs), then the tool's permission
    /// domain. Returns the error to send, or nil to proceed.
    private func gateCheck(tool: MCPTool, helperId: String, messageId: String) async -> WireResponse? {
        let origin = RequestOrigin.from(helperId: helperId) ?? .mcp
        let (enabled, readOnly, contactsOK, eventsOK) = await MainActor.run {
            (
                origin == .cli ? gates.isCLIEnabled : gates.isMCPEnabled,
                origin == .cli ? gates.isCLIReadOnly : gates.isMCPReadOnly,
                gates.contactsAuthorized,
                gates.eventsAuthorized
            )
        }
        guard enabled else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .disabled, message: WireErrorMessage.disabled)
        }
        if tool.isWrite && readOnly {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .readOnly, message: WireErrorMessage.readOnly)
        }
        switch tool.permissionDomain {
        case .contacts where !contactsOK:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        case .events where !eventsOK:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .permissionDenied, message: WireErrorMessage.permissionDeniedEvents)
        default:
            return nil
        }
    }

    // MARK: - Contacts tools

    private func contactsSearch(
        helperId: String, messageId: String, query: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams,
                message: "The query argument must be at least 2 characters.")
        }
        guard admitSearch() else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .busy, message: WireErrorMessage.busy)
        }
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }

        // Search on a copy whose URL list is pre-filtered to the
        // user-visible addresses: `matches()` iterates the RAW list, which
        // carries the internal identity URL, and match-presence alone leaks
        // (INV-3b — `contacts_search("guesswho")` must find nothing via
        // that URL). `matches()` itself is the pinned, note-free search
        // (INV-3).
        let matching = await MainActor.run { () -> [Contact] in
            contacts.allContacts.filter { contact in
                var sanitized = contact
                sanitized.urlAddresses = contact.userVisibleURLAddresses
                return sanitized.matches(searchQuery: needle)
            }
        }
        let (slice, nextCursor) = page.slice(matching)
        var items: [WireContactSummary] = []
        items.reserveCapacity(slice.count)
        for contact in slice {
            items.append(WireMapping.summary(contact, handle: await mintContactHandle(contact)))
        }
        return .contactPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func contactsGet(helperId: String, messageId: String, contactId: String) async -> WireResponse {
        switch await resolveContact(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let isFavorite = await MainActor.run { contacts.isFavorite(contact.contactID) }
            let handle = await mintContactHandle(contact)
            return .contact(
                helperId: helperId, messageId: messageId,
                contact: WireMapping.contact(contact, handle: handle, isFavorite: isFavorite))
        }
    }

    private func contactsListNotes(
        helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveContact(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let id = contact.contactID
            let fetchedNotes = await MainActor.run { contacts.notes(for: id) }
            let notes = fetchedNotes
                .filter { !$0.isDeleted }
                .sorted { $0.createdAt < $1.createdAt }
            let (slice, nextCursor) = page.slice(notes)
            var items: [WireNote] = []
            for note in slice {
                let handle = await registry.handle(for: .note(note.id))
                if let dto = WireMapping.note(note, handle: handle) { items.append(dto) }
            }
            return .notePage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: items, nextCursor: nextCursor))
        }
    }

    private func contactsListCustomFields(
        helperId: String, messageId: String, contactId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveContact(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let id = contact.contactID
            // `fields(for:)` is the pinned source: it already excludes
            // attachment-typed fields (the previousPhoto phantom-row
            // lesson); the mapper re-drops them defensively.
            let fetchedFields = await MainActor.run { contacts.fields(for: id) }
            let fields = fetchedFields.filter { $0.deletedAt == nil }
            let (slice, nextCursor) = page.slice(fields)
            var items: [WireCustomField] = []
            for field in slice {
                let handle = await registry.handle(for: .customField(field.id))
                if let dto = WireMapping.customField(field, handle: handle) { items.append(dto) }
            }
            return .customFieldPage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: items, nextCursor: nextCursor))
        }
    }

    /// Shared list for Linked Contacts ("person") / Linked Organizations
    /// ("organization") — the shipping UI's two sections, partitioned by
    /// the far endpoint's kind.
    private func contactsListLinked(
        helperId: String, messageId: String, contactId: String, kind: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveContact(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let id = contact.contactID
            let wantOrganization = kind == "organization"
            let links = await contacts.links(for: id)
            var pairs: [(Link, Contact)] = []
            for link in links where link.deletedAt == nil {
                // DELIBERATE divergence from the UI: a link whose far
                // endpoint doesn't resolve (deleted / not-yet-synced
                // contact) is DROPPED here, while the detail view buckets
                // it into "People" as a placeholder row. The placeholder
                // exists so a human can repair or delete the link; an
                // agent can't act on a row with no name and no id (there
                // is no Contact to mint a sealed reference from), and a
                // partial DTO would break the allowlist shape.
                guard let other = await MainActor.run(body: { contacts.linkedContact(of: link, for: id) })
                else { continue }
                let isOrganization = other.contactType == .organization
                if isOrganization == wantOrganization {
                    pairs.append((link, other))
                }
            }
            pairs.sort { $0.0.createdAt < $1.0.createdAt }
            let (slice, nextCursor) = page.slice(pairs)
            var items: [WireLinkedContact] = []
            for (link, other) in slice {
                let linkHandle = await registry.handle(for: .link(link.id))
                let otherHandle = await mintContactHandle(other)
                if let dto = WireMapping.linkedContact(
                    link: link, linkHandle: linkHandle, other: other, otherHandle: otherHandle) {
                    items.append(dto)
                }
            }
            return .linkedContactPage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: items, nextCursor: nextCursor))
        }
    }

    private func contactsListFavorites(
        helperId: String, messageId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let favorites = await MainActor.run { () -> [Contact] in
            contacts.allContacts.filter { contacts.isFavorite($0.contactID) }
        }
        let (slice, nextCursor) = page.slice(favorites)
        var items: [WireContactSummary] = []
        for contact in slice {
            items.append(WireMapping.summary(contact, handle: await mintContactHandle(contact)))
        }
        return .contactPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func contactsListGroups(
        helperId: String, messageId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let groups = await contacts.fetchGroups()
        let (slice, nextCursor) = page.slice(groups)
        var items: [WireGroup] = []
        for group in slice {
            let handle = await registry.handle(for: .group(localID: group.localID))
            items.append(WireMapping.group(group, handle: handle))
        }
        return .groupPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func groupsListMembers(
        helperId: String, messageId: String, groupId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        guard let entry = await registry.entry(for: groupId),
              case .group(let localID) = entry.referent
        else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        let members = await contacts.members(ofGroup: localID)
        let (slice, nextCursor) = page.slice(members)
        var items: [WireContactSummary] = []
        for contact in slice {
            items.append(WireMapping.summary(contact, handle: await mintContactHandle(contact)))
        }
        return .contactPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    // MARK: - Events tools

    private func eventsList(
        helperId: String, messageId: String, startDate: String, endDate: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        guard let start = Self.parseISODate(startDate) else {
            return .error(
                helperId: helperId, messageId: messageId, code: .invalidParams,
                message: "The startDate argument for events_list must be an ISO 8601 date, like 2026-07-01T00:00:00Z.")
        }
        guard let end = Self.parseISODate(endDate) else {
            return .error(
                helperId: helperId, messageId: messageId, code: .invalidParams,
                message: "The endDate argument for events_list must be an ISO 8601 date, like 2026-07-31T00:00:00Z.")
        }
        guard end > start else {
            return .error(
                helperId: helperId, messageId: messageId, code: .invalidParams,
                message: "endDate must be after startDate.")
        }
        guard end.timeIntervalSince(start) <= 366 * 24 * 3600 else {
            return .error(
                helperId: helperId, messageId: messageId, code: .invalidParams,
                message: "The date window may span at most one year. Ask for a narrower window.")
        }

        let fetched = await events.fetchEventsRange(from: start, to: end)
        let sorted = fetched.sorted { $0.startDate < $1.startDate }
        let (slice, nextCursor) = page.slice(sorted)
        var items: [WireEventSummary] = []
        for event in slice {
            let handle = await mintEventHandle(event)
            items.append(WireMapping.eventSummary(event, handle: handle))
        }
        return .eventPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func eventsGet(helperId: String, messageId: String, eventId: String) async -> WireResponse {
        switch await resolveEvent(eventId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let event):
            let handle = await mintEventHandle(event)
            return .event(
                helperId: helperId, messageId: messageId,
                event: WireMapping.event(event, handle: handle))
        }
    }

    private func eventsListTags(
        helperId: String, messageId: String, eventId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveEvent(eventId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let event):
            let uuid = Self.eventUUIDString(event)
            let fetchedTags = await MainActor.run { events.eventTags(forEventUUID: uuid) }
            let tags = fetchedTags.filter { $0.deletedAt == nil }
            let (slice, nextCursor) = page.slice(tags)
            var items: [WireTag] = []
            for tag in slice {
                let handle = await registry.handle(for: .tag(tag.id))
                if let dto = WireMapping.tag(tag, handle: handle) { items.append(dto) }
            }
            return .tagPage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: items, nextCursor: nextCursor))
        }
    }

    // MARK: - Guides tools

    private func guidesList(
        helperId: String, messageId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let all = await guides.allGuides()
        let sorted = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let (slice, nextCursor) = page.slice(sorted)
        var items: [WireGuide] = []
        for guide in slice {
            let handle = await registry.handle(for: .guide(guide.id))
            items.append(WireMapping.guide(guide, handle: handle))
        }
        return .guidePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func guidesGet(helperId: String, messageId: String, guideId: String) async -> WireResponse {
        guard let entry = await registry.entry(for: guideId),
              case .guide(let id) = entry.referent
        else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        let all = await guides.allGuides()
        guard let guide = all.first(where: { $0.id == id }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        let handle = await registry.handle(for: .guide(guide.id))
        return .guide(
            helperId: helperId, messageId: messageId,
            guide: WireMapping.guide(guide, handle: handle))
    }

    private func placesList(
        helperId: String, messageId: String, guideId: String?, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let places: [MapsPlace]
        if let guideId {
            guard let entry = await registry.entry(for: guideId),
                  case .guide(let id) = entry.referent
            else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            places = await guides.places(inGuide: id)
        } else {
            places = await guides.allPlaces()
        }
        let (slice, nextCursor) = page.slice(places)
        var items: [WirePlace] = []
        for place in slice {
            let handle = await registry.handle(for: .place(place.id))
            let guideHandle = await registry.handle(for: .guide(place.guideID))
            items.append(WireMapping.place(place, handle: handle, guideHandle: guideHandle))
        }
        return .placePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    // MARK: - Write pipeline (plans/cli-mcp.md Phase 2)

    /// The write wrapper every write tool runs through: idempotent replay →
    /// write budget → execute. The idempotency check comes FIRST so a retry
    /// neither burns budget nor re-applies; only successful responses are
    /// cached (a failed write should re-attempt on retry).
    private func handleWrite(
        _ request: WireRequest, helperId: String, messageId: String
    ) async -> WireResponse {
        if let token = request.idempotencyToken {
            pruneIdempotencyCache()
            if let cached = idempotencyCache[Self.idempotencyKey(helperId: helperId, token: token)] {
                return cached.response.readdressed(helperId: helperId, messageId: messageId)
            }
        }
        guard admitWrite() else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .busy, message: WireErrorMessage.writeBusy)
        }
        let response = await executeWrite(request, helperId: helperId, messageId: messageId)
        if let token = request.idempotencyToken, response.errorPayload == nil {
            idempotencyCache[Self.idempotencyKey(helperId: helperId, token: token)] =
                (Date(), response)
        }
        return response
    }

    private func executeWrite(
        _ request: WireRequest, helperId: String, messageId: String
    ) async -> WireResponse {
        switch request {
        case .contactsAddNote(_, _, let contactId, let body, _):
            return await contactsAddNote(
                helperId: helperId, messageId: messageId, contactId: contactId, body: body)
        case .contactsEditNote(_, _, let contactId, let noteId, let body, _):
            return await contactsEditNote(
                helperId: helperId, messageId: messageId,
                contactId: contactId, noteId: noteId, body: body)
        case .contactsDeleteNote(_, _, let contactId, let noteId, _):
            return await contactsDeleteNote(
                helperId: helperId, messageId: messageId, contactId: contactId, noteId: noteId)
        case .contactsSetCustomField(_, _, let contactId, let name, let type, let value, _):
            return await contactsSetCustomField(
                helperId: helperId, messageId: messageId,
                contactId: contactId, name: name, type: type, value: value)
        case .contactsDeleteCustomField(_, _, let contactId, let fieldId, _):
            return await contactsDeleteCustomField(
                helperId: helperId, messageId: messageId, contactId: contactId, fieldId: fieldId)
        case .contactsAddLinkedContact(_, _, let contactId, let personId, let note, _):
            return await contactsAddLink(
                helperId: helperId, messageId: messageId,
                contactId: contactId, otherId: personId, note: note, wantOrganization: false)
        case .contactsAddLinkedOrganization(_, _, let contactId, let organizationId, let note, _):
            return await contactsAddLink(
                helperId: helperId, messageId: messageId,
                contactId: contactId, otherId: organizationId, note: note, wantOrganization: true)
        case .contactsRemoveLinkedContact(_, _, let linkId, _):
            return await contactsRemoveLink(
                helperId: helperId, messageId: messageId, linkId: linkId)
        case .contactsSetFavorite(_, _, let contactId, let favorite, _):
            return await contactsSetFavorite(
                helperId: helperId, messageId: messageId, contactId: contactId, favorite: favorite)
        case .eventsAddTag(_, _, let eventId, let text, _):
            return await eventsAddTag(
                helperId: helperId, messageId: messageId, eventId: eventId, text: text)
        case .eventsEditTag(_, _, let eventId, let tagId, let text, _):
            return await eventsEditTag(
                helperId: helperId, messageId: messageId,
                eventId: eventId, tagId: tagId, text: text)
        case .eventsDeleteTag(_, _, let eventId, let tagId, _):
            return await eventsDeleteTag(
                helperId: helperId, messageId: messageId, eventId: eventId, tagId: tagId)
        case .guidesCreate(_, _, let name, let places, _):
            return await guidesCreate(
                helperId: helperId, messageId: messageId, name: name, places: places)
        case .guidesDelete(_, _, let guideId, _):
            return await guidesDelete(helperId: helperId, messageId: messageId, guideId: guideId)
        case .guidesReorderPlaces(_, _, let guideId, let placeIds, _):
            return await guidesReorderPlaces(
                helperId: helperId, messageId: messageId, guideId: guideId, placeIds: placeIds)
        case .placesDelete(_, _, let placeId, _):
            return await placesDelete(helperId: helperId, messageId: messageId, placeId: placeId)
        default:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        }
    }

    // MARK: - Contact writes

    private func contactsAddNote(
        helperId: String, messageId: String, contactId: String, body: String
    ) async -> WireResponse {
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                let (effective, noteID) = try await withWriteKeysLocked([token.localID]) {
                    try await mintVerifiedWrite(
                        token: token,
                        write: { id in
                            try await contacts.addNote(for: id, body: body, createdAt: Date())
                        },
                        verify: { id, noteID in
                            await MainActor.run { contacts.notes(for: id).contains { $0.id == noteID } }
                        })
                }
                let written = await MainActor.run {
                    contacts.allNotes(for: effective.contactID).first { $0.id == noteID }
                }
                guard let written,
                      let dto = WireMapping.note(
                        written, handle: await registry.handle(for: .note(written.id)))
                else {
                    return writeFailure(helperId: helperId, messageId: messageId)
                }
                await recordAudit(
                    .addNote, kind: .contact, contact: effective,
                    instanceID: noteID, postModifiedAt: written.modifiedAt,
                    priorValue: nil, newValue: body)
                return .note(helperId: helperId, messageId: messageId, note: dto)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func contactsEditNote(
        helperId: String, messageId: String, contactId: String, noteId: String, body: String
    ) async -> WireResponse {
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            guard let noteUUID = await resolveInstance(noteId, kind: "note") else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            let id = contact.contactID
            let prior = await MainActor.run {
                contacts.notes(for: id).first { $0.id == noteUUID }
            }
            guard let prior else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundNote)
            }
            do {
                try await withWriteKeysLocked([id.localID]) {
                    try await contacts.editNote(for: id, id: noteUUID, newBody: body, createdAt: nil)
                }
                let written = await MainActor.run {
                    contacts.allNotes(for: id).first { $0.id == noteUUID }
                }
                guard let written,
                      let dto = WireMapping.note(
                        written, handle: await registry.handle(for: .note(written.id)))
                else {
                    return writeFailure(helperId: helperId, messageId: messageId)
                }
                await recordAudit(
                    .editNote, kind: .contact, contact: contact,
                    instanceID: noteUUID, postModifiedAt: written.modifiedAt,
                    priorValue: prior.body, newValue: body)
                return .note(helperId: helperId, messageId: messageId, note: dto)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func contactsDeleteNote(
        helperId: String, messageId: String, contactId: String, noteId: String
    ) async -> WireResponse {
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            guard let noteUUID = await resolveInstance(noteId, kind: "note") else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            let id = contact.contactID
            let prior = await MainActor.run {
                contacts.notes(for: id).first { $0.id == noteUUID }
            }
            guard let prior else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundNote)
            }
            do {
                try await withWriteKeysLocked([id.localID]) {
                    try await contacts.deleteNote(for: id, id: noteUUID)
                }
                let tombstone = await MainActor.run {
                    contacts.allNotes(for: id).first { $0.id == noteUUID }
                }
                await recordAudit(
                    .deleteNote, kind: .contact, contact: contact,
                    instanceID: noteUUID, postModifiedAt: tombstone?.modifiedAt,
                    priorValue: prior.body, newValue: nil)
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: WireAckMessage.noteDeleted)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func contactsSetCustomField(
        helperId: String, messageId: String, contactId: String,
        name: String, type: String?, value: String
    ) async -> WireResponse {
        let fieldName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fieldName.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "The name argument must not be empty.")
        }
        // Reserved-name guardrail: the upsert-by-name path REPLACES an
        // existing same-name field of a different type, so a write named
        // like an internal field would clobber it (the previousPhoto
        // photo-restore snapshot, the user's own notes).
        guard !ContactsRepository.isReservedFieldName(fieldName) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.reservedFieldName)
        }
        // Wire-writable types only; `.blob` and anything unknown is rejected
        // (an agent must never inject attachment pointers).
        guard let fieldType = Self.wireWritableFieldType(type) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidFieldType)
        }
        guard let payload = Self.fieldPayload(value, for: fieldType) else {
            let expected = fieldType == .date
                ? "The value argument for a date field must be an ISO 8601 date, like 2026-07-01."
                : "The value argument for a checkbox field must be \"true\" or \"false\"."
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: expected)
        }

        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                let priorValue = await MainActor.run {
                    contacts.fields(for: contact.contactID)
                        .first { $0.deletedAt == nil && $0.field == fieldName }
                        .flatMap { field -> String? in
                            if case .string(let string) = field.value { return string }
                            if case .bool(let bool) = field.value { return bool ? "true" : "false" }
                            return nil
                        }
                }
                let (effective, fieldID) = try await withWriteKeysLocked([token.localID]) {
                    try await mintVerifiedWrite(
                        token: token,
                        write: { id in
                            try await contacts.upsertField(
                                for: id, field: fieldName, value: payload, type: fieldType)
                        },
                        verify: { id, fieldID in
                            await MainActor.run { contacts.fields(for: id).contains { $0.id == fieldID } }
                        })
                }
                let written = await MainActor.run {
                    contacts.allFields(for: effective.contactID).first { $0.id == fieldID }
                }
                guard let written,
                      let dto = WireMapping.customField(
                        written, handle: await registry.handle(for: .customField(written.id)))
                else {
                    return writeFailure(helperId: helperId, messageId: messageId)
                }
                await recordAudit(
                    .setCustomField, kind: .contact, contact: effective,
                    instanceID: fieldID, postModifiedAt: written.modifiedAt,
                    priorValue: priorValue, newValue: value)
                return .customField(helperId: helperId, messageId: messageId, field: dto)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func contactsDeleteCustomField(
        helperId: String, messageId: String, contactId: String, fieldId: String
    ) async -> WireResponse {
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            guard let fieldUUID = await resolveInstance(fieldId, kind: "customField") else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            let id = contact.contactID
            let prior = await MainActor.run {
                contacts.fields(for: id).first { $0.id == fieldUUID }
            }
            guard let prior else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundField)
            }
            do {
                try await withWriteKeysLocked([id.localID]) {
                    try await contacts.deleteField(for: id, id: fieldUUID)
                }
                let tombstone = await MainActor.run {
                    contacts.allFields(for: id).first { $0.id == fieldUUID }
                }
                let priorValue: String? = {
                    if case .string(let string) = prior.value { return string }
                    if case .bool(let bool) = prior.value { return bool ? "true" : "false" }
                    return nil
                }()
                await recordAudit(
                    .deleteCustomField, kind: .contact, contact: contact,
                    instanceID: fieldUUID, postModifiedAt: tombstone?.modifiedAt,
                    priorValue: priorValue, newValue: nil)
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: WireAckMessage.fieldDeleted)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    /// Shared implementation for contacts_add_linked_contact ("person") and
    /// contacts_add_linked_organization ("organization") — one engine write,
    /// gated on the far endpoint's kind matching the tool.
    private func contactsAddLink(
        helperId: String, messageId: String, contactId: String, otherId: String,
        note: String?, wantOrganization: Bool
    ) async -> WireResponse {
        let near: Contact
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            near = contact
        }
        let far: Contact
        switch await resolveContactForWrite(otherId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            far = contact
        }
        let farIsOrganization = far.contactType == .organization
        guard farIsOrganization == wantOrganization else {
            let message = wantOrganization
                ? "That id belongs to a person. Use contacts_add_linked_contact for people."
                : "That id belongs to an organization. Use contacts_add_linked_organization for organizations."
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: message)
        }

        let nearToken = near.contactID.restorationToken
        let farToken = far.contactID.restorationToken
        do {
            let (effectiveNear, effectiveFar, link) = try await withWriteKeysLocked(
                [nearToken.localID, farToken.localID]
            ) { () -> (Contact, Contact, Link) in
                func resolveBoth() async throws -> (Contact, Contact) {
                    guard
                        let currentNear = await MainActor.run(body: { contacts.contact(restorationToken: nearToken) }),
                        let currentFar = await MainActor.run(body: { contacts.contact(restorationToken: farToken) })
                    else { throw WriteProblem.stale }
                    return (currentNear, currentFar)
                }
                func linkVisible(_ pair: (Contact, Contact), _ link: Link) async -> Bool {
                    let nearMintedBefore = pair.0.contactID.restorationToken.guessWhoID == nil
                    let farMintedBefore = pair.1.contactID.restorationToken.guessWhoID == nil
                    guard let (freshNear, freshFar) = try? await resolveBoth() else { return false }
                    if nearMintedBefore {
                        let seen = await contacts.links(for: freshNear.contactID).contains { $0.id == link.id }
                        if !seen { return false }
                    }
                    if farMintedBefore {
                        let seen = await contacts.links(for: freshFar.contactID).contains { $0.id == link.id }
                        if !seen { return false }
                    }
                    return true
                }

                var pair = try await resolveBoth()
                var link = try await contacts.addLink(
                    from: pair.0.contactID, to: pair.1.contactID, note: note ?? "")
                if await !linkVisible(pair, link) {
                    // A concurrent first-writer's mint won on one endpoint:
                    // the link is keyed on a losing identity. Remove it and
                    // retry once against the now-canonical identities — no
                    // half-orphaned link is left behind.
                    let staleLinkID = link.id
                    try? await MainActor.run { try contacts.removeLink(id: staleLinkID) }
                    pair = try await resolveBoth()
                    link = try await contacts.addLink(
                        from: pair.0.contactID, to: pair.1.contactID, note: note ?? "")
                    guard await linkVisible(pair, link) else { throw WriteProblem.verifyFailed }
                }
                let final = try await resolveBoth()
                return (final.0, final.1, link)
            }
            let linkHandle = await registry.handle(for: .link(link.id))
            let farHandle = await mintContactHandle(effectiveFar)
            guard let dto = WireMapping.linkedContact(
                link: link, linkHandle: linkHandle, other: effectiveFar, otherHandle: farHandle)
            else {
                return writeFailure(helperId: helperId, messageId: messageId)
            }
            await recordAudit(
                .addLinkedContact, kind: .contact, contact: effectiveNear,
                instanceID: link.id, postModifiedAt: link.modifiedAt,
                priorValue: nil, newValue: note)
            return .linkedContact(helperId: helperId, messageId: messageId, link: dto)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func contactsRemoveLink(
        helperId: String, messageId: String, linkId: String
    ) async -> WireResponse {
        guard let linkUUID = await resolveInstance(linkId, kind: "link") else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        let existing = await MainActor.run { contacts.link(id: linkUUID) }
        guard let existing, existing.deletedAt == nil else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundLink)
        }
        do {
            try await MainActor.run { try contacts.removeLink(id: linkUUID) }
            let tombstone = await MainActor.run { contacts.link(id: linkUUID) }
            // Best-effort display name from either contact endpoint, for
            // the audit row.
            let endpointA = existing.endpointA
            let endpointB = existing.endpointB
            let subjectName = await MainActor.run { () -> String? in
                let all = contacts.allContacts
                func name(_ endpoint: SidecarKey) -> String? {
                    guard endpoint.kind == .contact else { return nil }
                    return all.first {
                        $0.contactID.restorationToken.guessWhoID == endpoint.id
                    }?.displayName
                }
                return name(endpointA) ?? name(endpointB)
            }
            await audit?.record(MCPAuditEntry(
                at: Date(), action: .removeLinkedContact, subjectKind: .link,
                subjectID: linkUUID.uuidString.lowercased(),
                subjectName: subjectName ?? "",
                instanceID: linkUUID.uuidString.lowercased(),
                postModifiedAt: tombstone?.modifiedAt,
                priorValue: existing.note.isEmpty ? nil : existing.note,
                newValue: nil))
            return .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.linkRemoved)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func contactsSetFavorite(
        helperId: String, messageId: String, contactId: String, favorite: Bool
    ) async -> WireResponse {
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                let changed = try await withWriteKeysLocked([token.localID]) { () -> Bool in
                    guard let current = await MainActor.run(body: { contacts.contact(restorationToken: token) })
                    else { throw WriteProblem.stale }
                    let currentState = await MainActor.run { contacts.isFavorite(current.contactID) }
                    // Already in the requested state: an idempotent no-op —
                    // deliberately no engine call, so clearing the favorite
                    // of an untouched contact never mints an identity.
                    guard currentState != favorite else { return false }
                    let willMint = current.contactID.restorationToken.guessWhoID == nil
                    var newState = try await contacts.toggleFavorite(current.contactID)
                    if willMint {
                        guard let fresh = await MainActor.run(body: { contacts.contact(restorationToken: token) })
                        else { throw WriteProblem.verifyFailed }
                        let visible = await MainActor.run { contacts.isFavorite(fresh.contactID) }
                        if visible != favorite {
                            newState = try await contacts.toggleFavorite(fresh.contactID)
                            guard newState == favorite else { throw WriteProblem.verifyFailed }
                        }
                    }
                    guard newState == favorite else { throw WriteProblem.verifyFailed }
                    return true
                }
                if changed {
                    let effective = await MainActor.run { contacts.contact(restorationToken: token) }
                    await recordAudit(
                        .setFavorite, kind: .contact, contact: effective ?? contact,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: favorite ? "false" : "true",
                        newValue: favorite ? "true" : "false")
                }
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: favorite ? WireAckMessage.favoriteSet : WireAckMessage.favoriteCleared)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    // MARK: - Event tag writes

    private func eventsAddTag(
        helperId: String, messageId: String, eventId: String, text: String
    ) async -> WireResponse {
        let resolution = await resolveEventForWrite(eventId)
        switch resolution {
        case .unadopted, .stale:
            return resolution.failureResponse(helperId: helperId, messageId: messageId)
        case .adopted(let event):
            let uuid = Self.eventUUIDString(event)
            do {
                let tagID = try await MainActor.run {
                    try events.addEventTag(text: text, forEventUUID: uuid)
                }
                let written = await MainActor.run {
                    events.eventTags(forEventUUID: uuid).first { $0.id == tagID }
                }
                guard let written,
                      let dto = WireMapping.tag(
                        written, handle: await registry.handle(for: .tag(written.id)))
                else {
                    return writeFailure(helperId: helperId, messageId: messageId)
                }
                let cell = await MainActor.run {
                    events.allEventTagFields(forEventUUID: uuid).first { $0.id == tagID }
                }
                await recordAudit(
                    .addTag, kind: .event, subjectID: uuid, subjectName: event.title,
                    instanceID: tagID, postModifiedAt: cell?.modifiedAt,
                    priorValue: nil, newValue: text)
                return .tag(helperId: helperId, messageId: messageId, tag: dto)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func eventsEditTag(
        helperId: String, messageId: String, eventId: String, tagId: String, text: String
    ) async -> WireResponse {
        let resolution = await resolveEventForWrite(eventId)
        switch resolution {
        case .unadopted, .stale:
            return resolution.failureResponse(helperId: helperId, messageId: messageId)
        case .adopted(let event):
            guard let tagUUID = await resolveInstance(tagId, kind: "tag") else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            let uuid = Self.eventUUIDString(event)
            let prior = await MainActor.run {
                events.eventTags(forEventUUID: uuid).first { $0.id == tagUUID }
            }
            guard let prior else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundTag)
            }
            do {
                try await MainActor.run {
                    try events.editEventTag(id: tagUUID, text: text, forEventUUID: uuid)
                }
                let written = await MainActor.run {
                    events.eventTags(forEventUUID: uuid).first { $0.id == tagUUID }
                }
                guard let written,
                      let dto = WireMapping.tag(
                        written, handle: await registry.handle(for: .tag(written.id)))
                else {
                    return writeFailure(helperId: helperId, messageId: messageId)
                }
                let cell = await MainActor.run {
                    events.allEventTagFields(forEventUUID: uuid).first { $0.id == tagUUID }
                }
                await recordAudit(
                    .editTag, kind: .event, subjectID: uuid, subjectName: event.title,
                    instanceID: tagUUID, postModifiedAt: cell?.modifiedAt,
                    priorValue: prior.text, newValue: text)
                return .tag(helperId: helperId, messageId: messageId, tag: dto)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func eventsDeleteTag(
        helperId: String, messageId: String, eventId: String, tagId: String
    ) async -> WireResponse {
        let resolution = await resolveEventForWrite(eventId)
        switch resolution {
        case .unadopted, .stale:
            return resolution.failureResponse(helperId: helperId, messageId: messageId)
        case .adopted(let event):
            guard let tagUUID = await resolveInstance(tagId, kind: "tag") else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            let uuid = Self.eventUUIDString(event)
            let prior = await MainActor.run {
                events.eventTags(forEventUUID: uuid).first { $0.id == tagUUID }
            }
            guard let prior else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundTag)
            }
            do {
                try await MainActor.run {
                    try events.deleteEventTag(id: tagUUID, forEventUUID: uuid)
                }
                let cell = await MainActor.run {
                    events.allEventTagFields(forEventUUID: uuid).first { $0.id == tagUUID }
                }
                await recordAudit(
                    .deleteTag, kind: .event, subjectID: uuid, subjectName: event.title,
                    instanceID: tagUUID, postModifiedAt: cell?.modifiedAt,
                    priorValue: prior.text, newValue: nil)
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: WireAckMessage.tagDeleted)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    // MARK: - Guide writes

    private func guidesCreate(
        helperId: String, messageId: String, name: String, places: [WireNewPlace]
    ) async -> WireResponse {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "The name argument must not be empty.")
        }
        let snapshot = MapsGuideURL.Snapshot(
            name: trimmed,
            entries: places.map {
                MapsGuideURL.Entry(
                    mapsPlaceID: nil, address: $0.address,
                    latitude: $0.latitude, longitude: $0.longitude)
            })
        do {
            let guideID = try await MainActor.run {
                try guides.importGuide(from: snapshot, sourceURL: nil)
            }
            let created = await guides.allGuides().first { $0.id == guideID }
            guard let created else {
                return writeFailure(helperId: helperId, messageId: messageId)
            }
            let handle = await registry.handle(for: .guide(created.id))
            await recordAudit(
                .createGuide, kind: .guide,
                subjectID: created.id.uuidString.lowercased(), subjectName: created.name,
                instanceID: nil, postModifiedAt: nil,
                priorValue: nil, newValue: trimmed)
            return .guide(
                helperId: helperId, messageId: messageId,
                guide: WireMapping.guide(created, handle: handle))
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func guidesDelete(
        helperId: String, messageId: String, guideId: String
    ) async -> WireResponse {
        guard let entry = await registry.entry(for: guideId),
              case .guide(let id) = entry.referent
        else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        guard let guide = await guides.allGuides().first(where: { $0.id == id }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGuide)
        }
        do {
            try await MainActor.run { try guides.deleteGuide(uuid: guide.id.uuidString) }
            await recordAudit(
                .deleteGuide, kind: .guide,
                subjectID: guide.id.uuidString.lowercased(), subjectName: guide.name,
                instanceID: nil, postModifiedAt: nil,
                priorValue: guide.sourceURL, newValue: nil)
            return .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.guideDeleted)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func guidesReorderPlaces(
        helperId: String, messageId: String, guideId: String, placeIds: [String]
    ) async -> WireResponse {
        guard let entry = await registry.entry(for: guideId),
              case .guide(let id) = entry.referent
        else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        var orderedIDs: [UUID] = []
        orderedIDs.reserveCapacity(placeIds.count)
        for placeHandle in placeIds {
            guard let placeUUID = await resolveInstancePlace(placeHandle) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
            orderedIDs.append(placeUUID)
        }
        let current = await guides.places(inGuide: id)
        guard Set(orderedIDs) == Set(current.map(\.id)), orderedIDs.count == current.count else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams,
                message: "The placeIds argument must contain every place in the guide exactly once, in the desired order.")
        }
        let finalOrder = orderedIDs
        await MainActor.run { guides.reorderPlaces(inGuide: id, orderedIDs: finalOrder) }
        let guideName = await guides.allGuides().first { $0.id == id }?.name ?? ""
        await recordAudit(
            .reorderPlaces, kind: .guide,
            subjectID: id.uuidString.lowercased(), subjectName: guideName,
            instanceID: nil, postModifiedAt: nil, priorValue: nil, newValue: nil)
        return .acknowledged(
            helperId: helperId, messageId: messageId,
            message: WireAckMessage.placesReordered)
    }

    private func placesDelete(
        helperId: String, messageId: String, placeId: String
    ) async -> WireResponse {
        guard let placeUUID = await resolveInstancePlace(placeId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
        }
        guard let place = await guides.allPlaces().first(where: { $0.id == placeUUID }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundPlace)
        }
        do {
            try await MainActor.run { try guides.deletePlace(uuid: place.id.uuidString) }
            await recordAudit(
                .deletePlace, kind: .place,
                subjectID: place.id.uuidString.lowercased(), subjectName: place.name,
                instanceID: nil, postModifiedAt: nil,
                priorValue: place.address, newValue: nil)
            return .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.placeDeleted)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    // MARK: - Write helpers

    private enum WriteProblem: Error {
        case stale
        case verifyFailed
    }

    /// Resolve a contact wire id for a WRITE: the read-side resolution PLUS
    /// the display-name fingerprint check for ids minted without a durable
    /// identity — Apple unification can silently re-point such a contact's
    /// local id at a different person mid-conversation, and a write must not
    /// land on the wrong card (plans/cli-mcp.md stale-localID guard).
    private func resolveContactForWrite(_ handle: String) async -> Result<Contact, ResolveFailure> {
        guard let entry = await registry.entry(for: handle) else {
            return .failure(.stale(WireErrorMessage.staleReference))
        }
        guard case .contact(let token) = entry.referent else {
            return .failure(.wrongKind("That id doesn't belong to a contact. Use an id from contacts_search or a contacts list tool."))
        }
        guard let contact = await MainActor.run(body: { contacts.contact(restorationToken: token) }) else {
            return .failure(.stale(WireErrorMessage.staleReference))
        }
        if let fingerprint = entry.fingerprint,
           HandleRegistry.displayNameFingerprint(contact) != fingerprint {
            return .failure(.stale(WireErrorMessage.staleReference))
        }
        return .success(contact)
    }

    private enum EventWriteResolution {
        case adopted(Event)
        /// The id resolves only to a system calendar event — no GuessWho
        /// record yet. Option B: the write answers the typed
        /// open-it-in-the-app error and MINTS NOTHING.
        case unadopted
        case stale

        func failureResponse(helperId: String, messageId: String) -> WireResponse {
            switch self {
            case .adopted:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .invalidParams, message: WireErrorMessage.staleReferenceGeneric)
            case .unadopted:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .requiresAppAction, message: WireErrorMessage.eventNeedsAppFirst)
            case .stale:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .staleHandle, message: WireErrorMessage.staleReferenceGeneric)
            }
        }
    }

    /// Resolve an event wire id for a WRITE. An id that resolves only to a
    /// system calendar event (no GuessWho record yet) answers the typed
    /// Option B error and MINTS NOTHING — writes-do-not-adopt, mirroring
    /// reads-never-mint (plans/cli-mcp.md Phase 2 event-tag rule; a
    /// mint-on-write would race the app's own adopt-on-load and strand a
    /// duplicate record that is never collapsed).
    private func resolveEventForWrite(_ handle: String) async -> EventWriteResolution {
        guard let entry = await registry.entry(for: handle),
              case .event(let uuid, let eventKitID) = entry.referent
        else {
            return .stale
        }
        if let event = await MainActor.run(body: { events.event(uuid: uuid) }) {
            return .adopted(event)
        }
        if let eventKitID,
           await MainActor.run(body: { events.eventKitEvent(eventKitID: eventKitID) }) != nil {
            return .unadopted
        }
        return .stale
    }

    /// Resolve an instance wire id (note / custom field / tag / link) to
    /// its record UUID; nil for unknown ids or ids of another kind.
    private func resolveInstance(_ handle: String, kind: String) async -> UUID? {
        guard let entry = await registry.entry(for: handle) else { return nil }
        switch (entry.referent, kind) {
        case (.note(let id), "note"): return id
        case (.customField(let id), "customField"): return id
        case (.tag(let id), "tag"): return id
        case (.link(let id), "link"): return id
        default: return nil
        }
    }

    private func resolveInstancePlace(_ handle: String) async -> UUID? {
        guard let entry = await registry.entry(for: handle),
              case .place(let id) = entry.referent else { return nil }
        return id
    }

    /// Executes a contact write with the double-mint protections
    /// (plans/cli-mcp.md Phase 2): runs `write` against the contact's
    /// CURRENT identity, and — when this was a first write, which mints the
    /// identity — verifies the written instance is reachable under the
    /// card's post-write identity, retrying once if a concurrent
    /// first-writer's mint won (the losing-mint case leaves the OTHER
    /// writer's identity on the card, silently orphaning ours). Callers hold
    /// the per-localID write lock around this.
    private func mintVerifiedWrite<Instance>(
        token: ContactRestorationToken,
        write: (ContactID) async throws -> Instance,
        verify: (ContactID, Instance) async -> Bool
    ) async throws -> (Contact, Instance) {
        guard let current = await MainActor.run(body: { contacts.contact(restorationToken: token) }) else {
            throw WriteProblem.stale
        }
        let willMint = current.contactID.restorationToken.guessWhoID == nil
        var instance = try await write(current.contactID)
        guard willMint else { return (current, instance) }

        guard let fresh = await MainActor.run(body: { contacts.contact(restorationToken: token) }) else {
            throw WriteProblem.verifyFailed
        }
        if await verify(fresh.contactID, instance) {
            return (fresh, instance)
        }
        // The mint raced a concurrent first-writer and lost. Re-run the
        // write under the card's now-canonical identity and verify again.
        instance = try await write(fresh.contactID)
        guard let settled = await MainActor.run(body: { contacts.contact(restorationToken: token) }),
              await verify(settled.contactID, instance)
        else {
            throw WriteProblem.verifyFailed
        }
        return (settled, instance)
    }

    /// Hold the per-key write locks for `keys` (contact localIDs) across
    /// `body`. Acquisition is in sorted order so multi-key writes can't
    /// deadlock; the actor's isolation makes the check-and-insert atomic
    /// between suspensions.
    private func withWriteKeysLocked<T>(
        _ keys: [String], _ body: () async throws -> T
    ) async rethrows -> T {
        let sorted = Array(Set(keys)).sorted()
        for key in sorted {
            while lockedWriteKeys.contains(key) {
                await withCheckedContinuation { continuation in
                    writeKeyWaiters[key, default: []].append(continuation)
                }
            }
            lockedWriteKeys.insert(key)
        }
        defer { unlockWriteKeys(sorted) }
        return try await body()
    }

    private func unlockWriteKeys(_ keys: [String]) {
        for key in keys {
            lockedWriteKeys.remove(key)
            if var waiters = writeKeyWaiters[key], !waiters.isEmpty {
                let next = waiters.removeFirst()
                writeKeyWaiters[key] = waiters.isEmpty ? nil : waiters
                next.resume()
            } else {
                writeKeyWaiters[key] = nil
            }
        }
    }

    private func admitWrite() -> Bool {
        let now = Date()
        writeWindow.removeAll { now.timeIntervalSince($0) > writeWindowSeconds }
        guard writeWindow.count < writeLimitPerWindow else { return false }
        writeWindow.append(now)
        return true
    }

    private static func idempotencyKey(helperId: String, token: String) -> String {
        helperId + "|" + token
    }

    private func pruneIdempotencyCache() {
        let now = Date()
        idempotencyCache = idempotencyCache.filter {
            now.timeIntervalSince($0.value.recordedAt) <= idempotencyWindowSeconds
        }
    }

    /// Wire type-name → engine field type for custom-field writes. Returns
    /// nil for `.blob` and anything unrecognized — attachment pointers are
    /// never wire-writable.
    private static func wireWritableFieldType(_ raw: String?) -> SidecarFieldType? {
        switch raw ?? "text" {
        case "text", "note": return .note
        case "multilineNote": return .multilineNote
        case "date": return .date
        case "checkbox": return .checkbox
        default: return nil
        }
    }

    /// Validate + normalize the string `value` into the engine payload for
    /// `type`. Dates are re-rendered as internet date-time so the engine's
    /// stricter parser always accepts what the permissive wire parser did.
    private static func fieldPayload(_ value: String, for type: SidecarFieldType) -> JSONValue? {
        switch type {
        case .note, .multilineNote:
            return .string(value)
        case .date:
            guard let date = parseISODate(value) else { return nil }
            return .string(WireMapping.timestamp(date))
        case .checkbox:
            switch value.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return nil
            }
        case .blob:
            return nil
        }
    }

    private func writeFailure(_ error: Error? = nil, helperId: String, messageId: String) -> WireResponse {
        if let problem = error as? WriteProblem, case .stale = problem {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .staleHandle, message: WireErrorMessage.staleReference)
        }
        return .error(
            helperId: helperId, messageId: messageId,
            code: .writeFailed, message: WireErrorMessage.writeFailed)
    }

    /// Append one audit entry for a contact-subject write. Best-effort and
    /// AFTER the engine write returned (append-before would record phantom
    /// writes; losing one entry to a crash between write and append is the
    /// accepted direction).
    private func recordAudit(
        _ action: MCPAuditEntry.Action, kind: MCPAuditEntry.SubjectKind,
        contact: Contact, instanceID: UUID?, postModifiedAt: Date?,
        priorValue: String?, newValue: String?
    ) async {
        await recordAudit(
            action, kind: kind,
            subjectID: contact.contactID.restorationToken.guessWhoID ?? "",
            subjectName: contact.displayName,
            instanceID: instanceID, postModifiedAt: postModifiedAt,
            priorValue: priorValue, newValue: newValue)
    }

    private func recordAudit(
        _ action: MCPAuditEntry.Action, kind: MCPAuditEntry.SubjectKind,
        subjectID: String, subjectName: String,
        instanceID: UUID?, postModifiedAt: Date?,
        priorValue: String?, newValue: String?
    ) async {
        guard let audit else { return }
        await audit.record(MCPAuditEntry(
            at: Date(), action: action, subjectKind: kind,
            subjectID: subjectID, subjectName: subjectName,
            instanceID: instanceID?.uuidString.lowercased(),
            postModifiedAt: postModifiedAt,
            priorValue: priorValue, newValue: newValue))
    }

    // MARK: - Resolution

    private enum ResolveFailure: Error {
        case stale(String)
        case wrongKind(String)

        func response(helperId: String, messageId: String) -> WireResponse {
            switch self {
            case .stale(let message):
                return .error(helperId: helperId, messageId: messageId, code: .staleHandle, message: message)
            case .wrongKind(let message):
                return .error(helperId: helperId, messageId: messageId, code: .invalidParams, message: message)
            }
        }
    }

    private func resolveContact(_ handle: String) async -> Result<Contact, ResolveFailure> {
        guard let entry = await registry.entry(for: handle) else {
            return .failure(.stale(WireErrorMessage.staleReference))
        }
        guard case .contact(let token) = entry.referent else {
            return .failure(.wrongKind("That id doesn't belong to a contact. Use an id from contacts_search or a contacts list tool."))
        }
        guard let contact = await MainActor.run(body: { contacts.contact(restorationToken: token) }) else {
            return .failure(.stale(WireErrorMessage.staleReference))
        }
        return .success(contact)
    }

    private func resolveEvent(_ handle: String) async -> Result<Event, ResolveFailure> {
        guard let entry = await registry.entry(for: handle) else {
            return .failure(.stale(WireErrorMessage.staleReferenceGeneric))
        }
        guard case .event(let uuid, let eventKitID) = entry.referent else {
            return .failure(.wrongKind("That id doesn't belong to an event. Use an id from events_list."))
        }
        if let event = await MainActor.run(body: { events.event(uuid: uuid) }) {
            return .success(event)
        }
        if let eventKitID,
           let event = await MainActor.run(body: { events.eventKitEvent(eventKitID: eventKitID) }) {
            return .success(event)
        }
        return .failure(.stale(WireErrorMessage.staleReferenceGeneric))
    }

    // MARK: - Handle minting

    private func mintContactHandle(_ contact: Contact) async -> String {
        let id = contact.contactID
        let token = id.restorationToken
        // Snapshot the display-name fingerprint ONLY for contacts with no
        // durable identity yet — the write-side guard for the localID
        // re-pointing hazard (compared in Phase 2, minted now).
        let fingerprint: UInt64? = token.guessWhoID == nil
            ? HandleRegistry.displayNameFingerprint(contact)
            : nil
        return await registry.handle(for: .contact(token), fingerprint: fingerprint)
    }

    private static func eventUUIDString(_ event: Event) -> String {
        event.id.uuidString.lowercased()
    }

    private func mintEventHandle(_ event: Event) async -> String {
        await registry.handle(
            for: .event(uuid: Self.eventUUIDString(event), eventKitID: event.eventKitID))
    }

    // MARK: - Pagination, caps, limits

    private struct PageBounds {
        let limit: Int
        let offset: Int

        func slice<T>(_ items: [T]) -> ([T], String?) {
            guard offset < items.count else { return ([], nil) }
            let end = min(offset + limit, items.count)
            let next = end < items.count ? "o\(end)" : nil
            return (Array(items[offset..<end]), next)
        }
    }

    private func pageBounds(limit: Int?, cursor: String?) -> PageBounds? {
        let boundedLimit = min(max(limit ?? Self.defaultLimit, 1), Self.maxLimit)
        var offset = 0
        if let cursor {
            guard cursor.hasPrefix("o"), let parsed = Int(cursor.dropFirst()), parsed >= 0 else {
                return nil
            }
            offset = parsed
        }
        return PageBounds(limit: boundedLimit, offset: offset)
    }

    private func invalidCursor(helperId: String, messageId: String) -> WireResponse {
        .error(
            helperId: helperId, messageId: messageId,
            code: .invalidParams,
            message: "The cursor argument isn't from a previous result. Omit it to start from the first page.")
    }

    /// Response-size cap: a page whose encoded payload exceeds the cap
    /// becomes the typed too-large error with guidance — never a silent
    /// truncation (a truncated list read as complete is a correctness
    /// trap).
    ///
    /// The measuring encode here is a second encode (the transport encodes
    /// again when writing the pipe) — accepted: payloads are ≤256KB by
    /// this very check, both encodes run off the main actor, and threading
    /// pre-encoded bytes through the host's response writer would couple
    /// the dispatcher to the transport's framing.
    private func capped(_ response: WireResponse) -> WireResponse {
        if case .error = response { return response }
        guard let encoded = try? JSONEncoder().encode(response) else { return response }
        if encoded.count > WireEnvironment.maxResponsePayloadBytes {
            return .error(
                helperId: response.helperId, messageId: response.messageId,
                code: .tooLarge, message: WireErrorMessage.tooLarge)
        }
        return response
    }

    /// Admit a search against the sliding window; false = over budget.
    private func admitSearch() -> Bool {
        let now = Date()
        searchWindow.removeAll { now.timeIntervalSince($0) > searchWindowSeconds }
        guard searchWindow.count < searchLimitPerWindow else { return false }
        searchWindow.append(now)
        return true
    }

    private static func parseISODate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: string)
    }
}
