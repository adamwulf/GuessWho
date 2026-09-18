import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Hierarchy mutation freshness", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GroupHierarchyFreshnessTests {
    private struct Fixture {
        let root: URL
        let store: ScriptedHierarchySidecarStore
        let contacts: ScriptedMembersContactStore
        let sync: GuessWhoSync
        let repo: ContactsRepository
        let group: ContactGroup
        let source: String
        let destination: String
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ScriptedHierarchySidecarStore(wrapping: InMemorySidecarStore())
        let contacts = ScriptedMembersContactStore()
        let sync = GuessWhoSync(contacts: contacts, events: InMemoryEventStore(), sidecars: store, deviceID: "A")
        let repo = ContactsRepository(contacts: contacts, sync: sync, favorites: FavoritesStore(root: root),
                                      notificationCenter: NotificationCenter())
        let group = try await contacts.seedGroup(name: "Work")
        await repo.loadGroups()
        let source = try await repo.createGroupFolder(name: "Source", inFolder: nil)
        let destination = try await repo.createGroupFolder(name: "Destination", inFolder: nil)
        return Fixture(root: root, store: store, contacts: contacts, sync: sync, repo: repo,
                       group: group, source: source, destination: destination)
    }

    enum Command: CaseIterable, Sendable { case create, rename, moveFolder, delete, moveGroup }

    private func mutate(_ command: Command, in f: Fixture) async throws {
        switch command {
        case .create: _ = try await f.repo.createGroupFolder(name: "New", inFolder: f.destination)
        case .rename: try await f.repo.renameGroupFolder(id: f.source, to: "Renamed")
        case .moveFolder: try await f.repo.moveGroupFolder(id: f.source, toFolder: f.destination)
        case .delete: try await f.repo.deleteGroupFolder(id: f.source)
        case .moveGroup: try await f.repo.moveGroup(f.group, toFolder: f.destination)
        }
    }

    @Test(arguments: Command.allCases, [true, false])
    func mutationsRefuseFailedOrSupersededReads(command: Command, enumerationFails: Bool) async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let before = try await f.sync.groupHierarchyRecords()
        if enumerationFails {
            f.store.failEnumeration = true
            await #expect(throws: GroupHierarchyError.hierarchyUnavailable) {
                try await mutate(command, in: f)
            }
            #expect(f.repo.groupFolderTree.isComplete == false)
            f.store.failEnumeration = false
        } else {
            let gate = f.store.gateNextEnumeration()
            let pending = Task { try await mutate(command, in: f) }
            await gate.waitUntilEntered()
            // A later watcher read wins while this command is suspended.
            await f.repo.loadGroups()
            gate.release()
            await #expect(throws: GroupHierarchyError.hierarchyUnavailable) {
                try await pending.value
            }
        }
        #expect(try await f.sync.groupHierarchyRecords() == before)
        // A retry obtains a fresh read and performs the requested mutation.
        try await mutate(command, in: f)
        #expect(f.repo.groupFolderTree.isComplete)
    }

    @Test
    func failedReadAfterFingerprintCannotUseCachedDestination() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        await f.contacts.gateFingerprint(f.group)
        let pending = Task { try await f.repo.moveGroup(f.group, toFolder: f.destination) }
        await f.contacts.waitUntilGated(f.group)
        try f.sync.markGroupFolderDeleted(id: f.destination, promotedToFolderID: nil)
        f.store.failEnumeration = true
        await f.contacts.release(f.group)
        await #expect(throws: GroupHierarchyError.hierarchyUnavailable) { try await pending.value }
        f.store.failEnumeration = false
        #expect(try await f.sync.groupHierarchyRecords().groupPlacements.isEmpty)
    }
}
