import Foundation
import XCTest
import GuessWhoSync
import GuessWhoSyncTesting
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

/// Records accidental use of a repository/storage semantic that this legacy
/// source intentionally no longer models. Non-throwing protocol requirements
/// still need a value, so they return a neutral fallback *after* recording the
/// XCTest failure. Throwing requirements record the same failure and throw.
private struct UnexpectedLegacySemanticPathError: Error {
    let path: String
}

@MainActor
private func unexpectedLegacySemanticPath<T>(
    _ path: String,
    returning fallback: T,
    file: StaticString = #filePath,
    line: UInt = #line
) -> T {
    XCTFail(
        "LegacyScriptedContactSource does not model production semantic: \(path)",
        file: file,
        line: line)
    return fallback
}

@MainActor
private func throwUnexpectedLegacySemanticPath(
    _ path: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Never {
    XCTFail(
        "Legacy scripted source does not model production semantic: \(path)",
        file: file,
        line: line)
    throw UnexpectedLegacySemanticPathError(path: path)
}

/// Legacy scripted contact source used only where a test needs a boundary
/// fault or an identity-race scenario that `RecordingContactStore` cannot
/// express. It is deliberately *not* a repository conformance harness.
///
/// Matching, sorting, department rename, favorite persistence/CAS, group
/// favorite state, and photo snapshot assertions must use
/// `MCPProductionFixture`. The remaining identity/link/sidecar simulations
/// support older, separately-scoped dispatcher race tests and are named here
/// so no caller can mistake them for production semantics.
@MainActor
final class LegacyScriptedContactSource: MCPContactSource {
    var contacts: [Contact] = []
    private(set) var allContactsReadCount = 0
    var groups: [ContactGroup] = []
    private(set) var fetchGroupsCallCount = 0
    var membersByGroup: [String: [Contact]] = [:]
    var groupWriteError: (any Error)?
    var authorizationStatus: StoreAuthorizationStatus = .authorized
    private(set) var groupCreateCount = 0
    /// Explicit results used only when a scripted CRUD gate/error test needs
    /// the dispatcher to decorate a returned group. Unconfigured reads fail.
    var scriptedGroupFavoriteReadResults: [Bool] = []
    var notesByEffectiveID: [String: [ContactNote]] = [:]
    var fieldsByEffectiveID: [String: [SidecarField]] = [:]
    var linksByID: [UUID: Link] = [:]
    var favoriteEffectiveIDs: Set<String> = []

    /// When set, EVERY link method routes through this REAL engine (over a
    /// real temp-directory store) instead of the in-memory maps — the link
    /// tests' production pathway. This legacy source still scripts the contact
    /// book instead of using the production repository with a substituted
    /// `ContactStoreProtocol` boundary; the identity resolve-or-mint simulation
    /// in `effectiveWriteID` mirrors how the real repository funnels
    /// resolve-or-mint before the engine write.
    var linkEngine: GuessWhoSync?

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

    var allContacts: [Contact] {
        allContactsReadCount += 1
        return contacts
    }

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
        if let engine = linkEngine {
            // Mirrors ContactsRepository.links(for:): unreconciled contacts
            // hold no links; live contact↔contact links only.
            guard let guessWhoID = id.restorationToken.guessWhoID else { return [] }
            let endpoint = SidecarKey(kind: .contact, id: guessWhoID)
            let all = (try? await engine.links(at: endpoint)) ?? []
            return all
                .filter { link in
                    guard link.deletedAt == nil else { return false }
                    let far = link.endpointA == endpoint ? link.endpointB : link.endpointA
                    return far.kind == .contact
                }
                .sorted { $0.createdAt < $1.createdAt }
        }
        let effective = effectiveID(id)
        return linksByID.values
            .filter { link in
                link.deletedAt == nil
                    && (link.endpointA.id == effective || link.endpointB.id == effective)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func link(id linkID: UUID) -> Link? {
        if let engine = linkEngine {
            return (try? engine.link(id: linkID)) ?? nil
        }
        return linksByID[linkID]
    }

    func isFavorite(_ id: ContactID) -> Bool {
        favoriteEffectiveIDs.contains(effectiveID(id))
    }

    func fetchGroups() async -> [ContactGroup] {
        fetchGroupsCallCount += 1
        return groups
    }

    func members(ofGroup groupLocalID: String) async -> [Contact] {
        membersByGroup[groupLocalID] ?? []
    }

    func contactsAssociated(with organization: Contact) -> [Contact] {
        unexpectedLegacySemanticPath(
            "ContactsRepository.contactsAssociated(with:)", returning: [])
    }

    func departments(in organization: Contact) -> [String] {
        unexpectedLegacySemanticPath(
            "ContactsRepository.departments(in:)", returning: [])
    }

    func contactsAssociated(with organization: Contact, inDepartment department: String) -> [Contact] {
        unexpectedLegacySemanticPath(
            "ContactsRepository.contactsAssociated(with:inDepartment:)", returning: [])
    }

    func contactPhotoData(for id: ContactID, kind: ContactPhotoKind) async throws -> ContactPhoto? {
        try throwUnexpectedLegacySemanticPath(
            "ContactsRepository.contactPhotoData(for:kind:)")
    }

    func groups(containing contact: Contact) async -> [ContactGroup] {
        unexpectedLegacySemanticPath(
            "ContactsRepository.groups(containing:)", returning: [])
    }

    func isGroupFavorite(_ group: ContactGroup) -> Bool {
        guard !scriptedGroupFavoriteReadResults.isEmpty else {
            return unexpectedLegacySemanticPath(
                "ContactsRepository.isGroupFavorite", returning: false)
        }
        return scriptedGroupFavoriteReadResults.removeFirst()
    }

    func group(forFavoriteID id: String) -> ContactGroup? {
        // This generic fake has no group-identity sidecar model. A seeded raw
        // group identifier therefore models a legacy favorite and is correctly
        // unavailable after the durable group-UUID change.
        nil
    }

    // MARK: Writes

    func createGroup(name: String) async throws -> ContactGroup {
        if let groupWriteError { throw groupWriteError }
        groupCreateCount += 1
        let group = ContactGroup(localID: "fake-group-\(groupCreateCount)", name: name)
        groups.append(group)
        return group
    }

    func renameGroup(_ group: ContactGroup, to name: String) async throws {
        if let groupWriteError { throw groupWriteError }
        guard let index = groups.firstIndex(where: { $0.localID == group.localID }) else {
            throw ContactStoreError.groupNotFound(localID: group.localID)
        }
        groups[index] = ContactGroup(localID: group.localID, name: name)
    }

    func deleteGroup(_ group: ContactGroup) async throws {
        if let groupWriteError { throw groupWriteError }
        guard groups.contains(where: { $0.localID == group.localID }) else {
            throw ContactStoreError.groupNotFound(localID: group.localID)
        }
        groups.removeAll { $0.localID == group.localID }
        membersByGroup[group.localID] = nil
    }

    func addContacts(_ requested: [Contact], toGroup group: ContactGroup) async throws {
        try applyMembership(.addition, requested: requested, group: group)
    }

    func removeContacts(_ requested: [Contact], fromGroup group: ContactGroup) async throws {
        try applyMembership(.removal, requested: requested, group: group)
    }

    private func applyMembership(
        _ change: GroupMembershipChange,
        requested: [Contact],
        group: ContactGroup
    ) throws {
        try throwUnexpectedLegacySemanticPath(
            "ContactsRepository group membership mutation")
    }

    func setGroupFavorite(_ favorite: Bool, for group: ContactGroup) async throws -> Bool {
        try throwUnexpectedLegacySemanticPath(
            "ContactsRepository.setGroupFavorite")
    }

    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        authorizationStatus
    }

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
        if let engine = linkEngine {
            return try engine.addLink(
                from: SidecarKey(kind: .contact, id: aKey),
                to: SidecarKey(kind: .contact, id: bKey),
                note: note)
        }
        let now = Date()
        let link = Link(
            id: UUID(),
            endpointA: SidecarKey(kind: .contact, id: aKey),
            endpointB: SidecarKey(kind: .contact, id: bKey),
            note: note, createdAt: now, modifiedAt: now,
            modifiedBy: Sentinels.deviceID)
        linksByID[link.id] = link
        return link
    }

    func addEventLink(for id: ContactID, eventUUID: String, note: String) async throws -> Link {
        let key = try await effectiveWriteID(id)
        if let engine = linkEngine {
            return try engine.addLink(
                from: SidecarKey(kind: .contact, id: key),
                to: SidecarKey(kind: .event, id: eventUUID),
                note: note)
        }
        let now = Date()
        let link = Link(
            id: UUID(),
            endpointA: SidecarKey(kind: .contact, id: key),
            endpointB: SidecarKey(kind: .event, id: eventUUID),
            note: note, createdAt: now, modifiedAt: now,
            modifiedBy: Sentinels.deviceID)
        linksByID[link.id] = link
        return link
    }

    func addPlaceLink(for id: ContactID, placeUUID: String, note: String) async throws -> Link {
        let key = try await effectiveWriteID(id)
        if let engine = linkEngine {
            return try engine.addLink(
                from: SidecarKey(kind: .contact, id: key),
                to: SidecarKey(kind: .place, id: placeUUID),
                note: note)
        }
        let now = Date()
        let link = Link(
            id: UUID(),
            endpointA: SidecarKey(kind: .contact, id: key),
            endpointB: SidecarKey(kind: .place, id: placeUUID),
            note: note, createdAt: now, modifiedAt: now,
            modifiedBy: Sentinels.deviceID)
        linksByID[link.id] = link
        return link
    }

    func setLinkNote(id linkID: UUID, note: String) throws {
        if unavailable { throw SidecarUnavailableError() }
        if let engine = linkEngine {
            try engine.setLinkNote(id: linkID, note: note)
            return
        }
        guard var link = linksByID[linkID] else { return }
        link.note = note
        link.modifiedAt = Date()
        link.deletedAt = nil // undelete, mirroring the engine
        linksByID[linkID] = link
    }

    func removeLink(id linkID: UUID) throws {
        if unavailable { throw SidecarUnavailableError() }
        if let engine = linkEngine {
            try engine.removeLink(id: linkID)
            return
        }
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
    /// A one-shot error specifically at save time, after editableContact
    /// succeeded. Structured-entry tests use this to prove an in-memory
    /// mutation is not published when the actual save fails.
    var nextSaveContactError: Error?
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
        if let error = nextSaveContactError {
            nextSaveContactError = nil
            throw error
        }
        try takeContactStoreError()
        guard let index = contacts.firstIndex(where: {
            $0.contactID.restorationToken.localID == edited.contactID.restorationToken.localID
        }) else { return }
        contacts[index] = edited
    }

    func setContactPhoto(for id: ContactID, imageData: Data?) async throws -> Bool {
        try throwUnexpectedLegacySemanticPath(
            "ContactsRepository.setContactPhoto")
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

    func renameDepartment(
        from oldName: String, to newName: String, in organization: Contact
    ) async throws -> Int {
        try throwUnexpectedLegacySemanticPath(
            "ContactsRepository.renameDepartment")
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

/// The dispatcher's event source over a REAL `GuessWhoSync` — the same thin
/// adapter shape as the app's `SyncService` conformance, so the events_* and
/// event-tag tools exercise the production engine + on-disk store, not a
/// reimplementation of tag storage.
///
/// The ONE carve-out is the EventKit-visibility seam `eventKitOnlyEvents`:
/// headless `swift test` has NO calendar, so a "system-calendar-only" event
/// (visible in Calendar.app, no GuessWho record yet) can't come from the
/// engine. This single map stands in for that boundary so the Option-B path —
/// a tag/favorite write on an un-adopted calendar event must answer the typed
/// `requiresAppAction` error and MINT NOTHING — stays reproducible. Everything
/// else (tag add/edit/delete + tombstone-inclusive `allEventTagFields`,
/// `event(uuid:)`, the `eventUUID` reverse lookup, the sidecar side of the
/// windowed read) rides the real engine.
@MainActor
final class EngineEventSource: MCPEventSource {
    let engine: GuessWhoSync
    /// The lone EventKit-visibility seam (see the type doc). Keyed by EventKit
    /// identifier; each event's `id` is `Event.stableID(forEventKitID:)`, so it
    /// renders as the derived `e-…` wire id and never as a record UUID.
    var eventKitOnlyEvents: [String: Event] = [:]

    nonisolated init(engine: GuessWhoSync) {
        self.engine = engine
    }

    func fetchEventsRange(from start: Date, to end: Date) async -> [Event] {
        // No calendar headless: the engine window never includes EventKit
        // (`includeEventKit: false`). The seam's calendar-only events are merged
        // in as ephemeral rows to stand in for what EventKit would surface. The
        // filter is a simple start-in-window test (not EventKit's start/end
        // overlap) — sufficient because the seam holds only point-in-time events
        // and no test probes the window edges.
        let sidecar = (try? await engine.eventsWindow(
            from: start, to: end, includeEventKit: false)) ?? []
        let calendarOnly = eventKitOnlyEvents.values.filter {
            $0.startDate >= start && $0.startDate <= end
        }
        return sidecar + calendarOnly
    }

    func event(uuid: String) -> Event? {
        (try? engine.event(at: SidecarKey(kind: .event, id: uuid))) ?? nil
    }

    func eventKitEvent(eventKitID: String) -> Event? {
        eventKitOnlyEvents[eventKitID]
    }

    func eventTags(forEventUUID uuid: String) -> [EventTag] {
        (try? engine.tags(at: SidecarKey(kind: .event, id: uuid))) ?? []
    }

    func allEventTagFields(forEventUUID uuid: String) -> [SidecarField] {
        // Same projection as `SyncService.allEventTagFields`: the raw tag cells
        // INCLUDING tombstones (each carrying its `modifiedAt`/`deletedAt`
        // stamps), for the audit trail + Recently Deleted surface.
        let raw = (try? engine.fields(at: SidecarKey(kind: .event, id: uuid))) ?? []
        return raw.filter { $0.field == GuessWhoSync.eventTagFieldName && $0.type == .note }
    }

    func eventUUID(forEventKitID eventKitID: String) async -> UUID? {
        (try? await engine.eventUUID(forEventKitID: eventKitID)) ?? nil
    }

    @discardableResult
    func addEventTag(text: String, forEventUUID uuid: String) throws -> UUID {
        try engine.addTag(at: SidecarKey(kind: .event, id: uuid), text: text)
    }

    func editEventTag(id: UUID, text: String, forEventUUID uuid: String) throws {
        try engine.editTag(at: SidecarKey(kind: .event, id: uuid), id: id, text: text)
    }

    func deleteEventTag(id: UUID, forEventUUID uuid: String) throws {
        try engine.deleteTag(at: SidecarKey(kind: .event, id: uuid), id: id)
    }
}

/// The dispatcher's guide/place source over a REAL `GuessWhoSync` + a REAL
/// `FavoritesStore` — the same thin adapter shape as the app's `SyncService`
/// conformance, so the guides_*/places_* tools exercise the production engine
/// + on-disk store, not a reimplementation of guide/place semantics.
///
/// `allGuidesCallCount`/`allPlacesCallCount` are pure test observations (the
/// favorites-reorder test proves the dispatcher reads each collection exactly
/// once); the counter increments before delegating to the real engine, so the
/// engine is still underneath. `favorites()` reads the SAME real
/// `FavoritesStore` the guide/place UI reads.
@MainActor
final class EngineGuideSource: MCPGuideSource {
    let engine: GuessWhoSync
    let favoritesStore: FavoritesStore
    private(set) var allGuidesCallCount = 0
    private(set) var allPlacesCallCount = 0

    // MainActor-isolated (not `nonisolated` like the other adapters) because
    // `FavoritesStore` is not `Sendable`; both fixtures build this on the main
    // actor anyway.
    init(engine: GuessWhoSync, favoritesStore: FavoritesStore) {
        self.engine = engine
        self.favoritesStore = favoritesStore
    }

    func allGuides() async -> [MapsGuide] {
        allGuidesCallCount += 1
        return (try? await engine.allGuides()) ?? []
    }

    func allPlaces() async -> [MapsPlace] {
        allPlacesCallCount += 1
        return (try? await engine.allPlaces()) ?? []
    }

    func places(inGuide guideID: UUID) async -> [MapsPlace] {
        (try? await engine.places(inGuide: guideID)) ?? []
    }

    func guides(containingPlace place: MapsPlace) async -> [MapsGuide] {
        // Mirrors `SyncService.guides(containingPlace:)`: derive the place's
        // street needle and match it against every guide/place. Reads the
        // engine directly (not the counted `allGuides`/`allPlaces` above), so
        // this reverse lookup doesn't perturb the call-count observation —
        // exactly as the retired fake did.
        guard let needle = GuideAddressMatcher.streetNeedle(for: place) else { return [] }
        let guides = (try? await engine.allGuides()) ?? []
        let places = (try? await engine.allPlaces()) ?? []
        return GuideAddressMatcher.guides(
            containingAnyOf: [needle], guides: guides, places: places
        ).map(\.guide)
    }

    func favorites() -> [Favorite] {
        // The SAME real store the guide/place UI reads. Filter to guide/place
        // kinds, matching the retired fake's contract (guide/place read tools
        // only care about their own favorite kinds).
        let all = (try? favoritesStore.loadAll()) ?? []
        return all.filter { $0.kind == .guide || $0.kind == .place }
    }

    @discardableResult
    func importGuide(from snapshot: MapsGuideURL.Snapshot, sourceURL: String?) throws -> UUID {
        try engine.importGuide(from: snapshot, sourceURL: sourceURL)
    }

    func deleteGuide(uuid: String) throws {
        try engine.deleteGuide(at: SidecarKey(kind: .guide, id: uuid))
    }

    func reorderPlaces(inGuide guideID: UUID, orderedIDs: [UUID]) {
        // Best-effort by design, mirroring `SyncService.reorderPlaces`.
        try? engine.reorderPlaces(inGuide: guideID, orderedIDs: orderedIDs)
    }

    func deletePlace(uuid: String) throws {
        try engine.deletePlace(at: SidecarKey(kind: .place, id: uuid))
    }
}

/// Scripted boundary used only for dispatcher fault/race observations.
///
/// It intentionally does not reproduce FavoritesStore canonicalization,
/// idempotency, validation, or compare-and-swap. Tests asserting those rules
/// use MCPProductionFixture and the real on-disk store.
@MainActor
final class FaultInjectingFavoriteSource: MCPFavoriteSource {
    var items: [Favorite] = []
    private(set) var loadCallCount = 0
    private(set) var setCallCount = 0
    private(set) var reorderCallCount = 0
    /// Explicit outcomes for the few gate/budget tests that need a successful
    /// favorite-source call without asserting storage behavior. An unconfigured
    /// call is an accidental semantic dependency and fails loudly.
    var scriptedSetResults: [Bool] = []
    /// Explicitly allows the one successful reorder used to observe that a
    /// non-contact snapshot avoids loading Contacts. CAS/order semantics are
    /// never modeled here.
    var acceptNextReorder = false
    var mutateBeforeNextReorder = false
    var failReads = false
    var onLoadFavorites: (() -> Void)?

    nonisolated init() {}

    func loadFavorites() throws -> [Favorite] {
        loadCallCount += 1
        onLoadFavorites?()
        if failReads { throw SidecarUnavailableError() }
        return items
    }

    func setFavorite(kind: FavoriteKind, id: String, favorite: Bool) throws -> Bool {
        guard !scriptedSetResults.isEmpty else {
            try throwUnexpectedLegacySemanticPath("FavoritesStore.set")
        }
        setCallCount += 1
        return scriptedSetResults.removeFirst()
    }

    func reorderFavorites(expected: [Favorite], reordered: [Favorite]) throws -> Bool {
        if mutateBeforeNextReorder {
            mutateBeforeNextReorder = false
            items.append(Favorite(kind: .guide, id: UUID().uuidString, addedAt: Date()))
            throw FavoritesStoreMutationError.changed
        }
        guard acceptNextReorder else {
            try throwUnexpectedLegacySemanticPath("FavoritesStore.reorder")
        }
        acceptNextReorder = false
        reorderCallCount += 1
        return true
    }
}

/// The dispatcher's link source over a REAL `GuessWhoSync` — the same thin
/// adapter shape as the app's `SyncService` conformance, so the links_*
/// tools exercise the production engine + on-disk store, not a fake.
@MainActor
final class EngineLinkSource: MCPLinkSource {
    let engine: GuessWhoSync

    nonisolated init(engine: GuessWhoSync) {
        self.engine = engine
    }

    func links(at endpoint: SidecarKey) async -> [Link] {
        ((try? await engine.links(at: endpoint)) ?? []).filter { $0.deletedAt == nil }
    }

    func link(id: UUID) -> Link? {
        (try? engine.link(id: id)) ?? nil
    }

    func addLink(from: SidecarKey, to: SidecarKey, note: String) throws -> Link {
        try engine.addLink(from: from, to: to, note: note)
    }

    func removeLink(id: UUID) throws {
        try engine.removeLink(id: id)
    }
}

/// REAL-engine seeding shared by the fixtures and the migrated guide/place/
/// event tests. Every record these mint is a genuine sidecar in the shared
/// `GuessWhoSync` store; callers read the returned projections to learn the
/// engine-minted UUIDs and derived timestamps instead of hardcoding them.
enum EngineSeed {
    enum SeedError: Error { case guideVanished }

    /// Create a manual (sidecar-only) event and return its minted UUID.
    @discardableResult
    static func manualEvent(
        _ engine: GuessWhoSync, title: String,
        start: Date, end: Date, isAllDay: Bool = false, location: String? = nil
    ) throws -> UUID {
        try engine.createManualEvent(
            title: title, startDate: start, endDate: end,
            isAllDay: isAllDay, location: location)
    }

    /// Mint a sidecar event that points at an EventKit id (an "adopted"
    /// calendar event). Returns the minted record UUID.
    @discardableResult
    static func adoptedEvent(
        _ engine: GuessWhoSync, eventKitID: String, title: String,
        start: Date, end: Date
    ) throws -> UUID {
        let snapshot = Event(
            id: UUID(), eventKitID: eventKitID, title: title,
            startDate: start, endDate: end)
        return try engine.linkEvent(toEventKitID: eventKitID, snapshot: snapshot)
    }

    /// Import a guide + its places and return the engine's projection of both.
    @discardableResult
    static func guide(
        _ engine: GuessWhoSync, name: String, sourceURL: String? = nil,
        entries: [MapsGuideURL.Entry]
    ) throws -> (guide: MapsGuide, places: [MapsPlace]) {
        let id = try engine.importGuide(
            from: MapsGuideURL.Snapshot(name: name, entries: entries),
            sourceURL: sourceURL)
        guard let guide = try engine.guide(at: SidecarKey(kind: .guide, id: id.uuidString)) else {
            throw SeedError.guideVanished
        }
        return (guide, try engine.places(inGuide: id))
    }

    /// Re-read a guide's engine projection (for asserting the wire mapping
    /// against the same values the dispatcher will read).
    static func guide(_ engine: GuessWhoSync, id: UUID) throws -> MapsGuide? {
        try engine.guide(at: SidecarKey(kind: .guide, id: id.uuidString))
    }

    /// Re-read a place's engine projection.
    static func place(_ engine: GuessWhoSync, id: UUID, inGuide guideID: UUID) throws -> MapsPlace? {
        try engine.places(inGuide: guideID).first { $0.id == id }
    }

    /// Soft-delete every live guide (and its places) so a test can start from a
    /// clean guide set before seeding its own — the engine equivalent of the
    /// retired fake's `guides = [...]` wholesale replacement.
    static func clearGuides(_ engine: GuessWhoSync) throws {
        for guide in try engine.allGuides() {
            try engine.deleteGuide(at: SidecarKey(kind: .guide, id: guide.id.uuidString))
        }
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
    let contacts: LegacyScriptedContactSource
    /// Events + guides/places now ride the REAL `GuessWhoSync` engine (the
    /// SAME `linkEngine` store the links surface uses), so event-tag and
    /// guide/place semantics are exercised in production code. The event
    /// source keeps ONE minimal EventKit-visibility seam (see
    /// `EngineEventSource`).
    let events: EngineEventSource
    let guides: EngineGuideSource
    let favorites: FaultInjectingFavoriteSource
    /// REAL storage: a production `GuessWhoSync` over a real temp-directory
    /// `FileSystemSidecarStore` — links, events, and guides/places all live
    /// here. The links_* tests set `contacts.linkEngine = linkEngine` so the
    /// contact-endpoint link surface also runs against it; the default fixture
    /// leaves the scripted contact source's canned in-memory links in place for
    /// the pre-existing read-tool tests.
    let links: EngineLinkSource
    let linkEngine: GuessWhoSync
    /// The REAL on-disk `FavoritesStore` the guide/place read tools read for
    /// `isFavorite`. Distinct from the fault-injecting `favorites` source that
    /// backs the favorites_* tools (the two need not be the same store here —
    /// unlike production — because the fault-injection tests never read the
    /// guide/place `isFavorite` projection).
    let guidesFavoritesStore: FavoritesStore
    let gates: FakeGateSource
    let confirmations: FakeConfirmationSource
    let audit: MCPAuditLog

    /// The seeded records' engine-minted identities, exposed so tests can
    /// address them without reaching through a fake collection.
    let galaEventUUID: UUID
    let coffeeGuideID: UUID
    let bluebirdPlaceID: UUID

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

    /// A REAL engine over a REAL on-disk store in a unique temp directory —
    /// the production link/event/guide write/read path, no TCC needed.
    static func makeLinkEngine() -> GuessWhoSync {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mcp-link-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return GuessWhoSync(
            contacts: InMemoryContactStore(),
            events: InMemoryEventStore(),
            sidecars: FileSystemSidecarStore(root: root),
            deviceID: Sentinels.deviceID)
    }

    /// A REAL on-disk `FavoritesStore` in a unique temp directory — backs the
    /// guide/place read tools' `isFavorite` projection.
    static func makeFavoritesStore() -> FavoritesStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-mcp-guide-favorites-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FavoritesStore(root: root)
    }

    @MainActor
    static func make(
        writeLimitPerWindow: Int = 30,
        writeWindowSeconds: TimeInterval = 60
    ) -> Fixture {
        let contacts = LegacyScriptedContactSource()
        let linkEngine = makeLinkEngine()
        let guidesFavoritesStore = makeFavoritesStore()
        let events = EngineEventSource(engine: linkEngine)
        let guides = EngineGuideSource(engine: linkEngine, favoritesStore: guidesFavoritesStore)
        let favorites = FaultInjectingFavoriteSource()
        let links = EngineLinkSource(engine: linkEngine)
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
        contacts.favoriteEffectiveIDs = [janeKey]
        favorites.items = [
            Favorite(
                kind: .contact, id: janeKey,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        contacts.groups = [ContactGroup(localID: "CNGroup-LOCAL-1", name: "Museum Friends")]
        contacts.membersByGroup["CNGroup-LOCAL-1"] = [jane]

        // The gala is a REAL manual (sidecar-only) event minted by the engine;
        // its tag "fundraiser" is a REAL engine tag cell. `createManualEvent`
        // carries title/dates/location only (no attendees/calendarName/notes) —
        // no fixture-backed test asserts those on the gala.
        let galaEventUUID = try! EngineSeed.manualEvent(
            linkEngine, title: "Museum Gala",
            start: Date(timeIntervalSince1970: 1_760_000_000),
            end: Date(timeIntervalSince1970: 1_760_007_200),
            location: "City Museum")
        try! linkEngine.addTag(
            at: SidecarKey(kind: .event, id: galaEventUUID.uuidString), text: "fundraiser")

        // The dentist is the ONE EventKit-visibility seam: a system-calendar
        // event with no GuessWho record (headless has no calendar to mint one).
        events.eventKitOnlyEvents["EK-SENTINEL-42"] = Event(
            id: Event.stableID(forEventKitID: "EK-SENTINEL-42"),
            eventKitID: "EK-SENTINEL-42",
            title: "Dentist",
            startDate: Date(timeIntervalSince1970: 1_760_100_000),
            endDate: Date(timeIntervalSince1970: 1_760_103_600))

        // A REAL guide + place minted by the engine's import path. The place is
        // resolved to carry the "Bluebird Espresso" name/address the retired
        // fake gave it.
        let (coffeeGuide, coffeePlaces) = try! EngineSeed.guide(
            linkEngine, name: "Coffee Crawl",
            sourceURL: "https://guides.apple/example",
            entries: [MapsGuideURL.Entry(
                address: "12 Main St", latitude: 30.27, longitude: -97.74)])
        let bluebirdPlaceID = coffeePlaces[0].id
        try! linkEngine.markPlaceResolved(
            at: SidecarKey(kind: .place, id: bluebirdPlaceID.uuidString),
            name: "Bluebird Espresso", address: "12 Main St",
            latitude: 30.27, longitude: -97.74)

        let dispatcher = ToolDispatcher(
            contacts: contacts, events: events, guides: guides,
            favorites: favorites, links: links, gates: gates,
            confirmations: confirmations,
            audit: audit,
            writeLimitPerWindow: writeLimitPerWindow,
            writeWindowSeconds: writeWindowSeconds)
        return Fixture(
            dispatcher: dispatcher, contacts: contacts, events: events,
            guides: guides, favorites: favorites, links: links,
            linkEngine: linkEngine, guidesFavoritesStore: guidesFavoritesStore,
            gates: gates, confirmations: confirmations, audit: audit,
            galaEventUUID: galaEventUUID, coffeeGuideID: coffeeGuide.id,
            bluebirdPlaceID: bluebirdPlaceID)
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
