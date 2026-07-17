import Foundation
import GuessWhoSync

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
    func linkedContact(of link: Link, for id: ContactID) -> Contact?
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
    func setLinkNote(id linkID: UUID, note: String) throws
    func removeLink(id linkID: UUID) throws
    @discardableResult
    func toggleFavorite(_ id: ContactID) async throws -> Bool

    // Tombstone-inclusive reads for the write-side audit (post-write
    // `modifiedAt`) and the Recently Deleted surface. Never wired to a tool.
    func allNotes(for id: ContactID) -> [ContactNote]
    func allFields(for id: ContactID) -> [SidecarField]
    func link(id linkID: UUID) -> Link?
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

/// Master toggles + system-permission state, read live per call — the
/// server-side gate (hiding tools from listTools is UX; this is the
/// enforcement).
@MainActor
public protocol MCPGateSource: AnyObject {
    var isMCPEnabled: Bool { get }
    var isCLIEnabled: Bool { get }
    var isMCPReadOnly: Bool { get }
    var isCLIReadOnly: Bool { get }
    var contactsAuthorized: Bool { get }
    var eventsAuthorized: Bool { get }
}
