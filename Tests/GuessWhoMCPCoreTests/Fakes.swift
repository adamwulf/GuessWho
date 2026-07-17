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
    var linksByID: [UUID: Link] = [:]
    var linkedContactsByLinkID: [UUID: Contact] = [:]
    var favoriteEffectiveIDs: Set<String> = []

    /// When true, every write throws like the engine's `.unavailable`
    /// storage state.
    var unavailable = false
    /// How many identity mints the fake performed (a mint = a first write
    /// to a contact with no durable identity).
    private(set) var mintCount = 0
    /// One-shot: the NEXT mint stores its data under its own fresh UUID but
    /// stamps the card with a DIFFERENT UUID — simulating a concurrent
    /// first-writer (e.g. the UI) whose mint won the race. Exercises the
    /// dispatcher's post-mint verify + retry.
    var simulateLosingMintOnce = false

    nonisolated init() {}

    private func effectiveID(_ id: ContactID) -> String {
        // Same rule the engine uses: durable identity first, local fallback.
        // Test-side only; nothing here crosses a wire.
        id.restorationToken.guessWhoID ?? id.restorationToken.localID
    }

    /// Resolve-or-mint, mirroring the engine's structure: the resolve spans
    /// an `await`, so two UNSERIALIZED first-writers interleave exactly like
    /// the real `resolveOrMintGuessWhoID` race — each mints, the last stamp
    /// wins the card, the loser's data is stranded. The dispatcher's
    /// single-flight + post-mint verify are what keep tests green here.
    private func effectiveWriteID(_ id: ContactID) async throws -> String {
        if unavailable { throw SidecarUnavailableError() }
        if let existing = id.restorationToken.guessWhoID { return existing }
        let localID = id.restorationToken.localID
        if let carried = contacts.first(where: { $0.contactID.restorationToken.localID == localID })?
            .contactID.restorationToken.guessWhoID {
            return carried
        }
        mintCount += 1
        // Mirrors the engine's DETERMINISTIC mint (Revision 2): the minted
        // UUID is derived from localID + display name, so the wire id an
        // agent got BEFORE the mint is the id the card ends up carrying.
        let minted = contacts.first(where: {
            $0.contactID.restorationToken.localID == localID
        })?.deterministicGuessWhoID ?? UUID().uuidString.lowercased()
        await Task.yield() // the engine's await window: racers interleave here
        if simulateLosingMintOnce {
            simulateLosingMintOnce = false
            stamp(localID: localID, guessWhoID: UUID().uuidString.lowercased())
            return minted // our data lands under the losing identity
        }
        stamp(localID: localID, guessWhoID: minted) // last write wins the card
        return minted
    }

    private func stamp(localID: String, guessWhoID: String) {
        guard let index = contacts.firstIndex(where: {
            $0.contactID.restorationToken.localID == localID
        }) else { return }
        var contact = contacts[index]
        // The real adapter replaces urlAddresses wholesale — LWW, one URL.
        contact.urlAddresses.removeAll { $0.value.hasPrefix("guesswho://") }
        contact.urlAddresses.append(
            LabeledValue(label: "", value: "guesswho://contact/\(guessWhoID)"))
        contacts[index] = contact
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
        // Mirrors the live read contract: tombstones are excluded.
        (notesByEffectiveID[effectiveID(id)] ?? []).filter { !$0.isDeleted }
    }

    func allNotes(for id: ContactID) -> [ContactNote] {
        notesByEffectiveID[effectiveID(id)] ?? []
    }

    func fields(for id: ContactID) -> [SidecarField] {
        // Mirrors the live `fields(for:)` contract: attachment-typed fields
        // and tombstones are excluded at the source.
        (fieldsByEffectiveID[effectiveID(id)] ?? [])
            .filter { $0.type != .blob && $0.deletedAt == nil }
    }

    func allFields(for id: ContactID) -> [SidecarField] {
        fieldsByEffectiveID[effectiveID(id)] ?? []
    }

    func links(for id: ContactID) async -> [Link] {
        let effective = effectiveID(id)
        return linksByID.values
            .filter { link in
                link.deletedAt == nil
                    && (link.endpointA.id == effective || link.endpointB.id == effective)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func linkedContact(of link: Link, for id: ContactID) -> Contact? {
        linkedContactsByLinkID[link.id]
    }

    func link(id linkID: UUID) -> Link? {
        linksByID[linkID]
    }

    func isFavorite(_ id: ContactID) -> Bool {
        favoriteEffectiveIDs.contains(effectiveID(id))
    }

    func fetchGroups() async -> [ContactGroup] { groups }

    func members(ofGroup groupLocalID: String) async -> [Contact] {
        membersByGroup[groupLocalID] ?? []
    }

    // MARK: Writes

    func addNote(for id: ContactID, body: String, createdAt: Date) async throws -> UUID {
        let key = try await effectiveWriteID(id)
        let noteID = UUID()
        notesByEffectiveID[key, default: []].append(ContactNote(
            id: noteID, body: body, createdAt: createdAt,
            modifiedAt: Date(), modifiedBy: Sentinels.deviceID))
        return noteID
    }

    func editNote(for id: ContactID, id noteID: UUID, newBody: String, createdAt: Date?) async throws {
        let key = try await effectiveWriteID(id)
        guard var list = notesByEffectiveID[key],
              let index = list.firstIndex(where: { $0.id == noteID }) else { return }
        let old = list[index]
        // setField semantics: an edit bumps the stamp and UN-deletes.
        list[index] = ContactNote(
            id: old.id, body: newBody, createdAt: createdAt ?? old.createdAt,
            modifiedAt: Date(), modifiedBy: Sentinels.deviceID, deletedAt: nil)
        notesByEffectiveID[key] = list
    }

    func deleteNote(for id: ContactID, id noteID: UUID) async throws {
        let key = try await effectiveWriteID(id)
        guard var list = notesByEffectiveID[key],
              let index = list.firstIndex(where: { $0.id == noteID }),
              list[index].deletedAt == nil else { return }
        let old = list[index]
        let now = Date()
        list[index] = ContactNote(
            id: old.id, body: old.body, createdAt: old.createdAt,
            modifiedAt: now, modifiedBy: Sentinels.deviceID, deletedAt: now)
        notesByEffectiveID[key] = list
    }

    func upsertField(
        for id: ContactID, field: String, value: JSONValue, type: SidecarFieldType
    ) async throws -> UUID {
        let key = try await effectiveWriteID(id)
        var list = fieldsByEffectiveID[key] ?? []
        if let index = list.firstIndex(where: { $0.deletedAt == nil && $0.field == field }) {
            let old = list[index]
            if old.type == type {
                list[index] = SidecarField(
                    id: old.id, field: field, type: type, value: value,
                    createdAt: old.createdAt, modifiedAt: Date(),
                    modifiedBy: Sentinels.deviceID, deletedAt: nil)
                fieldsByEffectiveID[key] = list
                return old.id
            }
            // Type change: replace (tombstone old, mint new) — the engine's
            // type-replace upsert, the reason reserved names are rejected.
            list[index] = SidecarField(
                id: old.id, field: old.field, type: old.type, value: old.value,
                createdAt: old.createdAt, modifiedAt: Date(),
                modifiedBy: Sentinels.deviceID, deletedAt: Date())
        }
        let newID = UUID()
        list.append(SidecarField(
            id: newID, field: field, type: type, value: value,
            createdAt: Date(), modifiedAt: Date(),
            modifiedBy: Sentinels.deviceID, deletedAt: nil))
        fieldsByEffectiveID[key] = list
        return newID
    }

    func editField(for id: ContactID, id fieldID: UUID, value: JSONValue) async throws {
        let key = try await effectiveWriteID(id)
        guard var list = fieldsByEffectiveID[key],
              let index = list.firstIndex(where: { $0.id == fieldID }) else { return }
        let old = list[index]
        // setField semantics: the payload must match the cell's immutable
        // type (string cells take strings, checkbox cells take bools), the
        // stamp bumps, and the cell UN-deletes.
        switch (old.type, value) {
        case (.note, .string), (.multilineNote, .string), (.date, .string), (.checkbox, .bool):
            break
        default:
            struct TypeValueMismatch: Error {}
            throw TypeValueMismatch()
        }
        list[index] = SidecarField(
            id: old.id, field: old.field, type: old.type, value: value,
            createdAt: old.createdAt, modifiedAt: Date(),
            modifiedBy: Sentinels.deviceID, deletedAt: nil)
        fieldsByEffectiveID[key] = list
    }

    func deleteField(for id: ContactID, id fieldID: UUID) async throws {
        let key = try await effectiveWriteID(id)
        guard var list = fieldsByEffectiveID[key],
              let index = list.firstIndex(where: { $0.id == fieldID }),
              list[index].deletedAt == nil else { return }
        let old = list[index]
        let now = Date()
        list[index] = SidecarField(
            id: old.id, field: old.field, type: old.type, value: old.value,
            createdAt: old.createdAt, modifiedAt: now,
            modifiedBy: Sentinels.deviceID, deletedAt: now)
        fieldsByEffectiveID[key] = list
    }

    func addLink(from a: ContactID, to b: ContactID, note: String) async throws -> Link {
        let aKey = try await effectiveWriteID(a)
        let bKey = try await effectiveWriteID(b)
        let now = Date()
        let link = Link(
            id: UUID(),
            endpointA: SidecarKey(kind: .contact, id: aKey),
            endpointB: SidecarKey(kind: .contact, id: bKey),
            note: note, createdAt: now, modifiedAt: now,
            modifiedBy: Sentinels.deviceID)
        linksByID[link.id] = link
        if let far = contacts.first(where: { $0.contactID.restorationToken.guessWhoID == bKey }) {
            linkedContactsByLinkID[link.id] = far
        }
        return link
    }

    func setLinkNote(id linkID: UUID, note: String) throws {
        if unavailable { throw SidecarUnavailableError() }
        guard var link = linksByID[linkID] else { return }
        link.note = note
        link.modifiedAt = Date()
        link.deletedAt = nil // undelete, mirroring the engine
        linksByID[linkID] = link
    }

    func removeLink(id linkID: UUID) throws {
        if unavailable { throw SidecarUnavailableError() }
        guard var link = linksByID[linkID], link.deletedAt == nil else { return }
        let now = Date()
        link.deletedAt = now
        link.modifiedAt = now
        linksByID[linkID] = link
    }

    func toggleFavorite(_ id: ContactID) async throws -> Bool {
        let key = try await effectiveWriteID(id)
        if favoriteEffectiveIDs.contains(key) {
            favoriteEffectiveIDs.remove(key)
            return false
        }
        favoriteEffectiveIDs.insert(key)
        return true
    }

    // MARK: Contact-record writes (Revision 2)

    /// When set, the next saveContact/createContact/deleteContact throws it
    /// (one-shot) — the 134092-style store-rejection / revoked-access
    /// simulation.
    var nextContactStoreError: Error?
    private(set) var deletedContactLocalIDs: [String] = []

    private func takeContactStoreError() throws {
        if unavailable { throw SidecarUnavailableError() }
        if let error = nextContactStoreError {
            nextContactStoreError = nil
            throw error
        }
    }

    func editableContact(id: ContactID) async throws -> Contact? {
        try takeContactStoreError()
        return contact(restorationToken: id.restorationToken)
    }

    func saveContact(_ edited: Contact, for id: ContactID) async throws {
        try takeContactStoreError()
        guard let index = contacts.firstIndex(where: {
            $0.contactID.restorationToken.localID == edited.contactID.restorationToken.localID
        }) else { return }
        contacts[index] = edited
    }

    func createContact(_ seed: Contact) async throws -> Contact {
        try takeContactStoreError()
        // The store issues the local identifier; the seed's is ignored —
        // mirrors CNContactStoreAdapter.create.
        let created = Contact(
            localID: "ABPerson-LOCAL-CREATED-\(contacts.count + 1)",
            contactType: seed.contactType,
            namePrefix: seed.namePrefix,
            givenName: seed.givenName,
            middleName: seed.middleName,
            familyName: seed.familyName,
            previousFamilyName: seed.previousFamilyName,
            nameSuffix: seed.nameSuffix,
            nickname: seed.nickname,
            phoneticGivenName: seed.phoneticGivenName,
            phoneticMiddleName: seed.phoneticMiddleName,
            phoneticFamilyName: seed.phoneticFamilyName,
            jobTitle: seed.jobTitle,
            departmentName: seed.departmentName,
            organizationName: seed.organizationName,
            phoneticOrganizationName: seed.phoneticOrganizationName,
            note: seed.note,
            phoneNumbers: seed.phoneNumbers,
            emailAddresses: seed.emailAddresses,
            postalAddresses: seed.postalAddresses,
            urlAddresses: seed.urlAddresses,
            birthday: seed.birthday,
            nonGregorianBirthday: seed.nonGregorianBirthday,
            dates: seed.dates,
            socialProfiles: seed.socialProfiles,
            instantMessageAddresses: seed.instantMessageAddresses,
            contactRelations: seed.contactRelations,
            imageDataAvailable: seed.imageDataAvailable)
        contacts.append(created)
        return created
    }

    func deleteContact(id: ContactID) async throws -> Bool {
        try takeContactStoreError()
        let localID = id.restorationToken.localID
        guard let index = contacts.firstIndex(where: {
            $0.contactID.restorationToken.localID == localID
        }) else { return false }
        deletedContactLocalIDs.append(localID)
        contacts.remove(at: index)
        return true
    }
}

/// Test double for the human-in-the-loop confirmation: scripted decisions,
/// recorded prompts.
@MainActor
final class FakeConfirmationSource: MCPConfirmationSource {
    /// The next answers to hand out, in order. Empty = `unpresentable` (nil).
    var decisions: [Bool?] = []
    private(set) var promptedNames: [String] = []

    nonisolated init() {}

    func confirmContactDelete(named contactName: String) async -> Bool? {
        promptedNames.append(contactName)
        guard !decisions.isEmpty else { return nil }
        return decisions.removeFirst()
    }
}

/// Collects deferred (out-of-band) responses for tests, with a wait helper.
actor DeferredResponseProbe {
    private var responses: [WireResponse] = []

    func record(_ response: WireResponse) {
        responses.append(response)
    }

    /// Poll until at least one response arrives (or ~2s pass).
    func next() async -> WireResponse? {
        for _ in 0..<200 {
            if !responses.isEmpty { return responses.removeFirst() }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}

@MainActor
final class FakeEventSource: MCPEventSource {
    var events: [Event] = []
    var eventKitOnlyEvents: [String: Event] = [:]
    /// Tag storage mirrors the engine: tags are `.note`-typed field cells
    /// named "tag"; the live `eventTags` read derives from these.
    var tagFieldsByEventUUID: [String: [SidecarField]] = [:]
    /// Every event UUID a tag WRITE touched — the Option B test asserts
    /// this stays empty for un-adopted events (the dispatcher must never
    /// reach the engine).
    private(set) var tagWriteEventUUIDs: [String] = []

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
        (tagFieldsByEventUUID[uuid.lowercased()] ?? []).compactMap { field in
            guard field.deletedAt == nil, case .string(let text) = field.value else { return nil }
            return EventTag(id: field.id, text: text, createdAt: field.createdAt, deletedAt: nil)
        }
    }

    func allEventTagFields(forEventUUID uuid: String) -> [SidecarField] {
        tagFieldsByEventUUID[uuid.lowercased()] ?? []
    }

    func eventUUID(forEventKitID eventKitID: String) async -> UUID? {
        events.first { $0.eventKitID == eventKitID }?.id
    }

    func addEventTag(text: String, forEventUUID uuid: String) throws -> UUID {
        tagWriteEventUUIDs.append(uuid)
        let tagID = UUID()
        tagFieldsByEventUUID[uuid.lowercased(), default: []].append(SidecarField(
            id: tagID, field: "tag", type: .note, value: .string(text),
            createdAt: Date(), modifiedAt: Date(),
            modifiedBy: Sentinels.deviceID, deletedAt: nil))
        return tagID
    }

    func editEventTag(id: UUID, text: String, forEventUUID uuid: String) throws {
        tagWriteEventUUIDs.append(uuid)
        let key = uuid.lowercased()
        guard var list = tagFieldsByEventUUID[key],
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        let old = list[index]
        list[index] = SidecarField(
            id: old.id, field: old.field, type: old.type, value: .string(text),
            createdAt: old.createdAt, modifiedAt: Date(),
            modifiedBy: Sentinels.deviceID, deletedAt: nil)
        tagFieldsByEventUUID[key] = list
    }

    func deleteEventTag(id: UUID, forEventUUID uuid: String) throws {
        tagWriteEventUUIDs.append(uuid)
        let key = uuid.lowercased()
        guard var list = tagFieldsByEventUUID[key],
              let index = list.firstIndex(where: { $0.id == id }),
              list[index].deletedAt == nil else { return }
        let old = list[index]
        let now = Date()
        list[index] = SidecarField(
            id: old.id, field: old.field, type: old.type, value: old.value,
            createdAt: old.createdAt, modifiedAt: now,
            modifiedBy: Sentinels.deviceID, deletedAt: now)
        tagFieldsByEventUUID[key] = list
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

    func importGuide(from snapshot: MapsGuideURL.Snapshot, sourceURL: String?) throws -> UUID {
        let guide = MapsGuide(
            id: UUID(), name: snapshot.name, sourceURL: sourceURL, createdAt: Date())
        guides.append(guide)
        for entry in snapshot.entries {
            places.append(MapsPlace(
                id: UUID(), guideID: guide.id,
                name: entry.address ?? "",
                address: entry.address,
                latitude: entry.latitude, longitude: entry.longitude))
        }
        return guide.id
    }

    func deleteGuide(uuid: String) throws {
        guides.removeAll { $0.id.uuidString.lowercased() == uuid.lowercased() }
        places.removeAll { $0.guideID.uuidString.lowercased() == uuid.lowercased() }
    }

    func reorderPlaces(inGuide guideID: UUID, orderedIDs: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        var reordered: [MapsPlace] = places.filter { $0.guideID != guideID }
        reordered.append(contentsOf: orderedIDs.compactMap { byID[$0] })
        places = reordered
    }

    func deletePlace(uuid: String) throws {
        places.removeAll { $0.id.uuidString.lowercased() == uuid.lowercased() }
    }
}

@MainActor
final class FakeGateSource: MCPGateSource {
    /// Read-only by default — the fixture's stand-in for a user who has
    /// opted in to reads but not writes; write tests flip to `.readWrite`
    /// the way the user's setting would.
    var mcpAccess: MCPAccessMode = .readOnly
    var cliAccess: MCPAccessMode = .readOnly
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
    let confirmations: FakeConfirmationSource
    let audit: MCPAuditLog

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
    /// nil-identity fingerprint path and the first-write mint).
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

    /// A temp-file audit log, unique per fixture.
    static func makeAuditLog() -> MCPAuditLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mcp-audit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
        return MCPAuditLog(fileURL: url)
    }

    @MainActor
    static func make(
        writeLimitPerWindow: Int = 30,
        writeWindowSeconds: TimeInterval = 60
    ) -> Fixture {
        let contacts = FakeContactSource()
        let events = FakeEventSource()
        let guides = FakeGuideSource()
        let gates = FakeGateSource()
        let confirmations = FakeConfirmationSource()
        let audit = makeAuditLog()

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
        contacts.linksByID[personLink.id] = personLink
        contacts.linksByID[organizationLink.id] = organizationLink
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
        events.tagFieldsByEventUUID[gala.id.uuidString.lowercased()] = [
            SidecarField(
                id: UUID(), field: "tag", type: .note, value: .string("fundraiser"),
                createdAt: Date(timeIntervalSince1970: 1_750_000_000),
                modifiedAt: Date(timeIntervalSince1970: 1_750_000_000),
                modifiedBy: Sentinels.deviceID, deletedAt: nil)
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
            contacts: contacts, events: events, guides: guides, gates: gates,
            confirmations: confirmations,
            audit: audit,
            writeLimitPerWindow: writeLimitPerWindow,
            writeWindowSeconds: writeWindowSeconds)
        return Fixture(
            dispatcher: dispatcher, contacts: contacts, events: events,
            guides: guides, gates: gates, confirmations: confirmations, audit: audit)
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
