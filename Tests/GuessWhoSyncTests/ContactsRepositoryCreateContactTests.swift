import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

private struct InjectedCreationTimestampFailure: Error {}

private final class FailFirstCreationTimestampWriteStore: SidecarStoreProtocol {
    private let inner = InMemorySidecarStore()
    private var shouldFailWrite = true

    func read(_ key: SidecarKey) throws -> SidecarEnvelope? {
        try inner.read(key)
    }

    func write(_ envelope: SidecarEnvelope, at key: SidecarKey) throws {
        if shouldFailWrite {
            shouldFailWrite = false
            throw InjectedCreationTimestampFailure()
        }
        try inner.write(envelope, at: key)
    }

    func delete(_ key: SidecarKey) throws {
        try inner.delete(key)
    }

    func allKeys() throws -> [SidecarKey] {
        try inner.allKeys()
    }

    func downloadStatus(_ key: SidecarKey) -> SidecarDownloadStatus {
        inner.downloadStatus(key)
    }

    func requestDownload(_ key: SidecarKey) throws {
        try inner.requestDownload(key)
    }
}

/// `ContactsRepository.createContact(_:)` — the create-returning-identity
/// entry point behind the app's "+" add-contact flow and the LinkedIn
/// no-match import. Unlike `save` (which also inserts on an unknown
/// `localID` but returns nothing), `createContact` hands back the cached
/// record carrying the store-issued identity so the caller can open it or
/// apply follow-up writes.
@Suite("ContactsRepository.createContact")
struct ContactsRepositoryCreateContactTests {
    @MainActor
    private func makeRepo() async -> (ContactsRepository, InMemoryContactStore, GuessWhoSync) {
        let store = InMemoryContactStore()
        let sync = GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test"
        )
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        return (repo, store, sync)
    }

    @Test @MainActor
    func blankSeed_createsRecordAndReturnsCachedIdentity() async throws {
        let (repo, store, _) = await makeRepo()
        let created = try await repo.createContact(Contact())

        // Store issued a real identity...
        #expect(!created.localID.isEmpty)
        // ...the record is in the backing store...
        #expect(try await store.fetch(localID: created.localID) != nil)
        // ...and already in the repository cache, addressable both ways.
        #expect(repo.contact(localID: created.localID) != nil)
        #expect(repo.contact(id: created.contactID) != nil)
    }

    @Test @MainActor
    func seededFields_carryThroughToTheCreatedRecord() async throws {
        let (repo, _, _) = await makeRepo()
        let seed = Contact(
            givenName: "Ada",
            familyName: "Lovelace",
            emailAddresses: [LabeledValue(label: "", value: "ada@example.com")]
        )
        let created = try await repo.createContact(seed)
        #expect(created.givenName == "Ada")
        #expect(created.familyName == "Lovelace")
        #expect(created.emailAddresses.map(\.value) == ["ada@example.com"])
        // The new record is findable through the normal match indexes.
        #expect(repo.contactIDs(matchingEmail: "ada@example.com") == [created.contactID])
    }

    @Test @MainActor
    func seedLocalID_isIgnored_storeIssuesItsOwn() async throws {
        let (repo, _, _) = await makeRepo()
        let created = try await repo.createContact(Contact(localID: "STALE-SEED-ID"))
        #expect(created.localID != "STALE-SEED-ID")
        #expect(repo.contact(localID: "STALE-SEED-ID") == nil)
    }

    @Test @MainActor
    func create_stampsCreatedAndModifiedAtTheSameTime() async throws {
        let before = Date()
        let (repo, _, sync) = await makeRepo()
        let created = try await repo.createContact(Contact(givenName: "Ada"))
        let after = Date()
        let guessWhoID = try #require(ContactID(contact: created).guessWhoID)
        let timestamps = try sync.contactTimestamps(
            at: SidecarKey(kind: .contact, id: guessWhoID)
        )
        let createdAt = try #require(timestamps.createdAt)
        #expect(createdAt.timeIntervalSince(before) >= -0.01)
        #expect(createdAt.timeIntervalSince(after) <= 0.01)
        #expect(timestamps.lastModified == createdAt)
    }

    @Test @MainActor
    func failedTimestampWriteIsDurablyRetriedWithOriginalCreationInstant() async throws {
        let defaultsName = "ContactsRepositoryCreateContactTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let contacts = InMemoryContactStore()
        let sidecars = FailFirstCreationTimestampWriteStore()
        let firstSync = GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
        let firstJournal = UserDefaultsContactCreationTimestampRepairStore(defaults: defaults)
        let firstRepository = ContactsRepository(
            contacts: contacts,
            sync: firstSync,
            notificationCenter: NotificationCenter(),
            creationTimestampRepairs: firstJournal
        )

        let before = Date()
        let created = try await firstRepository.createContact(Contact(givenName: "Ada"))
        let after = Date()
        let pending = try #require(firstJournal.pendingRepairs().first)
        #expect(pending.localID == created.localID)
        #expect(pending.createdAt.timeIntervalSince(before) >= -0.01)
        #expect(pending.createdAt.timeIntervalSince(after) <= 0.01)

        // Reconstruct both the journal facade and repository, modeling a later
        // launch after the transient write failure.
        let secondSync = GuessWhoSync(
            contacts: contacts,
            events: InMemoryEventStore(),
            sidecars: sidecars,
            deviceID: "device-test"
        )
        let secondJournal = UserDefaultsContactCreationTimestampRepairStore(defaults: defaults)
        let secondRepository = ContactsRepository(
            contacts: contacts,
            sync: secondSync,
            notificationCenter: NotificationCenter(),
            creationTimestampRepairs: secondJournal
        )
        await secondRepository.reload()

        let repairedContact = try #require(secondRepository.contact(localID: created.localID))
        let guessWhoID = try #require(ContactID(contact: repairedContact).guessWhoID)
        let timestamps = try secondSync.contactTimestamps(
            at: SidecarKey(kind: .contact, id: guessWhoID)
        )
        // Sidecar dates round-trip through their ISO-8601 wire precision.
        #expect(abs(try #require(timestamps.createdAt).timeIntervalSince(pending.createdAt)) < 0.01)
        #expect(abs(try #require(timestamps.lastModified).timeIntervalSince(pending.createdAt)) < 0.01)
        #expect(secondJournal.pendingRepairs().isEmpty)
    }
}
