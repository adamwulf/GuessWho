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
}

@MainActor
public protocol MCPGuideSource: AnyObject {
    func allGuides() async -> [MapsGuide]
    func allPlaces() async -> [MapsPlace]
    func places(inGuide guideID: UUID) async -> [MapsPlace]
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
