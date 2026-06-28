import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// The `ContactID`-keyed stamp verbs on `ContactsRepository`
/// (`stampModified`/`stampInteracted`/`stampViewed`). Like every other write
/// here they resolve-or-mint first, so the FIRST stamp to an unreconciled
/// contact reconciles + mints its GuessWho URL, writes the cell, and refreshes
/// the bulk timestamp cache so a time-ordered list reflects it. With no engine
/// they throw `SidecarUnavailableError`.
@Suite("ContactsRepository stamp verbs")
@MainActor
struct ContactsRepositoryStampTests {
    private func makeSync(_ store: InMemoryContactStore) -> GuessWhoSync {
        GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: InMemorySidecarStore(), deviceID: "device-test")
    }

    @Test
    func stampViewed_onUnreconciledContact_mintsAndStamps() async throws {
        let target = Contact(localID: "TARGET", givenName: "Ada")
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(store)
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()

        let id = try #require(repo.contact(localID: "TARGET")).contactID
        #expect(id.guessWhoID == nil)

        try await repo.stampViewed(id)

        // The store record now carries a minted GuessWho URL, and the viewed
        // timestamp is readable through the now-reconciled id.
        let saved = try #require(try await store.fetch(localID: "TARGET"))
        let reconciledID = saved.contactID
        let guessWhoID = try #require(reconciledID.guessWhoID)
        let ts = try sync.contactTimestamps(at: SidecarKey(kind: .contact, id: guessWhoID))
        #expect(ts.lastViewed != nil)
        #expect(ts.lastModified == nil)
        #expect(ts.lastInteracted == nil)
    }

    @Test
    func eachStampVerb_writesItsOwnCell() async throws {
        let target = Contact(
            localID: "RECON",
            givenName: "Grace",
            urlAddresses: [LabeledValue(label: "g", value: "\(SidecarKey.guessWhoContactURLPrefix)99999999-9999-9999-9999-999999999999")]
        )
        let store = InMemoryContactStore(contacts: [target])
        let sync = makeSync(store)
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()

        let id = try #require(repo.contact(localID: "RECON")).contactID
        try await repo.stampModified(id)
        try await repo.stampInteracted(id)
        try await repo.stampViewed(id)

        let guessWhoID = try #require(id.guessWhoID)
        let ts = try sync.contactTimestamps(at: SidecarKey(kind: .contact, id: guessWhoID))
        #expect(ts.lastModified != nil)
        #expect(ts.lastInteracted != nil)
        #expect(ts.lastViewed != nil)
    }

    @Test
    func stamp_refreshesTimestampCache_soTimeSortSeesIt() async throws {
        // Two reconciled contacts. Stamp ONLY 'stamped' — under .lastViewed it
        // must jump ahead of the never-viewed 'unstamped' (nil → last) WITHOUT
        // an explicit reload, proving the stamp path refreshed the bulk cache.
        // Names are chosen so the DEFAULT alphabetical tie-break would put
        // 'unstamped' first; the time sort overrides that.
        let stamped = Contact(
            localID: "stamped",
            givenName: "Zoe",
            urlAddresses: [LabeledValue(label: "g", value: "\(SidecarKey.guessWhoContactURLPrefix)10000000-0000-0000-0000-000000000001")]
        )
        let unstamped = Contact(
            localID: "unstamped",
            givenName: "Amy",
            urlAddresses: [LabeledValue(label: "g", value: "\(SidecarKey.guessWhoContactURLPrefix)10000000-0000-0000-0000-000000000002")]
        )
        let store = InMemoryContactStore(contacts: [stamped, unstamped])
        let sync = makeSync(store)
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        repo.sortOrder = .lastViewed

        // Before any stamp: both nil → tie-break alphabetical (Amy before Zoe).
        #expect(repo.people.map(\.localID) == ["unstamped", "stamped"])

        try await repo.stampViewed(repo.contact(localID: "stamped")!.contactID)

        // After stamping 'stamped': it has a viewed timestamp, the other is nil
        // (→ last). No explicit reload — the stamp path refreshed the cache.
        #expect(repo.people.map(\.localID) == ["stamped", "unstamped"])
    }

    @Test
    func stamp_withNilEngine_throws() async {
        let target = Contact(localID: "T", givenName: "Z")
        let store = InMemoryContactStore(contacts: [target])
        let repo = ContactsRepository(contacts: store)   // no sync engine
        await repo.reload()
        let id = repo.contact(localID: "T")!.contactID

        await #expect(throws: SidecarUnavailableError.self) {
            try await repo.stampViewed(id)
        }
    }
}
