import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedMembershipStoreFailure: Error {}

/// Delegating store that can park inside `addMember`, fail `removeMember` for
/// chosen contacts, and record the ORDER in which group operations completed —
/// so the serialization test can prove a membership batch and a concurrent
/// `deleteGroup` never interleave. Mirrors `SuspendingGroupContactStore` in
/// `ContactsRepositoryGroupsTests`.
private actor SuspendingMembershipContactStore: ContactStoreProtocol {
    private let base: InMemoryContactStore
    private var shouldSuspendAddMember = false
    private var addMemberGate: CheckedContinuation<Void, Never>?
    private var addMemberStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var removeMemberFailures: Set<String> = []

    /// Group operations in COMPLETION order — the discriminating signal:
    /// unserialized, the delete finishes while the add is parked.
    private(set) var completedOps: [String] = []

    init(contacts: [Contact] = []) {
        base = InMemoryContactStore(contacts: contacts)
    }

    func seedGroup(name: String) async throws -> ContactGroup {
        try await base.createGroup(name: name)
    }

    func suspendNextAddMember() {
        shouldSuspendAddMember = true
    }

    func waitUntilAddMemberIsSuspended() async {
        guard addMemberGate == nil else { return }
        await withCheckedContinuation { addMemberStartWaiters.append($0) }
    }

    func resumeAddMember() {
        addMemberGate?.resume()
        addMemberGate = nil
    }

    /// Make every `removeMember` for this contact throw. The in-memory store
    /// alone can't provoke a removal failure — its `fetchMembers` drops member
    /// ids with no contact record, so the batch's pre-flight read never offers
    /// such a contact for removal in the first place.
    func failRemoveMember(forContactLocalID localID: String) {
        removeMemberFailures.insert(localID)
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
    func fetchAllGroups() async throws -> [ContactGroup] { try await base.fetchAllGroups() }
    func fetchGroup(localID: String) async throws -> ContactGroup? {
        try await base.fetchGroup(localID: localID)
    }
    func createGroup(name: String) async throws -> ContactGroup {
        try await base.createGroup(name: name)
    }
    func renameGroup(localID: String, to name: String) async throws {
        try await base.renameGroup(localID: localID, to: name)
    }

    func deleteGroup(localID: String) async throws {
        try await base.deleteGroup(localID: localID)
        completedOps.append("deleteGroup")
    }

    /// Call counters proving the batch preflight asks the cheap question. The
    /// full-record read must stay at zero for a membership write.
    private(set) var fetchMembersCallCount = 0
    private(set) var fetchMemberLocalIDsCallCount = 0

    func fetchMembers(ofGroup groupLocalID: String) async throws -> [Contact] {
        fetchMembersCallCount += 1
        return try await base.fetchMembers(ofGroup: groupLocalID)
    }

    func fetchMemberLocalIDs(ofGroup groupLocalID: String) async throws -> [String] {
        fetchMemberLocalIDsCallCount += 1
        return try await base.fetchMemberLocalIDs(ofGroup: groupLocalID)
    }

    func seedMember(contactLocalID: String, inGroup groupLocalID: String) async throws {
        try await base.addMember(contactLocalID: contactLocalID, toGroup: groupLocalID)
    }

    func fetchGroupMemberships(contactLocalID: String) async throws -> [ContactGroup] {
        try await base.fetchGroupMemberships(contactLocalID: contactLocalID)
    }

    func addMember(contactLocalID: String, toGroup groupLocalID: String) async throws {
        // Park BEFORE delegating: an unserialized concurrent delete then pulls
        // the group out from under this write and it fails, which is exactly
        // what serialization must prevent.
        if shouldSuspendAddMember {
            shouldSuspendAddMember = false
            await withCheckedContinuation { continuation in
                addMemberGate = continuation
                let waiters = addMemberStartWaiters
                addMemberStartWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        try await base.addMember(contactLocalID: contactLocalID, toGroup: groupLocalID)
        completedOps.append("addMember")
    }

    func removeMember(contactLocalID: String, fromGroup groupLocalID: String) async throws {
        if removeMemberFailures.contains(contactLocalID) {
            throw InjectedMembershipStoreFailure()
        }
        try await base.removeMember(contactLocalID: contactLocalID, fromGroup: groupLocalID)
        completedOps.append("removeMember")
    }
}

/// Collects `.contactsRepositoryGroupMembershipDidChange` posts. The repository
/// posts synchronously from the main actor, so `assumeIsolated` holds — the
/// same pattern the app's list controllers use for its sibling notification.
@MainActor
private final class MembershipChangeRecorder {
    struct Post {
        let groupLocalID: String?
        let contactIDs: [ContactID]?
        let change: GroupMembershipChange?
    }

    private(set) var posts: [Post] = []

    /// Observing a per-test center keeps one repository's posts out of another's
    /// recorder under parallel `swift test`.
    init(center: NotificationCenter) {
        center.addObserver(
            forName: .contactsRepositoryGroupMembershipDidChange,
            object: nil,
            queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let info = note.userInfo
                self?.posts.append(
                    Post(
                        groupLocalID: info?[
                            ContactsRepositoryGroupMembershipDidChangeKey.groupLocalID
                        ] as? String,
                        contactIDs: info?[
                            ContactsRepositoryGroupMembershipDidChangeKey.contactIDs
                        ] as? [ContactID],
                        change: info?[
                            ContactsRepositoryGroupMembershipDidChangeKey.change
                        ] as? GroupMembershipChange
                    )
                )
            }
        }
    }
}

@Suite("ContactsRepository — group membership mutation")
struct ContactsRepositoryGroupMembershipTests {
    private static let ada = Contact(localID: "ada", givenName: "Ada", familyName: "Lovelace")
    private static let alan = Contact(localID: "alan", givenName: "Alan", familyName: "Turing")
    private static let grace = Contact(localID: "grace", givenName: "Grace", familyName: "Hopper")

    @Test @MainActor
    func addContactsMakesEveryRequestedContactAMember() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan, Self.grace])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        try await repository.addContacts([Self.ada, Self.alan, Self.grace], toGroup: work)

        let members = await repository.members(ofGroup: work.localID)
        #expect(Set(members.map(\.displayName)) == ["Ada Lovelace", "Alan Turing", "Grace Hopper"])
        // Also visible through the store's own membership read, so the write
        // really landed in Contacts and not in some repository-side cache.
        let memberships = try await store.fetchGroupMemberships(contactLocalID: Self.ada.localID)
        #expect(memberships.map(\.localID) == [work.localID])
        // …and through the contact-side repository read the detail view uses.
        #expect(await repository.groups(containing: Self.alan).map(\.name) == ["Work"])
    }

    @Test @MainActor
    func addContactsLeavesTheGroupsCacheAndOtherGroupsAlone() async throws {
        // The `groups` ARRAY is unchanged by a membership write — it is the set
        // of groups, not their contents — and a contact only joins the group it
        // was added to.
        let store = InMemoryContactStore(contacts: [Self.ada])
        let work = try await store.createGroup(name: "Work")
        let family = try await store.createGroup(name: "Family")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()
        let cachedBefore = repository.groups

        try await repository.addContacts([Self.ada], toGroup: work)

        #expect(repository.groups == cachedBefore)
        #expect(await repository.members(ofGroup: family.localID).isEmpty)
    }

    @Test @MainActor
    func addingAContactAlreadyInTheGroupIsANoOpAndDoesNotThrow() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        try await repository.addContacts([Self.ada], toGroup: work)
        // Ada is already in; Alan is not. The batch must not throw, and must
        // still add Alan.
        try await repository.addContacts([Self.ada, Self.alan], toGroup: work)

        let members = await repository.members(ofGroup: work.localID)
        #expect(Set(members.map(\.displayName)) == ["Ada Lovelace", "Alan Turing"])
    }

    @Test @MainActor
    func addContactsCollapsesDuplicateEntriesInOneRequest() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        try await repository.addContacts([Self.ada, Self.ada], toGroup: work)

        #expect(await repository.members(ofGroup: work.localID).count == 1)
    }

    @Test @MainActor
    func removeContactsClearsMembershipWithoutDeletingTheContacts() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)
        try await repository.addContacts([Self.ada, Self.alan], toGroup: work)

        try await repository.removeContacts([Self.ada], fromGroup: work)

        #expect(await repository.members(ofGroup: work.localID).map(\.displayName) == ["Alan Turing"])
        #expect(await repository.groups(containing: Self.ada).isEmpty)
        // Removing from a group never removes the contact from Contacts.
        #expect(try await store.fetch(localID: Self.ada.localID) != nil)
    }

    @Test @MainActor
    func removingANonMemberIsANoOpAndDoesNotThrow() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)
        try await repository.addContacts([Self.ada], toGroup: work)

        try await repository.removeContacts([Self.alan], fromGroup: work)

        #expect(await repository.members(ofGroup: work.localID).map(\.displayName) == ["Ada Lovelace"])
    }

    @Test @MainActor
    func emptyRequestSucceedsWithoutTouchingTheStore() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada])
        let repository = ContactsRepository(contacts: store)
        // A group id that does not exist: an empty request asked for nothing,
        // so it must not fail on the missing group.
        let ghostGroup = ContactGroup(localID: "no-such-group", name: "Ghost")

        try await repository.addContacts([], toGroup: ghostGroup)
        try await repository.removeContacts([], fromGroup: ghostGroup)
    }

    // MARK: - Partial failure

    @Test @MainActor
    func partialFailureRunsToTheEndAndReportsWhatLanded() async throws {
        // The ghost is not in the store, so `addMember` throws `contactNotFound`
        // for it. It is FIRST in the batch, which proves the write continued
        // through the remaining contacts instead of stopping at the failure.
        let ghost = Contact(localID: "ghost", givenName: "No", familyName: "Body")
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        do {
            try await repository.addContacts([ghost, Self.ada, Self.alan], toGroup: work)
            Issue.record("expected a GroupMembershipPartialFailureError")
        } catch let error as GroupMembershipPartialFailureError {
            #expect(error.change == .addition)
            #expect(error.group.localID == work.localID)
            #expect(error.applied.map(\.displayName) == ["Ada Lovelace", "Alan Turing"])
            #expect(error.failures.map(\.contact.displayName) == ["No Body"])
            // The store's own typed error rides along, unflattened.
            guard let storeError = error.failures.first?.error as? ContactStoreError,
                  case .contactNotFound = storeError else {
                Issue.record("expected contactNotFound, got \(String(describing: error.failures.first?.error))")
                return
            }
        }

        // The two writable contacts really did land.
        let members = await repository.members(ofGroup: work.localID)
        #expect(Set(members.map(\.displayName)) == ["Ada Lovelace", "Alan Turing"])
    }

    @Test @MainActor
    func partialFailureWithNothingApplicableReportsAnEmptyAppliedList() async throws {
        let ghost = Contact(localID: "ghost", givenName: "No", familyName: "Body")
        let phantom = Contact(localID: "phantom", givenName: "Not", familyName: "Here")
        let store = InMemoryContactStore(contacts: [])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        do {
            try await repository.addContacts([ghost, phantom], toGroup: work)
            Issue.record("expected a GroupMembershipPartialFailureError")
        } catch let error as GroupMembershipPartialFailureError {
            // Empty `applied` means "none landed", not "nothing was attempted":
            // both contacts were tried and both are reported.
            #expect(error.applied.isEmpty)
            #expect(error.failures.count == 2)
        }
    }

    @Test @MainActor
    func removalPartialFailureIsReportedAsARemoval() async throws {
        let store = SuspendingMembershipContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.seedGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)
        try await repository.addContacts([Self.ada, Self.alan], toGroup: work)

        // Alan's removal is scripted to fail, and he is FIRST in the batch —
        // Ada's removal must still be attempted after it.
        await store.failRemoveMember(forContactLocalID: Self.alan.localID)

        do {
            try await repository.removeContacts([Self.alan, Self.ada], fromGroup: work)
            Issue.record("expected a GroupMembershipPartialFailureError")
        } catch let error as GroupMembershipPartialFailureError {
            #expect(error.change == .removal)
            #expect(error.applied.map(\.displayName) == ["Ada Lovelace"])
            #expect(error.failures.map(\.contact.displayName) == ["Alan Turing"])
            #expect(error.failures.first?.error is InjectedMembershipStoreFailure)
        }

        #expect(await repository.members(ofGroup: work.localID).map(\.displayName) == ["Alan Turing"])
    }

    @Test @MainActor
    func aMissingGroupFailsBeforeAnyWriteAndIsNotAPartialFailure() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let real = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)
        let ghostGroup = ContactGroup(localID: "no-such-group", name: "Ghost")

        await #expect(throws: ContactStoreError.self) {
            try await repository.addContacts([Self.ada, Self.alan], toGroup: ghostGroup)
        }

        // Nothing was attempted, so no contact moved anywhere.
        #expect(await repository.members(ofGroup: real.localID).isEmpty)
        #expect(await repository.groups(containing: Self.ada).isEmpty)
    }

    @Test @MainActor
    func singleContactConvenienceThrowsTheUnderlyingStoreError() async throws {
        let ghost = Contact(localID: "ghost", givenName: "No", familyName: "Body")
        let store = InMemoryContactStore(contacts: [Self.ada])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        // One contact has no partial state: the store's own error surfaces
        // unwrapped, NOT a GroupMembershipPartialFailureError.
        await #expect(throws: ContactStoreError.self) {
            try await repository.addContact(ghost, toGroup: work)
        }

        try await repository.addContact(Self.ada, toGroup: work)
        #expect(await repository.members(ofGroup: work.localID).map(\.displayName) == ["Ada Lovelace"])

        try await repository.removeContact(Self.ada, fromGroup: work)
        #expect(await repository.members(ofGroup: work.localID).isEmpty)
    }

    // MARK: - Empty-localID contacts

    @Test @MainActor
    func aNeverSavedContactIsReportedRatherThanSilentlyDropped() async throws {
        // `Contact()` mints an empty localID: a value that was never saved to
        // Contacts and so has no membership to change.
        let unsaved = Contact(givenName: "Unsaved", familyName: "Draft")
        let store = InMemoryContactStore(contacts: [Self.ada])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        do {
            try await repository.addContacts([unsaved, Self.ada], toGroup: work)
            Issue.record("expected a GroupMembershipPartialFailureError")
        } catch let error as GroupMembershipPartialFailureError {
            #expect(error.applied.map(\.displayName) == ["Ada Lovelace"])
            #expect(error.failures.map(\.contact.displayName) == ["Unsaved Draft"])
            #expect(error.failures.first?.error is ContactNotSavedError)
        }

        #expect(await repository.members(ofGroup: work.localID).map(\.displayName) == ["Ada Lovelace"])
    }

    @Test @MainActor
    func severalNeverSavedContactsAreEachReported() async throws {
        // They all share the empty localID, so dedup must NOT collapse them —
        // the report has to account for every contact the caller asked about.
        let first = Contact(givenName: "First", familyName: "Draft")
        let second = Contact(givenName: "Second", familyName: "Draft")
        let third = Contact(givenName: "Third", familyName: "Draft")
        let store = InMemoryContactStore(contacts: [])
        let work = try await store.createGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        do {
            try await repository.addContacts([first, second, third], toGroup: work)
            Issue.record("expected a GroupMembershipPartialFailureError")
        } catch let error as GroupMembershipPartialFailureError {
            #expect(error.applied.isEmpty)
            #expect(error.failures.map(\.contact.displayName)
                == ["First Draft", "Second Draft", "Third Draft"])
            #expect(error.failures.allSatisfy { $0.error is ContactNotSavedError })
        }
    }

    @Test @MainActor
    func twoStaleValuesForOneRecordCollapseToASingleRequest() async throws {
        // Same Contacts record reached twice (e.g. from two list sections),
        // captured at different times so the values differ. One record, one
        // request, one entry — reported as the first value passed.
        let stale = Contact(localID: "ada", givenName: "Ada", familyName: "Byron")
        let fresh = Contact(localID: "ada", givenName: "Ada", familyName: "Lovelace")
        let store = InMemoryContactStore(contacts: [fresh])
        let work = try await store.createGroup(name: "Work")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: store, notificationCenter: center)
        let recorder = MembershipChangeRecorder(center: center)

        try await repository.addContacts([stale, fresh], toGroup: work)

        #expect(await repository.members(ofGroup: work.localID).count == 1)
        // One write, so one contact in the single post — not two.
        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.contactIDs?.count == 1)
    }

    // MARK: - Preflight cost

    @Test @MainActor
    func thePreflightUsesTheIdentifierOnlyReadNotTheFullRecordFetch() async throws {
        let store = SuspendingMembershipContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.seedGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)

        try await repository.addContacts([Self.ada, Self.alan], toGroup: work)

        // One preflight for the whole batch, and never the fetch that
        // materializes every member's full record.
        #expect(await store.fetchMemberLocalIDsCallCount == 1)
        #expect(await store.fetchMembersCallCount == 0)
    }

    @Test @MainActor
    func thePreflightSeesAMemberAddedThroughTheStore() async throws {
        let store = SuspendingMembershipContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.seedGroup(name: "Work")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: store, notificationCenter: center)
        let recorder = MembershipChangeRecorder(center: center)

        // Ada joins behind the repository's back, exactly as an external change
        // would. The preflight must observe her.
        try await store.seedMember(contactLocalID: Self.ada.localID, inGroup: work.localID)

        try await repository.addContacts([Self.ada, Self.alan], toGroup: work)

        // Only Alan needed writing, so only Alan is announced.
        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.contactIDs == [Self.alan.contactID])
        let members = await repository.members(ofGroup: work.localID)
        #expect(Set(members.map(\.displayName)) == ["Ada Lovelace", "Alan Turing"])
    }

    @Test @MainActor
    func identifierOnlyReadMatchesTheFullFetchAndFailsOnAMissingGroup() async throws {
        // The contract the repository relies on: these ids ARE the `localID`s
        // the full fetch reports, and a bad group id is a typed error.
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.createGroup(name: "Work")
        try await store.addMember(contactLocalID: Self.ada.localID, toGroup: work.localID)
        try await store.addMember(contactLocalID: Self.alan.localID, toGroup: work.localID)

        let ids = try await store.fetchMemberLocalIDs(ofGroup: work.localID)
        let fromFullFetch = try await store.fetchMembers(ofGroup: work.localID).map(\.localID)
        #expect(Set(ids) == Set(fromFullFetch))
        #expect(ids.count == fromFullFetch.count)

        await #expect(throws: ContactStoreError.self) {
            _ = try await store.fetchMemberLocalIDs(ofGroup: "no-such-group")
        }
    }

    // MARK: - Change notification

    @Test @MainActor
    func aLandedWriteAnnouncesTheGroupContactsAndDirection() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada, Self.alan])
        let work = try await store.createGroup(name: "Work")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: store, notificationCenter: center)
        let recorder = MembershipChangeRecorder(center: center)

        try await repository.addContacts([Self.ada, Self.alan], toGroup: work)

        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.groupLocalID == work.localID)
        #expect(recorder.posts.first?.contactIDs == [Self.ada.contactID, Self.alan.contactID])
        #expect(recorder.posts.first?.change == .addition)

        try await repository.removeContacts([Self.ada], fromGroup: work)

        #expect(recorder.posts.count == 2)
        #expect(recorder.posts.last?.contactIDs == [Self.ada.contactID])
        #expect(recorder.posts.last?.change == .removal)
    }

    @Test @MainActor
    func announcedTokensComeFromTheCacheNotTheCallersStaleValue() async throws {
        // The record is reconciled (it carries a GuessWho URL), so its identity
        // is the UUID. A caller holding a value captured BEFORE that would key
        // its token on localID — and an observer, whose tokens come from this
        // cache, would compare unequal and ignore the post.
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        let reconciled = Contact(
            localID: "ada",
            givenName: "Ada",
            familyName: "Lovelace",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/\(uuid)")]
        )
        let stale = Contact(localID: "ada", givenName: "Ada", familyName: "Lovelace")
        let store = InMemoryContactStore(contacts: [reconciled])
        let work = try await store.createGroup(name: "Work")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: store, notificationCenter: center)
        await repository.reload()
        let recorder = MembershipChangeRecorder(center: center)

        try await repository.addContacts([stale], toGroup: work)

        let cachedToken = try #require(repository.contact(id: stale.contactID)?.contactID)
        #expect(recorder.posts.first?.contactIDs == [cachedToken])
        // The stale value's own token keys on localID, so this is a real
        // difference, not a tautology.
        #expect(cachedToken != stale.contactID)
    }

    @Test @MainActor
    func aPartialFailureAnnouncesTheWritesThatLandedBeforeThrowing() async throws {
        let ghost = Contact(localID: "ghost", givenName: "No", familyName: "Body")
        let store = InMemoryContactStore(contacts: [Self.ada])
        let work = try await store.createGroup(name: "Work")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: store, notificationCenter: center)
        let recorder = MembershipChangeRecorder(center: center)

        await #expect(throws: GroupMembershipPartialFailureError.self) {
            try await repository.addContacts([ghost, Self.ada], toGroup: work)
        }

        // Ada really joined, so observers must hear about it even though the
        // call threw.
        #expect(recorder.posts.count == 1)
        #expect(recorder.posts.first?.contactIDs == [Self.ada.contactID])
    }

    @Test @MainActor
    func nothingIsAnnouncedWhenNothingWasWritten() async throws {
        let store = InMemoryContactStore(contacts: [Self.ada])
        let work = try await store.createGroup(name: "Work")
        let center = NotificationCenter()
        let repository = ContactsRepository(contacts: store, notificationCenter: center)
        try await repository.addContacts([Self.ada], toGroup: work)

        let recorder = MembershipChangeRecorder(center: center)

        // Already a member: a pure no-op.
        try await repository.addContacts([Self.ada], toGroup: work)
        // Not a member: also a pure no-op.
        try await repository.removeContacts(
            [Contact(localID: "alan", givenName: "Alan", familyName: "Turing")],
            fromGroup: work
        )
        // Asked for nothing.
        try await repository.addContacts([], toGroup: work)
        // Failed before any write.
        await #expect(throws: ContactStoreError.self) {
            try await repository.addContacts(
                [Self.ada],
                toGroup: ContactGroup(localID: "no-such-group", name: "Ghost")
            )
        }

        #expect(recorder.posts.isEmpty)
    }

    // MARK: - Serialization

    @Test @MainActor
    func membershipBatchAndConcurrentDeleteDoNotInterleave() async throws {
        let store = SuspendingMembershipContactStore(contacts: [Self.ada])
        let work = try await store.seedGroup(name: "Work")
        let repository = ContactsRepository(contacts: store)
        await repository.loadGroups()

        await store.suspendNextAddMember()
        let add = Task { @MainActor in
            try await repository.addContacts([Self.ada], toGroup: work)
        }
        await store.waitUntilAddMemberIsSuspended()

        let delete = Task { @MainActor in try await repository.deleteGroup(work) }
        // Give the delete every chance to reach the store while the add is
        // parked. Serialized it waits on the mutation tail; unserialized these
        // yields are plenty for it to delete the group mid-batch.
        for _ in 0..<10 { await Task.yield() }

        await store.resumeAddMember()
        try await add.value
        try await delete.value

        #expect(await store.completedOps == ["addMember", "deleteGroup"])
        #expect(try await store.fetchGroup(localID: work.localID) == nil)
        #expect(repository.groups.isEmpty)
    }
}
