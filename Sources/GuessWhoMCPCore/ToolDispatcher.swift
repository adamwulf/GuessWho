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
    /// The kind-agnostic connection primitive (links_* tools). Contact
    /// endpoints still WRITE through `contacts` (resolve-or-mint); this is
    /// the list/lookup surface plus the write path for pairs with no
    /// contact endpoint (event↔event, event↔place).
    private let links: MCPLinkSource
    private let gates: MCPGateSource
    /// Presents human-in-the-loop confirmations (contacts_delete). nil =
    /// no way to confirm, so confirmation-gated writes answer the typed
    /// "couldn't show the confirmation" error.
    private let confirmations: MCPConfirmationSource?

    /// Sends a response OUT OF BAND — after `handle` already returned nil
    /// for a confirmation-gated request (fire-and-forget dispatch: the
    /// request handler never blocks on a human; the answer is correlated
    /// by helperId+messageId when it exists). Wired by the host to the
    /// pipe writer; wired by tests to a probe.
    private var deferredSend: (@Sendable (WireResponse) async -> Void)?

    /// One confirmation on screen at a time — a flood of dialogs is its
    /// own denial-of-service.
    private var pendingConfirmation = false

    /// Clock for the confirmation-abandonment check, injectable so tests
    /// can drive the timed-out-then-approved race deterministically. The
    /// check is THE safety property of confirmation-gated deletes ("the
    /// agent saw a timeout" and "the delete fired" must be mutually
    /// exclusive), so it has to be regression-testable with the real
    /// timeout arithmetic, not a warped margin.
    private let now: @Sendable () -> Date

    /// Safety margin under the tool's declarative timeout: covers the gap
    /// between the helper starting its timer (at send) and the host
    /// starting its own (at receipt), plus response-delivery time. Public
    /// so the abandonment regression tests exercise the REAL arithmetic.
    public static let confirmationTimeoutMargin: TimeInterval = 15

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
        links: MCPLinkSource,
        gates: MCPGateSource,
        confirmations: MCPConfirmationSource? = nil,
        audit: MCPAuditLog? = nil,
        searchLimitPerWindow: Int = 30,
        searchWindowSeconds: TimeInterval = 60,
        writeLimitPerWindow: Int = 30,
        writeWindowSeconds: TimeInterval = 60,
        idempotencyWindowSeconds: TimeInterval = 600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.contacts = contacts
        self.events = events
        self.guides = guides
        self.links = links
        self.gates = gates
        self.confirmations = confirmations
        self.audit = audit
        self.now = now
        self.searchLimitPerWindow = searchLimitPerWindow
        self.searchWindowSeconds = searchWindowSeconds
        self.writeLimitPerWindow = writeLimitPerWindow
        self.writeWindowSeconds = writeWindowSeconds
        self.idempotencyWindowSeconds = idempotencyWindowSeconds
    }

    /// Install the out-of-band response sender (see `deferredSend`).
    public func setDeferredResponder(_ send: @escaping @Sendable (WireResponse) async -> Void) {
        deferredSend = send
    }

    // MARK: - Entry point

    /// Handle one request. Returns the response to send — or nil for a
    /// confirmation-gated request whose answer will arrive later through
    /// the deferred responder (fire-and-forget; the request-reading path
    /// must never block on a human decision).
    public func handle(_ request: WireRequest) async -> WireResponse? {
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

        if case .contactsDelete(_, _, let contactId, let idempotencyToken) = request {
            // Confirmation-gated: may return nil (answer sent later).
            return await contactsDeleteRequested(
                helperId: helperId, messageId: messageId,
                contactId: contactId, idempotencyToken: idempotencyToken)
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
        case .contactsList(_, _, let type, let limit, let cursor):
            response = await contactsList(
                helperId: helperId, messageId: messageId,
                type: type, limit: limit, cursor: cursor)
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
        case .linksList(_, _, let id, let kind, let limit, let cursor):
            response = await linksList(
                helperId: helperId, messageId: messageId,
                id: id, kind: kind, limit: limit, cursor: cursor)
        case .initialize, .deinitialize, .ping, .listTools:
            response = .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        case .contactsCreate, .contactsUpdate, .contactsDelete,
             .contactsAddPhone, .contactsRemovePhone, .contactsEditPhone,
             .contactsAddEmail, .contactsRemoveEmail, .contactsEditEmail,
             .contactsAddURL, .contactsRemoveURL, .contactsEditURL,
             .contactsAddRelatedName, .contactsRemoveRelatedName, .contactsEditRelatedName,
             .contactsAddDate, .contactsRemoveDate, .contactsEditDate,
             .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsSetFavorite,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete,
             .linksCreate, .linksRemove:
            // Unreachable: every write case dispatched through handleWrite
            // (or the confirmation-gated delete path) above. Kept explicit
            // so a new write case that forgets its isWrite classification
            // fails a test, not silently.
            response = .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        }
        return capped(response)
    }

    // MARK: - Gates

    /// Tools visible to `listTools`, given the live gates. Empty when the
    /// origin's access mode is off — with the status string riding along
    /// so the agent relays something actionable instead of "no tools".
    private func listTools(helperId: String, messageId: String) async -> WireResponse {
        let origin = RequestOrigin.from(helperId: helperId) ?? .mcp
        let (mode, contactsOK, eventsOK) = await MainActor.run {
            (
                gates.accessMode(for: origin),
                gates.contactsAuthorized,
                gates.eventsAuthorized
            )
        }
        guard mode.allowsReads else {
            return .toolList(
                helperId: helperId, messageId: messageId,
                tools: [], status: WireErrorMessage.disabled)
        }
        let tools = MCPTool.allCases.filter { tool in
            if tool.isWrite && !mode.allowsWrites { return false }
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

    /// The per-call server-side gate: the origin's tri-state access mode
    /// (off rejects everything; read-only rejects write tools — THE consent
    /// gate, no per-call dialogs; read-write passes), then the tool's
    /// permission domain. Returns the error to send, or nil to proceed.
    private func gateCheck(tool: MCPTool, helperId: String, messageId: String) async -> WireResponse? {
        let origin = RequestOrigin.from(helperId: helperId) ?? .mcp
        let (mode, contactsOK, eventsOK) = await MainActor.run {
            (
                gates.accessMode(for: origin),
                gates.contactsAuthorized,
                gates.eventsAuthorized
            )
        }
        guard mode.allowsReads else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .disabled, message: WireErrorMessage.disabled)
        }
        if tool.isWrite && !mode.allowsWrites {
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
        let items = slice.map { WireMapping.summary($0, id: WireRecordID.contactID(for: $0)) }
        return .contactPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    /// The whole-book enumeration (contacts_search requires a 2+ character
    /// needle, so this is the only way to list EVERY contact). The order is
    /// a fixed (lowercased display name, wire id) sort — deterministic,
    /// total (the unique id breaks name ties), and independent of both the
    /// repository's user-configurable UI sort and the cached array's
    /// incidental order — so the offset cursor pages one stable sequence
    /// with no skips or duplicates while the contact set is unchanged.
    /// Plain enumeration of the cached book: none of contacts_search's
    /// per-contact text matching, so it takes no search budget (same
    /// stance as contacts_list_favorites). Ids come from the same no-mint
    /// derivation every read uses.
    private func contactsList(
        helperId: String, messageId: String, type: String?, limit: Int?, cursor: String?
    ) async -> WireResponse {
        let wanted: ContactType?
        switch type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil: wanted = nil
        case "person": wanted = .person
        case "organization": wanted = .organization
        default:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidTypeArgument)
        }
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let matching = await MainActor.run { () -> [Contact] in
            guard let wanted else { return contacts.allContacts }
            return contacts.allContacts.filter { $0.contactType == wanted }
        }
        // Sort OFF the main actor; ids are derived once and reused for both
        // the sort tiebreak and the DTO.
        let ordered = matching
            .map { (contact: $0, id: WireRecordID.contactID(for: $0)) }
            .sorted { a, b in
                let nameA = a.contact.displayName.lowercased()
                let nameB = b.contact.displayName.lowercased()
                if nameA != nameB { return nameA < nameB }
                return a.id < b.id
            }
        let (slice, nextCursor) = page.slice(ordered)
        let items = slice.map { WireMapping.summary($0.contact, id: $0.id) }
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
            return .contact(
                helperId: helperId, messageId: messageId,
                contact: WireMapping.contact(
                    contact, id: WireRecordID.contactID(for: contact), isFavorite: isFavorite))
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
            let items = slice.compactMap {
                WireMapping.note($0, id: $0.id.uuidString.lowercased())
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
            let items = slice.compactMap {
                WireMapping.customField($0, id: $0.id.uuidString.lowercased())
            }
            return .customFieldPage(
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
        let items = slice.map { WireMapping.summary($0, id: WireRecordID.contactID(for: $0)) }
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
        let items = slice.map { WireMapping.group($0, id: WireRecordID.groupID(for: $0)) }
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
        let groups = await contacts.fetchGroups()
        guard let group = WireRecordID.group(for: groupId, in: groups) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGroup)
        }
        let members = await contacts.members(ofGroup: group.localID)
        let (slice, nextCursor) = page.slice(members)
        let items = slice.map { WireMapping.summary($0, id: WireRecordID.contactID(for: $0)) }
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
        let items = slice.map { WireMapping.eventSummary($0, id: WireRecordID.eventID(for: $0)) }
        return .eventPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func eventsGet(helperId: String, messageId: String, eventId: String) async -> WireResponse {
        switch await resolveEvent(eventId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let event):
            return .event(
                helperId: helperId, messageId: messageId,
                event: WireMapping.event(event, id: WireRecordID.eventID(for: event)))
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
            let items = slice.compactMap {
                WireMapping.tag($0, id: $0.id.uuidString.lowercased())
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
        let items = slice.map { WireMapping.guide($0, id: $0.id.uuidString.lowercased()) }
        return .guidePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func guidesGet(helperId: String, messageId: String, guideId: String) async -> WireResponse {
        guard let id = WireRecordID.recordUUID(guideId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGuide)
        }
        let all = await guides.allGuides()
        guard let guide = all.first(where: { $0.id == id }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGuide)
        }
        return .guide(
            helperId: helperId, messageId: messageId,
            guide: WireMapping.guide(guide, id: guide.id.uuidString.lowercased()))
    }

    private func placesList(
        helperId: String, messageId: String, guideId: String?, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let places: [MapsPlace]
        if let guideId {
            guard let id = WireRecordID.recordUUID(guideId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundGuide)
            }
            places = await guides.places(inGuide: id)
        } else {
            places = await guides.allPlaces()
        }
        let (slice, nextCursor) = page.slice(places)
        let items = slice.map {
            WireMapping.place(
                $0, id: $0.id.uuidString.lowercased(),
                guideID: $0.guideID.uuidString.lowercased())
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
        case .contactsCreate(_, _, let kind, let fields, _):
            return await contactsCreate(
                helperId: helperId, messageId: messageId, kind: kind, fields: fields)
        case .contactsUpdate(_, _, let contactId, let fields, _):
            return await contactsUpdate(
                helperId: helperId, messageId: messageId, contactId: contactId, fields: fields)
        case .contactsAddPhone(_, _, let contactId, let value, let label, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .phone, operation: .add(value: value, label: label))
        case .contactsRemovePhone(_, _, let contactId, let value, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .phone, operation: .remove(value: value))
        case .contactsEditPhone(_, _, let contactId, let currentValue, let newValue, let newLabel, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .phone,
                operation: .edit(currentValue: currentValue, newValue: newValue, newLabel: newLabel))
        case .contactsAddEmail(_, _, let contactId, let value, let label, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .email, operation: .add(value: value, label: label))
        case .contactsRemoveEmail(_, _, let contactId, let value, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .email, operation: .remove(value: value))
        case .contactsEditEmail(_, _, let contactId, let currentValue, let newValue, let newLabel, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .email,
                operation: .edit(currentValue: currentValue, newValue: newValue, newLabel: newLabel))
        case .contactsAddURL(_, _, let contactId, let value, let label, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .url, operation: .add(value: value, label: label))
        case .contactsRemoveURL(_, _, let contactId, let value, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .url, operation: .remove(value: value))
        case .contactsEditURL(_, _, let contactId, let currentValue, let newValue, let newLabel, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .url,
                operation: .edit(currentValue: currentValue, newValue: newValue, newLabel: newLabel))
        case .contactsAddRelatedName(_, _, let contactId, let value, let label, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .relatedName, operation: .add(value: value, label: label))
        case .contactsRemoveRelatedName(_, _, let contactId, let value, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .relatedName, operation: .remove(value: value))
        case .contactsEditRelatedName(_, _, let contactId, let currentValue, let newValue, let newLabel, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .relatedName,
                operation: .edit(currentValue: currentValue, newValue: newValue, newLabel: newLabel))
        case .contactsAddDate(_, _, let contactId, let value, let label, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .date, operation: .add(value: value, label: label))
        case .contactsRemoveDate(_, _, let contactId, let value, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .date, operation: .remove(value: value))
        case .contactsEditDate(_, _, let contactId, let currentValue, let newValue, let newLabel, _):
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: .date,
                operation: .edit(currentValue: currentValue, newValue: newValue, newLabel: newLabel))
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
        case .linksCreate(_, _, let fromId, let fromKind, let toId, let toKind, let note, _):
            return await linksCreate(
                helperId: helperId, messageId: messageId,
                fromId: fromId, fromKind: fromKind, toId: toId, toKind: toKind, note: note)
        case .linksRemove(_, _, let linkId, _):
            return await linksRemove(helperId: helperId, messageId: messageId, linkId: linkId)
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
                      let dto = WireMapping.note(written, id: written.id.uuidString.lowercased())
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
            guard let noteUUID = WireRecordID.recordUUID(noteId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundNote)
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
                      let dto = WireMapping.note(written, id: written.id.uuidString.lowercased())
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
            guard let noteUUID = WireRecordID.recordUUID(noteId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundNote)
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
                code: .invalidParams, message: WireErrorMessage.emptyNameArgument)
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
                ? WireErrorMessage.invalidDateFieldValue
                : WireErrorMessage.invalidCheckboxFieldValue
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
                      let dto = WireMapping.customField(written, id: written.id.uuidString.lowercased())
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
            guard let fieldUUID = WireRecordID.recordUUID(fieldId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundField)
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

    /// The locked contact↔contact link write shared by links_create:
    /// resolve both endpoints under their per-localID write
    /// locks, write the link through the identity-minting repository funnel,
    /// and verify-with-one-retry when a concurrent first-writer's mint won
    /// (removing the stale link so no half-orphan survives). Returns the
    /// post-write contacts and the link.
    private func addContactContactLink(
        near: Contact, far: Contact, note: String?
    ) async throws -> (Contact, Contact, Link) {
        let nearToken = near.contactID.restorationToken
        let farToken = far.contactID.restorationToken
        return try await withWriteKeysLocked(
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

    // MARK: - Contact-record writes (Revision 2: full Contact Store parity)

    /// Map a thrown contact-record save error to its typed wire response.
    /// Categorization rides the SAME `ContactEditModel.saveErrorCategory`
    /// the app's editor uses (incl. the 134092 store-rejection family —
    /// documented fragile; a failed save must surface typed, never crash,
    /// never claim success). Messages are FIXED strings: the category's
    /// detail text can carry contact data, so it never crosses.
    private func contactSaveFailure(
        _ error: Error, helperId: String, messageId: String
    ) -> WireResponse {
        switch ContactEditModel.saveErrorCategory(error) {
        case .authorizationDenied:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        case .recordDoesNotExist:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundContact)
        case .invalidField:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.contactFieldRejected)
        case .storeRejected, .unknown:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .writeFailed, message: WireErrorMessage.writeFailed)
        }
    }

    /// Whether any wire-supplied web address uses the app's own reserved
    /// address form — an agent must never be able to plant (or spoof) an
    /// identity URL through the writable URL list.
    private static func containsReservedURL(_ urls: [WireLabeledValue]?) -> Bool {
        guard let urls else { return false }
        return urls.contains {
            $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix(SidecarKey.guessWhoContactURLPrefix)
        }
    }

    /// "yyyy-MM-dd" / "--MM-dd" → `DateComponents`; nil for anything else.
    private static func parseCalendarDate(_ string: String) -> DateComponents? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("--") {
            let parts = trimmed.dropFirst(2).split(separator: "-")
            guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                  (1...12).contains(month), (1...31).contains(day)
            else { return nil }
            return DateComponents(month: month, day: day)
        }
        let parts = trimmed.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// Apply the supplied single-value fields onto `contact` — the whole
    /// contacts_update surface, and the scalar half of contacts_create. By
    /// construction there is no path to `Contact.note` (the DTO has no such
    /// member) and none to the contact's identity. Returns a message for an
    /// unparseable value.
    private static func applyScalarFields(
        _ fields: WireContactScalarFields, to contact: inout Contact
    ) -> String? {
        if let value = fields.namePrefix { contact.namePrefix = value }
        if let value = fields.givenName { contact.givenName = value }
        if let value = fields.middleName { contact.middleName = value }
        if let value = fields.familyName { contact.familyName = value }
        if let value = fields.previousFamilyName { contact.previousFamilyName = value }
        if let value = fields.nameSuffix { contact.nameSuffix = value }
        if let value = fields.nickname { contact.nickname = value }
        if let value = fields.phoneticGivenName { contact.phoneticGivenName = value }
        if let value = fields.phoneticMiddleName { contact.phoneticMiddleName = value }
        if let value = fields.phoneticFamilyName { contact.phoneticFamilyName = value }
        if let value = fields.organization { contact.organizationName = value }
        if let value = fields.phoneticOrganization { contact.phoneticOrganizationName = value }
        if let value = fields.department { contact.departmentName = value }
        if let value = fields.jobTitle { contact.jobTitle = value }
        if let value = fields.birthday {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contact.birthday = nil
            } else if let components = parseCalendarDate(value) {
                contact.birthday = components
            } else {
                return WireErrorMessage.invalidCalendarDateValue
            }
        }
        return nil
    }

    /// Apply the full contacts_create field set onto `contact` — the
    /// scalars plus every list EXCEPT the URL list, which the caller sets
    /// (create takes it whole after the reserved-address check). Lists are
    /// safe to take whole here: a blank seed has no existing entries a
    /// replacement could clobber. Returns a message for an unparseable
    /// value.
    private static func applyFields(
        _ fields: WireContactFields, to contact: inout Contact
    ) -> String? {
        if let problem = applyScalarFields(fields.scalarFields, to: &contact) {
            return problem
        }
        if let values = fields.phoneNumbers {
            contact.phoneNumbers = values.map { LabeledValue(label: $0.label ?? "", value: $0.value) }
        }
        if let values = fields.emailAddresses {
            contact.emailAddresses = values.map { LabeledValue(label: $0.label ?? "", value: $0.value) }
        }
        if let values = fields.postalAddresses {
            contact.postalAddresses = values.map { address in
                LabeledPostalAddress(
                    label: address.label ?? "",
                    value: PostalAddress(
                        street: address.street,
                        subLocality: address.subLocality ?? "",
                        city: address.city,
                        subAdministrativeArea: address.subAdministrativeArea ?? "",
                        state: address.state,
                        postalCode: address.postalCode,
                        country: address.country,
                        isoCountryCode: address.isoCountryCode ?? ""))
            }
        }
        if let values = fields.dates {
            var parsed: [LabeledDate] = []
            for date in values {
                guard let components = parseCalendarDate(date.date) else {
                    return WireErrorMessage.invalidCalendarDateValue
                }
                parsed.append(LabeledDate(label: date.label ?? "", value: components))
            }
            contact.dates = parsed
        }
        if let values = fields.socialProfiles {
            contact.socialProfiles = values.map { profile in
                LabeledSocialProfile(
                    label: profile.label ?? "",
                    value: SocialProfile(
                        urlString: profile.url ?? "",
                        username: profile.username ?? "",
                        userIdentifier: "",
                        service: profile.service ?? ""))
            }
        }
        if let values = fields.instantMessages {
            contact.instantMessageAddresses = values.map { address in
                LabeledInstantMessageAddress(
                    label: address.label ?? "",
                    value: InstantMessageAddress(
                        username: address.username, service: address.service ?? ""))
            }
        }
        if let values = fields.relatedNames {
            contact.contactRelations = values.map { relation in
                LabeledContactRelation(
                    label: relation.label ?? "",
                    value: ContactRelation(name: relation.value))
            }
        }
        return nil
    }

    private func contactsCreate(
        helperId: String, messageId: String, kind: String?, fields: WireContactFields
    ) async -> WireResponse {
        let contactType: ContactType
        switch kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "person": contactType = .person
        case "organization": contactType = .organization
        default:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidKindArgument)
        }
        guard !Self.containsReservedURL(fields.urlAddresses) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.reservedWebAddress)
        }
        var seed = Contact(contactType: contactType)
        if let problem = Self.applyFields(fields, to: &seed) {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: problem)
        }
        if let urls = fields.urlAddresses {
            seed.urlAddresses = urls.map { LabeledValue(label: $0.label ?? "", value: $0.value) }
        }
        // displayName falls back to a placeholder for a blank card, so
        // check the actual components: some name part or an organization.
        let nameParts = [
            seed.namePrefix, seed.givenName, seed.middleName, seed.familyName,
            seed.nameSuffix, seed.nickname, seed.organizationName,
        ]
        guard nameParts.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.contactNeedsAName)
        }
        do {
            let created = try await contacts.createContact(seed)
            await recordAudit(
                .createContact, kind: .contact, contact: created,
                instanceID: nil, postModifiedAt: nil,
                priorValue: nil, newValue: created.displayName)
            return .contact(
                helperId: helperId, messageId: messageId,
                contact: WireMapping.contact(
                    created, id: WireRecordID.contactID(for: created), isFavorite: false))
        } catch {
            return contactSaveFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func contactsUpdate(
        helperId: String, messageId: String, contactId: String, fields: WireContactScalarFields
    ) async -> WireResponse {
        guard !fields.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.updateNeedsAField)
        }
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                return try await withWriteKeysLocked([token.localID]) { () -> WireResponse in
                    // Fresh fetch through the SAME editable path the app's
                    // editor uses — it carries every field, including ones
                    // the wire never sees (the Apple note rides through
                    // UNTOUCHED, and the scalar patch can't reach any list,
                    // so the URL slots — identity URL included — survive
                    // verbatim).
                    guard let editable = try await contacts.editableContact(id: contact.contactID)
                    else {
                        return .error(
                            helperId: helperId, messageId: messageId,
                            code: .notFound, message: WireErrorMessage.notFoundContact)
                    }
                    var edited = editable
                    if let problem = Self.applyScalarFields(fields, to: &edited) {
                        return .error(
                            helperId: helperId, messageId: messageId,
                            code: .invalidParams, message: problem)
                    }
                    try await contacts.saveContact(edited, for: contact.contactID)
                    let fresh = await MainActor.run {
                        contacts.contact(restorationToken: token)
                    } ?? edited
                    let isFavorite = await MainActor.run { contacts.isFavorite(fresh.contactID) }
                    await recordAudit(
                        .editContact, kind: .contact, contact: fresh,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: nil,
                        newValue: fields.providedFieldNames.joined(separator: ", "))
                    return .contact(
                        helperId: helperId, messageId: messageId,
                        contact: WireMapping.contact(
                            fresh, id: WireRecordID.contactID(for: fresh), isFavorite: isFavorite))
                }
            } catch {
                return contactSaveFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    // MARK: - Single-entry list edits (plans/cli-mcp.md Phase 7)

    /// The contact-card lists editable one entry at a time — each is a
    /// list whose entry identity is ONE scalar plus a label, so an exact
    /// value match can name a single entry and the edit signature
    /// (newValue + newLabel) can express every change. Postal addresses,
    /// social profiles, and instant messages are deliberately absent:
    /// their identity spans several subfields (street+city…,
    /// service+username), so a single-value match can't name one entry —
    /// they stay create-only on the wire until they get their own design.
    private enum ContactListField {
        case phone, email, url, relatedName, date

        /// The audit/display name — the same list name the create schema
        /// uses.
        var fieldName: String {
            switch self {
            case .phone: return "phoneNumbers"
            case .email: return "emailAddresses"
            case .url: return "urlAddresses"
            case .relatedName: return "relatedNames"
            case .date: return "dates"
            }
        }

        var notFoundMessage: String {
            switch self {
            case .phone: return WireErrorMessage.noPhoneWithThatValue
            case .email: return WireErrorMessage.noEmailWithThatValue
            case .url: return WireErrorMessage.noURLWithThatValue
            case .relatedName: return WireErrorMessage.noRelatedNameWithThatValue
            case .date: return WireErrorMessage.noDateWithThatValue
            }
        }

        var ambiguousMessage: String {
            switch self {
            case .phone: return WireErrorMessage.ambiguousPhoneValue
            case .email: return WireErrorMessage.ambiguousEmailValue
            case .url: return WireErrorMessage.ambiguousURLValue
            case .relatedName: return WireErrorMessage.ambiguousRelatedNameValue
            case .date: return WireErrorMessage.ambiguousDateValue
            }
        }
    }

    /// One single-entry list operation, pre-validated by
    /// `listOperationProblem` before any resolve or lock.
    private enum ListItemOperation {
        case add(value: String, label: String?)
        case remove(value: String)
        case edit(currentValue: String, newValue: String, newLabel: String?)
    }

    /// nil when `value` is acceptable as a NEW entry for `field`; else the
    /// typed invalidParams message. The reserved-address check keeps an
    /// agent from planting the app's internal URL form one entry at a time
    /// (the same guard contacts_create applies to the whole list).
    private static func newListValueProblem(
        _ value: String, field: ContactListField
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return WireErrorMessage.emptyValueArgument }
        switch field {
        case .url where trimmed.lowercased().hasPrefix(SidecarKey.guessWhoContactURLPrefix):
            return WireErrorMessage.reservedWebAddress
        case .date where parseCalendarDate(value) == nil:
            return WireErrorMessage.invalidCalendarDateValue
        default:
            return nil
        }
    }

    /// nil when `value` can be used to MATCH an entry of `field`. An
    /// unparseable date is a spelling problem, not a missing entry, so it
    /// answers invalidParams rather than a misleading notFound.
    private static func matchListValueProblem(
        _ value: String, field: ContactListField
    ) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return WireErrorMessage.emptyValueArgument
        }
        if field == .date, parseCalendarDate(value) == nil {
            return WireErrorMessage.invalidCalendarDateValue
        }
        return nil
    }

    private static func listOperationProblem(
        _ operation: ListItemOperation, field: ContactListField
    ) -> String? {
        switch operation {
        case .add(let value, _):
            return newListValueProblem(value, field: field)
        case .remove(let value):
            return matchListValueProblem(value, field: field)
        case .edit(let currentValue, let newValue, _):
            return matchListValueProblem(currentValue, field: field)
                ?? newListValueProblem(newValue, field: field)
        }
    }

    /// The needle in the same canonical form `matchValues` renders: dates
    /// re-render through the shared calendar-date form so "--03-14" and a
    /// stored month/day pair compare equal regardless of spelling; every
    /// other field matches the stored value verbatim.
    private static func canonicalMatchValue(
        _ value: String, field: ContactListField
    ) -> String {
        guard field == .date,
              let components = parseCalendarDate(value),
              let rendered = WireMapping.calendarDate(components)
        else { return value }
        return rendered
    }

    /// The list being matched, one string per entry, index-aligned with
    /// the underlying storage. URLs use the USER-VISIBLE list only — the
    /// internal identity URL is structurally unmatchable, so no remove or
    /// edit can ever name it. An unrenderable date maps to "" (a needle is
    /// never empty, so it can't match).
    private static func matchValues(
        _ field: ContactListField, in contact: Contact
    ) -> [String] {
        switch field {
        case .phone: return contact.phoneNumbers.map(\.value)
        case .email: return contact.emailAddresses.map(\.value)
        case .url: return contact.userVisibleURLAddresses.map(\.value)
        case .relatedName: return contact.contactRelations.map(\.value.name)
        case .date: return contact.dates.map { WireMapping.calendarDate($0.value) ?? "" }
        }
    }

    /// Replace the contact's visible URL list through the editor's own
    /// merge, so the internal identity URLs keep their slots verbatim —
    /// the same path contacts_update's whole-list replace used to ride.
    private static func setVisibleURLs(_ visible: [LabeledValue], on contact: inout Contact) {
        contact.urlAddresses = ContactEditModel.mergeURLAddresses(
            original: contact.urlAddresses, visible: visible)
    }

    private static func appendListItem(
        _ field: ContactListField, to contact: inout Contact, value: String, label: String?
    ) {
        let label = label ?? ""
        switch field {
        case .phone:
            contact.phoneNumbers.append(LabeledValue(label: label, value: value))
        case .email:
            contact.emailAddresses.append(LabeledValue(label: label, value: value))
        case .url:
            var visible = contact.userVisibleURLAddresses
            visible.append(LabeledValue(label: label, value: value))
            setVisibleURLs(visible, on: &contact)
        case .relatedName:
            contact.contactRelations.append(
                LabeledContactRelation(label: label, value: ContactRelation(name: value)))
        case .date:
            guard let components = parseCalendarDate(value) else { return }
            contact.dates.append(LabeledDate(label: label, value: components))
        }
    }

    /// Replace the entry at `index` in place — position and, when no new
    /// label is given, the existing label both survive.
    private static func replaceListItem(
        _ field: ContactListField, in contact: inout Contact,
        at index: Int, newValue: String, newLabel: String?
    ) {
        switch field {
        case .phone:
            let old = contact.phoneNumbers[index]
            contact.phoneNumbers[index] = LabeledValue(label: newLabel ?? old.label, value: newValue)
        case .email:
            let old = contact.emailAddresses[index]
            contact.emailAddresses[index] = LabeledValue(label: newLabel ?? old.label, value: newValue)
        case .url:
            var visible = contact.userVisibleURLAddresses
            let old = visible[index]
            visible[index] = LabeledValue(label: newLabel ?? old.label, value: newValue)
            setVisibleURLs(visible, on: &contact)
        case .relatedName:
            let old = contact.contactRelations[index]
            contact.contactRelations[index] = LabeledContactRelation(
                label: newLabel ?? old.label, value: ContactRelation(name: newValue))
        case .date:
            guard let components = parseCalendarDate(newValue) else { return }
            let old = contact.dates[index]
            contact.dates[index] = LabeledDate(label: newLabel ?? old.label, value: components)
        }
    }

    private static func removeListItem(
        _ field: ContactListField, from contact: inout Contact, at index: Int
    ) {
        switch field {
        case .phone:
            contact.phoneNumbers.remove(at: index)
        case .email:
            contact.emailAddresses.remove(at: index)
        case .url:
            var visible = contact.userVisibleURLAddresses
            visible.remove(at: index)
            setVisibleURLs(visible, on: &contact)
        case .relatedName:
            contact.contactRelations.remove(at: index)
        case .date:
            contact.dates.remove(at: index)
        }
    }

    /// The shared handler behind every contacts_add_/edit_/remove_ list
    /// tool: resolve, fetch the CURRENT card through the editor's own
    /// editable path, match the one entry by exact value against that
    /// fresh card, mutate exactly that entry, and save through the same
    /// funnel contacts_update uses. 0 matches → typed notFound; more than
    /// one → typed ambiguous; neither changes anything.
    private func contactsEditListItem(
        helperId: String, messageId: String, contactId: String,
        field: ContactListField, operation: ListItemOperation
    ) async -> WireResponse {
        if let problem = Self.listOperationProblem(operation, field: field) {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: problem)
        }
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                return try await withWriteKeysLocked([token.localID]) { () -> WireResponse in
                    guard let editable = try await contacts.editableContact(id: contact.contactID)
                    else {
                        return .error(
                            helperId: helperId, messageId: messageId,
                            code: .notFound, message: WireErrorMessage.notFoundContact)
                    }
                    var edited = editable
                    switch operation {
                    case .add(let value, let label):
                        Self.appendListItem(field, to: &edited, value: value, label: label)
                    case .remove(let value):
                        switch Self.matchIndex(of: value, field: field, in: editable) {
                        case .failure(let failure):
                            return failure.response(helperId: helperId, messageId: messageId)
                        case .success(let index):
                            Self.removeListItem(field, from: &edited, at: index)
                        }
                    case .edit(let currentValue, let newValue, let newLabel):
                        switch Self.matchIndex(of: currentValue, field: field, in: editable) {
                        case .failure(let failure):
                            return failure.response(helperId: helperId, messageId: messageId)
                        case .success(let index):
                            Self.replaceListItem(
                                field, in: &edited,
                                at: index, newValue: newValue, newLabel: newLabel)
                        }
                    }
                    try await contacts.saveContact(edited, for: contact.contactID)
                    let fresh = await MainActor.run {
                        contacts.contact(restorationToken: token)
                    } ?? edited
                    let isFavorite = await MainActor.run { contacts.isFavorite(fresh.contactID) }
                    await recordAudit(
                        .editContact, kind: .contact, contact: fresh,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: nil, newValue: field.fieldName)
                    return .contact(
                        helperId: helperId, messageId: messageId,
                        contact: WireMapping.contact(
                            fresh, id: WireRecordID.contactID(for: fresh), isFavorite: isFavorite))
                }
            } catch {
                return contactSaveFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    /// A match failure carrying its typed wire answer (mirrors
    /// `LinkResolveFailure`).
    private struct ListMatchFailure: Error {
        let code: WireErrorCode
        let message: String

        func response(helperId: String, messageId: String) -> WireResponse {
            .error(helperId: helperId, messageId: messageId, code: code, message: message)
        }
    }

    /// The index of the SINGLE entry whose value exactly matches, in the
    /// index space `matchValues`/the mutators share. NEVER guesses: no
    /// match and many matches are both typed failures.
    private static func matchIndex(
        of value: String, field: ContactListField, in contact: Contact
    ) -> Result<Int, ListMatchFailure> {
        let needle = canonicalMatchValue(value, field: field)
        let matches = matchValues(field, in: contact).enumerated()
            .filter { $0.element == needle }
            .map(\.offset)
        guard let first = matches.first else {
            return .failure(ListMatchFailure(code: .notFound, message: field.notFoundMessage))
        }
        guard matches.count == 1 else {
            return .failure(ListMatchFailure(code: .ambiguous, message: field.ambiguousMessage))
        }
        return .success(first)
    }

    // MARK: - Confirmation-gated delete (fire-and-forget)

    /// contacts_delete, part 1 — runs on the request path and NEVER waits
    /// on the human: it either answers immediately (replay, budget, resolve
    /// and presentation errors) or schedules the confirmation and returns
    /// nil; the real answer goes out later through the deferred responder,
    /// correlated by helperId+messageId.
    private func contactsDeleteRequested(
        helperId: String, messageId: String, contactId: String, idempotencyToken: String?
    ) async -> WireResponse? {
        if let token = idempotencyToken {
            pruneIdempotencyCache()
            if let cached = idempotencyCache[Self.idempotencyKey(helperId: helperId, token: token)] {
                return cached.response.readdressed(helperId: helperId, messageId: messageId)
            }
        }
        // One dialog at a time — a queue of confirmations is an attack
        // surface, not a feature.
        guard !pendingConfirmation else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .busy, message: WireErrorMessage.confirmationAlreadyPending)
        }
        guard admitWrite() else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .busy, message: WireErrorMessage.writeBusy)
        }
        let contact: Contact
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let resolved):
            contact = resolved
        }
        guard confirmations != nil else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .requiresAppAction, message: WireErrorMessage.confirmationUnavailable)
        }
        pendingConfirmation = true
        let receivedAt = now()
        Task { [weak self] in
            await self?.runContactDeleteConfirmation(
                helperId: helperId, messageId: messageId, contactId: contactId,
                contactName: contact.displayName, receivedAt: receivedAt,
                idempotencyToken: idempotencyToken)
        }
        return nil
    }

    /// contacts_delete, part 2 — awaits the user's decision, applies (or
    /// refuses) the delete, and sends the deferred response.
    private func runContactDeleteConfirmation(
        helperId: String, messageId: String, contactId: String,
        contactName: String, receivedAt: Date, idempotencyToken: String?
    ) async {
        defer { pendingConfirmation = false }
        let decision = await confirmations?.confirmContactDelete(named: contactName)
        let response: WireResponse
        switch decision {
        case nil:
            // Nothing could be presented (no foreground scene). NEVER
            // proceed without the dialog having been seen.
            response = .error(
                helperId: helperId, messageId: messageId,
                code: .requiresAppAction, message: WireErrorMessage.confirmationUnavailable)
        case false?:
            response = .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.contactDeleteDeclined)
        case true?:
            // Abandonment check (the EssentialMCP gap we must not inherit):
            // if the caller's wait has expired, the agent was already told
            // "timed out" — performing the delete now would make its report
            // and the actual effect disagree.
            let elapsed = now().timeIntervalSince(receivedAt)
            if elapsed > MCPTool.contactsDelete.timeout - Self.confirmationTimeoutMargin {
                response = .error(
                    helperId: helperId, messageId: messageId,
                    code: .writeFailed, message: WireErrorMessage.confirmationExpired)
            } else {
                response = await performConfirmedContactDelete(
                    helperId: helperId, messageId: messageId, contactId: contactId)
            }
        }
        if let token = idempotencyToken, response.errorPayload == nil {
            idempotencyCache[Self.idempotencyKey(helperId: helperId, token: token)] =
                (Date(), response)
        }
        if let deferredSend {
            await deferredSend(response)
        }
    }

    private func performConfirmedContactDelete(
        helperId: String, messageId: String, contactId: String
    ) async -> WireResponse {
        // Re-resolve: the book may have changed while the dialog was up.
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            do {
                let deleted = try await contacts.deleteContact(id: contact.contactID)
                guard deleted else {
                    return .error(
                        helperId: helperId, messageId: messageId,
                        code: .notFound, message: WireErrorMessage.notFoundContact)
                }
                await recordAudit(
                    .deleteContact, kind: .contact, contact: contact,
                    instanceID: nil, postModifiedAt: nil,
                    priorValue: contact.displayName, newValue: nil)
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: WireAckMessage.contactDeleted)
            } catch {
                return contactSaveFailure(error, helperId: helperId, messageId: messageId)
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
                      let dto = WireMapping.tag(written, id: written.id.uuidString.lowercased())
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
            guard let tagUUID = WireRecordID.recordUUID(tagId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundTag)
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
                      let dto = WireMapping.tag(written, id: written.id.uuidString.lowercased())
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
            guard let tagUUID = WireRecordID.recordUUID(tagId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundTag)
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
                code: .invalidParams, message: WireErrorMessage.emptyNameArgument)
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
            await recordAudit(
                .createGuide, kind: .guide,
                subjectID: created.id.uuidString.lowercased(), subjectName: created.name,
                instanceID: nil, postModifiedAt: nil,
                priorValue: nil, newValue: trimmed)
            return .guide(
                helperId: helperId, messageId: messageId,
                guide: WireMapping.guide(created, id: created.id.uuidString.lowercased()))
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func guidesDelete(
        helperId: String, messageId: String, guideId: String
    ) async -> WireResponse {
        guard let id = WireRecordID.recordUUID(guideId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGuide)
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
        guard let id = WireRecordID.recordUUID(guideId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGuide)
        }
        var orderedIDs: [UUID] = []
        orderedIDs.reserveCapacity(placeIds.count)
        for placeId in placeIds {
            guard let placeUUID = WireRecordID.recordUUID(placeId) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundPlace)
            }
            orderedIDs.append(placeUUID)
        }
        let current = await guides.places(inGuide: id)
        guard Set(orderedIDs) == Set(current.map(\.id)), orderedIDs.count == current.count else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams,
                message: WireErrorMessage.reorderMustCoverEveryPlace)
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
        guard let placeUUID = WireRecordID.recordUUID(placeId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundPlace)
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

    // MARK: - Links tools (generic connections)

    /// The wire's endpoint-kind vocabulary for links_*. "person" and
    /// "organization" are both CONTACT endpoints (the same distinction the
    /// linked-contact tools enforce); events and places ride their own
    /// record UUIDs.
    private enum LinkKind: String {
        case person, organization, event, place

        init?(argument: String) {
            self.init(rawValue: argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }

        var isContact: Bool { self == .person || self == .organization }
    }

    /// A resolved links_create endpoint.
    private enum LinkWriteEndpoint {
        case contact(Contact)
        case event(Event)
        case place(MapsPlace)
    }

    /// A links_create endpoint that didn't resolve, carrying its typed
    /// wire answer.
    private struct LinkResolveFailure: Error {
        let code: WireErrorCode
        let message: String

        func response(helperId: String, messageId: String) -> WireResponse {
            .error(helperId: helperId, messageId: messageId, code: code, message: message)
        }
    }

    /// The links_* per-kind system-permission gate. The tools' static
    /// domain is `.none` (connection storage is GuessWho's own), so each
    /// call re-checks the domains its endpoint kinds actually touch — the
    /// same enforcement stance as gateCheck.
    private func linkKindGate(
        _ kinds: [LinkKind], helperId: String, messageId: String
    ) async -> WireResponse? {
        let needsContacts = kinds.contains { $0.isContact }
        let needsEvents = kinds.contains(.event)
        guard needsContacts || needsEvents else { return nil }
        let (contactsOK, eventsOK) = await MainActor.run {
            (gates.contactsAuthorized, gates.eventsAuthorized)
        }
        if needsContacts && !contactsOK {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .permissionDenied, message: WireErrorMessage.permissionDeniedContacts)
        }
        if needsEvents && !eventsOK {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .permissionDenied, message: WireErrorMessage.permissionDeniedEvents)
        }
        return nil
    }

    /// The wire (kind, id) pair for a resolved links_create endpoint. A
    /// contact's wire id is stable across the mint boundary (deterministic
    /// mint), so the pre-write resolution is safe to echo.
    private func linkWireDescriptor(_ endpoint: LinkWriteEndpoint) -> (kind: String, id: String) {
        switch endpoint {
        case .contact(let contact):
            return (
                contact.contactType == .organization ? "organization" : "person",
                WireRecordID.contactID(for: contact))
        case .event(let event):
            return ("event", WireRecordID.eventID(for: event))
        case .place(let place):
            return ("place", place.id.uuidString.lowercased())
        }
    }

    private func linksList(
        helperId: String, messageId: String, id: String, kind: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        guard let parsedKind = LinkKind(argument: kind) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidLinkKindArgument)
        }
        if let gateError = await linkKindGate([parsedKind], helperId: helperId, messageId: messageId) {
            return gateError
        }

        func emptyPage() -> WireResponse {
            .linkPage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: [], nextCursor: nil))
        }

        let endpoint: SidecarKey
        switch parsedKind {
        case .person, .organization:
            switch await resolveContact(id) {
            case .failure(let failure):
                return failure.response(helperId: helperId, messageId: messageId)
            case .success(let contact):
                // A contact with no minted identity can hold no connections
                // yet — an empty page, not an error. (The list is permissive
                // about person vs organization: both resolve in the contact
                // id space, matching contacts_get.)
                guard let guessWhoID = contact.contactID.restorationToken.guessWhoID else {
                    return emptyPage()
                }
                endpoint = SidecarKey(kind: .contact, id: guessWhoID)
            }
        case .event:
            switch await resolveEvent(id) {
            case .failure(let failure):
                return failure.response(helperId: helperId, messageId: messageId)
            case .success(let event):
                // A system-calendar-only row has no GuessWho record, so it
                // can hold no connections (reads never mint) — empty page.
                guard !WireRecordID.isSystemOnlyEvent(event) else { return emptyPage() }
                endpoint = SidecarKey.forEvent(event)
            }
        case .place:
            guard let uuid = WireRecordID.recordUUID(id),
                  let place = await guides.allPlaces().first(where: { $0.id == uuid })
            else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundPlace)
            }
            endpoint = SidecarKey(kind: .place, id: place.id.uuidString)
        }

        let fetched = await links.links(at: endpoint)
        var rows: [(link: Link, farKind: String, farID: String)] = []
        for link in fetched where link.deletedAt == nil {
            let far = link.endpointA == endpoint ? link.endpointB : link.endpointA
            // Same DELIBERATE divergence as the linked-contact list: a link
            // whose far endpoint doesn't resolve to a live record is
            // DROPPED — an agent can't act on a row with no id to read.
            guard let resolved = await resolveFarEndpoint(far) else { continue }
            rows.append((link, resolved.kind, resolved.id))
        }
        rows.sort { $0.link.createdAt < $1.link.createdAt }
        let (slice, nextCursor) = page.slice(rows)
        let items = slice.compactMap {
            WireMapping.link($0.link, otherKind: $0.farKind, otherID: $0.farID)
        }
        return .linkPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    /// The wire (kind, id) of a link's far endpoint, or nil when it no
    /// longer resolves to a live record.
    private func resolveFarEndpoint(_ endpoint: SidecarKey) async -> (kind: String, id: String)? {
        switch endpoint.kind {
        case .contact:
            let contact = await MainActor.run { () -> Contact? in
                contacts.allContacts.first {
                    $0.contactID.restorationToken.guessWhoID == endpoint.id
                }
            }
            guard let contact else { return nil }
            return (
                contact.contactType == .organization ? "organization" : "person",
                WireRecordID.contactID(for: contact))
        case .event:
            guard let event = await MainActor.run(body: { events.event(uuid: endpoint.id) })
            else { return nil }
            return ("event", WireRecordID.eventID(for: event))
        case .place:
            guard let place = await guides.allPlaces().first(where: {
                $0.id.uuidString.lowercased() == endpoint.id
            }) else { return nil }
            return ("place", place.id.uuidString.lowercased())
        case .link, .guide:
            return nil
        }
    }

    private func linksCreate(
        helperId: String, messageId: String,
        fromId: String, fromKind: String, toId: String, toKind: String, note: String?
    ) async -> WireResponse {
        guard let from = LinkKind(argument: fromKind), let to = LinkKind(argument: toKind) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidLinkKindArgument)
        }
        // The one kind pair with no app affordance. Every other combination
        // of person/organization/event/place matches a shipping detail-view
        // action (guides have none, so "guide" isn't a kind here at all).
        if from == .place && to == .place {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.linkPairUnsupported)
        }
        if let gateError = await linkKindGate([from, to], helperId: helperId, messageId: messageId) {
            return gateError
        }

        let fromEndpoint: LinkWriteEndpoint
        switch await resolveLinkWriteEndpoint(id: fromId, kind: from) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let endpoint):
            fromEndpoint = endpoint
        }
        let toEndpoint: LinkWriteEndpoint
        switch await resolveLinkWriteEndpoint(id: toId, kind: to) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let endpoint):
            toEndpoint = endpoint
        }

        // Self-connection guard (the app's pickers exclude the current
        // record). Two ids can name one card, so compare resolved records.
        if case .contact(let a) = fromEndpoint, case .contact(let b) = toEndpoint,
           a.contactID.restorationToken.localID == b.contactID.restorationToken.localID {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.linkSelfNotAllowed)
        }
        if case .event(let a) = fromEndpoint, case .event(let b) = toEndpoint, a.id == b.id {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.linkSelfNotAllowed)
        }

        do {
            let link: Link
            switch (fromEndpoint, toEndpoint) {
            case (.contact(let near), .contact(let far)):
                let (_, _, written) = try await addContactContactLink(near: near, far: far, note: note)
                link = written
            case (.contact(let contact), .event(let event)),
                 (.event(let event), .contact(let contact)):
                link = try await addContactRecordLink(contact: contact) { id in
                    try await contacts.addEventLink(
                        for: id, eventUUID: Self.eventUUIDString(event), note: note ?? "")
                }
            case (.contact(let contact), .place(let place)),
                 (.place(let place), .contact(let contact)):
                link = try await addContactRecordLink(contact: contact) { id in
                    try await contacts.addPlaceLink(
                        for: id, placeUUID: place.id.uuidString, note: note ?? "")
                }
            case (.event(let a), .event(let b)):
                link = try await MainActor.run {
                    try links.addLink(
                        from: SidecarKey(kind: .event, id: Self.eventUUIDString(a)),
                        to: SidecarKey(kind: .event, id: Self.eventUUIDString(b)),
                        note: note ?? "")
                }
            case (.event(let event), .place(let place)),
                 (.place(let place), .event(let event)):
                link = try await MainActor.run {
                    try links.addLink(
                        from: SidecarKey(kind: .event, id: Self.eventUUIDString(event)),
                        to: SidecarKey(kind: .place, id: place.id.uuidString),
                        note: note ?? "")
                }
            case (.place, .place):
                // Unreachable: rejected before resolution. Kept explicit for
                // exhaustiveness.
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .invalidParams, message: WireErrorMessage.linkPairUnsupported)
            }
            await recordLinkCreateAudit(from: fromEndpoint, link: link, note: note)
            let far = linkWireDescriptor(toEndpoint)
            guard let dto = WireMapping.link(link, otherKind: far.kind, otherID: far.id) else {
                return writeFailure(helperId: helperId, messageId: messageId)
            }
            return .link(helperId: helperId, messageId: messageId, link: dto)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    /// Resolve one links_create endpoint. Contact ids must match their
    /// declared person/organization kind (the linked-contact tools' rule);
    /// an event id that resolves only to a system calendar event answers
    /// the typed Option B error and MINTS NOTHING (the same
    /// writes-do-not-adopt rule as event tags).
    private func resolveLinkWriteEndpoint(
        id: String, kind: LinkKind
    ) async -> Result<LinkWriteEndpoint, LinkResolveFailure> {
        switch kind {
        case .person, .organization:
            switch await resolveContactForWrite(id) {
            case .failure:
                return .failure(LinkResolveFailure(
                    code: .notFound, message: WireErrorMessage.notFoundContact))
            case .success(let contact):
                let isOrganization = contact.contactType == .organization
                guard isOrganization == (kind == .organization) else {
                    return .failure(LinkResolveFailure(
                        code: .invalidParams, message: WireErrorMessage.linkKindMismatch))
                }
                return .success(.contact(contact))
            }
        case .event:
            switch await resolveEventForWrite(id) {
            case .adopted(let event):
                return .success(.event(event))
            case .unadopted:
                return .failure(LinkResolveFailure(
                    code: .requiresAppAction, message: WireErrorMessage.eventNeedsAppFirstToConnect))
            case .stale:
                return .failure(LinkResolveFailure(
                    code: .notFound, message: WireErrorMessage.notFoundEvent))
            }
        case .place:
            guard let uuid = WireRecordID.recordUUID(id),
                  let place = await guides.allPlaces().first(where: { $0.id == uuid })
            else {
                return .failure(LinkResolveFailure(
                    code: .notFound, message: WireErrorMessage.notFoundPlace))
            }
            return .success(.place(place))
        }
    }

    /// The locked single-contact link write for contact↔event and
    /// contact↔place pairs — the one-endpoint sibling of
    /// addContactContactLink, with the same mint protections: `write` runs
    /// the identity-minting repository funnel; when this was a first write
    /// (which mints), the link is verified reachable at the card's settled
    /// key, retrying once (removing the stale link) if a concurrent
    /// first-writer's mint won.
    private func addContactRecordLink(
        contact: Contact,
        write: (ContactID) async throws -> Link
    ) async throws -> Link {
        let token = contact.contactID.restorationToken
        return try await withWriteKeysLocked([token.localID]) { () -> Link in
            func resolve() async throws -> Contact {
                guard let current = await MainActor.run(body: { contacts.contact(restorationToken: token) })
                else { throw WriteProblem.stale }
                return current
            }
            func linkVisible(_ before: Contact, _ link: Link) async -> Bool {
                guard before.contactID.restorationToken.guessWhoID == nil else { return true }
                guard let fresh = try? await resolve(),
                      let guessWhoID = fresh.contactID.restorationToken.guessWhoID
                else { return false }
                let key = SidecarKey(kind: .contact, id: guessWhoID)
                return await links.links(at: key).contains { $0.id == link.id }
            }

            var current = try await resolve()
            var link = try await write(current.contactID)
            if await !linkVisible(current, link) {
                let staleLinkID = link.id
                try? await MainActor.run { try links.removeLink(id: staleLinkID) }
                current = try await resolve()
                link = try await write(current.contactID)
                guard await linkVisible(current, link) else { throw WriteProblem.verifyFailed }
            }
            return link
        }
    }

    /// Audit entry for links_create; the subject is the FROM record.
    /// Contact subjects re-resolve so a mid-write mint's canonical identity
    /// is what lands in the log.
    private func recordLinkCreateAudit(
        from endpoint: LinkWriteEndpoint, link: Link, note: String?
    ) async {
        switch endpoint {
        case .contact(let contact):
            let effective = await MainActor.run {
                contacts.contact(restorationToken: contact.contactID.restorationToken)
            }
            await recordAudit(
                .addLinkedContact, kind: .contact, contact: effective ?? contact,
                instanceID: link.id, postModifiedAt: link.modifiedAt,
                priorValue: nil, newValue: note)
        case .event(let event):
            await recordAudit(
                .addLinkedContact, kind: .event,
                subjectID: Self.eventUUIDString(event), subjectName: event.title,
                instanceID: link.id, postModifiedAt: link.modifiedAt,
                priorValue: nil, newValue: note)
        case .place(let place):
            await recordAudit(
                .addLinkedContact, kind: .place,
                subjectID: place.id.uuidString.lowercased(), subjectName: place.name,
                instanceID: link.id, postModifiedAt: link.modifiedAt,
                priorValue: nil, newValue: note)
        }
    }

    private func linksRemove(
        helperId: String, messageId: String, linkId: String
    ) async -> WireResponse {
        guard let linkUUID = WireRecordID.recordUUID(linkId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundConnection)
        }
        let existing = await MainActor.run { links.link(id: linkUUID) }
        guard let existing, existing.deletedAt == nil else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundConnection)
        }
        do {
            try await MainActor.run { try links.removeLink(id: linkUUID) }
            let tombstone = await MainActor.run { links.link(id: linkUUID) }
            let subjectName = await linkSubjectName(existing)
            // A .removeLinkedContact / .link audit entry, so the Recently
            // Deleted restore path covers these rows.
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

    /// Best-effort display name for a connection's audit row, from either
    /// endpoint (a contact's display name, an event title, a place name).
    private func linkSubjectName(_ link: Link) async -> String? {
        func name(_ endpoint: SidecarKey) async -> String? {
            switch endpoint.kind {
            case .contact:
                return await MainActor.run {
                    contacts.allContacts.first {
                        $0.contactID.restorationToken.guessWhoID == endpoint.id
                    }?.displayName
                }
            case .event:
                return await MainActor.run { events.event(uuid: endpoint.id)?.title }
            case .place:
                return await guides.allPlaces().first {
                    $0.id.uuidString.lowercased() == endpoint.id
                }?.name
            case .link, .guide:
                return nil
            }
        }
        if let nearName = await name(link.endpointA) { return nearName }
        return await name(link.endpointB)
    }

    // MARK: - Write helpers

    private enum WriteProblem: Error {
        case stale
        case verifyFailed
    }

    /// Resolve a contact wire id for a WRITE. Same resolution as reads —
    /// and for pre-mint ids the deterministic derivation EMBEDS the display
    /// name, so a localID that system unification silently re-pointed at a
    /// different person stops resolving instead of landing the write on the
    /// wrong card (the stale-localID guard, now structural).
    private func resolveContactForWrite(_ id: String) async -> Result<Contact, ResolveFailure> {
        await resolveContact(id)
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
                    code: .invalidParams, message: WireErrorMessage.notFoundEvent)
            case .unadopted:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .requiresAppAction, message: WireErrorMessage.eventNeedsAppFirst)
            case .stale:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundEvent)
            }
        }
    }

    /// Resolve an event wire id for a WRITE. An id that resolves only to a
    /// system calendar event (no GuessWho record yet) answers the typed
    /// Option B error and MINTS NOTHING — writes-do-not-adopt, mirroring
    /// reads-never-mint (plans/cli-mcp.md Phase 2 event-tag rule; a
    /// mint-on-write would race the app's own adopt-on-load and strand a
    /// duplicate record that is never collapsed).
    private func resolveEventForWrite(_ id: String) async -> EventWriteResolution {
        guard let parsed = WireRecordID.parseEventID(id) else { return .stale }
        switch parsed {
        case .record(let uuid):
            if let event = await MainActor.run(body: { events.event(uuid: uuid) }) {
                return .adopted(event)
            }
            return .stale
        case .system(let eventKitID):
            // The user may have opened the event in the app since this id
            // was handed out — a record may now exist for the calendar id.
            if let uuid = await events.eventUUID(forEventKitID: eventKitID),
               let event = await MainActor.run(body: {
                   events.event(uuid: uuid.uuidString.lowercased())
               }) {
                return .adopted(event)
            }
            if await MainActor.run(body: { events.eventKitEvent(eventKitID: eventKitID) }) != nil {
                return .unadopted
            }
            return .stale
        }
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
                code: .notFound, message: WireErrorMessage.notFoundContact)
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
        case notFound(String)

        func response(helperId: String, messageId: String) -> WireResponse {
            switch self {
            case .notFound(let message):
                return .error(helperId: helperId, messageId: messageId, code: .notFound, message: message)
            }
        }
    }

    private func resolveContact(_ id: String) async -> Result<Contact, ResolveFailure> {
        let found = await MainActor.run {
            WireRecordID.contact(for: id, in: contacts.allContacts)
        }
        guard let found else {
            return .failure(.notFound(WireErrorMessage.notFoundContact))
        }
        return .success(found)
    }

    private func resolveEvent(_ id: String) async -> Result<Event, ResolveFailure> {
        guard let parsed = WireRecordID.parseEventID(id) else {
            return .failure(.notFound(WireErrorMessage.notFoundEvent))
        }
        switch parsed {
        case .record(let uuid):
            if let event = await MainActor.run(body: { events.event(uuid: uuid) }) {
                return .success(event)
            }
            return .failure(.notFound(WireErrorMessage.notFoundEvent))
        case .system(let eventKitID):
            if let uuid = await events.eventUUID(forEventKitID: eventKitID),
               let event = await MainActor.run(body: {
                   events.event(uuid: uuid.uuidString.lowercased())
               }) {
                return .success(event)
            }
            if let event = await MainActor.run(body: { events.eventKitEvent(eventKitID: eventKitID) }) {
                return .success(event)
            }
            return .failure(.notFound(WireErrorMessage.notFoundEvent))
        }
    }

    private static func eventUUIDString(_ event: Event) -> String {
        event.id.uuidString.lowercased()
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
