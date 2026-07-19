import Foundation
import GuessWhoSync
import GuessWhoMCPWire

/// The seams between the dispatch core and the app's LIVE data layer
/// (plans/cli-mcp.md INV-2b): the host injects the app's existing
/// `ContactsRepository` / `SyncService` instances behind these protocols —
/// the dispatch core NEVER constructs a store of its own — and the
/// package tests substitute fakes so INV-3 / allowlist / vocabulary tests
/// run under plain `swift test`.
///
/// All three sources are `@MainActor`: the live conformers are MainActor
/// classes, and isolating the protocol keeps every repository read on the
/// actor the UI already serializes on. The dispatcher hops to MainActor
/// ONLY for these calls; DTO mapping and wire encoding happen off it (see
/// the 2026-07-02 main-actor-I/O hang, plans/cli-mcp.md dispatch model).

@MainActor
public protocol MCPContactSource: AnyObject {
    /// Every cached contact, UNFILTERED — deliberately not the UI's
    /// search-filtered projections, whose contents follow the user's
    /// current search box.
    var allContacts: [Contact] { get }
    func contact(restorationToken: ContactRestorationToken) -> Contact?
    func notes(for id: ContactID) -> [ContactNote]
    func fields(for id: ContactID) -> [SidecarField]
    func links(for id: ContactID) async -> [Link]
    func isFavorite(_ id: ContactID) -> Bool
    /// Refreshes and returns the user's contact groups.
    func fetchGroups() async -> [ContactGroup]
    func members(ofGroup groupLocalID: String) async -> [Contact]

    // Writes (plans/cli-mcp.md Phase 2) — the SAME repository entry points
    // the UI uses (INV-2), so the change-watcher, iCloud push, and UI
    // observation all fire. Deletes are soft-deletes at the engine level.
    @discardableResult
    func addNote(for id: ContactID, body: String, createdAt: Date) async throws -> UUID
    func editNote(for id: ContactID, id noteID: UUID, newBody: String, createdAt: Date?) async throws
    func deleteNote(for id: ContactID, id noteID: UUID) async throws
    @discardableResult
    func upsertField(for id: ContactID, field: String, value: JSONValue, type: SidecarFieldType) async throws -> UUID
    /// By-id value write; un-deletes a tombstoned field (the Recently
    /// Deleted restore path rides this). Takes the payload as `JSONValue`
    /// so every field type restores — a checkbox cell's value is a JSON
    /// bool, not a string.
    func editField(for id: ContactID, id fieldID: UUID, value: JSONValue) async throws
    func deleteField(for id: ContactID, id fieldID: UUID) async throws
    @discardableResult
    func addLink(from a: ContactID, to b: ContactID, note: String) async throws -> Link
    // Contact↔event / contact↔place connections (links_create) — the SAME
    // repository funnels the app's detail views use, so the contact
    // endpoint resolves-or-mints its canonical identity before the link is
    // written. The far endpoint is addressed by its own record UUID.
    @discardableResult
    func addEventLink(for id: ContactID, eventUUID: String, note: String) async throws -> Link
    @discardableResult
    func addPlaceLink(for id: ContactID, placeUUID: String, note: String) async throws -> Link
    func setLinkNote(id linkID: UUID, note: String) throws
    func removeLink(id linkID: UUID) throws
    @discardableResult
    func toggleFavorite(_ id: ContactID) async throws -> Bool

    // Tombstone-inclusive reads for the write-side audit (post-write
    // `modifiedAt`) and the Recently Deleted surface. Never wired to a tool.
    func allNotes(for id: ContactID) -> [ContactNote]
    func allFields(for id: ContactID) -> [SidecarField]
    func link(id linkID: UUID) -> Link?

    // Contact-record writes (plans/cli-mcp.md Revision 2: full Contact
    // Store parity) — the SAME repository entry points the app's contact
    // editor uses, so merge rules (identity-URL carry-through) and the
    // change-watcher behave identically. Saves can fail (the 134092
    // store-rejection family, revoked access); the dispatcher maps thrown
    // errors to typed wire codes and never crashes.
    func editableContact(id: ContactID) async throws -> Contact?
    func saveContact(_ edited: Contact, for id: ContactID) async throws
    func createContact(_ seed: Contact) async throws -> Contact
    /// Whole-contact delete — reachable ONLY through the user-confirmed
    /// contacts_delete path. Returns false when the id no longer resolves.
    @discardableResult
    func deleteContact(id: ContactID) async throws -> Bool
}

extension ContactsRepository: MCPContactSource {
    public var allContacts: [Contact] { contacts }

    public func fetchGroups() async -> [ContactGroup] {
        await loadGroups()
        return groups
    }
}

@MainActor
public protocol MCPEventSource: AnyObject {
    func fetchEventsRange(from start: Date, to end: Date) async -> [Event]
    /// A stored event by its stable id string, or nil if none exists.
    func event(uuid: String) -> Event?
    /// A snapshot of a system calendar event that has no GuessWho record of
    /// its own (reads never create one), or nil if it no longer exists.
    func eventKitEvent(eventKitID: String) -> Event?
    func eventTags(forEventUUID uuid: String) -> [EventTag]

    // Tag writes (plans/cli-mcp.md Phase 2). The dispatcher only calls
    // these for events that already HAVE a GuessWho record — a write to an
    // un-adopted event answers the typed Option B error and mints nothing.
    @discardableResult
    func addEventTag(text: String, forEventUUID uuid: String) throws -> UUID
    func editEventTag(id: UUID, text: String, forEventUUID uuid: String) throws
    func deleteEventTag(id: UUID, forEventUUID uuid: String) throws
    /// The raw tag cells INCLUDING tombstones (with their `modifiedAt`
    /// stamps), for the audit trail and the Recently Deleted surface.
    func allEventTagFields(forEventUUID uuid: String) -> [SidecarField]
    /// The record UUID currently bound to a system calendar identifier, or
    /// nil when that calendar event has no GuessWho record. Lets a derived
    /// (`e-`) wire id keep resolving after the user opens the event in the
    /// app.
    func eventUUID(forEventKitID eventKitID: String) async -> UUID?
}

/// The generic connection surface (links_list / links_create /
/// links_remove): the KIND-AGNOSTIC engine primitive the app's own detail
/// views funnel into for non-contact endpoints (event↔event, event↔place).
/// Contact endpoints do NOT ride this for writes — they go through the
/// `MCPContactSource` funnels above so an unreconciled contact
/// resolves-or-mints its canonical identity first.
@MainActor
public protocol MCPLinkSource: AnyObject {
    /// Every LIVE connection touching `endpoint` (soft-deleted ones are
    /// excluded at the source).
    func links(at endpoint: SidecarKey) async -> [Link]
    /// One connection by its own id, INCLUDING soft-deleted ones — the
    /// remove path's prior-state read; callers check `deletedAt`.
    func link(id: UUID) -> Link?
    @discardableResult
    func addLink(from: SidecarKey, to: SidecarKey, note: String) throws -> Link
    func removeLink(id: UUID) throws
}

/// Human-in-the-loop confirmation for uniquely destructive agent writes
/// (contacts_delete). The app presents a standard alert naming the
/// specific record on the frontmost scene; the dispatcher awaits the
/// answer OFF the request-reading path (fire-and-forget dispatch) and
/// sends the response when the user decides.
@MainActor
public protocol MCPConfirmationSource: AnyObject {
    /// Present the delete-contact confirmation naming `contactName`.
    /// Returns the user's decision — or nil when nothing could be
    /// presented (no foreground scene): the caller must NOT proceed, and
    /// must never treat "no dialog was seen" as approval.
    func confirmContactDelete(named contactName: String) async -> Bool?
}

@MainActor
public protocol MCPGuideSource: AnyObject {
    func allGuides() async -> [MapsGuide]
    func allPlaces() async -> [MapsPlace]
    func places(inGuide guideID: UUID) async -> [MapsPlace]

    // Guide/place writes (plans/cli-mcp.md Phase 2).
    @discardableResult
    func importGuide(from snapshot: MapsGuideURL.Snapshot, sourceURL: String?) throws -> UUID
    func deleteGuide(uuid: String) throws
    /// Best-effort by design: mirrors the app's own reorder path, which
    /// treats a failed order write as non-fatal.
    func reorderPlaces(inGuide guideID: UUID, orderedIDs: [UUID])
    func deletePlace(uuid: String) throws
}

/// Per-surface access mode + system-permission state, read live per call —
/// the server-side gate (hiding tools from listTools is UX; this is the
/// enforcement). One tri-state per surface (off → read-only → read-write),
/// both defaulting to off (plans/cli-mcp.md Revision 2).
@MainActor
public protocol MCPGateSource: AnyObject {
    var mcpAccess: MCPAccessMode { get }
    var cliAccess: MCPAccessMode { get }
    var contactsAuthorized: Bool { get }
    var eventsAuthorized: Bool { get }
}

extension MCPGateSource {
    /// The access mode governing a request, by its origin surface.
    public func accessMode(for origin: RequestOrigin) -> MCPAccessMode {
        origin == .cli ? cliAccess : mcpAccess
    }
}
