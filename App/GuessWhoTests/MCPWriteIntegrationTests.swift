import Foundation
import Testing
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire
@testable import GuessWho

/// INV-2, app-hosted (plans/cli-mcp.md Phase 2): an agent write dispatched
/// through `ToolDispatcher` against the LIVE `SyncService` — the same
/// instance and the same entry points the UI uses — is visible through the
/// UI's own reads immediately (no reload, no relaunch) AND lands in the
/// synced storage root on disk (the write iCloud pushes).
///
/// Mirrors the `SyncServiceTests` harness: a real service over protocol
/// stubs and a temp-dir sidecar root. The event-tag write is the INV-2
/// vehicle because the fixture event can be PRE-ADOPTED via the service's
/// own create path (Option B forbids adopt-on-write, so an un-adopted
/// fixture would exercise the error, not the write).
@MainActor
@Suite("MCP write integration (INV-2)")
struct MCPWriteIntegrationTests {

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mcp-inv2-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeService(root: URL) -> SyncService {
        SyncService(
            contactsAdapter: INV2StubContactStore(),
            eventsAdapter: INV2StubEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
    }

    @Test
    func agentTagWriteOnAdoptedEventIsLiveInUIReadsAndOnDisk() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = makeService(root: root)
        let repository = service.makeContactsRepository()
        let gates = INV2Gates()
        let audit = MCPAuditLog(
            fileURL: root.appendingPathComponent("audit-test/audit.jsonl"))

        // The dispatcher gets the LIVE instances — the same objects a UI
        // would render from (INV-2b: injected, never constructed).
        let dispatcher = ToolDispatcher(
            contacts: repository,
            events: INV2LiveEventSource(service: service),
            guides: INV2LiveGuideSource(service: service),
            gates: gates,
            audit: audit)

        // Pre-adopt the fixture event through the app's own create path.
        let eventUUID = try service.createManualEvent(
            title: "Fixture Gala",
            startDate: Date(timeIntervalSince1970: 1_760_000_000),
            endDate: Date(timeIntervalSince1970: 1_760_007_200),
            isAllDay: false,
            location: "City Museum")
        let uuidString = eventUUID.uuidString.lowercased()

        // Agent path: list to mint a sealed id, then write the tag.
        let helper = RequestOrigin.mcp.makeHelperId()
        let list = await dispatcher.handle(.eventsList(
            helperId: helper, messageId: "inv2-list",
            startDate: "2025-10-01T00:00:00Z", endDate: "2025-10-31T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = list,
              let fixtureEvent = page.items.first(where: { $0.title == "Fixture Gala" })
        else {
            Issue.record("the adopted event should be listed; got \(list)")
            return
        }

        let write = await dispatcher.handle(.eventsAddTag(
            helperId: helper, messageId: "inv2-write",
            eventId: fixtureEvent.id, text: "inv2-tag", idempotencyToken: nil))
        guard case .tag(_, _, let tag) = write else {
            Issue.record("expected a tag echo; got \(write)")
            return
        }
        #expect(tag.text == "inv2-tag")

        // Visible through the SAME read the event detail UI renders, on the
        // SAME live service instance, with no reload and no relaunch.
        let uiTags = service.eventTags(forEventUUID: uuidString)
        #expect(uiTags.contains { $0.text == "inv2-tag" })

        // And durably in the synced storage root on disk — the coordinated
        // write that the sync machinery pushes to the user's cloud storage.
        // A field cell's `value` is the §5.2 inner object
        // { field, type, value, createdAt }; the tag text is its `value`.
        let onDisk = try FileSystemSidecarStore(root: root)
            .read(SidecarKey(kind: .event, id: uuidString))
        let storedValues = (onDisk?.fields.values).map(Array.init) ?? []
        #expect(storedValues.contains { cell in
            guard case .object(let inner) = cell.value,
                  case .string(let text) = inner["value"] else { return false }
            return text == "inv2-tag"
        })

        // The write also left its provenance record in the audit log.
        let entries = await audit.entries()
        #expect(entries.contains { $0.action == .addTag && $0.newValue == "inv2-tag" })
    }

    @Test
    func readOnlyToggleRejectsAgentWriteAgainstLiveService() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = makeService(root: root)
        let repository = service.makeContactsRepository()
        let gates = INV2Gates()
        gates.isMCPReadOnly = true
        let dispatcher = ToolDispatcher(
            contacts: repository,
            events: INV2LiveEventSource(service: service),
            guides: INV2LiveGuideSource(service: service),
            gates: gates)

        let eventUUID = try service.createManualEvent(
            title: "Untouchable",
            startDate: Date(timeIntervalSince1970: 1_760_000_000),
            endDate: Date(timeIntervalSince1970: 1_760_003_600),
            isAllDay: false,
            location: nil)

        let helper = RequestOrigin.mcp.makeHelperId()
        let list = await dispatcher.handle(.eventsList(
            helperId: helper, messageId: "ro-list",
            startDate: "2025-10-01T00:00:00Z", endDate: "2025-10-31T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = list, let event = page.items.first else {
            Issue.record("expected the event to list")
            return
        }
        let write = await dispatcher.handle(.eventsAddTag(
            helperId: helper, messageId: "ro-write",
            eventId: event.id, text: "should not land", idempotencyToken: nil))
        #expect(write.errorPayload?.code == .readOnly)
        #expect(service.eventTags(forEventUUID: eventUUID.uuidString.lowercased()).isEmpty)
    }
}

// MARK: - Live-source adapters
//
// Thin forwarders so the test builds on every destination: the production
// `SyncService: MCPEventSource/MCPGuideSource` conformances live in
// MCPHostController.swift behind `#if targetEnvironment(macCatalyst)`
// (INV-5), while this bundle also runs on the iOS simulator. Every call
// forwards to the SAME live SyncService method the production conformance
// binds — nothing is reimplemented.

@MainActor
private final class INV2LiveEventSource: MCPEventSource {
    private let service: SyncService
    init(service: SyncService) { self.service = service }

    func fetchEventsRange(from start: Date, to end: Date) async -> [Event] {
        await service.fetchEventsRange(from: start, to: end)
    }
    func event(uuid: String) -> Event? { service.event(uuid: uuid) }
    func eventKitEvent(eventKitID: String) -> Event? { service.eventKitEvent(eventKitID: eventKitID) }
    func eventTags(forEventUUID uuid: String) -> [EventTag] { service.eventTags(forEventUUID: uuid) }
    func addEventTag(text: String, forEventUUID uuid: String) throws -> UUID {
        try service.addEventTag(text: text, forEventUUID: uuid)
    }
    func editEventTag(id: UUID, text: String, forEventUUID uuid: String) throws {
        try service.editEventTag(id: id, text: text, forEventUUID: uuid)
    }
    func deleteEventTag(id: UUID, forEventUUID uuid: String) throws {
        try service.deleteEventTag(id: id, forEventUUID: uuid)
    }
    func allEventTagFields(forEventUUID uuid: String) -> [SidecarField] {
        service.allEventTagFields(forEventUUID: uuid)
    }
}

@MainActor
private final class INV2LiveGuideSource: MCPGuideSource {
    private let service: SyncService
    init(service: SyncService) { self.service = service }

    func allGuides() async -> [MapsGuide] { await service.allGuides() }
    func allPlaces() async -> [MapsPlace] { await service.allPlaces() }
    func places(inGuide guideID: UUID) async -> [MapsPlace] {
        await service.places(inGuide: guideID)
    }
    func importGuide(from snapshot: MapsGuideURL.Snapshot, sourceURL: String?) throws -> UUID {
        try service.importGuide(from: snapshot, sourceURL: sourceURL)
    }
    func deleteGuide(uuid: String) throws { try service.deleteGuide(uuid: uuid) }
    func reorderPlaces(inGuide guideID: UUID, orderedIDs: [UUID]) {
        service.reorderPlaces(inGuide: guideID, orderedIDs: orderedIDs)
    }
    func deletePlace(uuid: String) throws { try service.deletePlace(uuid: uuid) }
}

@MainActor
private final class INV2Gates: MCPGateSource {
    var isMCPEnabled = true
    var isCLIEnabled = true
    var isMCPReadOnly = false
    var isCLIReadOnly = false
    var contactsAuthorized = true
    var eventsAuthorized = true
}

// MARK: - Protocol stubs (same shape as SyncServiceTests' private stubs)

private func inv2Unused(function: String = #function) -> Never {
    fatalError("INV-2 test stub member unexpectedly reached: \(function)")
}

private actor INV2StubContactStore: ContactStoreProtocol {
    func fetchAll() async throws -> [Contact] { [] }
    func fetch(localID: String) async throws -> Contact? { nil }
    func save(_ contact: Contact) async throws { inv2Unused() }
    func delete(localID: String) async throws { inv2Unused() }
    func create(_ contact: Contact) async throws -> Contact { inv2Unused() }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .notDetermined }
    func requestContactsAccess() async -> StoreAccessResult { inv2Unused() }
    func changes(since token: Data?) async throws -> ContactChangeSet { inv2Unused() }
    func loadImageData(localID: String) async throws -> Data? { nil }
    func loadThumbnailImageData(localID: String) async throws -> Data? { nil }
    func setImageData(localID: String, imageData: Data?) async throws { inv2Unused() }
    func fetchAllGroups() async throws -> [ContactGroup] { [] }
    func fetchGroup(localID: String) async throws -> ContactGroup? { nil }
    func createGroup(name: String) async throws -> ContactGroup { inv2Unused() }
    func renameGroup(localID: String, to name: String) async throws { inv2Unused() }
    func deleteGroup(localID: String) async throws { inv2Unused() }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] { [] }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { inv2Unused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { inv2Unused() }
}

private final class INV2StubEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .notDetermined }
    func requestEventsAccess() async -> StoreAccessResult { inv2Unused() }
    func fetchEvents(in interval: DateInterval) throws -> [Event] { [] }
    func fetch(eventKitID: String) throws -> Event? { nil }
    func fetchEvents(on day: Date) throws -> [Event] { [] }
    func searchEvents(matching text: String, in interval: DateInterval) throws -> [Event] { [] }
    func eventsWithAttendee(
        matchingEmails emails: Set<String>,
        orLocations locations: Set<String>,
        in interval: DateInterval,
        limit: Int
    ) throws -> [Event] { [] }
    func fetch(legacyEventIdentifier: String) throws -> Event? { nil }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws -> Event { inv2Unused() }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws { inv2Unused() }
}
