import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedGroupStoreFailure: Error {}

private actor SuspendingGroupContactStore: ContactStoreProtocol {
    private let base = InMemoryContactStore()
    private var shouldSuspendGroupFetch = false
    private var groupFetchGate: CheckedContinuation<Void, Never>?
    private var groupFetchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendRename = false
    private var renameGate: CheckedContinuation<Void, Never>?
    private var renameStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldFailGroupFetch = false
    private var shouldFailRename = false

    func seedGroup(name: String) async throws -> ContactGroup {
        try await base.createGroup(name: name)
    }

    func suspendNextGroupFetch() {
        shouldSuspendGroupFetch = true
    }

    func waitUntilGroupFetchIsSuspended() async {
        guard groupFetchGate == nil else { return }
        await withCheckedContinuation { groupFetchStartWaiters.append($0) }
    }

    func resumeGroupFetch() {
        groupFetchGate?.resume()
        groupFetchGate = nil
    }

    func suspendNextRename() {
        shouldSuspendRename = true
    }

    func waitUntilRenameIsSuspended() async {
        guard renameGate == nil else { return }
        await withCheckedContinuation { renameStartWaiters.append($0) }
    }

    func resumeRename() {
        renameGate?.resume()
        renameGate = nil
    }

    func failNextGroupFetch() {
        shouldFailGroupFetch = true
    }

    func failNextRename() {
        shouldFailRename = true
    }

    func fetchAll() async throws -> [Contact] { try await base.fetchAll() }
    func fetch(localID: String) async throws -> Contact? { try await base.fetch(localID: localID) }
    func save(_ contact: Contact) async throws { try await base.save(contact) }
    func delete(localID: String) async throws { try await base.delete(localID: localID) }
    func create(_ contact: Contact) async throws -> Contact { try await base.create(contact) }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus {
        await base.contactsAuthorizationStatus()
    }
    func requestContactsAccess() async -> StoreAccessResult {
        await base.requestContactsAccess()
    }
    func changes(since token: Data?) async throws -> ContactChangeSet {
        try await base.changes(since: token)
    }
    func loadImageData(localID: String) async throws -> Data? {
        try await base.loadImageData(localID: localID)
    }
    func loadThumbnailImageData(localID: String) async throws -> Data? {
        try await base.loadThumbnailImageData(localID: localID)
    }
    func setImageData(localID: String, imageData: Data?) async throws {
        try await base.setImageData(localID: localID, imageData: imageData)
    }

    func fetchAllGroups() async throws -> [ContactGroup] {
        if shouldFailGroupFetch {
            shouldFailGroupFetch = false
            throw InjectedGroupStoreFailure()
        }
        let snapshot = try await base.fetchAllGroups()
        guard shouldSuspendGroupFetch else { return snapshot }
        shouldSuspendGroupFetch = false
        await withCheckedContinuation { continuation in
            groupFetchGate = continuation
            let waiters = groupFetchStartWaiters
            groupFetchStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return snapshot
    }

    func fetchGroup(localID: String) async throws -> ContactGroup? {
        try await base.fetchGroup(localID: localID)
    }

    func createGroup(name: String) async throws -> ContactGroup {
        try await base.createGroup(name: name)
    }

    func renameGroup(localID: String, to name: String) async throws {
        if shouldFailRename {
            shouldFailRename = false
            throw InjectedGroupStoreFailure()
        }
        try await base.renameGroup(localID: localID, to: name)
        guard shouldSuspendRename else { return }
        shouldSuspendRename = false
        await withCheckedContinuation { continuation in
            renameGate = continuation
            let waiters = renameStartWaiters
            renameStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func deleteGroup(localID: String) async throws {
        try await base.deleteGroup(localID: localID)
    }
    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        try await base.fetchMembers(ofGroup: groupLocalID)
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

@Suite("ContactsRepository — group memberships")
struct ContactsRepositoryGroupsTests {
    @Test @MainActor
    func staleLoadCannotOverwriteACompletedCreate() async throws {
        let store = SuspendingGroupContactStore()
        _ = try await store.seedGroup(name: "Family")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        await store.suspendNextGroupFetch()
        let staleLoad = Task { @MainActor in await repository.loadGroups() }
        await store.waitUntilGroupFetchIsSuspended()

        _ = try await repository.createGroup(name: "Work")
        await store.resumeGroupFetch()
        await staleLoad.value

        #expect(repository.groups.map(\.name) == ["Family", "Work"])
    }

    @Test @MainActor
    func concurrentRenameThenDeleteCannotResurrectDeletedGroup() async throws {
        let store = SuspendingGroupContactStore()
        let family = try await store.seedGroup(name: "Family")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        await store.suspendNextRename()
        let rename = Task { @MainActor in
            try await repository.renameGroup(family, to: "Close Family")
        }
        await store.waitUntilRenameIsSuspended()
        let delete = Task { @MainActor in
            try await repository.deleteGroup(family)
        }

        await store.resumeRename()
        try await rename.value
        try await delete.value

        #expect(repository.groups.isEmpty)
        #expect(try await store.fetchGroup(localID: family.localID) == nil)
    }

    @Test @MainActor
    func failedLoadAndMutationPreserveLastGoodCache() async throws {
        let store = SuspendingGroupContactStore()
        let family = try await store.seedGroup(name: "Family")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        await store.failNextGroupFetch()
        await repository.loadGroups()
        #expect(repository.groups.map(\.name) == ["Family"])
        #expect(repository.groupsError != nil)

        await store.failNextRename()
        await #expect(throws: InjectedGroupStoreFailure.self) {
            try await repository.renameGroup(family, to: "Close Family")
        }
        #expect(repository.groups.map(\.name) == ["Family"])
    }

    @Test @MainActor
    func createRenameDeleteGroupUpdatesStoreAndSortedCache() async throws {
        let store = InMemoryContactStore()
        let repository = ContactsRepository(contacts: store)

        let work = try await repository.createGroup(name: "Work")
        let family = try await repository.createGroup(name: "Family")
        #expect(repository.groups.map(\.name) == ["Family", "Work"])
        #expect(try await store.fetchGroup(localID: family.localID)?.name == "Family")

        try await repository.renameGroup(work, to: "Colleagues")
        #expect(repository.groups.map(\.name) == ["Colleagues", "Family"])
        #expect(try await store.fetchGroup(localID: work.localID)?.name == "Colleagues")

        try await repository.deleteGroup(family)
        #expect(repository.groups.map(\.name) == ["Colleagues"])
        #expect(try await store.fetchGroup(localID: family.localID) == nil)
    }

    @Test @MainActor
    func groupsContainingReturnsEveryContainingGroupSortedByName() async throws {
        let person = Contact(localID: "person", givenName: "Ada", familyName: "Lovelace")
        let store = InMemoryContactStore(contacts: [person])
        // Create out of alphabetical order so the sort is exercised, plus one
        // unrelated group the person is NOT in.
        let work = try await store.createGroup(name: "Work")
        let family = try await store.createGroup(name: "Family")
        let unrelated = try await store.createGroup(name: "Hobbies")
        try await store.addMember(contactLocalID: person.localID, toGroup: work.localID)
        try await store.addMember(contactLocalID: person.localID, toGroup: family.localID)

        let repository = ContactsRepository(contacts: store)

        let groups = await repository.groups(containing: person)
        // Sorted by name ("Family" before "Work"), unrelated group excluded.
        #expect(groups.map(\.name) == ["Family", "Work"])
        #expect(!groups.map(\.localID).contains(unrelated.localID))
    }

    @Test @MainActor
    func groupsContainingReturnsEmptyWhenInNoGroups() async {
        // Organizations are Contacts too: a group can hold either, so the same
        // query serves the org detail screen.
        let organization = Contact(localID: "org", contactType: .organization, organizationName: "Analytical Engine")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: [organization]))

        let groups = await repository.groups(containing: organization)
        #expect(groups.isEmpty)
    }

    @Test @MainActor
    func groupsContainingDegradesToEmptyAndRecordsErrorForMissingContact() async {
        // The store throws `contactNotFound` for an unknown localID; the
        // repository must degrade to an empty list and record `lastError`
        // rather than propagating, matching `members(ofGroup:)`.
        let ghost = Contact(localID: "ghost", givenName: "Nobody")
        let repository = ContactsRepository(contacts: InMemoryContactStore(contacts: []))

        let groups = await repository.groups(containing: ghost)
        #expect(groups.isEmpty)
        #expect(repository.lastError != nil)
    }
}
