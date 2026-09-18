import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("Member list loading races", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GroupMemberListLoaderTests {
    private struct Fixture {
        let root: URL
        let store: ScriptedMembersContactStore
        let sidecars: InMemorySidecarStore
        let sync: GuessWhoSync
        let repo: ContactsRepository
        let group: ContactGroup
        let folder: String
        let loader: GroupMemberListLoader
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ScriptedMembersContactStore(contacts: [Contact(localID: "ann", givenName: "Ann")])
        let sidecars = InMemorySidecarStore()
        let sync = GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "A")
        let repo = ContactsRepository(
            contacts: store, sync: sync, favorites: FavoritesStore(root: root),
            notificationCenter: NotificationCenter())
        let group = try await store.seedGroup(name: "Work", members: ["ann"])
        await repo.loadGroups()
        let folder = try await repo.createGroupFolder(name: "Folder", inFolder: nil)
        try await repo.moveGroup(group, toFolder: folder)
        return Fixture(root: root, store: store, sidecars: sidecars, sync: sync, repo: repo,
                       group: group, folder: folder,
                       loader: GroupMemberListLoader(scope: .folder(id: folder), repository: repo))
    }

    private func waitFor(_ status: GroupMemberListLoader.Status, in loader: GroupMemberListLoader) async {
        guard loader.status != status else { return }
        await withCheckedContinuation { continuation in
            loader.onChange = {
                guard loader.status == status else { return }
                loader.onChange = {}
                continuation.resume()
            }
        }
    }

    @Test
    func threeStaleReadsKeepAcceptedRowsAndAutomaticallyRetry() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        f.loader.reload()
        await waitFor(.loaded, in: f.loader)
        #expect(f.loader.snapshot?.contacts.map(\.localID) == ["ann"])
        await f.store.gate(f.group)
        f.loader.reload()

        for index in 0..<3 {
            await f.store.waitUntilGated(f.group)
            await f.store.script([Contact(localID: "stale-\(index)")], for: f.group)
            await f.repo.reload()
            f.loader.repositoryDidChange()
            await f.store.release(f.group, keepGated: true)
        }
        // The fourth fetch must be scheduled without another notification.
        // The third obsolete snapshot must never replace the accepted rows.
        await f.store.waitUntilGated(f.group)
        #expect(f.loader.status == .loading)
        #expect(f.loader.snapshot?.contacts.map(\.localID) == ["ann"])
        await f.store.script([Contact(localID: "fresh")], for: f.group)
        await f.store.release(f.group)
        await waitFor(.loaded, in: f.loader)
        #expect(f.loader.snapshot?.contacts.map(\.localID) == ["fresh"])
        #expect(f.loader.snapshot.map { f.repo.isCurrent($0) } == true)
    }

    @Test(arguments: [true, false])
    func deletionDuringInitialFetchReportsDisappearance(notifyWhileLoading: Bool) async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        await f.store.gate(f.group)
        f.loader.reload()
        await f.store.waitUntilGated(f.group)
        try await f.repo.deleteGroupFolder(id: f.folder)
        if notifyWhileLoading { f.loader.repositoryDidChange() }
        await f.store.release(f.group)
        await waitFor(.disappeared, in: f.loader)
        #expect(f.loader.snapshot == nil)
        var furtherChanges = 0
        f.loader.onChange = { furtherChanges += 1 }
        f.loader.repositoryDidChange()
        f.loader.reload()
        #expect(furtherChanges == 0)
    }

    @Test(arguments: [true, false])
    func unavailableFolderPreservesAcceptedRowsAndRecovers(hadLoaded: Bool) async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        if hadLoaded {
            f.loader.reload()
            await waitFor(.loaded, in: f.loader)
        }
        await f.store.gate(f.group)
        f.loader.reload()
        await f.store.waitUntilGated(f.group)
        let key = SidecarKey(kind: .groupFolder, id: f.folder)
        let good = try #require(try f.sidecars.read(key))
        // A future/invalid record is excluded from the tree but is not deleted.
        try f.sidecars.write(SidecarEnvelope(entityID: f.folder, fields: [:]), at: key)
        await f.repo.loadGroups()
        #expect(f.repo.groupFolderTree.folders[f.folder] == nil)
        #expect(f.repo.groupFolderTree.unavailableKeys.contains(key))
        await f.store.release(f.group)
        await waitFor(.unavailable, in: f.loader)
        #expect(f.loader.snapshot?.contacts.map(\.localID) == (hadLoaded ? ["ann"] : nil))

        try f.sidecars.write(good, at: key)
        await f.repo.loadGroups()
        f.loader.repositoryDidChange()
        await waitFor(.loaded, in: f.loader)
        #expect(f.loader.snapshot?.contacts.map(\.localID) == ["ann"])
    }

    @Test
    func absentFolderWithoutDeletionMarkerIsUnavailable() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let absent = GroupMemberListLoader(scope: .folder(id: UUID().uuidString), repository: f.repo)
        absent.reload()
        #expect(absent.status == .unavailable)
        #expect(absent.snapshot == nil)
    }
}
