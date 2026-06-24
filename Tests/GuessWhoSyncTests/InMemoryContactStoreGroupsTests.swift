import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("InMemoryContactStore — groups")
struct InMemoryContactStoreGroupsTests {
    private func sampleContact(localID: String) -> Contact {
        Contact(localID: localID, givenName: "Ada", familyName: "Lovelace")
    }

    @Test
    func createAndFetchAllGroups() async throws {
        let store = InMemoryContactStore()
        let a = try await store.createGroup(name: "Family")
        let b = try await store.createGroup(name: "Work")

        let all = try await store.fetchAllGroups().sorted { $0.name < $1.name }
        #expect(all.count == 2)
        #expect(all.map(\.name) == ["Family", "Work"])
        #expect(Set(all.map(\.localID)) == [a.localID, b.localID])
    }

    @Test
    func fetchGroupByIDReturnsNilWhenMissing() async throws {
        let store = InMemoryContactStore()
        #expect(try await store.fetchGroup(localID: "nope") == nil)

        let g = try await store.createGroup(name: "Family")
        let fetched = try await store.fetchGroup(localID: g.localID)
        #expect(fetched == g)
    }

    @Test
    func renameGroupPersistsAcrossFetch() async throws {
        let store = InMemoryContactStore()
        let g = try await store.createGroup(name: "Family")
        try await store.renameGroup(localID: g.localID, to: "Close Family")

        let fetched = try await store.fetchGroup(localID: g.localID)
        #expect(fetched?.name == "Close Family")
    }

    @Test
    func renameMissingGroupThrows() async throws {
        let store = InMemoryContactStore()
        await #expect(throws: ContactStoreError.self) {
            try await store.renameGroup(localID: "missing", to: "x")
        }
    }

    @Test
    func deleteGroupRemovesItAndItsMembership() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)
        let g = try await store.createGroup(name: "Family")
        try await store.addMember(contactLocalID: contact.localID, toGroup: g.localID)

        try await store.deleteGroup(localID: g.localID)

        #expect(try await store.fetchGroup(localID: g.localID) == nil)
        // membership lookup must throw groupNotFound for a deleted group
        await #expect(throws: ContactStoreError.self) {
            _ = try await store.fetchMembers(ofGroup: g.localID)
        }
        // contact's memberships list no longer contains the deleted group
        let memberships = try await store.fetchGroupMemberships(contactLocalID: contact.localID)
        #expect(memberships.isEmpty)
    }

    @Test
    func deleteMissingGroupThrows() async throws {
        let store = InMemoryContactStore()
        await #expect(throws: ContactStoreError.self) {
            try await store.deleteGroup(localID: "missing")
        }
    }

    @Test
    func addAndRemoveMember() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)
        let g = try await store.createGroup(name: "Family")

        try await store.addMember(contactLocalID: contact.localID, toGroup: g.localID)
        let members = try await store.fetchMembers(ofGroup: g.localID)
        #expect(members.map(\.localID) == ["c-1"])

        try await store.removeMember(contactLocalID: contact.localID, fromGroup: g.localID)
        let after = try await store.fetchMembers(ofGroup: g.localID)
        #expect(after.isEmpty)
    }

    @Test
    func addMemberTwiceIsIdempotent() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)
        let g = try await store.createGroup(name: "Family")

        try await store.addMember(contactLocalID: contact.localID, toGroup: g.localID)
        try await store.addMember(contactLocalID: contact.localID, toGroup: g.localID)

        let members = try await store.fetchMembers(ofGroup: g.localID)
        #expect(members.count == 1)
    }

    @Test
    func removeNonMemberIsNoOp() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)
        let g = try await store.createGroup(name: "Family")

        try await store.removeMember(contactLocalID: contact.localID, fromGroup: g.localID)
        let members = try await store.fetchMembers(ofGroup: g.localID)
        #expect(members.isEmpty)
    }

    @Test
    func membershipMutationOnMissingContactThrows() async throws {
        let store = InMemoryContactStore()
        let g = try await store.createGroup(name: "Family")

        await #expect(throws: ContactStoreError.self) {
            try await store.addMember(contactLocalID: "nope", toGroup: g.localID)
        }
        await #expect(throws: ContactStoreError.self) {
            try await store.removeMember(contactLocalID: "nope", fromGroup: g.localID)
        }
    }

    @Test
    func membershipMutationOnMissingGroupThrows() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)

        await #expect(throws: ContactStoreError.self) {
            try await store.addMember(contactLocalID: contact.localID, toGroup: "nope")
        }
        await #expect(throws: ContactStoreError.self) {
            try await store.removeMember(contactLocalID: contact.localID, fromGroup: "nope")
        }
    }

    @Test
    func fetchGroupMembershipsListsEveryContainingGroup() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)
        let family = try await store.createGroup(name: "Family")
        let work = try await store.createGroup(name: "Work")
        let unrelated = try await store.createGroup(name: "Hobbies")

        try await store.addMember(contactLocalID: contact.localID, toGroup: family.localID)
        try await store.addMember(contactLocalID: contact.localID, toGroup: work.localID)

        let memberships = try await store.fetchGroupMemberships(contactLocalID: contact.localID)
        let ids = Set(memberships.map(\.localID))
        #expect(ids == [family.localID, work.localID])
        #expect(!ids.contains(unrelated.localID))
    }

    @Test
    func fetchGroupMembershipsOnMissingContactThrows() async throws {
        let store = InMemoryContactStore()
        await #expect(throws: ContactStoreError.self) {
            _ = try await store.fetchGroupMemberships(contactLocalID: "nope")
        }
    }

    @Test
    func deletingContactClearsItFromGroups() async throws {
        let store = InMemoryContactStore()
        let contact = sampleContact(localID: "c-1")
        try await store.save(contact)
        let g = try await store.createGroup(name: "Family")
        try await store.addMember(contactLocalID: contact.localID, toGroup: g.localID)

        try await store.delete(localID: contact.localID)

        let members = try await store.fetchMembers(ofGroup: g.localID)
        #expect(members.isEmpty)
    }
}
