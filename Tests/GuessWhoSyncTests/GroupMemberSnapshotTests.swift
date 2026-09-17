import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// A Contacts store whose group-member fetches can be made to fail, to wait, or
/// to return a chosen version of a contact — the conditions a folder's
/// multi-fetch member read has to survive.
actor ScriptedMembersContactStore: ContactStoreProtocol {
    struct FetchFailed: Error {}

    private let base: InMemoryContactStore
    private var failingGroups: Set<String> = []
    private var scriptedMembers: [String: [Contact]] = [:]
    private var gatedGroups: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var gateArrivalWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var fetchCounts: [String: Int] = [:]
    private var fetchDelay: Duration?

    init(contacts: [Contact] = []) {
        base = InMemoryContactStore(contacts: contacts)
    }

    func seedGroup(name: String, members: [String] = []) async throws -> ContactGroup {
        let group = try await base.createGroup(name: name)
        for member in members {
            try await base.addMember(contactLocalID: member, toGroup: group.localID)
        }
        return group
    }

    func fail(_ group: ContactGroup) { failingGroups.insert(group.localID) }
    func succeed(_ group: ContactGroup) { failingGroups.remove(group.localID) }
    func script(_ members: [Contact], for group: ContactGroup) { scriptedMembers[group.localID] = members }
    func gate(_ group: ContactGroup) { gatedGroups.insert(group.localID) }
    func delayEveryFetch(by delay: Duration) { fetchDelay = delay }

    func waitUntilGated(_ group: ContactGroup) async {
        guard gates[group.localID] == nil else { return }
        await withCheckedContinuation { gateArrivalWaiters[group.localID, default: []].append($0) }
    }

    func release(_ group: ContactGroup) {
        gatedGroups.remove(group.localID)
        gates.removeValue(forKey: group.localID)?.resume()
    }

    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        fetchCounts[groupLocalID, default: 0] += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if gatedGroups.contains(groupLocalID) {
            await withCheckedContinuation { continuation in
                gates[groupLocalID] = continuation
                gateArrivalWaiters.removeValue(forKey: groupLocalID)?.forEach { $0.resume() }
            }
        }
        if let fetchDelay { try? await Task.sleep(for: fetchDelay) }
        if failingGroups.contains(groupLocalID) { throw FetchFailed() }
        if let scripted = scriptedMembers[groupLocalID] { return scripted }
        return try await base.fetchMembers(ofGroup: groupLocalID)
    }

    func fetchAll() async throws -> [Contact] { try await base.fetchAll() }
    func fetch(localID: String) async throws -> Contact? { try await base.fetch(localID: localID) }
    func save(_ contact: Contact) async throws { try await base.save(contact) }
    func delete(localID: String) async throws { try await base.delete(localID: localID) }
    func create(_ contact: Contact) async throws -> Contact { try await base.create(contact) }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        await base.contactsAuthorizationStatus()
    }
    func requestContactsAccess() async -> StoreAccessResult { await base.requestContactsAccess() }
    func changes(since token: Data?) async throws -> ContactChangeSet { try await base.changes(since: token) }
    func loadImageData(localID: String) async throws -> Data? { try await base.loadImageData(localID: localID) }
    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await base.loadThumbnailImageData(localID: localID)
    }
    func setImageData(localID: String, imageData: Data?) async throws {
        try await base.setImageData(localID: localID, imageData: imageData)
    }
    func fetchAllGroups() async throws -> [ContactGroup] { try await base.fetchAllGroups() }
    func fetchGroup(localID: String) async throws -> ContactGroup? { try await base.fetchGroup(localID: localID) }
    func createGroup(name: String) async throws -> ContactGroup { try await base.createGroup(name: name) }
    func renameGroup(localID: String, to name: String) async throws {
        try await base.renameGroup(localID: localID, to: name)
    }
    func deleteGroup(localID: String) async throws { try await base.deleteGroup(localID: localID) }
    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] {
        try await base.fetchMemberLocalIDs(ofGroup: groupLocalID)
    }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] {
        try await base.fetchGroupMemberships(contactLocalID: contactLocalID)
    }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {
        try await base.addMember(contactLocalID: contactLocalID, toGroup: groupLocalID)
    }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {
        try await base.removeMember(contactLocalID: contactLocalID, fromGroup: groupLocalID)
    }
}

/// The error-aware member read for a group or a folder
/// (`plans/group-folders.md`, delivery step 3).
@Suite("Group and folder member snapshots", .serialized)
@MainActor
struct GroupMemberSnapshotTests {
    private struct Fixture {
        let store: ScriptedMembersContactStore
        let sync: GuessWhoSync
        let repository: ContactsRepository
        let root: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture(contacts: [Contact]) throws -> Fixture {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/TestTemp", isDirectory: true)
            .appendingPathComponent("guesswho-member-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ScriptedMembersContactStore(contacts: contacts)
        let sync = GuessWhoSync(
            contacts: store, events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(), deviceID: "device-A")
        let repository = ContactsRepository(
            contacts: store, sync: sync, favorites: FavoritesStore(root: root),
            notificationCenter: NotificationCenter())
        return Fixture(store: store, sync: sync, repository: repository, root: root)
    }

    private func person(_ localID: String, guessWhoID: String? = nil) -> Contact {
        Contact(
            localID: localID,
            givenName: localID,
            urlAddresses: guessWhoID.map {
                [LabeledValue(label: "GuessWho", value: SidecarKey.guessWhoContactURLPrefix + $0)]
            } ?? [])
    }

    private let annID = "11111111-1111-4111-8111-111111111111"

    // MARK: - Scopes

    @Test
    func groupScopeReturnsTheGroupsDirectMembers() async throws {
        let fixture = try makeFixture(contacts: [person("ann"), person("bob")])
        defer { fixture.cleanup() }
        let work = try await fixture.store.seedGroup(name: "Work", members: ["ann"])
        let empty = try await fixture.store.seedGroup(name: "Empty")
        await fixture.repository.reload()
        await fixture.repository.loadGroups()

        let snapshot = await fixture.repository.memberSnapshot(for: .group(work))
        #expect(snapshot.contacts.map(\.localID) == ["ann"])
        #expect(snapshot.groups == [work])
        #expect(snapshot.isPartial == false)
        #expect(snapshot.emptiness == .notEmpty)
        #expect(fixture.repository.isCurrent(snapshot))

        let none = await fixture.repository.memberSnapshot(for: .group(empty))
        #expect(none.contacts.isEmpty)
        #expect(none.emptiness == .noMembers)
    }

    /// A folder covers every group beneath it, at any depth, and each person
    /// appears once with the groups that brought them in.
    @Test
    func folderScopeUnionsEveryDescendantGroupAndDeduplicates() async throws {
        let fixture = try makeFixture(contacts: [person("ann"), person("bob"), person("cy")])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        let immediate = try await fixture.store.seedGroup(name: "Immediate Family", members: ["ann", "bob"])
        let soccer = try await fixture.store.seedGroup(name: "Soccer Parents", members: ["bob", "cy"])
        _ = try await fixture.store.seedGroup(name: "Work", members: ["cy"])
        await repo.reload()
        await repo.loadGroups()
        let family = try await repo.createGroupFolder(name: "Family", inFolder: nil)
        let activities = try await repo.createGroupFolder(name: "Activities", inFolder: family)
        let emptyFolder = try await repo.createGroupFolder(name: "Nothing Here", inFolder: nil)
        try await repo.moveGroup(immediate, toFolder: family)
        try await repo.moveGroup(soccer, toFolder: activities)

        let snapshot = await repo.memberSnapshot(for: .folder(id: family))

        // Tree order: Activities (Soccer Parents) sorts before Immediate Family.
        #expect(snapshot.groups == [soccer, immediate])
        // Each person once. The test store keeps a group's members in a Set, so
        // only the order ACROSS groups is fixed: ann is reached last, through
        // Immediate Family alone.
        #expect(snapshot.contacts.count == 3)
        #expect(Set(snapshot.contacts.map(\.localID)) == ["ann", "bob", "cy"])
        #expect(snapshot.contacts.last?.localID == "ann")
        let bob = try #require(snapshot.contacts.first { $0.localID == "bob" })
        #expect(snapshot.contributingGroups[bob.contactID] == [soccer, immediate])
        #expect(snapshot.isPartial == false)
        // "Work" is outside the folder, so cy arrives only through Soccer Parents.
        let cy = try #require(snapshot.contacts.first { $0.localID == "cy" })
        #expect(snapshot.contributingGroups[cy.contactID] == [soccer])

        let nested = await repo.memberSnapshot(for: .folder(id: activities))
        #expect(Set(nested.contacts.map(\.localID)) == ["bob", "cy"])
        #expect(nested.contacts.count == 2)

        let nothing = await repo.memberSnapshot(for: .folder(id: emptyFolder))
        #expect(nothing.emptiness == .noGroups)
    }

    // MARK: - Failures

    /// A group that cannot be fetched is REPORTED. Its absence is never passed
    /// off as "no members", and the groups that did load still show.
    @Test
    func failedGroupMakesTheSnapshotPartialNotEmpty() async throws {
        let fixture = try makeFixture(contacts: [person("ann"), person("bob")])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        let good = try await fixture.store.seedGroup(name: "Good", members: ["ann"])
        let bad = try await fixture.store.seedGroup(name: "Bad", members: ["bob"])
        await repo.reload()
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Folder", inFolder: nil)
        try await repo.moveGroup(good, toFolder: folder)
        try await repo.moveGroup(bad, toFolder: folder)
        await fixture.store.fail(bad)

        let partial = await repo.memberSnapshot(for: .folder(id: folder))
        #expect(partial.contacts.map(\.localID) == ["ann"])
        #expect(partial.failedGroups == [bad])
        #expect(partial.isPartial)
        #expect(partial.emptiness == .notEmpty)

        await fixture.store.fail(good)
        let nothing = await repo.memberSnapshot(for: .folder(id: folder))
        #expect(nothing.contacts.isEmpty)
        #expect(nothing.emptiness == .unavailable)

        let single = await repo.memberSnapshot(for: .group(bad))
        #expect(single.failedGroups == [bad])
        #expect(single.emptiness == .unavailable)

        await fixture.store.succeed(bad)
        await fixture.store.succeed(good)
        let retried = await repo.memberSnapshot(for: .folder(id: folder))
        #expect(Set(retried.contacts.map(\.localID)) == ["ann", "bob"])
        #expect(retried.isPartial == false)
    }

    // MARK: - Order and identity do not depend on which fetch finishes last

    @Test
    func resultOrderIsTreeOrderEvenWhenTheFirstGroupFinishesLast() async throws {
        let fixture = try makeFixture(contacts: [person("ann"), person("bob")])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        let first = try await fixture.store.seedGroup(name: "Alpha", members: ["ann"])
        let second = try await fixture.store.seedGroup(name: "Beta", members: ["bob"])
        await repo.reload()
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Folder", inFolder: nil)
        try await repo.moveGroup(first, toFolder: folder)
        try await repo.moveGroup(second, toFolder: folder)
        await fixture.store.gate(first)

        async let pending = repo.memberSnapshot(for: .folder(id: folder))
        await fixture.store.waitUntilGated(first)
        // Beta has long since finished; Alpha is released last.
        try await Task.sleep(for: .milliseconds(50))
        await fixture.store.release(first)
        let snapshot = await pending

        #expect(snapshot.contacts.map(\.localID) == ["ann", "bob"])
    }

    /// Two fetches return the SAME person on either side of an identity change:
    /// one from before reconciliation gave the contact its GuessWho ID, one
    /// from after. The repository does not cache this contact, so neither fetch
    /// may simply win — above all not "whichever finished last." The record is
    /// read again, and the row carries its current identity either way.
    @Test(arguments: [true, false])
    func conflictingVersionsOfAnUncachedContactAreRereadNotRaced(staleFinishesLast: Bool) async throws {
        let fixture = try makeFixture(contacts: [person("ann", guessWhoID: annID)])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        let staleGroup = try await fixture.store.seedGroup(name: "Alpha", members: ["ann"])
        let freshGroup = try await fixture.store.seedGroup(name: "Beta", members: ["ann"])
        // No `reload()`: the repository's contact cache stays empty.
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Folder", inFolder: nil)
        try await repo.moveGroup(staleGroup, toFolder: folder)
        try await repo.moveGroup(freshGroup, toFolder: folder)
        await fixture.store.script([person("ann")], for: staleGroup)
        let gated = staleFinishesLast ? staleGroup : freshGroup
        await fixture.store.gate(gated)

        async let pending = repo.memberSnapshot(for: .folder(id: folder))
        await fixture.store.waitUntilGated(gated)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.store.release(gated)
        let snapshot = await pending

        let current = ContactID(contact: person("ann", guessWhoID: annID))
        #expect(snapshot.contacts.map(\.contactID) == [current])
        #expect(snapshot.contributingGroups[current] == [staleGroup, freshGroup])
    }

    /// When the repository DOES cache the contact, its record is the row: every
    /// other surface keys on that identity.
    @Test
    func cachedRecordIsTheRowEvenWhenAFetchReturnsAnOlderVersion() async throws {
        let fixture = try makeFixture(contacts: [person("ann", guessWhoID: annID)])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        let group = try await fixture.store.seedGroup(name: "Work", members: ["ann"])
        await repo.reload()
        await repo.loadGroups()
        await fixture.store.script([person("ann")], for: group)

        let snapshot = await repo.memberSnapshot(for: .group(group))

        #expect(snapshot.contacts.map(\.contactID) == [ContactID(contact: person("ann", guessWhoID: annID))])
    }

    // MARK: - Cost

    @Test
    func eachGroupIsFetchedOnceWithBoundedConcurrency() async throws {
        let fixture = try makeFixture(contacts: [person("ann")])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        var groups: [ContactGroup] = []
        for index in 0..<12 {
            groups.append(try await fixture.store.seedGroup(name: "Group \(index)", members: ["ann"]))
        }
        await repo.reload()
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Folder", inFolder: nil)
        for group in groups { try await repo.moveGroup(group, toFolder: folder) }
        await fixture.store.delayEveryFetch(by: .milliseconds(20))

        let snapshot = await repo.memberSnapshot(for: .folder(id: folder))

        #expect(snapshot.groups.count == 12)
        #expect(snapshot.contacts.map(\.localID) == ["ann"])
        let counts = await fixture.store.fetchCounts
        #expect(groups.allSatisfy { counts[$0.localID] == 1 })
        let peak = await fixture.store.maxInFlight
        #expect(peak > 1)
        #expect(peak <= 4)
    }

    /// A read is a read: it mints no identity for a contact or a group.
    @Test
    func readingMembersMintsNothing() async throws {
        let fixture = try makeFixture(contacts: [person("ann")])
        defer { fixture.cleanup() }
        let group = try await fixture.store.seedGroup(name: "Work", members: ["ann"])
        await fixture.repository.reload()
        await fixture.repository.loadGroups()

        _ = await fixture.repository.memberSnapshot(for: .group(group))

        #expect(try fixture.sync.allGroupIdentities().isEmpty)
        #expect(try await fixture.store.fetch(localID: "ann")?.contactID.guessWhoID == nil)
    }

    // MARK: - A snapshot that spans a change is not current

    enum Interference: CaseIterable, CustomTestStringConvertible, Sendable {
        case membershipWrite, contactReload, hierarchyChange

        var testDescription: String {
            switch self {
            case .membershipWrite: "a membership write"
            case .contactReload: "a contact reload with memberships unchanged"
            case .hierarchyChange: "a hierarchy change"
            }
        }
    }

    @Test(arguments: Interference.allCases)
    func snapshotSpanningAChangeIsNotCurrent(_ interference: Interference) async throws {
        let fixture = try makeFixture(contacts: [person("ann"), person("bob")])
        defer { fixture.cleanup() }
        let repo = fixture.repository
        let group = try await fixture.store.seedGroup(name: "Work", members: ["ann"])
        let other = try await fixture.store.seedGroup(name: "Other")
        await repo.reload()
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Folder", inFolder: nil)
        try await repo.moveGroup(group, toFolder: folder)
        await fixture.store.gate(group)

        async let pending = repo.memberSnapshot(for: .folder(id: folder))
        await fixture.store.waitUntilGated(group)
        switch interference {
        case .membershipWrite:
            let bob = try #require(repo.contact(localID: "bob"))
            try await repo.addContact(bob, toGroup: other)
        case .contactReload:
            await repo.reload()
        case .hierarchyChange:
            try await repo.moveGroup(other, toFolder: folder)
        }
        await fixture.store.release(group)
        let stale = await pending

        #expect(repo.isCurrent(stale) == false)
        let fresh = await repo.memberSnapshot(for: .folder(id: folder))
        #expect(repo.isCurrent(fresh))
    }
}
