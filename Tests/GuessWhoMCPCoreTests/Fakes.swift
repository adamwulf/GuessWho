import Foundation
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

/// Deterministic non-UUID message ids for tests: the leak tests assert NO
/// UUID-shaped string appears anywhere in wire output, so test-minted
/// message ids must not be UUIDs themselves.
enum TestMessageID {
    private static var counter = 0
    private static let lock = NSLock()

    static func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "msg-\(counter)"
    }
}

/// Sentinels the security tests hunt for in tool output. Unique enough
/// that any appearance in encoded JSON is a real leak, not a coincidence.
enum Sentinels {
    /// Planted in the Apple `Contact.note` field (INV-3).
    static let appleNote = "XAPPLENOTESENTINELX-classified-cabbage-9481"
    /// A per-install device UUID planted in every `modifiedBy` (INV-3b).
    static let deviceID = "DEADBEEF-0000-4000-8000-FEEDFACE0001"
    /// The GuessWho identity UUID planted on the reconciled fixture contact.
    static let guessWhoUUID = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f10111213"
    /// The Apple local identifier planted on fixture contacts.
    static let localID = "ABPerson-LOCAL-SENTINEL-77"
}

@MainActor
final class FakeContactSource: MCPContactSource {
    var contacts: [Contact] = []
    var groups: [ContactGroup] = []
    var membersByGroup: [String: [Contact]] = [:]
    var notesByEffectiveID: [String: [ContactNote]] = [:]
    var fieldsByEffectiveID: [String: [SidecarField]] = [:]
    var linksByEffectiveID: [String: [Link]] = [:]
    var linkedContactsByLinkID: [UUID: Contact] = [:]
    var favoriteEffectiveIDs: Set<String> = []

    nonisolated init() {}

    private func effectiveID(_ id: ContactID) -> String {
        // Same rule the engine uses: durable identity first, local fallback.
        // Test-side only; nothing here crosses a wire.
        id.restorationToken.guessWhoID ?? id.restorationToken.localID
    }

    var allContacts: [Contact] { contacts }

    func contact(restorationToken: ContactRestorationToken) -> Contact? {
        contacts.first { candidate in
            let token = candidate.contactID.restorationToken
            if let wanted = restorationToken.guessWhoID {
                return token.guessWhoID == wanted
            }
            return token.localID == restorationToken.localID
        }
    }

    func notes(for id: ContactID) -> [ContactNote] {
        notesByEffectiveID[effectiveID(id)] ?? []
    }

    func fields(for id: ContactID) -> [SidecarField] {
        // Mirrors the live `fields(for:)` contract: attachment-typed fields
        // are excluded at the source.
        (fieldsByEffectiveID[effectiveID(id)] ?? []).filter { $0.type != .blob }
    }

    func links(for id: ContactID) async -> [Link] {
        linksByEffectiveID[effectiveID(id)] ?? []
    }

    func linkedContact(of link: Link, for id: ContactID) -> Contact? {
        linkedContactsByLinkID[link.id]
    }

    func isFavorite(_ id: ContactID) -> Bool {
        favoriteEffectiveIDs.contains(effectiveID(id))
    }

    func fetchGroups() async -> [ContactGroup] { groups }

    func members(ofGroup groupLocalID: String) async -> [Contact] {
        membersByGroup[groupLocalID] ?? []
    }
}

@MainActor
final class FakeEventSource: MCPEventSource {
    var events: [Event] = []
    var eventKitOnlyEvents: [String: Event] = [:]
    var tagsByEventUUID: [String: [EventTag]] = [:]

    nonisolated init() {}

    func fetchEventsRange(from start: Date, to end: Date) async -> [Event] {
        (events + eventKitOnlyEvents.values).filter { $0.startDate >= start && $0.startDate <= end }
    }

    func event(uuid: String) -> Event? {
        events.first { $0.id.uuidString.lowercased() == uuid.lowercased() }
    }

    func eventKitEvent(eventKitID: String) -> Event? {
        eventKitOnlyEvents[eventKitID]
    }

    func eventTags(forEventUUID uuid: String) -> [EventTag] {
        tagsByEventUUID[uuid.lowercased()] ?? []
    }
}

@MainActor
final class FakeGuideSource: MCPGuideSource {
    var guides: [MapsGuide] = []
    var places: [MapsPlace] = []

    nonisolated init() {}

    func allGuides() async -> [MapsGuide] { guides }
    func allPlaces() async -> [MapsPlace] { places }
    func places(inGuide guideID: UUID) async -> [MapsPlace] {
        places.filter { $0.guideID == guideID }
    }
}

@MainActor
final class FakeGateSource: MCPGateSource {
    var isMCPEnabled = true
    var isCLIEnabled = true
    var isMCPReadOnly = true
    var isCLIReadOnly = true
    var contactsAuthorized = true
    var eventsAuthorized = true

    nonisolated init() {}
}

/// A ready-to-use dispatcher over fully-populated fixtures. Every record
/// carries the sentinels somewhere it must NOT escape from: the Apple
/// note, the identity URL, `modifiedBy` device ids, raw local ids.
struct Fixture {
    let dispatcher: ToolDispatcher
    let contacts: FakeContactSource
    let events: FakeEventSource
    let guides: FakeGuideSource
    let gates: FakeGateSource

    static let helper = RequestOrigin.mcp.makeHelperId()

    /// The reconciled person fixture ("Jane Doe") — carries the identity
    /// URL + the Apple-note sentinel.
    @MainActor
    static func janeDoe() -> Contact {
        Contact(
            localID: Sentinels.localID,
            givenName: "Jane",
            familyName: "Doe",
            jobTitle: "Curator",
            organizationName: "Doe Industries",
            note: Sentinels.appleNote,
            phoneNumbers: [LabeledValue(label: "mobile", value: "+1 (555) 010-7788")],
            emailAddresses: [LabeledValue(label: "work", value: "jane@doe.example")],
            urlAddresses: [
                LabeledValue(label: "homepage", value: "https://janedoe.example"),
                LabeledValue(label: "", value: "guesswho://contact/\(Sentinels.guessWhoUUID)"),
            ],
            birthday: DateComponents(year: 1984, month: 3, day: 14))
    }

    /// A never-reconciled person (no identity URL — exercises the
    /// nil-identity fingerprint path).
    @MainActor
    static func freshFace() -> Contact {
        Contact(
            localID: "ABPerson-LOCAL-FRESH-88",
            givenName: "Fresh",
            familyName: "Face",
            note: Sentinels.appleNote)
    }

    /// An organization linked to Jane.
    @MainActor
    static func doeIndustries() -> Contact {
        Contact(
            localID: "ABPerson-LOCAL-ORG-99",
            contactType: .organization,
            organizationName: "Doe Industries",
            note: Sentinels.appleNote)
    }

    @MainActor
    static func make() -> Fixture {
        let contacts = FakeContactSource()
        let events = FakeEventSource()
        let guides = FakeGuideSource()
        let gates = FakeGateSource()

        let jane = janeDoe()
        let fresh = freshFace()
        let organization = doeIndustries()
        contacts.contacts = [jane, fresh, organization]
        let janeKey = Sentinels.guessWhoUUID

        contacts.notesByEffectiveID[janeKey] = [
            ContactNote(
                id: UUID(), body: "Met at the museum gala",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                modifiedBy: Sentinels.deviceID),
            ContactNote(
                id: UUID(), body: "Deleted note body",
                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_100_000),
                modifiedBy: Sentinels.deviceID,
                deletedAt: Date(timeIntervalSince1970: 1_700_200_000)),
        ]
        contacts.fieldsByEffectiveID[janeKey] = [
            SidecarField(
                id: UUID(), field: "Coffee order", type: .note,
                value: .string("Flat white"), createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_200),
                modifiedBy: Sentinels.deviceID, deletedAt: nil),
            SidecarField(
                id: UUID(), field: "previousPhoto", type: .blob,
                value: .string("blob:sha256/deadbeef"), createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_300),
                modifiedBy: Sentinels.deviceID, deletedAt: nil),
        ]

        let personLink = Link(
            id: UUID(),
            endpointA: SidecarKey(kind: .contact, id: janeKey),
            endpointB: SidecarKey(kind: .contact, id: UUID().uuidString.lowercased()),
            note: "College roommate",
            createdAt: Date(timeIntervalSince1970: 1_690_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_690_000_000),
            modifiedBy: Sentinels.deviceID)
        let organizationLink = Link(
            id: UUID(),
            endpointA: SidecarKey(kind: .contact, id: janeKey),
            endpointB: SidecarKey(kind: .contact, id: UUID().uuidString.lowercased()),
            note: "Board seat",
            createdAt: Date(timeIntervalSince1970: 1_691_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_691_000_000),
            modifiedBy: Sentinels.deviceID)
        contacts.linksByEffectiveID[janeKey] = [personLink, organizationLink]
        contacts.linkedContactsByLinkID[personLink.id] = fresh
        contacts.linkedContactsByLinkID[organizationLink.id] = organization
        contacts.favoriteEffectiveIDs = [janeKey]
        contacts.groups = [ContactGroup(localID: "CNGroup-LOCAL-1", name: "Museum Friends")]
        contacts.membersByGroup["CNGroup-LOCAL-1"] = [jane]

        let gala = Event(
            id: UUID(),
            eventKitID: nil,
            title: "Museum Gala",
            startDate: Date(timeIntervalSince1970: 1_760_000_000),
            endDate: Date(timeIntervalSince1970: 1_760_007_200),
            location: "City Museum",
            eventKitNotes: "Bring the auction catalog",
            attendees: [EventAttendee(name: "Jane Doe", email: "jane@doe.example")],
            calendarName: "Personal")
        events.events = [gala]
        let systemOnly = Event(
            id: Event.stableID(forEventKitID: "EK-SENTINEL-42"),
            eventKitID: "EK-SENTINEL-42",
            title: "Dentist",
            startDate: Date(timeIntervalSince1970: 1_760_100_000),
            endDate: Date(timeIntervalSince1970: 1_760_103_600))
        events.eventKitOnlyEvents["EK-SENTINEL-42"] = systemOnly
        events.tagsByEventUUID[gala.id.uuidString.lowercased()] = [
            EventTag(id: UUID(), text: "fundraiser", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        ]

        let guide = MapsGuide(
            id: UUID(), name: "Coffee Crawl",
            sourceURL: "https://guides.apple/example",
            createdAt: Date(timeIntervalSince1970: 1_740_000_000))
        guides.guides = [guide]
        guides.places = [
            MapsPlace(
                id: UUID(), guideID: guide.id, name: "Bluebird Espresso",
                address: "12 Main St", latitude: 30.27, longitude: -97.74)
        ]

        let dispatcher = ToolDispatcher(
            contacts: contacts, events: events, guides: guides, gates: gates)
        return Fixture(
            dispatcher: dispatcher, contacts: contacts, events: events,
            guides: guides, gates: gates)
    }
}

// MARK: - Output scanning helpers

extension WireResponse {
    /// The full agent-visible rendering of this response (what actually
    /// leaves the process), as text — the surface the leak tests scan.
    var agentVisibleText: String {
        asCallToolResult().content.map { content in
            if case .text(let text, _, _) = content { return text }
            return ""
        }.joined(separator: "\n")
    }

    /// The complete relay-bound encoding (everything that crosses the
    /// process boundary, not just the agent rendering).
    var wireJSON: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
