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
    private let favorites: MCPFavoriteSource
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
        favorites: MCPFavoriteSource,
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
        self.favorites = favorites
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
        if let gateError = await favoriteGateCheck(
            request, helperId: helperId, messageId: messageId
        ) {
            return gateError
        }

        // Reorder's permission domain is the complete stored set, not the
        // caller-provided order. Load that authoritative snapshot once,
        // reject missing permission before the write budget, and pass the
        // same values through validation and CAS so no second coordinated
        // read is needed in the dispatcher.
        var favoriteReorderSnapshot: [Favorite]?
        if case .favoritesReorder = request {
            do {
                favoriteReorderSnapshot = try await MainActor.run {
                    try favorites.loadFavorites()
                }
            } catch {
                return favoriteReadFailure(helperId: helperId, messageId: messageId)
            }
            if let stored = favoriteReorderSnapshot,
               let permissionError = await favoritePermissionError(
                   kinds: stored.map { Self.wireFavoriteKind($0.kind) },
                   helperId: helperId, messageId: messageId
               ) {
                return permissionError
            }
        }

        if case .contactsDelete(_, _, let contactId, let idempotencyToken) = request {
            // Confirmation-gated: may return nil (answer sent later).
            return await contactsDeleteRequested(
                helperId: helperId, messageId: messageId,
                contactId: contactId, idempotencyToken: idempotencyToken)
        }

        if tool.isWrite {
            return capped(await handleWrite(
                request, helperId: helperId, messageId: messageId,
                favoriteReorderSnapshot: favoriteReorderSnapshot))
        }

        let response: WireResponse
        switch request {
        case .contactsSearch(_, _, let query, let limit, let cursor):
            response = await contactsSearch(
                helperId: helperId, messageId: messageId,
                query: query, limit: limit, cursor: cursor)
        case .contactsList(_, _, let kind, let favoritesOnly, let groupId, let limit, let cursor):
            response = await contactsList(
                helperId: helperId, messageId: messageId,
                kind: kind, favoritesOnly: favoritesOnly, groupId: groupId,
                limit: limit, cursor: cursor)
        case .contactsGet(_, _, let contactId):
            response = await contactsGet(
                helperId: helperId, messageId: messageId, contactId: contactId)
        case .contactsGetPhoto(_, _, let contactId):
            response = await contactsGetPhoto(
                helperId: helperId, messageId: messageId, contactId: contactId)
        case .contactsListNotes(_, _, let contactId, let limit, let cursor):
            response = await contactsListNotes(
                helperId: helperId, messageId: messageId,
                contactId: contactId, limit: limit, cursor: cursor)
        case .contactsListCustomFields(_, _, let contactId, let limit, let cursor):
            response = await contactsListCustomFields(
                helperId: helperId, messageId: messageId,
                contactId: contactId, limit: limit, cursor: cursor)
        case .contactsListGroups(_, _, let limit, let cursor):
            response = await contactsListGroups(
                helperId: helperId, messageId: messageId, limit: limit, cursor: cursor)
        case .organizationsListMembers(_, _, let organizationId, let limit, let cursor):
            response = await organizationsListMembers(
                helperId: helperId, messageId: messageId,
                organizationId: organizationId, limit: limit, cursor: cursor)
        case .organizationsListDepartments(_, _, let organizationId, let limit, let cursor):
            response = await organizationsListDepartments(
                helperId: helperId, messageId: messageId,
                organizationId: organizationId, limit: limit, cursor: cursor)
        case .organizationsListDepartmentMembers(
            _, _, let organizationId, let department, let limit, let cursor
        ):
            response = await organizationsListDepartmentMembers(
                helperId: helperId, messageId: messageId,
                organizationId: organizationId, department: department,
                limit: limit, cursor: cursor)
        case .groupsListForContact(_, _, let contactId, let limit, let cursor):
            response = await groupsListForContact(
                helperId: helperId, messageId: messageId,
                contactId: contactId, limit: limit, cursor: cursor)
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
        case .guidesListForPlace(_, _, let placeId, let limit, let cursor):
            response = await guidesListForPlace(
                helperId: helperId, messageId: messageId,
                placeId: placeId, limit: limit, cursor: cursor)
        case .placesList(_, _, let guideId, let limit, let cursor):
            response = await placesList(
                helperId: helperId, messageId: messageId,
                guideId: guideId, limit: limit, cursor: cursor)
        case .placesSearch(_, _, let query, let limit, let cursor):
            response = await placesSearch(
                helperId: helperId, messageId: messageId,
                query: query, limit: limit, cursor: cursor)
        case .placesGet(_, _, let placeId):
            response = await placesGet(
                helperId: helperId, messageId: messageId, placeId: placeId)
        case .linksList(_, _, let id, let kind, let limit, let cursor):
            response = await linksList(
                helperId: helperId, messageId: messageId,
                id: id, kind: kind, limit: limit, cursor: cursor)
        case .favoritesList(_, _, let limit, let cursor):
            response = await favoritesList(
                helperId: helperId, messageId: messageId, limit: limit, cursor: cursor)
        case .initialize, .deinitialize, .ping, .listTools:
            response = .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        case .contactsCreate, .contactsUpdate, .contactsDelete,
             .contactsSetPhoto, .contactsDeletePhoto,
             .contactsAddValue, .contactsDeleteValue, .contactsEditValue,
             .contactsAddPostalAddress, .contactsEditPostalAddress,
             .contactsDeletePostalAddress,
             .contactsAddSocialProfile, .contactsEditSocialProfile,
             .contactsDeleteSocialProfile,
             .contactsAddInstantMessage, .contactsEditInstantMessage,
             .contactsDeleteInstantMessage,
             .contactsAddNote, .contactsEditNote, .contactsDeleteNote,
             .contactsSetCustomField, .contactsDeleteCustomField,
             .contactsSetFavorite,
             .favoritesSet, .favoritesReorder,
             .organizationsRenameDepartment,
             .groupsCreate, .groupsRename, .groupsDelete,
             .groupsAddMembers, .groupsRemoveMembers, .groupsSetFavorite,
             .eventsAddTag, .eventsEditTag, .eventsDeleteTag,
             .guidesCreate, .guidesDelete, .guidesReorderPlaces, .placesDelete,
             .linksCreate, .linksDelete:
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

    /// Favorites span several permission domains, so their static tool
    /// metadata is `.none` and the enforcement follows the actual referents
    /// on every call. A list containing an unauthorized referent fails as a
    /// whole; it never drops rows and thereby changes the stored projection.
    private func favoriteGateCheck(
        _ request: WireRequest, helperId: String, messageId: String
    ) async -> WireResponse? {
        let kinds: [WireFavoriteKind]
        switch request {
        case .favoritesSet(_, _, let kind, _, _, _):
            kinds = [kind]
        case .favoritesList, .favoritesReorder:
            // Each handler loads its own authoritative snapshot and checks
            // every referent kind before reading or writing entity data.
            // Avoid an immediately-discarded coordinated-file read here.
            return nil
        default:
            return nil
        }

        return await favoritePermissionError(
            kinds: kinds, helperId: helperId, messageId: messageId)
    }

    private func favoritePermissionError(
        kinds: [WireFavoriteKind], helperId: String, messageId: String
    ) async -> WireResponse? {
        let needsContacts = kinds.contains { $0 == .contact || $0 == .group || $0 == .department }
        let needsEvents = kinds.contains { $0 == .event }
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
    /// per-contact text matching, so it takes no search budget. Ids come
    /// from the same no-mint derivation every read uses.
    ///
    /// The optional `favoritesOnly` and `groupId` filters intersect with
    /// `kind` (all three AND-compose): the base set is one group's members
    /// when `groupId` is present (a group id that resolves to nothing is a
    /// typed notFound, never a silently empty page), otherwise the whole
    /// book, and `kind`/`favoritesOnly` narrow it. Every result — favorites
    /// included — runs through the one deterministic sort below.
    private func contactsList(
        helperId: String, messageId: String, kind: String?,
        favoritesOnly: Bool?, groupId: String?, limit: Int?, cursor: String?
    ) async -> WireResponse {
        let wanted: ContactType?
        switch kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil: wanted = nil
        case "person": wanted = .person
        case "organization": wanted = .organization
        default:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidKindFilterArgument)
        }
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        // Base set: one group's members (resolved via the same no-mint
        // group lookup + notFound the group-members filter has always used)
        // or the whole book. Then kind + favorites narrow it in place, so
        // the filters intersect.
        let baseSet: [Contact]
        if let groupId {
            let groups = await contacts.fetchGroups()
            guard let group = WireRecordID.group(for: groupId, in: groups) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundGroup)
            }
            baseSet = await contacts.members(ofGroup: group.localID)
        } else {
            baseSet = await MainActor.run { contacts.allContacts }
        }
        let matching = await MainActor.run { () -> [Contact] in
            baseSet.filter { contact in
                if let wanted, contact.contactType != wanted { return false }
                if favoritesOnly == true, !contacts.isFavorite(contact.contactID) { return false }
                return true
            }
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

    private func contactsGetPhoto(
        helperId: String, messageId: String, contactId: String
    ) async -> WireResponse {
        switch await resolveContact(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            do {
                guard let photo = try await contacts.contactPhotoData(
                    for: contact.contactID, kind: .fullSize)
                else {
                    return .contactPhoto(
                        helperId: helperId, messageId: messageId, photo: .none)
                }
                guard !photo.data.isEmpty else {
                    return .contactPhoto(
                        helperId: helperId, messageId: messageId, photo: .none)
                }
                guard photo.data.count <= WireEnvironment.maxContactPhotoBytes else {
                    return .error(
                        helperId: helperId, messageId: messageId,
                        code: .tooLarge, message: WireErrorMessage.photoTooLarge)
                }
                guard let mediaType = WireContactPhotoMedia.mediaType(for: photo.data) else {
                    return .error(
                        helperId: helperId, messageId: messageId,
                        code: .readFailed, message: WireErrorMessage.unsupportedStoredPhoto)
                }
                return .contactPhoto(
                    helperId: helperId, messageId: messageId,
                    photo: WireContactPhoto(
                        present: true,
                        mediaType: mediaType,
                        dataBase64: photo.data.base64EncodedString(),
                        byteCount: photo.data.count))
            } catch {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .readFailed, message: WireErrorMessage.photoReadFailed)
            }
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

    private func contactsListGroups(
        helperId: String, messageId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let groups = await contacts.fetchGroups()
        let (slice, nextCursor) = page.slice(groups)
        let favoriteStates = await MainActor.run {
            slice.map { contacts.isGroupFavorite($0) }
        }
        let items = zip(slice, favoriteStates).map {
            WireMapping.group(
                $0.0, id: WireRecordID.groupID(for: $0.0), isFavorite: $0.1)
        }
        return .groupPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    // MARK: - Organization tools

    private func organizationsListMembers(
        helperId: String, messageId: String, organizationId: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveOrganization(organizationId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let organization):
            let members = await MainActor.run {
                contacts.contactsAssociated(with: organization)
            }
            return contactSummaryPage(
                members, bounds: page, helperId: helperId, messageId: messageId)
        }
    }

    private func organizationsListDepartments(
        helperId: String, messageId: String, organizationId: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveOrganization(organizationId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let organization):
            let fetched = await MainActor.run { contacts.departments(in: organization) }
            // The repository owns extraction, trimming, de-duplication, and
            // matching semantics. This final total sort only makes paging
            // independent of locale/cache incidental ordering.
            let ordered = fetched.sorted { lhs, rhs in
                let foldedLHS = lhs.lowercased()
                let foldedRHS = rhs.lowercased()
                if foldedLHS != foldedRHS { return foldedLHS < foldedRHS }
                return lhs < rhs
            }
            let (slice, nextCursor) = page.slice(ordered)
            return .departmentPage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: slice, nextCursor: nextCursor))
        }
    }

    private func organizationsListDepartmentMembers(
        helperId: String, messageId: String, organizationId: String,
        department: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        guard !department.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.emptyDepartmentName)
        }
        switch await resolveOrganization(organizationId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let organization):
            let members = await MainActor.run {
                contacts.contactsAssociated(with: organization, inDepartment: department)
            }
            guard !members.isEmpty else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundDepartment)
            }
            return contactSummaryPage(
                members, bounds: page, helperId: helperId, messageId: messageId)
        }
    }

    /// Stable total ordering for organization-derived contact pages. The
    /// repository decides membership; ids only break equal display names.
    private func contactSummaryPage(
        _ contacts: [Contact], bounds: PageBounds,
        helperId: String, messageId: String
    ) -> WireResponse {
        let ordered = contacts
            .map { (contact: $0, id: WireRecordID.contactID(for: $0)) }
            .sorted { lhs, rhs in
                let lhsName = lhs.contact.displayName.lowercased()
                let rhsName = rhs.contact.displayName.lowercased()
                if lhsName != rhsName { return lhsName < rhsName }
                return lhs.id < rhs.id
            }
        let (slice, nextCursor) = bounds.slice(ordered)
        return .contactPage(
            helperId: helperId, messageId: messageId,
            page: WirePage(
                items: slice.map { WireMapping.summary($0.contact, id: $0.id) },
                nextCursor: nextCursor))
    }

    // MARK: - Group tools

    private func groupsListForContact(
        helperId: String, messageId: String, contactId: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        switch await resolveContact(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let groups = await contacts.groups(containing: contact)
            let (slice, nextCursor) = page.slice(groups)
            let favoriteStates = await MainActor.run {
                slice.map { contacts.isGroupFavorite($0) }
            }
            let items = zip(slice, favoriteStates).map {
                WireMapping.group(
                    $0.0, id: WireRecordID.groupID(for: $0.0), isFavorite: $0.1)
            }
            return .groupPage(
                helperId: helperId, messageId: messageId,
                page: WirePage(items: items, nextCursor: nextCursor))
        }
    }

    // MARK: - Group writes

    private func groupsCreate(
        helperId: String, messageId: String, name: String
    ) async -> WireResponse {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.emptyNameArgument)
        }
        do {
            let group = try await contacts.createGroup(name: normalized)
            let wireID = WireRecordID.groupID(for: group)
            let isFavorite = await MainActor.run { contacts.isGroupFavorite(group) }
            await recordAudit(
                .createGroup, kind: .group,
                subjectID: wireID, subjectName: group.name,
                instanceID: nil, postModifiedAt: nil,
                priorValue: nil, newValue: group.name)
            return .group(
                helperId: helperId, messageId: messageId,
                group: WireMapping.group(
                    group, id: wireID, isFavorite: isFavorite))
        } catch {
            return await groupWriteFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func groupsRename(
        helperId: String, messageId: String, groupId: String, name: String
    ) async -> WireResponse {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.emptyNameArgument)
        }
        guard let group = await resolveGroup(groupId) else {
            return groupNotFound(helperId: helperId, messageId: messageId)
        }
        do {
            try await contacts.renameGroup(group, to: normalized)
            let renamed = ContactGroup(localID: group.localID, name: normalized)
            let isFavorite = await MainActor.run { contacts.isGroupFavorite(renamed) }
            await recordAudit(
                .renameGroup, kind: .group,
                subjectID: groupId, subjectName: normalized,
                instanceID: nil, postModifiedAt: nil,
                priorValue: group.name, newValue: normalized)
            return .group(
                helperId: helperId, messageId: messageId,
                group: WireMapping.group(
                    renamed, id: groupId, isFavorite: isFavorite))
        } catch {
            return await groupWriteFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func groupsDelete(
        helperId: String, messageId: String, groupId: String
    ) async -> WireResponse {
        guard let group = await resolveGroup(groupId) else {
            return groupNotFound(helperId: helperId, messageId: messageId)
        }
        do {
            try await contacts.deleteGroup(group)
            // Match the app's delete path: the Contacts deletion is the primary
            // operation, and stale favorite cleanup is best-effort afterwards.
            _ = try? await contacts.setGroupFavorite(false, for: group)
            await recordAudit(
                .deleteGroup, kind: .group,
                subjectID: groupId, subjectName: group.name,
                instanceID: nil, postModifiedAt: nil,
                priorValue: group.name, newValue: nil)
            return .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.groupDeleted)
        } catch {
            return await groupWriteFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func groupsSetFavorite(
        helperId: String, messageId: String, groupId: String, favorite: Bool
    ) async -> WireResponse {
        // Resolve the opaque id to a live value BEFORE the repository is
        // allowed to inspect its Contacts identifier as a favorite key.
        guard let group = await resolveGroup(groupId) else {
            return groupNotFound(helperId: helperId, messageId: messageId)
        }
        let prior = await MainActor.run { contacts.isGroupFavorite(group) }
        do {
            let resulting = try await contacts.setGroupFavorite(favorite, for: group)
            guard resulting == favorite else { throw WriteProblem.verifyFailed }
            if prior != favorite {
                await recordAudit(
                    .setFavorite, kind: .group,
                    subjectID: groupId, subjectName: group.name,
                    instanceID: nil, postModifiedAt: nil,
                    priorValue: prior ? "true" : "false",
                    newValue: favorite ? "true" : "false")
            }
            return .group(
                helperId: helperId, messageId: messageId,
                group: WireMapping.group(
                    group, id: groupId, isFavorite: favorite))
        } catch {
            return await groupWriteFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func groupsChangeMembers(
        helperId: String, messageId: String,
        groupId: String, contactIds: [String], change: GroupMembershipChange
    ) async -> WireResponse {
        guard !contactIds.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.groupMembersRequired)
        }
        guard contactIds.count <= Self.maxLimit else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.tooManyGroupMembers)
        }
        guard let group = await resolveGroup(groupId) else {
            return groupNotFound(helperId: helperId, messageId: messageId)
        }

        // Collapse duplicate wire ids in caller order. Resolve the whole batch
        // before the first write: one invalid id cannot cause a half-applied
        // request before the caller learns its arguments were stale.
        var seen = Set<String>()
        let uniqueIDs = contactIds.filter { seen.insert($0).inserted }
        var resolved: [(id: String, contact: Contact)] = []
        var requested: [Contact] = []
        for id in uniqueIDs {
            switch await resolveContactForWrite(id) {
            case .failure(let failure):
                return failure.response(helperId: helperId, messageId: messageId)
            case .success(let contact):
                resolved.append((id, contact))
                // A pre-mint preview id and the subsequently minted id can
                // both resolve to the same card. Apply that contact once,
                // while retaining every distinct caller id for the result.
                if !requested.contains(where: {
                    $0.contactID == contact.contactID
                }) {
                    requested.append(contact)
                }
            }
        }

        // Snapshot membership only to make the audit honest about idempotent
        // no-ops. The repository remains authoritative for applying the batch.
        let currentIDs = Set(
            await contacts.members(ofGroup: group.localID)
                .map { WireRecordID.contactID(for: $0) }
        )
        let wouldChangeLocalIDs = Set(requested.compactMap { contact -> String? in
            // A pre-mint id can keep resolving after another writer assigns
            // the contact a different GuessWho id. Compare membership using
            // the resolved contact's current wire id. Track the internal
            // identity only for an exact, de-duplicated audit count.
            let canonicalID = WireRecordID.contactID(for: contact)
            let isMember = currentIDs.contains(canonicalID)
            switch change {
            case .addition:
                return isMember ? nil : contact.contactID.restorationToken.localID
            case .removal:
                return isMember ? contact.contactID.restorationToken.localID : nil
            }
        })

        do {
            switch change {
            case .addition:
                try await contacts.addContacts(requested, toGroup: group)
            case .removal:
                try await contacts.removeContacts(requested, fromGroup: group)
            }
            await recordGroupMembershipAudit(
                change: change, group: group, groupId: groupId,
                changedIDs: requested.compactMap { contact in
                    let localID = contact.contactID.restorationToken.localID
                    return wouldChangeLocalIDs.contains(localID)
                        ? WireRecordID.contactID(for: contact) : nil
                })
            return .groupMembership(
                helperId: helperId, messageId: messageId,
                result: WireGroupMembershipResult(
                    groupId: groupId,
                    appliedContactIds: uniqueIDs,
                    failures: []))
        } catch let partial as GroupMembershipPartialFailureError {
            let status = await contacts.contactsAuthorizationStatus()
            let appliedContactIDs = Set(partial.applied.map(\.contactID))
            let failuresByContactID = Dictionary(
                partial.failures.map { ($0.contact.contactID, $0) },
                uniquingKeysWith: { first, _ in first })

            // Classify the caller's distinct opaque ids in their original
            // order. If pre- and post-mint ids name the same contact, both
            // receive the one repository outcome, so none silently vanish.
            let applied = resolved.compactMap { pair in
                appliedContactIDs.contains(pair.contact.contactID) ? pair.id : nil
            }
            let failures = resolved.compactMap { pair in
                failuresByContactID[pair.contact.contactID].map {
                    groupMembershipFailure(
                        $0, contactId: pair.id, authorization: status)
                }
            }
            await recordGroupMembershipAudit(
                change: change, group: group, groupId: groupId,
                changedIDs: partial.applied.compactMap { contact in
                    let localID = contact.contactID.restorationToken.localID
                    return wouldChangeLocalIDs.contains(localID)
                        ? WireRecordID.contactID(for: contact) : nil
                })
            return .groupMembership(
                helperId: helperId, messageId: messageId,
                result: WireGroupMembershipResult(
                    groupId: groupId,
                    appliedContactIds: applied,
                    failures: failures))
        } catch {
            return await groupWriteFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func recordGroupMembershipAudit(
        change: GroupMembershipChange,
        group: ContactGroup,
        groupId: String,
        changedIDs: [String]
    ) async {
        guard !changedIDs.isEmpty else { return }
        let countDescription = changedIDs.count == 1
            ? "1 contact"
            : "\(changedIDs.count) contacts"
        await recordAudit(
            change == .addition ? .addGroupMembers : .removeGroupMembers,
            kind: .group,
            subjectID: groupId, subjectName: group.name,
            instanceID: nil, postModifiedAt: nil,
            priorValue: nil, newValue: countDescription)
    }

    private func groupMembershipFailure(
        _ failure: GroupMembershipPartialFailureError.Failure,
        contactId: String,
        authorization: StoreAuthorizationStatus
    ) -> WireGroupMembershipFailure {
        if let storeError = failure.error as? ContactStoreError,
           case .contactNotFound = storeError {
            return WireGroupMembershipFailure(
                contactId: contactId, code: .notFound,
                message: WireErrorMessage.notFoundContact)
        }
        if failure.error is ContactNotSavedError {
            return WireGroupMembershipFailure(
                contactId: contactId, code: .notFound,
                message: WireErrorMessage.notFoundContact)
        }
        if authorization == .denied || authorization == .restricted {
            return WireGroupMembershipFailure(
                contactId: contactId, code: .permissionDenied,
                message: WireErrorMessage.permissionDeniedContacts)
        }
        return WireGroupMembershipFailure(
            contactId: contactId, code: .writeFailed,
            message: WireErrorMessage.writeFailed)
    }

    private func groupWriteFailure(
        _ error: Error, helperId: String, messageId: String
    ) async -> WireResponse {
        if let storeError = error as? ContactStoreError {
            switch storeError {
            case .groupNotFound:
                return groupNotFound(helperId: helperId, messageId: messageId)
            case .contactNotFound:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundContact)
            }
        }
        let authorization = await contacts.contactsAuthorizationStatus()
        if authorization == .denied || authorization == .restricted {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .permissionDenied,
                message: WireErrorMessage.permissionDeniedContacts)
        }
        return .error(
            helperId: helperId, messageId: messageId,
            code: .writeFailed, message: WireErrorMessage.writeFailed)
    }

    private func groupNotFound(helperId: String, messageId: String) -> WireResponse {
        .error(
            helperId: helperId, messageId: messageId,
            code: .notFound, message: WireErrorMessage.notFoundGroup)
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
        async let fetchedGuides = guides.allGuides()
        async let fetchedPlaces = guides.allPlaces()
        let all = await fetchedGuides
        let allPlaces = await fetchedPlaces
        let sorted = Self.sortedGuides(all)
        let (slice, nextCursor) = page.slice(sorted)
        let items = await wireGuides(slice, allPlaces: allPlaces)
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
        async let fetchedGuides = guides.allGuides()
        async let fetchedPlaces = guides.allPlaces()
        guard let guide = await fetchedGuides.first(where: { $0.id == id }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundGuide)
        }
        let items = await wireGuides([guide], allPlaces: await fetchedPlaces)
        return .guide(
            helperId: helperId, messageId: messageId,
            guide: items[0])
    }

    private func guidesListForPlace(
        helperId: String, messageId: String, placeId: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        guard let id = WireRecordID.recordUUID(placeId) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundPlace)
        }
        let allPlaces = await guides.allPlaces()
        guard let place = allPlaces.first(where: { $0.id == id }) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundPlace)
        }
        // The source deliberately resolves containment through the same
        // address-based repository path used by the app. That live path may
        // read places again; keep this first snapshot for lookup and counts
        // instead of duplicating the matcher here and risking parity drift.
        let containing = Self.sortedGuides(await guides.guides(containingPlace: place))
        let (slice, nextCursor) = page.slice(containing)
        let items = await wireGuides(slice, allPlaces: allPlaces)
        return .guidePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
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
            guard await guides.allGuides().contains(where: { $0.id == id }) else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundGuide)
            }
            places = Self.sortedPlacesInGuide(await guides.places(inGuide: id))
        } else {
            places = Self.sortedPlaces(await guides.allPlaces())
        }
        let (slice, nextCursor) = page.slice(places)
        let items = await wirePlaces(slice)
        return .placePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    private func placesSearch(
        helperId: String, messageId: String, query: String,
        limit: Int?, cursor: String?
    ) async -> WireResponse {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unlike contact search, accept one visible character: saved place
        // and guide names can legitimately be a single character. Paging,
        // the shared search budget, and the response cap bound the result.
        guard !needle.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "The query argument must contain visible text.")
        }
        guard admitSearch() else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .busy, message: WireErrorMessage.busy)
        }
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        async let fetchedGuides = guides.allGuides()
        async let fetchedPlaces = guides.allPlaces()
        let guideNames = Dictionary(
            await fetchedGuides.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        let matches = await fetchedPlaces.filter { place in
            place.name.localizedCaseInsensitiveContains(needle)
                || place.address?.localizedCaseInsensitiveContains(needle) == true
                || guideNames[place.guideID]?.localizedCaseInsensitiveContains(needle) == true
        }
        let ordered = Self.sortedPlaceSearchResults(matches, guideNames: guideNames)
        let (slice, nextCursor) = page.slice(ordered)
        return .placePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: await wirePlaces(slice), nextCursor: nextCursor))
    }

    private func placesGet(
        helperId: String, messageId: String, placeId: String
    ) async -> WireResponse {
        guard let id = WireRecordID.recordUUID(placeId),
              let place = await guides.allPlaces().first(where: { $0.id == id })
        else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .notFound, message: WireErrorMessage.notFoundPlace)
        }
        let items = await wirePlaces([place])
        return .place(helperId: helperId, messageId: messageId, place: items[0])
    }

    private func wireGuides(
        _ records: [MapsGuide], allPlaces: [MapsPlace]
    ) async -> [WireGuide] {
        let counts = Dictionary(grouping: allPlaces, by: \.guideID).mapValues(\.count)
        let favoriteIDs = await favoriteIDs(kind: .guide)
        return records.map { guide in
            let id = guide.id.uuidString.lowercased()
            return WireMapping.guide(
                guide, id: id, placeCount: counts[guide.id, default: 0],
                isFavorite: favoriteIDs.contains(id))
        }
    }

    private func wirePlaces(_ records: [MapsPlace]) async -> [WirePlace] {
        let favoriteIDs = await favoriteIDs(kind: .place)
        return records.map { place in
            let id = place.id.uuidString.lowercased()
            return WireMapping.place(
                place, id: id, guideID: place.guideID.uuidString.lowercased(),
                isFavorite: favoriteIDs.contains(id))
        }
    }

    private func favoriteIDs(kind: FavoriteKind) async -> Set<String> {
        Set(await guides.favorites().lazy.filter { $0.kind == kind }.map(\.id))
    }

    private static func sortedGuides(_ records: [MapsGuide]) -> [MapsGuide] {
        records.sorted { lhs, rhs in
            let left = lhs.name.lowercased()
            let right = rhs.name.lowercased()
            if left != right { return left < right }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    private static func sortedPlacesInGuide(_ records: [MapsPlace]) -> [MapsPlace] {
        records.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    private static func sortedPlaces(_ records: [MapsPlace]) -> [MapsPlace] {
        records.sorted { lhs, rhs in
            let leftGuide = lhs.guideID.uuidString.lowercased()
            let rightGuide = rhs.guideID.uuidString.lowercased()
            if leftGuide != rightGuide { return leftGuide < rightGuide }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    private static func sortedPlaceSearchResults(
        _ records: [MapsPlace], guideNames: [UUID: String]
    ) -> [MapsPlace] {
        records.sorted { lhs, rhs in
            let leftName = lhs.name.lowercased()
            let rightName = rhs.name.lowercased()
            if leftName != rightName { return leftName < rightName }
            let leftAddress = lhs.address?.lowercased() ?? ""
            let rightAddress = rhs.address?.lowercased() ?? ""
            if leftAddress != rightAddress { return leftAddress < rightAddress }
            let leftGuide = guideNames[lhs.guideID]?.lowercased() ?? ""
            let rightGuide = guideNames[rhs.guideID]?.lowercased() ?? ""
            if leftGuide != rightGuide { return leftGuide < rightGuide }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    // MARK: - Favorites read tool

    private func favoritesList(
        helperId: String, messageId: String, limit: Int?, cursor: String?
    ) async -> WireResponse {
        guard let page = pageBounds(limit: limit, cursor: cursor) else {
            return invalidCursor(helperId: helperId, messageId: messageId)
        }
        let stored: [Favorite]
        do {
            stored = try await MainActor.run { try favorites.loadFavorites() }
        } catch {
            return favoriteReadFailure(helperId: helperId, messageId: messageId)
        }
        if let permissionError = await favoritePermissionError(
            kinds: stored.map { Self.wireFavoriteKind($0.kind) },
            helperId: helperId, messageId: messageId
        ) {
            return permissionError
        }
        let (slice, nextCursor) = page.slice(stored)

        // Resolve only the requested page, but keep the page boundaries over
        // the raw stored order so stale rows cannot shift or disappear. A
        // department favorite resolves its organization from the same snapshot.
        let contactSnapshot = slice.contains { $0.kind == .contact || $0.kind == .department }
            ? await MainActor.run { contacts.allContacts } : []
        let groupSnapshot = slice.contains { $0.kind == .group }
            ? await contacts.fetchGroups() : []
        let guideSnapshot = slice.contains { $0.kind == .guide }
            ? await guides.allGuides() : []
        let placeSnapshot = slice.contains { $0.kind == .place }
            ? await guides.allPlaces() : []

        var items: [WireFavorite] = []
        items.reserveCapacity(slice.count)
        for favorite in slice {
            let resolved = await resolveStoredFavorite(
                favorite, contacts: contactSnapshot, groups: groupSnapshot,
                guides: guideSnapshot, places: placeSnapshot)
            items.append(resolved.wire)
        }
        return .favoritePage(
            helperId: helperId, messageId: messageId,
            page: WirePage(items: items, nextCursor: nextCursor))
    }

    // MARK: - Write pipeline (plans/cli-mcp.md Phase 2)

    /// The write wrapper every write tool runs through: idempotent replay →
    /// write budget → execute. The idempotency check comes FIRST so a retry
    /// neither burns budget nor re-applies; only successful responses are
    /// cached (a failed write should re-attempt on retry).
    private func handleWrite(
        _ request: WireRequest, helperId: String, messageId: String,
        favoriteReorderSnapshot: [Favorite]?
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
        let response = await executeWrite(
            request, helperId: helperId, messageId: messageId,
            favoriteReorderSnapshot: favoriteReorderSnapshot)
        if let token = request.idempotencyToken, response.errorPayload == nil {
            idempotencyCache[Self.idempotencyKey(helperId: helperId, token: token)] =
                (Date(), response)
        }
        return response
    }

    private func executeWrite(
        _ request: WireRequest, helperId: String, messageId: String,
        favoriteReorderSnapshot: [Favorite]?
    ) async -> WireResponse {
        switch request {
        case .contactsCreate(_, _, let kind, let fields, _):
            return await contactsCreate(
                helperId: helperId, messageId: messageId, kind: kind, fields: fields)
        case .contactsUpdate(_, _, let contactId, let fields, _):
            return await contactsUpdate(
                helperId: helperId, messageId: messageId, contactId: contactId, fields: fields)
        case .contactsSetPhoto(_, _, let contactId, let mediaType, let dataBase64, _):
            return await contactsSetPhoto(
                helperId: helperId, messageId: messageId, contactId: contactId,
                mediaType: mediaType, dataBase64: dataBase64)
        case .contactsDeletePhoto(_, _, let contactId, _):
            return await contactsDeletePhoto(
                helperId: helperId, messageId: messageId, contactId: contactId)
        case .contactsAddValue(_, _, let contactId, let wireField, let value, let label, _):
            guard let field = ContactListField(wireField: wireField) else {
                return invalidContactListField(helperId: helperId, messageId: messageId)
            }
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: field, operation: .add(value: value, label: label))
        case .contactsDeleteValue(_, _, let contactId, let wireField, let value, _):
            guard let field = ContactListField(wireField: wireField) else {
                return invalidContactListField(helperId: helperId, messageId: messageId)
            }
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: field, operation: .remove(value: value))
        case .contactsEditValue(
            _, _, let contactId, let wireField,
            let currentValue, let newValue, let newLabel, _
        ):
            guard let field = ContactListField(wireField: wireField) else {
                return invalidContactListField(helperId: helperId, messageId: messageId)
            }
            return await contactsEditListItem(
                helperId: helperId, messageId: messageId, contactId: contactId,
                field: field,
                operation: .edit(currentValue: currentValue, newValue: newValue, newLabel: newLabel))
        case .contactsAddPostalAddress(_, _, let contactId, let address, _):
            return await contactsEditPostalAddress(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .add(address))
        case .contactsEditPostalAddress(
            _, _, let contactId, let currentAddress, let newAddress, _
        ):
            return await contactsEditPostalAddress(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .edit(current: currentAddress, replacement: newAddress))
        case .contactsDeletePostalAddress(_, _, let contactId, let address, _):
            return await contactsEditPostalAddress(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .remove(address))
        case .contactsAddSocialProfile(_, _, let contactId, let profile, _):
            return await contactsEditSocialProfile(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .add(profile))
        case .contactsEditSocialProfile(
            _, _, let contactId, let currentProfile, let newProfile, _
        ):
            return await contactsEditSocialProfile(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .edit(current: currentProfile, replacement: newProfile))
        case .contactsDeleteSocialProfile(_, _, let contactId, let profile, _):
            return await contactsEditSocialProfile(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .remove(profile))
        case .contactsAddInstantMessage(_, _, let contactId, let instantMessage, _):
            return await contactsEditInstantMessage(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .add(instantMessage))
        case .contactsEditInstantMessage(
            _, _, let contactId, let currentInstantMessage, let newInstantMessage, _
        ):
            return await contactsEditInstantMessage(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .edit(
                    current: currentInstantMessage, replacement: newInstantMessage))
        case .contactsDeleteInstantMessage(_, _, let contactId, let instantMessage, _):
            return await contactsEditInstantMessage(
                helperId: helperId, messageId: messageId, contactId: contactId,
                operation: .remove(instantMessage))
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
        case .favoritesSet(_, _, let kind, let id, let favorite, _):
            return await favoritesSet(
                helperId: helperId, messageId: messageId,
                kind: kind, id: id, favorite: favorite)
        case .favoritesReorder(_, _, let identities, _):
            return await favoritesReorder(
                helperId: helperId, messageId: messageId, identities: identities,
                current: favoriteReorderSnapshot)
        case .organizationsRenameDepartment(
            _, _, let organizationId, let oldName, let newName, _
        ):
            return await organizationsRenameDepartment(
                helperId: helperId, messageId: messageId,
                organizationId: organizationId, oldName: oldName, newName: newName)
        case .groupsCreate(_, _, let name, _):
            return await groupsCreate(
                helperId: helperId, messageId: messageId, name: name)
        case .groupsRename(_, _, let groupId, let name, _):
            return await groupsRename(
                helperId: helperId, messageId: messageId, groupId: groupId, name: name)
        case .groupsDelete(_, _, let groupId, _):
            return await groupsDelete(
                helperId: helperId, messageId: messageId, groupId: groupId)
        case .groupsAddMembers(_, _, let groupId, let contactIds, _):
            return await groupsChangeMembers(
                helperId: helperId, messageId: messageId,
                groupId: groupId, contactIds: contactIds, change: .addition)
        case .groupsRemoveMembers(_, _, let groupId, let contactIds, _):
            return await groupsChangeMembers(
                helperId: helperId, messageId: messageId,
                groupId: groupId, contactIds: contactIds, change: .removal)
        case .groupsSetFavorite(_, _, let groupId, let favorite, _):
            return await groupsSetFavorite(
                helperId: helperId, messageId: messageId,
                groupId: groupId, favorite: favorite)
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
        case .linksDelete(_, _, let linkId, _):
            return await linksRemove(helperId: helperId, messageId: messageId, linkId: linkId)
        default:
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: "That isn't a callable tool.")
        }
    }

    // MARK: - Contact writes

    private func organizationsRenameDepartment(
        helperId: String, messageId: String, organizationId: String,
        oldName: String, newName: String
    ) async -> WireResponse {
        let trimmedOld = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOld.isEmpty, !trimmedNew.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.emptyDepartmentName)
        }
        // Exact equality after trimming is a no-op. Case-only changes are
        // meaningful display edits and deliberately pass through.
        guard trimmedOld != trimmedNew else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.unchangedDepartmentName)
        }

        switch await resolveOrganization(organizationId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let organization):
            let members = await MainActor.run {
                contacts.contactsAssociated(with: organization, inDepartment: trimmedOld)
            }
            guard !members.isEmpty else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.notFoundDepartment)
            }
            let keys = members.map { $0.contactID.restorationToken.localID }
            do {
                let affectedCount = try await withWriteKeysLocked(keys) {
                    // ONE repository call: it owns matching, fresh fetches,
                    // saves, cache refresh, and the user-level operation.
                    try await contacts.renameDepartment(
                        from: trimmedOld, to: trimmedNew, in: organization)
                }
                if affectedCount > 0 {
                    await recordAudit(
                        .renameDepartment, kind: .contact, contact: organization,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: trimmedOld, newValue: trimmedNew)
                }
                return .departmentRename(
                    helperId: helperId, messageId: messageId,
                    result: WireDepartmentRenameResult(affectedCount: affectedCount))
            } catch {
                // renameDepartment can throw after earlier member saves.
                // The fixed failure text explicitly requires a re-read and
                // never claims that zero records changed.
                return contactSaveFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

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
            let expected: String
            switch fieldType {
            case .date: expected = WireErrorMessage.invalidDateFieldValue
            case .url: expected = WireErrorMessage.invalidURLFieldValue
            default: expected = WireErrorMessage.invalidCheckboxFieldValue
            }
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
        helperId: String, messageId: String, contactId: String, favorite: Bool,
        genericAcknowledgement: Bool = false
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
                    message: favorite
                        ? (genericAcknowledgement ? WireAckMessage.genericFavoriteSet : WireAckMessage.favoriteSet)
                        : (genericAcknowledgement ? WireAckMessage.genericFavoriteCleared : WireAckMessage.favoriteCleared))
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func favoritesSet(
        helperId: String, messageId: String, kind: WireFavoriteKind,
        id: String, favorite: Bool
    ) async -> WireResponse {
        // Contact favorites must ride the repository funnel: the first write
        // to an untouched contact resolves/mints its durable identity, exactly
        // as contacts_set_favorite has always done. Both tools therefore share
        // storage and behavior; only the acknowledgement copy differs.
        if kind == .contact {
            if Self.hasObviouslyDifferentFavoriteKind(id, expected: kind) {
                return favoriteKindMismatch(helperId: helperId, messageId: messageId)
            }
            if case .failure = await resolveContact(id) {
                if !favorite, let cleared = await clearStoredFavorite(
                    kind: kind, id: id, helperId: helperId, messageId: messageId
                ) {
                    return cleared
                }
                if await isKnownFavoriteID(id, excluding: kind) {
                    return favoriteKindMismatch(helperId: helperId, messageId: messageId)
                }
            }
            return await contactsSetFavorite(
                helperId: helperId, messageId: messageId,
                contactId: id, favorite: favorite, genericAcknowledgement: true)
        }

        // Group favorites also have a repository-owned identity boundary: the
        // wire id resolves to a live ContactGroup, then the repository mints or
        // adopts the durable group UUID and persists that UUID in Favorites.
        // The generic store must never see the device-local group identifier.
        if kind == .group {
            if Self.hasObviouslyDifferentFavoriteKind(id, expected: kind) {
                return favoriteKindMismatch(helperId: helperId, messageId: messageId)
            }
            let groups = await contacts.fetchGroups()
            // Accept BOTH group wire ids: the groups-list id (digest of the live
            // group's localID) for favoriting a group seen in the groups list,
            // AND the favorites-list id (digest of the durable GroupIdentity
            // UUID) for re-setting/clearing a group seen in the favorites list.
            // The favorites-list id stays stable across availability, so it is
            // NOT the localID digest and would otherwise fail to resolve here.
            let matchedGroup: ContactGroup?
            if let liveMatch = WireRecordID.group(for: id, in: groups) {
                matchedGroup = liveMatch
            } else {
                matchedGroup = await durableGroup(forFavoriteWireID: id)
            }
            guard let group = matchedGroup else {
                if !favorite, let cleared = await clearStoredFavorite(
                    kind: kind, id: id, helperId: helperId, messageId: messageId
                ) {
                    return cleared
                }
                if await isKnownFavoriteID(id, excluding: kind) {
                    return favoriteKindMismatch(helperId: helperId, messageId: messageId)
                }
                return FavoriteResolutionFailure
                    .notFound(WireErrorMessage.notFoundGroup)
                    .response(helperId: helperId, messageId: messageId)
            }

            let prior = await MainActor.run { contacts.isGroupFavorite(group) }
            do {
                let resulting = try await contacts.setGroupFavorite(favorite, for: group)
                if prior != resulting {
                    await recordAudit(
                        .setFavorite, kind: .group,
                        subjectID: WireRecordID.groupID(for: group), subjectName: group.name,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: prior ? "true" : "false",
                        newValue: resulting ? "true" : "false")
                    return .acknowledged(
                        helperId: helperId, messageId: messageId,
                        message: favorite
                            ? WireAckMessage.genericFavoriteSet
                            : WireAckMessage.genericFavoriteCleared)
                }

                // Nothing changed through the durable-identity path. When
                // clearing, this may be a LEGACY favorite whose stored id is the
                // raw CNGroup.identifier: on the device that created it the live
                // group still carries that identifier, so `WireRecordID.group`
                // matched here instead of falling to `clearStoredFavorite` above,
                // yet the live group has no GroupIdentity and `setGroupFavorite`
                // deliberately leaves the raw row untouched. Clear it directly so
                // the row actually goes — never ack a no-op clear as success.
                if !favorite, let cleared = await clearStoredFavorite(
                    kind: kind, id: id, helperId: helperId, messageId: messageId
                ) {
                    return cleared
                }
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: favorite
                        ? WireAckMessage.genericFavoriteSet
                        : WireAckMessage.genericFavoriteCleared)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }

        // Department favorites also have a repository-owned identity boundary:
        // the org side of the id resolve-or-mints its durable GuessWho UUID (like
        // a first contact favorite), then the favorite is keyed on
        // "<org uuid>/<department>". The generic store never sees a department id,
        // so the org identity is always minted before the favorite is written.
        if kind == .department {
            guard let key = DepartmentFavoriteKey(favoriteID: id) else {
                // Not a well-formed "<org id>/<department>" id. A clear can still
                // remove a stale stored row by its exact composite identity.
                if !favorite, let cleared = await clearStoredFavorite(
                    kind: kind, id: id, helperId: helperId, messageId: messageId
                ) {
                    return cleared
                }
                return FavoriteResolutionFailure
                    .notFound(WireErrorMessage.notFoundDepartment)
                    .response(helperId: helperId, messageId: messageId)
            }
            switch await resolveOrganization(key.organizationGuessWhoID) {
            case .failure(let failure):
                // The organization is gone (or the id names a person). A clear
                // may still target the stale favorite; an add cannot.
                if !favorite, let cleared = await clearStoredFavorite(
                    kind: kind, id: id, helperId: helperId, messageId: messageId
                ) {
                    return cleared
                }
                return failure.response(helperId: helperId, messageId: messageId)
            case .success(let organization):
                // Adding requires a live department; clearing does not, so an
                // emptied department can still be un-favorited.
                if favorite {
                    let liveDepartments = await MainActor.run {
                        contacts.departments(in: organization)
                    }
                    guard liveDepartments.contains(where: { key.matches(department: $0) }) else {
                        return FavoriteResolutionFailure
                            .notFound(WireErrorMessage.notFoundDepartment)
                            .response(helperId: helperId, messageId: messageId)
                    }
                }
                let prior = await MainActor.run {
                    contacts.isDepartmentFavorite(key.department, in: organization)
                }
                do {
                    _ = try await contacts.setDepartmentFavorite(
                        favorite, department: key.department, in: organization)
                    if prior != favorite {
                        // The org wire id is stable across the resolve-or-mint (a
                        // pre-mint id equals the deterministic id it mints to).
                        let wireID = DepartmentFavoriteKey(
                            organizationGuessWhoID: WireRecordID.contactID(for: organization),
                            department: key.department).favoriteID
                        await recordAudit(
                            .setFavorite, kind: .department,
                            subjectID: wireID, subjectName: key.department,
                            instanceID: nil, postModifiedAt: nil,
                            priorValue: prior ? "true" : "false",
                            newValue: favorite ? "true" : "false")
                    }
                    return .acknowledged(
                        helperId: helperId, messageId: messageId,
                        message: favorite
                            ? WireAckMessage.genericFavoriteSet
                            : WireAckMessage.genericFavoriteCleared)
                } catch {
                    return writeFailure(error, helperId: helperId, messageId: messageId)
                }
            }
        }

        switch await resolveFavoriteInput(kind: kind, id: id) {
        case .failure(let failure):
            if !favorite, let cleared = await clearStoredFavorite(
                kind: kind, id: id, helperId: helperId, messageId: messageId
            ) {
                return cleared
            }
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let resolved):
            do {
                let changed = try await MainActor.run {
                    try favorites.setFavorite(
                        kind: resolved.storageKind, id: resolved.storageID, favorite: favorite)
                }
                if changed {
                    await recordAudit(
                        .setFavorite, kind: Self.auditKind(resolved.storageKind),
                        subjectID: resolved.identity.id, subjectName: resolved.displayName,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: favorite ? "false" : "true",
                        newValue: favorite ? "true" : "false")
                }
                return .acknowledged(
                    helperId: helperId, messageId: messageId,
                    message: favorite
                        ? WireAckMessage.genericFavoriteSet
                        : WireAckMessage.genericFavoriteCleared)
            } catch {
                return writeFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    /// Removing a favorite is also the recovery path for an orphan left by
    /// deletion outside the favorites UI (including an MCP entity delete).
    /// Resolve the supplied composite identity against the stored favorite
    /// projection, whose opaque stale id is exactly what favorites_list
    /// exposes, then remove the underlying storage identity. Adding still
    /// always requires a live referent.
    /// Resolve a favorites-list group wire id — a one-way digest of the durable
    /// `GroupIdentity` UUID (see `safeStoredFavoriteID`) — to the live group
    /// behind it, or nil. `WireRecordID.group` already handles the groups-list
    /// id (digest of the live `localID`); this covers the id an agent reads from
    /// `favorites_list`, which stays stable across availability and therefore is
    /// NOT the localID digest. The UUID cannot be inverted from its digest, so we
    /// scan the known identity UUIDs and match by re-deriving each one's wire id.
    private func durableGroup(forFavoriteWireID id: String) async -> ContactGroup? {
        await MainActor.run {
            guard let uuid = contacts.groupFavoriteIdentityIDs().first(where: {
                WireRecordID.groupID(localID: $0) == id
            }) else { return nil }
            return contacts.group(forFavoriteID: uuid)
        }
    }

    private func clearStoredFavorite(
        kind: WireFavoriteKind, id: String, helperId: String, messageId: String
    ) async -> WireResponse? {
        guard let wanted = Self.canonicalStoredFavoriteIdentity(kind: kind, id: id) else {
            return nil
        }
        let stored: [Favorite]
        do {
            stored = try await MainActor.run { try favorites.loadFavorites() }
        } catch {
            return favoriteReadFailure(helperId: helperId, messageId: messageId)
        }
        let candidates = stored.filter { Self.wireFavoriteKind($0.kind) == kind }
        guard !candidates.isEmpty else { return nil }

        let contactSnapshot = (kind == .contact || kind == .department)
            ? await MainActor.run { contacts.allContacts } : []
        let groupSnapshot = kind == .group ? await contacts.fetchGroups() : []
        let guideSnapshot = kind == .guide ? await guides.allGuides() : []
        let placeSnapshot = kind == .place ? await guides.allPlaces() : []

        var match: StoredFavoriteResolution?
        for candidate in candidates {
            let resolved = await resolveStoredFavorite(
                candidate, contacts: contactSnapshot, groups: groupSnapshot,
                guides: guideSnapshot, places: placeSnapshot)
            if resolved.identity == wanted {
                match = resolved
                break
            }
        }
        guard let match else { return nil }

        do {
            let changed = try await MainActor.run {
                try favorites.setFavorite(
                    kind: match.favorite.kind, id: match.favorite.id, favorite: false)
            }
            if changed {
                await recordAudit(
                    .setFavorite, kind: Self.auditKind(match.favorite.kind),
                    subjectID: match.identity.id, subjectName: match.displayName,
                    instanceID: nil, postModifiedAt: nil,
                    priorValue: "true", newValue: "false")
            }
            return .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.genericFavoriteCleared)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
        }
    }

    private func favoritesReorder(
        helperId: String, messageId: String, identities: [WireFavoriteIdentity],
        current suppliedCurrent: [Favorite]?
    ) async -> WireResponse {
        guard Set(identities).count == identities.count else {
            return favoriteOrderMismatch(helperId: helperId, messageId: messageId)
        }

        guard let current = suppliedCurrent else {
            // All callers preflight the authoritative snapshot before the
            // write budget. Keep this fixed failure rather than silently
            // re-reading and changing the budget/permission ordering.
            return favoriteReadFailure(helperId: helperId, messageId: messageId)
        }
        guard identities.count == current.count else {
            return favoriteOrderMismatch(helperId: helperId, messageId: messageId)
        }
        let contactSnapshot = current.contains { $0.kind == .contact || $0.kind == .department }
            ? await MainActor.run { contacts.allContacts } : []
        let groupSnapshot = current.contains { $0.kind == .group }
            ? await contacts.fetchGroups() : []
        let guideSnapshot = current.contains { $0.kind == .guide }
            ? await guides.allGuides() : []
        let placeSnapshot = current.contains { $0.kind == .place }
            ? await guides.allPlaces() : []

        var projected: [StoredFavoriteResolution] = []
        projected.reserveCapacity(current.count)
        for favorite in current {
            let item = await resolveStoredFavorite(
                favorite, contacts: contactSnapshot, groups: groupSnapshot,
                guides: guideSnapshot, places: placeSnapshot)
            guard item.isAvailable else {
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: WireErrorMessage.staleFavorite)
            }
            projected.append(item)
        }

        let currentIdentities = projected.map(\.identity)
        guard Set(currentIdentities).count == currentIdentities.count else {
            return favoriteOrderMismatch(helperId: helperId, messageId: messageId)
        }

        let byIdentity = Dictionary(uniqueKeysWithValues: projected.map { ($0.identity, $0.favorite) })
        var canonicalRequested: [WireFavoriteIdentity] = []
        var reordered: [Favorite] = []
        canonicalRequested.reserveCapacity(identities.count)
        reordered.reserveCapacity(identities.count)
        for identity in identities {
            guard let canonical = Self.canonicalFavoriteIdentityForReorder(identity),
                  let favorite = byIdentity[canonical]
            else {
                return favoriteOrderMismatch(helperId: helperId, messageId: messageId)
            }
            canonicalRequested.append(canonical)
            reordered.append(favorite)
        }
        guard Set(canonicalRequested).count == canonicalRequested.count,
              Set(canonicalRequested) == Set(currentIdentities),
              reordered.count == current.count
        else {
            return favoriteOrderMismatch(helperId: helperId, messageId: messageId)
        }
        let validatedReorder = reordered

        do {
            let changed = try await MainActor.run {
                try favorites.reorderFavorites(expected: current, reordered: validatedReorder)
            }
            if changed {
                await recordAudit(
                    .reorderFavorites, kind: .favorites,
                    subjectID: "favorites", subjectName: "favorites",
                    instanceID: nil, postModifiedAt: nil,
                    priorValue: nil, newValue: nil)
            }
            return .acknowledged(
                helperId: helperId, messageId: messageId,
                message: WireAckMessage.favoritesReordered)
        } catch FavoritesStoreMutationError.changed {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .busy, message: WireErrorMessage.favoritesChangedDuringReorder)
        } catch FavoritesStoreMutationError.invalidOrder {
            return favoriteOrderMismatch(helperId: helperId, messageId: messageId)
        } catch {
            return writeFailure(error, helperId: helperId, messageId: messageId)
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
        if let value = fields.kind {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "person": contact.contactType = .person
            case "organization": contact.contactType = .organization
            default: return WireErrorMessage.invalidKindArgument
            }
        }
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

    private func contactsSetPhoto(
        helperId: String, messageId: String, contactId: String,
        mediaType: String, dataBase64: String
    ) async -> WireResponse {
        let normalizedType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard WireContactPhotoMedia.supportedMediaTypes.contains(normalizedType) else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidPhotoMediaType)
        }
        guard dataBase64.utf8.count <= WireEnvironment.maxContactPhotoBase64Bytes else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .tooLarge, message: WireErrorMessage.photoTooLarge)
        }
        guard let data = Data(base64Encoded: dataBase64), !data.isEmpty else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.invalidPhotoData)
        }
        guard data.count <= WireEnvironment.maxContactPhotoBytes else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .tooLarge, message: WireErrorMessage.photoTooLarge)
        }
        guard WireContactPhotoMedia.mediaType(for: data) == normalizedType else {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: WireErrorMessage.photoMediaTypeMismatch)
        }

        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                return try await withWriteKeysLocked([token.localID]) {
                    let prior = try await contacts.contactPhotoData(
                        for: contact.contactID, kind: .fullSize)?.data
                    // Intrinsically idempotent even without a client token:
                    // do not snapshot and rewrite identical bytes.
                    if prior == data {
                        return .acknowledged(
                            helperId: helperId, messageId: messageId,
                            message: WireAckMessage.photoSet)
                    }
                    guard try await contacts.setContactPhoto(
                        for: contact.contactID, imageData: data)
                    else {
                        return .error(
                            helperId: helperId, messageId: messageId,
                            code: .notFound, message: WireErrorMessage.notFoundContact)
                    }
                    // Contacts may transcode the supplied image, and the
                    // repository's full-size read deliberately falls back to
                    // a thumbnail on cards whose full bytes are unavailable.
                    // Verify the persisted invariant (a non-empty photo now
                    // exists), not byte identity with the input encoding.
                    guard let verified = try await contacts.contactPhotoData(
                        for: contact.contactID, kind: .fullSize)?.data,
                          !verified.isEmpty
                    else {
                        return writeFailure(helperId: helperId, messageId: messageId)
                    }
                    let fresh = await MainActor.run {
                        contacts.contact(restorationToken: token)
                    } ?? contact
                    await recordAudit(
                        .editContact, kind: .contact, contact: fresh,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: prior.map { "photo (\($0.count) bytes)" },
                        newValue: "photo (\(normalizedType), \(data.count) bytes)")
                    return .acknowledged(
                        helperId: helperId, messageId: messageId,
                        message: WireAckMessage.photoSet)
                }
            } catch {
                return contactSaveFailure(error, helperId: helperId, messageId: messageId)
            }
        }
    }

    private func contactsDeletePhoto(
        helperId: String, messageId: String, contactId: String
    ) async -> WireResponse {
        switch await resolveContactForWrite(contactId) {
        case .failure(let failure):
            return failure.response(helperId: helperId, messageId: messageId)
        case .success(let contact):
            let token = contact.contactID.restorationToken
            do {
                return try await withWriteKeysLocked([token.localID]) {
                    guard let prior = try await contacts.contactPhotoData(
                        for: contact.contactID, kind: .fullSize)?.data,
                          !prior.isEmpty
                    else {
                        // Already absent is a successful no-op.
                        return .acknowledged(
                            helperId: helperId, messageId: messageId,
                            message: WireAckMessage.photoDeleted)
                    }
                    guard try await contacts.setContactPhoto(
                        for: contact.contactID, imageData: nil)
                    else {
                        return .error(
                            helperId: helperId, messageId: messageId,
                            code: .notFound, message: WireErrorMessage.notFoundContact)
                    }
                    let remaining = try await contacts.contactPhotoData(
                        for: contact.contactID, kind: .fullSize)?.data
                    guard remaining?.isEmpty != false else {
                        return writeFailure(helperId: helperId, messageId: messageId)
                    }
                    let fresh = await MainActor.run {
                        contacts.contact(restorationToken: token)
                    } ?? contact
                    await recordAudit(
                        .editContact, kind: .contact, contact: fresh,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: "photo (\(prior.count) bytes)", newValue: "photo deleted")
                    return .acknowledged(
                        helperId: helperId, messageId: messageId,
                        message: WireAckMessage.photoDeleted)
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

        init?(wireField: String) {
            guard let wireField = WireContactListField(rawValue: wireField) else {
                return nil
            }
            self.init(wireField: wireField)
        }

        private init(wireField: WireContactListField) {
            switch wireField {
            case .phone: self = .phone
            case .email: self = .email
            case .url: self = .url
            case .relatedName: self = .relatedName
            case .date: self = .date
            }
        }

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

    private func invalidContactListField(
        helperId: String, messageId: String
    ) -> WireResponse {
        .error(
            helperId: helperId, messageId: messageId,
            code: .invalidParams, message: WireErrorMessage.invalidContactListField)
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

    /// The shared handler behind contacts_add_value, contacts_edit_value,
    /// and contacts_delete_value: resolve, fetch the CURRENT card through
    /// the editor's own editable path, match the one entry by exact value
    /// against that fresh card, mutate exactly that entry, and save through
    /// the same funnel contacts_update uses. 0 matches → typed notFound;
    /// more than one → typed ambiguous; neither changes anything.
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

    // MARK: - Structured single-entry edits

    private enum PostalAddressOperation {
        case add(WirePostalAddress)
        case remove(WirePostalAddress)
        case edit(current: WirePostalAddress, replacement: WirePostalAddress)
    }

    private enum SocialProfileOperation {
        case add(WireSocialProfile)
        case remove(WireSocialProfile)
        case edit(current: WireSocialProfile, replacement: WireSocialProfile)
    }

    private enum InstantMessageOperation {
        case add(WireInstantMessage)
        case remove(WireInstantMessage)
        case edit(current: WireInstantMessage, replacement: WireInstantMessage)
    }

    private static func nonBlank(_ values: [String?]) -> Bool {
        values.compactMap { $0 }.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func postalAddressProblem(_ address: WirePostalAddress) -> String? {
        nonBlank([
            address.street, address.subLocality, address.city,
            address.subAdministrativeArea, address.state, address.postalCode,
            address.country, address.isoCountryCode,
        ]) ? nil : WireErrorMessage.emptyPostalAddress
    }

    private static func socialProfileProblem(_ profile: WireSocialProfile) -> String? {
        nonBlank([profile.service, profile.username, profile.url])
            ? nil : WireErrorMessage.emptySocialProfile
    }

    private static func instantMessageProblem(_ address: WireInstantMessage) -> String? {
        nonBlank([address.username]) ? nil : WireErrorMessage.emptyInstantMessage
    }

    private static func postalAddressOperationProblem(
        _ operation: PostalAddressOperation
    ) -> String? {
        switch operation {
        case .add(let address), .remove(let address):
            return postalAddressProblem(address)
        case .edit(let current, let replacement):
            return postalAddressProblem(current) ?? postalAddressProblem(replacement)
        }
    }

    private static func socialProfileOperationProblem(
        _ operation: SocialProfileOperation
    ) -> String? {
        switch operation {
        case .add(let profile), .remove(let profile):
            return socialProfileProblem(profile)
        case .edit(let current, let replacement):
            return socialProfileProblem(current) ?? socialProfileProblem(replacement)
        }
    }

    private static func instantMessageOperationProblem(
        _ operation: InstantMessageOperation
    ) -> String? {
        switch operation {
        case .add(let address), .remove(let address):
            return instantMessageProblem(address)
        case .edit(let current, let replacement):
            return instantMessageProblem(current) ?? instantMessageProblem(replacement)
        }
    }

    /// Convert through the same blank-to-nil projection contacts_get uses.
    /// This is the canonical wire representation used for exact matching.
    private static func postalAddress(
        from wire: WirePostalAddress, preservingLabel: String? = nil
    ) -> LabeledPostalAddress {
        LabeledPostalAddress(
            label: wire.label ?? preservingLabel ?? "",
            value: PostalAddress(
                street: wire.street,
                subLocality: wire.subLocality ?? "",
                city: wire.city,
                subAdministrativeArea: wire.subAdministrativeArea ?? "",
                state: wire.state,
                postalCode: wire.postalCode,
                country: wire.country,
                isoCountryCode: wire.isoCountryCode ?? ""))
    }

    private static func canonicalPostalAddress(
        _ wire: WirePostalAddress
    ) -> WirePostalAddress {
        WireMapping.postalAddress(postalAddress(from: wire))
    }

    private static func socialProfile(
        from wire: WireSocialProfile,
        preservingLabel: String? = nil,
        preservingUserIdentifier: String = ""
    ) -> LabeledSocialProfile {
        LabeledSocialProfile(
            label: wire.label ?? preservingLabel ?? "",
            value: SocialProfile(
                urlString: wire.url ?? "",
                username: wire.username ?? "",
                userIdentifier: preservingUserIdentifier,
                service: wire.service ?? ""))
    }

    private static func canonicalSocialProfile(
        _ wire: WireSocialProfile
    ) -> WireSocialProfile {
        WireMapping.socialProfile(socialProfile(from: wire))
    }

    private static func instantMessage(
        from wire: WireInstantMessage, preservingLabel: String? = nil
    ) -> LabeledInstantMessageAddress {
        LabeledInstantMessageAddress(
            label: wire.label ?? preservingLabel ?? "",
            value: InstantMessageAddress(
                username: wire.username, service: wire.service ?? ""))
    }

    private static func canonicalInstantMessage(
        _ wire: WireInstantMessage
    ) -> WireInstantMessage {
        WireMapping.instantMessage(instantMessage(from: wire))
    }

    private static func exactStructuredMatchIndex<T: Equatable>(
        needle: T, entries: [T], notFound: String, ambiguous: String
    ) -> Result<Int, ListMatchFailure> {
        let matches = entries.enumerated()
            .filter { $0.element == needle }
            .map(\.offset)
        guard let first = matches.first else {
            return .failure(ListMatchFailure(code: .notFound, message: notFound))
        }
        guard matches.count == 1 else {
            return .failure(ListMatchFailure(code: .ambiguous, message: ambiguous))
        }
        return .success(first)
    }

    private func contactsEditPostalAddress(
        helperId: String, messageId: String, contactId: String,
        operation: PostalAddressOperation
    ) async -> WireResponse {
        if let problem = Self.postalAddressOperationProblem(operation) {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: problem)
        }
        return await contactsEditStructuredEntry(
            helperId: helperId, messageId: messageId, contactId: contactId,
            auditFieldName: "postalAddresses"
        ) { contact in
            switch operation {
            case .add(let address):
                contact.postalAddresses.append(Self.postalAddress(from: address))
            case .remove(let address):
                let match = Self.exactStructuredMatchIndex(
                    needle: Self.canonicalPostalAddress(address),
                    entries: contact.postalAddresses.map(WireMapping.postalAddress),
                    notFound: WireErrorMessage.noMatchingPostalAddress,
                    ambiguous: WireErrorMessage.ambiguousPostalAddress)
                switch match {
                case .failure(let failure): return failure
                case .success(let index): contact.postalAddresses.remove(at: index)
                }
            case .edit(let current, let replacement):
                let match = Self.exactStructuredMatchIndex(
                    needle: Self.canonicalPostalAddress(current),
                    entries: contact.postalAddresses.map(WireMapping.postalAddress),
                    notFound: WireErrorMessage.noMatchingPostalAddress,
                    ambiguous: WireErrorMessage.ambiguousPostalAddress)
                switch match {
                case .failure(let failure): return failure
                case .success(let index):
                    let old = contact.postalAddresses[index]
                    contact.postalAddresses[index] = Self.postalAddress(
                        from: replacement, preservingLabel: old.label)
                }
            }
            return nil
        }
    }

    private func contactsEditSocialProfile(
        helperId: String, messageId: String, contactId: String,
        operation: SocialProfileOperation
    ) async -> WireResponse {
        if let problem = Self.socialProfileOperationProblem(operation) {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: problem)
        }
        return await contactsEditStructuredEntry(
            helperId: helperId, messageId: messageId, contactId: contactId,
            auditFieldName: "socialProfiles"
        ) { contact in
            switch operation {
            case .add(let profile):
                contact.socialProfiles.append(Self.socialProfile(from: profile))
            case .remove(let profile):
                let match = Self.exactStructuredMatchIndex(
                    needle: Self.canonicalSocialProfile(profile),
                    entries: contact.socialProfiles.map(WireMapping.socialProfile),
                    notFound: WireErrorMessage.noMatchingSocialProfile,
                    ambiguous: WireErrorMessage.ambiguousSocialProfile)
                switch match {
                case .failure(let failure): return failure
                case .success(let index): contact.socialProfiles.remove(at: index)
                }
            case .edit(let current, let replacement):
                let match = Self.exactStructuredMatchIndex(
                    needle: Self.canonicalSocialProfile(current),
                    entries: contact.socialProfiles.map(WireMapping.socialProfile),
                    notFound: WireErrorMessage.noMatchingSocialProfile,
                    ambiguous: WireErrorMessage.ambiguousSocialProfile)
                switch match {
                case .failure(let failure): return failure
                case .success(let index):
                    let old = contact.socialProfiles[index]
                    contact.socialProfiles[index] = Self.socialProfile(
                        from: replacement,
                        preservingLabel: old.label,
                        preservingUserIdentifier: old.value.userIdentifier)
                }
            }
            return nil
        }
    }

    private func contactsEditInstantMessage(
        helperId: String, messageId: String, contactId: String,
        operation: InstantMessageOperation
    ) async -> WireResponse {
        if let problem = Self.instantMessageOperationProblem(operation) {
            return .error(
                helperId: helperId, messageId: messageId,
                code: .invalidParams, message: problem)
        }
        return await contactsEditStructuredEntry(
            helperId: helperId, messageId: messageId, contactId: contactId,
            auditFieldName: "instantMessages"
        ) { contact in
            switch operation {
            case .add(let address):
                contact.instantMessageAddresses.append(Self.instantMessage(from: address))
            case .remove(let address):
                let match = Self.exactStructuredMatchIndex(
                    needle: Self.canonicalInstantMessage(address),
                    entries: contact.instantMessageAddresses.map(WireMapping.instantMessage),
                    notFound: WireErrorMessage.noMatchingInstantMessage,
                    ambiguous: WireErrorMessage.ambiguousInstantMessage)
                switch match {
                case .failure(let failure): return failure
                case .success(let index): contact.instantMessageAddresses.remove(at: index)
                }
            case .edit(let current, let replacement):
                let match = Self.exactStructuredMatchIndex(
                    needle: Self.canonicalInstantMessage(current),
                    entries: contact.instantMessageAddresses.map(WireMapping.instantMessage),
                    notFound: WireErrorMessage.noMatchingInstantMessage,
                    ambiguous: WireErrorMessage.ambiguousInstantMessage)
                switch match {
                case .failure(let failure): return failure
                case .success(let index):
                    let old = contact.instantMessageAddresses[index]
                    contact.instantMessageAddresses[index] = Self.instantMessage(
                        from: replacement, preservingLabel: old.label)
                }
            }
            return nil
        }
    }

    /// Shared fresh-fetch / single-flight / save / audit funnel for all
    /// structured entry types. `mutation` changes at most one entry and
    /// returns a typed match failure before save when it cannot do so safely.
    private func contactsEditStructuredEntry(
        helperId: String, messageId: String, contactId: String,
        auditFieldName: String,
        mutation: (inout Contact) -> ListMatchFailure?
    ) async -> WireResponse {
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
                    if let failure = mutation(&edited) {
                        return failure.response(helperId: helperId, messageId: messageId)
                    }
                    try await contacts.saveContact(edited, for: contact.contactID)
                    let fresh = await MainActor.run {
                        contacts.contact(restorationToken: token)
                    } ?? edited
                    let isFavorite = await MainActor.run { contacts.isFavorite(fresh.contactID) }
                    await recordAudit(
                        .editContact, kind: .contact, contact: fresh,
                        instanceID: nil, postModifiedAt: nil,
                        priorValue: nil, newValue: auditFieldName)
                    return .contact(
                        helperId: helperId, messageId: messageId,
                        contact: WireMapping.contact(
                            fresh, id: WireRecordID.contactID(for: fresh),
                            isFavorite: isFavorite))
                }
            } catch {
                return contactSaveFailure(error, helperId: helperId, messageId: messageId)
            }
        }
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
            let wire = await wireGuides([created], allPlaces: await guides.allPlaces())
            return .guide(
                helperId: helperId, messageId: messageId,
                guide: wire[0])
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
                WireMapping.kind(contact),
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
                WireMapping.kind(contact),
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
        case .link, .guide, .group:
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
            case .link, .guide, .group:
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
        case "url": return .url
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
        case .url:
            // Store the trimmed URL string. Returns nil for anything that is
            // not an absolute http/https web address so the caller emits a
            // typed error, mirroring how a bad date is rejected above.
            guard let trimmed = SidecarField.canonicalWebURL(from: value) else { return nil }
            return .string(trimmed)
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

    private struct StoredFavoriteResolution {
        let favorite: Favorite
        let identity: WireFavoriteIdentity
        let displayName: String
        let isAvailable: Bool

        var wire: WireFavorite {
            WireFavorite(
                kind: identity.kind, id: identity.id,
                displayName: displayName,
                addedAt: WireMapping.timestamp(favorite.addedAt),
                isAvailable: isAvailable)
        }
    }

    private struct FavoriteInputResolution {
        let identity: WireFavoriteIdentity
        let storageKind: FavoriteKind
        let storageID: String
        let displayName: String
    }

    private enum FavoriteResolutionFailure: Error {
        case notFound(String)
        case kindMismatch
        case requiresAppAction(String)

        func response(helperId: String, messageId: String) -> WireResponse {
            switch self {
            case .notFound(let message):
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .notFound, message: message)
            case .kindMismatch:
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .invalidParams, message: WireErrorMessage.favoriteKindMismatch)
            case .requiresAppAction(let message):
                return .error(
                    helperId: helperId, messageId: messageId,
                    code: .requiresAppAction, message: message)
            }
        }
    }

    private static func wireFavoriteKind(_ kind: FavoriteKind) -> WireFavoriteKind {
        switch kind {
        case .contact: return .contact
        case .event: return .event
        case .group: return .group
        case .guide: return .guide
        case .place: return .place
        case .department: return .department
        }
    }

    private static func auditKind(_ kind: FavoriteKind) -> MCPAuditEntry.SubjectKind {
        switch kind {
        case .contact: return .contact
        case .event: return .event
        case .group: return .group
        case .guide: return .guide
        case .place: return .place
        case .department: return .department
        }
    }

    private static func hasObviouslyDifferentFavoriteKind(
        _ id: String, expected: WireFavoriteKind
    ) -> Bool {
        let canonical = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if canonical.hasPrefix("g-") { return expected != .group }
        if canonical.hasPrefix("e-") { return expected != .event }
        // A "<org uuid>/<department>" composite belongs to a department. Only a
        // department id carries the fixed 36-char UUID prefix + "/"; every other
        // kind's id is a bare UUID or a prefixed opaque value, so this never
        // mislabels them.
        if DepartmentFavoriteKey(favoriteID: canonical) != nil { return expected != .department }
        return false
    }

    /// Canonicalize only the public wire identity syntax used by reorder.
    /// Referent resolution has already happened once through `projected`; the
    /// caller's composite identity must match that live snapshot. Keeping this
    /// normalization local avoids repeating full contact-group / guide / place
    /// collection reads once per requested favorite.
    private static func canonicalFavoriteIdentityForReorder(
        _ identity: WireFavoriteIdentity
    ) -> WireFavoriteIdentity? {
        let trimmed = identity.id.trimmingCharacters(in: .whitespacesAndNewlines)
        switch identity.kind {
        case .contact, .guide, .place:
            guard let uuid = WireRecordID.recordUUID(trimmed) else { return nil }
            return WireFavoriteIdentity(
                kind: identity.kind, id: uuid.uuidString.lowercased())
        case .event:
            guard case .record(let id) = WireRecordID.parseEventID(trimmed) else { return nil }
            return WireFavoriteIdentity(kind: .event, id: id)
        case .group:
            guard trimmed.hasPrefix("g-") else { return nil }
            return WireFavoriteIdentity(kind: .group, id: trimmed)
        case .department:
            // "<org uuid>/<department>", parsed by the fixed 36-char prefix so a
            // department name containing "/" survives. The uuid is lowercased and
            // the department trimmed, matching the id `resolveStoredFavorite`
            // emits for an available department row.
            guard let key = DepartmentFavoriteKey(favoriteID: trimmed) else { return nil }
            return WireFavoriteIdentity(kind: .department, id: key.favoriteID)
        }
    }

    /// Canonical identity accepted when clearing an existing stored row.
    /// UUID-backed kinds accept their normal record UUID or the stable `x-`
    /// digest emitted for a malformed/stale legacy id. Groups accept only
    /// their one-way `g-` digest. Calendar-derived `e-` ids are deliberately
    /// excluded because they can never be persisted as favorites.
    private static func canonicalStoredFavoriteIdentity(
        kind: WireFavoriteKind, id: String
    ) -> WireFavoriteIdentity? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = WireRecordID.recordUUID(trimmed), kind != .group, kind != .department {
            return WireFavoriteIdentity(kind: kind, id: uuid.uuidString.lowercased())
        }
        switch kind {
        case .group:
            guard isOpaqueDigestID(trimmed, prefix: "g-") else { return nil }
            return WireFavoriteIdentity(kind: kind, id: trimmed)
        case .department:
            // A live-shaped "<org uuid>/<department>" canonicalizes to the same
            // composite `safeStoredFavoriteID` emits for a stale department row; a
            // malformed legacy id is matched by its opaque `x-` digest instead.
            if let key = DepartmentFavoriteKey(favoriteID: trimmed) {
                return WireFavoriteIdentity(kind: kind, id: key.favoriteID)
            }
            guard isOpaqueDigestID(trimmed, prefix: "x-") else { return nil }
            return WireFavoriteIdentity(kind: kind, id: trimmed)
        case .contact, .event, .guide, .place:
            guard isOpaqueDigestID(trimmed, prefix: "x-") else { return nil }
            return WireFavoriteIdentity(kind: kind, id: trimmed)
        }
    }

    private static func isOpaqueDigestID(_ id: String, prefix: String) -> Bool {
        guard id.hasPrefix(prefix), id.count == prefix.count + 32 else { return false }
        return id.dropFirst(prefix.count).allSatisfy { $0.isHexDigit }
    }

    private static func safeStoredFavoriteID(_ favorite: Favorite) -> String {
        switch favorite.kind {
        case .group:
            return WireRecordID.groupID(localID: favorite.id)
        case .department:
            // The stored id is "<org guesswho uuid>/<department>" — the org uuid
            // IS the org's wire contact id, and the department is user text also
            // returned as displayName, so the composite is safe to echo. A
            // malformed legacy id falls back to the opaque stale form.
            if let key = DepartmentFavoriteKey(favoriteID: favorite.id) {
                return key.favoriteID
            }
            return WireRecordID.opaqueStaleID(kind: favorite.kind.rawValue, id: favorite.id)
        case .contact, .event, .guide, .place:
            if let uuid = WireRecordID.recordUUID(favorite.id) {
                return uuid.uuidString.lowercased()
            }
            return WireRecordID.opaqueStaleID(kind: favorite.kind.rawValue, id: favorite.id)
        }
    }

    private func resolveStoredFavorite(
        _ favorite: Favorite, contacts contactSnapshot: [Contact],
        groups: [ContactGroup], guides: [MapsGuide], places: [MapsPlace]
    ) async -> StoredFavoriteResolution {
        let kind = Self.wireFavoriteKind(favorite.kind)
        var id = Self.safeStoredFavoriteID(favorite)
        var name = "Unavailable"
        var available = false

        switch favorite.kind {
        case .contact:
            if let contact = WireRecordID.contact(for: favorite.id, in: contactSnapshot) {
                id = WireRecordID.contactID(for: contact)
                name = contact.displayName
                available = true
            }
        case .event:
            if let event = await MainActor.run(body: { events.event(uuid: favorite.id) }) {
                id = WireRecordID.eventID(for: event)
                name = event.title
                available = true
            }
        case .group:
            if let group = await MainActor.run(body: {
                contacts.group(forFavoriteID: favorite.id)
            }) {
                name = group.name
                available = true
            }
        case .guide:
            if let uuid = WireRecordID.recordUUID(favorite.id),
               let guide = guides.first(where: { $0.id == uuid }) {
                id = guide.id.uuidString.lowercased()
                name = guide.name
                available = true
            }
        case .place:
            if let uuid = WireRecordID.recordUUID(favorite.id),
               let place = places.first(where: { $0.id == uuid }) {
                id = place.id.uuidString.lowercased()
                name = place.name.isEmpty ? (place.address ?? "Unnamed place") : place.name
                available = true
            }
        case .department:
            // Resolve the org by its GuessWho UUID, then find the LIVE department
            // whose trimmed, case-insensitive name matches the key — a department
            // exists only through people, so a favorite of one no person carries
            // reads as unavailable. The live match restores the display case the
            // lowercased stored key dropped; the wire id pairs the org's wire
            // contact id with that live name.
            if let key = DepartmentFavoriteKey(favoriteID: favorite.id),
               let organization = WireRecordID.contact(for: key.organizationGuessWhoID, in: contactSnapshot) {
                let liveDepartments = await MainActor.run { contacts.departments(in: organization) }
                if let liveName = liveDepartments.first(where: { key.matches(department: $0) }) {
                    id = DepartmentFavoriteKey(
                        organizationGuessWhoID: WireRecordID.contactID(for: organization),
                        department: liveName).favoriteID
                    name = liveName
                    available = true
                }
            }
        }
        return StoredFavoriteResolution(
            favorite: favorite,
            identity: WireFavoriteIdentity(kind: kind, id: id),
            displayName: name, isAvailable: available)
    }

    private func resolveFavoriteInput(
        kind: WireFavoriteKind, id: String
    ) async -> Result<FavoriteInputResolution, FavoriteResolutionFailure> {
        if Self.hasObviouslyDifferentFavoriteKind(id, expected: kind) {
            return .failure(.kindMismatch)
        }
        switch kind {
        case .contact:
            switch await resolveContact(id) {
            case .failure:
                return await isKnownFavoriteID(id, excluding: kind)
                    ? .failure(.kindMismatch)
                    : .failure(.notFound(WireErrorMessage.notFoundContact))
            case .success(let contact):
                let wireID = WireRecordID.contactID(for: contact)
                return .success(FavoriteInputResolution(
                    identity: WireFavoriteIdentity(kind: kind, id: wireID),
                    storageKind: .contact, storageID: wireID,
                    displayName: contact.displayName))
            }
        case .event:
            switch await resolveEvent(id) {
            case .failure:
                return await isKnownFavoriteID(id, excluding: kind)
                    ? .failure(.kindMismatch)
                    : .failure(.notFound(WireErrorMessage.notFoundEvent))
            case .success(let event):
                guard !WireRecordID.isSystemOnlyEvent(event) else {
                    return .failure(.requiresAppAction(WireErrorMessage.eventNeedsAppFirstToFavorite))
                }
                let storageID = event.id.uuidString.lowercased()
                return .success(FavoriteInputResolution(
                    identity: WireFavoriteIdentity(
                        kind: kind, id: WireRecordID.eventID(for: event)),
                    storageKind: .event, storageID: storageID,
                    displayName: event.title))
            }
        case .group:
            // Unreachable: group favorites are resolved and persisted ENTIRELY
            // by favoritesSet's dedicated `.group` branch, which mints/adopts the
            // durable GroupIdentity UUID and stores THAT. This generic resolver
            // must never run for a group — the only resolution it could build
            // here would use the device-local CNGroup.identifier as the storage
            // id, the exact cross-device boundary violation this feature removes.
            // Fail hard so a future refactor that routes a group through here
            // trips a test instead of silently persisting a localID.
            assertionFailure(
                "resolveFavoriteInput must not be reached for .group; favoritesSet handles groups directly")
            return .failure(.notFound(WireErrorMessage.notFoundGroup))
        case .guide:
            guard let uuid = WireRecordID.recordUUID(id),
                  let guide = await guides.allGuides().first(where: { $0.id == uuid })
            else {
                return await isKnownFavoriteID(id, excluding: kind)
                    ? .failure(.kindMismatch)
                    : .failure(.notFound(WireErrorMessage.notFoundGuide))
            }
            return .success(FavoriteInputResolution(
                identity: WireFavoriteIdentity(kind: kind, id: guide.id.uuidString.lowercased()),
                storageKind: .guide, storageID: guide.id.uuidString,
                displayName: guide.name))
        case .place:
            guard let uuid = WireRecordID.recordUUID(id),
                  let place = await guides.allPlaces().first(where: { $0.id == uuid })
            else {
                return await isKnownFavoriteID(id, excluding: kind)
                    ? .failure(.kindMismatch)
                    : .failure(.notFound(WireErrorMessage.notFoundPlace))
            }
            return .success(FavoriteInputResolution(
                identity: WireFavoriteIdentity(kind: kind, id: place.id.uuidString.lowercased()),
                storageKind: .place, storageID: place.id.uuidString,
                displayName: place.name.isEmpty ? (place.address ?? "Unnamed place") : place.name))
        case .department:
            // Unreachable: department favorites are resolved and persisted
            // ENTIRELY by favoritesSet's dedicated `.department` branch, which
            // resolve-or-mints the organization's identity and stores
            // "<org uuid>/<department>". This generic resolver must never run for
            // a department — routing one here would bypass the org resolve-or-mint
            // — so fail hard if a future refactor sends one through.
            assertionFailure(
                "resolveFavoriteInput must not be reached for .department; favoritesSet handles departments directly")
            return .failure(.notFound(WireErrorMessage.notFoundDepartment))
        }
    }

    private func isKnownFavoriteID(
        _ id: String, excluding excluded: WireFavoriteKind
    ) async -> Bool {
        let (contactsOK, eventsOK) = await MainActor.run {
            (gates.contactsAuthorized, gates.eventsAuthorized)
        }
        if contactsOK, excluded != .contact,
           case .success = await resolveContact(id) { return true }
        if eventsOK, excluded != .event,
           case .success = await resolveEvent(id) { return true }
        if contactsOK, excluded != .group {
            let groups = await contacts.fetchGroups()
            if WireRecordID.group(for: id, in: groups) != nil { return true }
        }
        if let uuid = WireRecordID.recordUUID(id) {
            if excluded != .guide, await guides.allGuides().contains(where: { $0.id == uuid }) {
                return true
            }
            if excluded != .place, await guides.allPlaces().contains(where: { $0.id == uuid }) {
                return true
            }
        }
        return false
    }

    private func favoriteKindMismatch(helperId: String, messageId: String) -> WireResponse {
        .error(
            helperId: helperId, messageId: messageId,
            code: .invalidParams, message: WireErrorMessage.favoriteKindMismatch)
    }

    private func favoriteReadFailure(helperId: String, messageId: String) -> WireResponse {
        .error(
            helperId: helperId, messageId: messageId,
            code: .busy, message: WireErrorMessage.favoritesReadFailed)
    }

    private func favoriteOrderMismatch(helperId: String, messageId: String) -> WireResponse {
        .error(
            helperId: helperId, messageId: messageId,
            code: .invalidParams, message: WireErrorMessage.reorderMustCoverEveryFavorite)
    }

    private enum ResolveFailure: Error {
        case notFound(String)
        case kindMismatch(String)

        func response(helperId: String, messageId: String) -> WireResponse {
            switch self {
            case .notFound(let message):
                return .error(helperId: helperId, messageId: messageId, code: .notFound, message: message)
            case .kindMismatch(let message):
                return .error(helperId: helperId, messageId: messageId, code: .kindMismatch, message: message)
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

    /// Resolve through the normal contact resolver first, then apply the
    /// organization-only kind contract. A person's valid contact id is not
    /// "missing"; it is a typed kind mismatch.
    private func resolveOrganization(_ id: String) async -> Result<Contact, ResolveFailure> {
        switch await resolveContact(id) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let contact) where contact.contactType == .organization:
            return .success(contact)
        case .success:
            return .failure(.kindMismatch(WireErrorMessage.organizationKindMismatch))
        }
    }

    private func resolveGroup(_ id: String) async -> ContactGroup? {
        let groups = await contacts.fetchGroups()
        return WireRecordID.group(for: id, in: groups)
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
