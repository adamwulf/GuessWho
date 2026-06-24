import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

@Suite("InMemoryContactStore.changes(since:)")
struct InMemoryContactStoreChangesTests {
    private func sampleContact(localID: String) -> Contact {
        Contact(localID: localID, givenName: "Ada", familyName: "Lovelace")
    }

    // MARK: - nil token

    @Test
    func nilTokenBaselinesWithFullReload() async throws {
        let store = InMemoryContactStore()
        try await store.save(sampleContact(localID: "a"), author: "external")

        let result = try await store.changes(since: nil)

        #expect(result.requiresFullReload)
        #expect(result.changes.isEmpty)
        // The returned token leaves the caller caught up.
        let next = try await store.changes(since: result.newToken)
        #expect(!next.requiresFullReload)
        #expect(next.changes.isEmpty)
    }

    // MARK: - ordered deltas

    @Test
    func addUpdateDeleteDeltasInOrder() async throws {
        let store = InMemoryContactStore()
        let baseline = try await store.changes(since: nil)

        try await store.save(sampleContact(localID: "a"), author: "external")     // add
        var updated = sampleContact(localID: "a")
        updated.givenName = "Augusta"
        try await store.save(updated, author: "external")                          // update
        try await store.delete(localID: "a", author: "external")                   // delete

        let result = try await store.changes(since: baseline.newToken)
        #expect(!result.requiresFullReload)
        #expect(result.changes == [
            .updated(localID: "a"),
            .updated(localID: "a"),
            .deleted(localID: "a"),
        ])
    }

    @Test
    func onlyChangesAfterTheGivenTokenAreReturned() async throws {
        let store = InMemoryContactStore()
        try await store.save(sampleContact(localID: "a"), author: "external")
        let mid = try await store.changes(since: nil) // baseline after "a"

        try await store.save(sampleContact(localID: "b"), author: "external")

        let result = try await store.changes(since: mid.newToken)
        #expect(result.changes == [.updated(localID: "b")])
    }

    // MARK: - delete-then-readd ordering

    @Test
    func deleteThenReaddPreservesOrderAndEndsPresent() async throws {
        let store = InMemoryContactStore()
        try await store.save(sampleContact(localID: "x"), author: "external")
        let baseline = try await store.changes(since: nil)

        try await store.delete(localID: "x", author: "external")
        try await store.save(sampleContact(localID: "x"), author: "external")

        let result = try await store.changes(since: baseline.newToken)
        // Order must be delete THEN update — not bucketed — so applying it ends
        // with the contact present.
        #expect(result.changes == [
            .deleted(localID: "x"),
            .updated(localID: "x"),
        ])
    }

    // MARK: - excluded author

    @Test
    func excludedAuthorWritesAreNotReported() async throws {
        let store = InMemoryContactStore()
        let baseline = try await store.changes(since: nil)

        // Our own writes use the self author and are excluded by default.
        try await store.save(sampleContact(localID: "self"), author: InMemoryContactStore.selfTransactionAuthor)
        // An external write IS reported.
        try await store.save(sampleContact(localID: "ext"), author: "external")

        let result = try await store.changes(since: baseline.newToken)
        #expect(result.changes == [.updated(localID: "ext")])
    }

    @Test
    func defaultSaveUsesExcludedSelfAuthorWhenSet() async throws {
        let store = InMemoryContactStore()
        await store.setTransactionAuthor(InMemoryContactStore.selfTransactionAuthor)
        let baseline = try await store.changes(since: nil)

        try await store.save(sampleContact(localID: "self"))   // tagged self → excluded
        try await store.setTransactionAuthor("external")
        try await store.save(sampleContact(localID: "ext"))    // tagged external → reported

        let result = try await store.changes(since: baseline.newToken)
        #expect(result.changes == [.updated(localID: "ext")])
    }

    // MARK: - drop everything

    @Test
    func dropEverythingForcesFullReload() async throws {
        let store = InMemoryContactStore()
        try await store.save(sampleContact(localID: "a"), author: "external")
        let baseline = try await store.changes(since: nil)
        try await store.save(sampleContact(localID: "b"), author: "external")

        await store.simulateDropEverything()

        let result = try await store.changes(since: baseline.newToken)
        #expect(result.requiresFullReload)
        #expect(result.changes.isEmpty)
        // After the drop, a fresh baseline catches the caller up again.
        let next = try await store.changes(since: result.newToken)
        #expect(!next.requiresFullReload)
    }

    @Test
    func tokenOlderThanRetainedLogForcesFullReload() async throws {
        let store = InMemoryContactStore()
        // A malformed / wrong-size token decodes to "from the beginning" and a
        // genuinely stale token (below the drop boundary) both force a reload.
        try await store.save(sampleContact(localID: "a"), author: "external")
        await store.simulateDropEverything()

        // A wrong-size token is treated as nil ⇒ full reload.
        let bogus = try await store.changes(since: Data([0x01, 0x02]))
        #expect(bogus.requiresFullReload)
    }
}
