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

    private func makeService(root: URL, store: INV2StubContactStore) -> SyncService {
        SyncService(
            contactsAdapter: store,
            eventsAdapter: INV2StubEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
    }

    private func makeService(root: URL, contacts: [Contact] = []) -> SyncService {
        makeService(root: root, store: INV2StubContactStore(contacts: contacts))
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
            links: service,
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
        gates.mcpAccess = .readOnly
        let dispatcher = ToolDispatcher(
            contacts: repository,
            events: INV2LiveEventSource(service: service),
            guides: INV2LiveGuideSource(service: service),
            links: service,
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
        #expect(write?.errorPayload?.code == .readOnly)
        #expect(service.eventTags(forEventUUID: eventUUID.uuidString.lowercased()).isEmpty)
    }

    /// contacts_list, hosted: the whole-book enumeration against the LIVE
    /// `ContactsRepository` — the production `reload()` + cached read-model
    /// the UI renders, with the stub contact store standing in ONLY at the
    /// TCC boundary where the CNContactStore adapter would sit. Asserts the
    /// stable name order, the kind filter, cursor paging with no skips or
    /// duplicates, the identity-URL-derived wire id, and that the Apple
    /// note never rides a list row.
    @Test
    func contactsListPagesTheLiveRepositoryReadModel() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let reconciledID = "3f2a9d64-1c5b-4e8a-9f70-2b6d8c1e4a55"
        let jane = Contact(
            givenName: "Live", familyName: "Jane",
            note: "hosted-apple-note-sentinel",
            urlAddresses: [LabeledValue(label: "", value: "guesswho://contact/\(reconciledID)")])
        let bob = Contact(givenName: "Live", familyName: "Bob")
        let org = Contact(contactType: .organization, organizationName: "Live Org")

        let service = makeService(root: root, contacts: [jane, bob, org])
        let repository = service.makeContactsRepository()
        await repository.reload()

        let dispatcher = ToolDispatcher(
            contacts: repository,
            events: INV2LiveEventSource(service: service),
            guides: INV2LiveGuideSource(service: service),
            links: service,
            gates: INV2Gates())

        let helper = RequestOrigin.mcp.makeHelperId()
        let all = await dispatcher.handle(.contactsList(
            helperId: helper, messageId: "list-all", type: nil, limit: nil, cursor: nil))
        guard case .contactPage(_, _, let page) = all else {
            Issue.record("expected a contact page; got \(String(describing: all))")
            return
        }
        #expect(page.items.map(\.name) == ["Live Bob", "Live Jane", "Live Org"])
        #expect(page.items.map(\.kind) == ["person", "person", "organization"])
        #expect(page.items.first(where: { $0.name == "Live Jane" })?.id == reconciledID)
        let encoded = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        #expect(!encoded.contains("hosted-apple-note-sentinel"))
        #expect(!encoded.contains("guesswho://"))

        let organizations = await dispatcher.handle(.contactsList(
            helperId: helper, messageId: "list-orgs",
            type: "organization", limit: nil, cursor: nil))
        guard case .contactPage(_, _, let orgPage) = organizations else {
            Issue.record("expected a contact page; got \(String(describing: organizations))")
            return
        }
        #expect(orgPage.items.map(\.name) == ["Live Org"])

        // Cursor paging over the live read-model: two pages, every contact
        // exactly once.
        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let response = await dispatcher.handle(.contactsList(
                helperId: helper, messageId: "list-page-\(pages)",
                type: nil, limit: 2, cursor: cursor))
            guard case .contactPage(_, _, let slice) = response else {
                Issue.record("expected a contact page; got \(String(describing: response))")
                return
            }
            seen.append(contentsOf: slice.items.map(\.id))
            cursor = slice.nextCursor
            pages += 1
        } while cursor != nil && pages < 5
        #expect(pages == 2)
        #expect(seen.count == 3)
        #expect(Set(seen).count == 3)
    }

    /// Single-entry list edits (Phase 7), hosted: contacts_add_phone /
    /// edit / remove against the LIVE `ContactsRepository` — the
    /// production `editableContact` → mutate-one-entry → `saveContact` →
    /// `refreshContact` funnel over its real cached read-model, with the
    /// stub record book standing in ONLY at the TCC boundary. Asserts one
    /// entry changes and nothing else does (the Apple note and the
    /// identity URL ride through byte-identical), the repository's own
    /// read-model reflects the write with no reload, and the 0-match /
    /// duplicate-value cases answer typed errors without changing
    /// anything.
    @Test
    func singleEntryPhoneEditsRideTheLiveRepositoryEditablePath() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let reconciledID = "7c1e5a2b-9d3f-4b6a-8e70-1a2b3c4d5e6f"
        let jane = Contact(
            givenName: "Live", familyName: "Jane",
            note: "hosted-apple-note-sentinel",
            phoneNumbers: [LabeledValue(label: "mobile", value: "+1 555 0100")],
            urlAddresses: [LabeledValue(label: "", value: "guesswho://contact/\(reconciledID)")])
        let store = INV2StubContactStore(contacts: [jane])
        let service = makeService(root: root, store: store)
        let repository = service.makeContactsRepository()
        await repository.reload()

        let dispatcher = ToolDispatcher(
            contacts: repository,
            events: INV2LiveEventSource(service: service),
            guides: INV2LiveGuideSource(service: service),
            links: service,
            gates: INV2Gates())
        let helper = RequestOrigin.mcp.makeHelperId()

        // Add appends ONE entry.
        let added = await dispatcher.handle(.contactsAddPhone(
            helperId: helper, messageId: "phone-add",
            contactId: reconciledID, value: "+1 555 0200", label: "work",
            idempotencyToken: nil))
        guard case .contact(_, _, let addedCard) = added else {
            Issue.record("expected the updated card; got \(String(describing: added))")
            return
        }
        #expect(addedCard.phoneNumbers.map(\.value) == ["+1 555 0100", "+1 555 0200"])

        // Visible through the repository's own cached read-model — the
        // same projection the UI renders — with no reload.
        #expect(
            repository.allContacts.first?.phoneNumbers.map(\.value)
                == ["+1 555 0100", "+1 555 0200"])

        // The stored record changed exactly one list; the Apple note and
        // the identity URL rode through byte-identical.
        let stored = await store.storedContacts().first
        #expect(stored?.phoneNumbers.map(\.value) == ["+1 555 0100", "+1 555 0200"])
        #expect(stored?.note == "hosted-apple-note-sentinel")
        #expect(stored?.urlAddresses.map(\.value) == ["guesswho://contact/\(reconciledID)"])

        // The echo leaks neither the note nor the identity URL form.
        let encoded = String(
            decoding: try JSONEncoder().encode(addedCard), as: UTF8.self)
        #expect(!encoded.contains("hosted-apple-note-sentinel"))
        #expect(!encoded.contains("guesswho://"))

        // Duplicate exact values: typed ambiguous, nothing changed.
        let duplicated = await dispatcher.handle(.contactsAddPhone(
            helperId: helper, messageId: "phone-dupe",
            contactId: reconciledID, value: "+1 555 0200", label: "home",
            idempotencyToken: nil))
        guard case .contact = duplicated else {
            Issue.record("expected the duplicate add to succeed")
            return
        }
        let ambiguous = await dispatcher.handle(.contactsRemovePhone(
            helperId: helper, messageId: "phone-ambiguous",
            contactId: reconciledID, value: "+1 555 0200", idempotencyToken: nil))
        #expect(ambiguous?.errorPayload?.code == .ambiguous)
        #expect(repository.allContacts.first?.phoneNumbers.count == 3)

        // 0 matches: typed notFound, nothing changed.
        let missing = await dispatcher.handle(.contactsEditPhone(
            helperId: helper, messageId: "phone-missing",
            contactId: reconciledID, currentValue: "+1 555 9999",
            newValue: "+1 555 9998", newLabel: nil, idempotencyToken: nil))
        #expect(missing?.errorPayload?.code == .notFound)
        #expect(repository.allContacts.first?.phoneNumbers.count == 3)

        // An unambiguous exact match removes exactly that entry.
        let removed = await dispatcher.handle(.contactsRemovePhone(
            helperId: helper, messageId: "phone-remove",
            contactId: reconciledID, value: "+1 555 0100", idempotencyToken: nil))
        guard case .contact(_, _, let finalCard) = removed else {
            Issue.record("expected the updated card; got \(String(describing: removed))")
            return
        }
        #expect(finalCard.phoneNumbers.map(\.value) == ["+1 555 0200", "+1 555 0200"])
        let finalStored = await store.storedContacts().first
        #expect(finalStored?.note == "hosted-apple-note-sentinel")
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
    func eventUUID(forEventKitID eventKitID: String) async -> UUID? {
        await service.eventUUID(forEventKitID: eventKitID)
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
    var mcpAccess: MCPAccessMode = .readWrite
    var cliAccess: MCPAccessMode = .readWrite
    var contactsAuthorized = true
    var eventsAuthorized = true
}

// MARK: - Protocol stubs (same shape as SyncServiceTests' private stubs)

private func inv2Unused(function: String = #function) -> Never {
    fatalError("INV-2 test stub member unexpectedly reached: \(function)")
}

private actor INV2StubContactStore: ContactStoreProtocol {
    /// The record book — the ONLY thing faked (the TCC boundary where the
    /// CNContactStore adapter would sit). `fetchAll` feeds the repository's
    /// real `reload()`; `fetch(localID:)`/`save` feed its real
    /// `editableContact`/`saveContact`/`refreshContact` write path.
    private var contacts: [Contact]

    init(contacts: [Contact] = []) {
        self.contacts = contacts
    }

    /// The stored records, for asserting what a save actually wrote.
    func storedContacts() -> [Contact] { contacts }

    func fetchAll() async throws -> [Contact] { contacts }
    // Every record the public initializer can seed carries the same
    // (empty) local identifier — the real one is package-scoped — so a
    // by-id lookup is well-defined only for a single-record book. The
    // write test uses exactly one record; the multi-record read tests
    // never reach these (nil preserves their old stub behavior).
    func fetch(localID: String) async throws -> Contact? {
        contacts.count == 1 ? contacts[0] : nil
    }
    func save(_ contact: Contact) async throws {
        guard contacts.count == 1 else { inv2Unused() }
        contacts[0] = contact
    }
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
