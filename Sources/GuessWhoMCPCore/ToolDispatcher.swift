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

    private static let defaultLimit = 50
    private static let maxLimit = 200

    public init(
        contacts: MCPContactSource,
        events: MCPEventSource,
        guides: MCPGuideSource,
        gates: MCPGateSource,
        registry: HandleRegistry = HandleRegistry(),
        searchLimitPerWindow: Int = 30,
        searchWindowSeconds: TimeInterval = 60
    ) {
        self.contacts = contacts
        self.events = events
        self.guides = guides
        self.gates = gates
        self.registry = registry
        self.searchLimitPerWindow = searchLimitPerWindow
        self.searchWindowSeconds = searchWindowSeconds
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
        }
        return capped(response)
    }

    // MARK: - Gates

    /// Tools visible to `listTools`, given the live gates. Empty when the
    /// origin's master toggle is off — with the status string riding along
    /// so the agent relays something actionable instead of "no tools".
    private func listTools(helperId: String, messageId: String) async -> WireResponse {
        let origin = RequestOrigin.from(helperId: helperId) ?? .mcp
        let (enabled, contactsOK, eventsOK) = await MainActor.run {
            (
                origin == .cli ? gates.isCLIEnabled : gates.isMCPEnabled,
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
    /// tool's permission domain. Returns the error to send, or nil to
    /// proceed.
    private func gateCheck(tool: MCPTool, helperId: String, messageId: String) async -> WireResponse? {
        let origin = RequestOrigin.from(helperId: helperId) ?? .mcp
        let (enabled, contactsOK, eventsOK) = await MainActor.run {
            (
                origin == .cli ? gates.isCLIEnabled : gates.isMCPEnabled,
                gates.contactsAuthorized,
                gates.eventsAuthorized
            )
        }
        guard enabled else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .disabled, message: WireErrorMessage.disabled)
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
