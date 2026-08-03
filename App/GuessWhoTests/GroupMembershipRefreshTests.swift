import Foundation
import Testing
import UIKit
import GuessWhoSync
@testable import GuessWho

/// The refresh half of "Add to Group": an open group member list must pick up a
/// contact added to THAT group without a manual reload.
///
/// `.contactsRepositoryDidReload` can't carry this — membership isn't cached by
/// the repository, so nothing about the cache changes when it moves and the
/// member SET has to be re-read. This drives the real view controller over a
/// stub Contacts store and asserts it re-reads (and that it stays put for a
/// different group's change).
@MainActor
@Suite("Group member list membership refresh")
struct GroupMembershipRefreshTests {
    /// Every test gets its OWN group ids. These notifications go through
    /// `NotificationCenter.default`, and the suite's tests run in parallel — two
    /// member lists open on the same group id would each answer the other's
    /// post and corrupt both fetch counts.
    private func uniqueGroup(_ name: String) -> ContactGroup {
        ContactGroup(localID: "group-\(name)-\(UUID().uuidString)", name: name)
    }

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw-group-membership-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMemberList(
        group: ContactGroup,
        root: URL,
        store: GroupStubContactStore
    ) -> GroupMembersListViewController {
        let service = SyncService(
            contactsAdapter: store,
            eventsAdapter: GroupStubEventStore(),
            sidecarLocation: .iCloud(root),
            deviceID: "test-device",
            contactCursorURL: root.appendingPathComponent("test-cursor")
        )
        let repository = service.makeContactsRepository()
        return GroupMembersListViewController(
            group: group,
            repository: repository,
            photoLoader: ContactPhotoLoader(repository: repository),
            favoritesStore: FavoritesListStore(service: service)
        )
    }

    private func membershipChanged(group: ContactGroup) {
        NotificationCenter.default.post(
            name: .contactsRepositoryGroupMembershipDidChange,
            object: nil,
            userInfo: [
                ContactsRepositoryGroupMembershipDidChangeKey.groupLocalID: group.localID,
                ContactsRepositoryGroupMembershipDidChangeKey.change: GroupMembershipChange.addition,
            ]
        )
    }

    /// Poll until the store has been asked for members `target` times, returning
    /// what was actually observed so a failed expectation names the real count.
    /// The re-read runs in a `Task`, so it lands a turn or two after the post.
    private func fetches(reaching target: Int, in store: GroupStubContactStore) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(3)
        var observed = await store.memberFetches
        while observed < target, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            observed = await store.memberFetches
        }
        return observed
    }

    @Test
    func anOpenMemberListReReadsItsMembersWhenItsGroupChanges() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = uniqueGroup("Family")
        let store = GroupStubContactStore()

        let listViewController = makeMemberList(group: group, root: root, store: store)
        // Force `viewDidLoad`, which kicks the initial member fetch.
        _ = listViewController.view
        #expect(try await fetches(reaching: 1, in: store) == 1)

        membershipChanged(group: group)

        #expect(try await fetches(reaching: 2, in: store) == 2)
    }

    @Test
    func anOpenMemberListIgnoresAnotherGroupsChange() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = uniqueGroup("Family")
        let store = GroupStubContactStore()

        let listViewController = makeMemberList(group: group, root: root, store: store)
        _ = listViewController.view
        #expect(try await fetches(reaching: 1, in: store) == 1)

        // A change to a DIFFERENT group, then one to this list's own group. The
        // observer callbacks run in post order, so once the second re-read has
        // landed the first has already had its chance.
        membershipChanged(group: uniqueGroup("Work"))
        membershipChanged(group: group)
        #expect(try await fetches(reaching: 2, in: store) == 2)

        // Settle, then confirm the unrelated group never produced a third read.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await store.memberFetches == 2)
    }
}

// MARK: - Stubs

private func groupStubUnused(function: String = #function) -> Never {
    fatalError("group membership test stub member unexpectedly reached: \(function)")
}

/// Counts member fetches so a test can assert that a surface re-read. Contacts
/// themselves are irrelevant here — the wiring under test is "did this list ask
/// Contacts again," not what came back.
private actor GroupStubContactStore: ContactStoreProtocol {
    private(set) var memberFetches = 0

    func fetchAll() async throws -> [Contact] { [] }
    func fetch(localID: String) async throws -> Contact? { nil }
    func save(_ contact: Contact) async throws { groupStubUnused() }
    func delete(localID: String) async throws { groupStubUnused() }
    func create(_ contact: Contact) async throws -> Contact { groupStubUnused() }
    func contactsAuthorizationStatus() async -> StoreAuthorizationStatus { .notDetermined }
    func requestContactsAccess() async -> StoreAccessResult { groupStubUnused() }
    func changes(since token: Data?) async throws -> ContactChangeSet { groupStubUnused() }
    func loadImageData(localID: String) async throws -> Data? { nil }
    func loadThumbnailImageData(localID: String) async throws -> Data? { nil }
    func setImageData(localID: String, imageData: Data?) async throws { groupStubUnused() }
    func fetchAllGroups() async throws -> [ContactGroup] { [] }
    func fetchGroup(localID: String) async throws -> ContactGroup? { nil }
    func createGroup(name: String) async throws -> ContactGroup { groupStubUnused() }
    func renameGroup(localID: String, to name: String) async throws { groupStubUnused() }
    func deleteGroup(localID: String) async throws { groupStubUnused() }

    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        memberFetches += 1
        return []
    }

    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] { [] }
    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] { [] }
    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws { groupStubUnused() }
    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws { groupStubUnused() }
}

private final class GroupStubEventStore: EventStoreProtocol, Sendable {
    func eventsAuthorizationStatus() -> StoreAuthorizationStatus { .notDetermined }
    func requestEventsAccess() async -> StoreAccessResult { groupStubUnused() }
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
    ) throws -> Event { groupStubUnused() }
    func updateEvent(
        eventKitID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?
    ) throws { groupStubUnused() }
}
