import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Repository-level coverage for the global `ContactSortOrder`: the two name
/// orders (`firstLast`/`lastFirst`) and the time orders (`lastModified` etc.),
/// plus the relative-time bucketing of a time order against an injected `now`.
///
/// Time-ordered sorts read the bulk timestamp cache, which is keyed on the
/// GuessWho UUID — so the contacts here are RECONCILED (each carries a
/// `guesswho://contact/<uuid>` URL) and their timestamps are stamped straight
/// onto the sidecar via the engine (which accepts an explicit `now`), then the
/// repository `reload()` pulls them into the cache.
@Suite("ContactSortOrder")
@MainActor
struct ContactSortOrderTests {
    /// A reconciled contact carrying the GuessWho URL for `uuid`.
    private func person(localID: String, given: String, family: String, uuid: String) -> Contact {
        Contact(
            localID: localID,
            givenName: given,
            familyName: family,
            urlAddresses: [LabeledValue(label: "guesswho", value: "\(SidecarKey.guessWhoContactURLPrefix)\(uuid)")]
        )
    }

    private func key(_ uuid: String) -> SidecarKey { SidecarKey(kind: .contact, id: uuid) }

    // MARK: - Name orders

    @Test
    func lastFirst_sortsByFamilyName_default() async {
        // Adams, Brown, Carter by family name regardless of given name order.
        let a = person(localID: "1", given: "Zoe", family: "Adams", uuid: "11111111-1111-1111-1111-111111111111")
        let b = person(localID: "2", given: "Amy", family: "Brown", uuid: "22222222-2222-2222-2222-222222222222")
        let c = person(localID: "3", given: "Bob", family: "Carter", uuid: "33333333-3333-3333-3333-333333333333")
        let store = InMemoryContactStore(contacts: [c, a, b])
        let repo = ContactsRepository(contacts: store)
        await repo.reload()

        // Default order is .lastFirst.
        #expect(repo.sortOrder == .lastFirst)
        #expect(repo.people.map(\.localID) == ["1", "2", "3"])
        #expect(repo.peopleSections.map(\.0) == ["A", "B", "C"])
    }

    @Test
    func firstLast_sortsByGivenName() async {
        // By given name: Amy, Bob, Zoe.
        let a = person(localID: "1", given: "Zoe", family: "Adams", uuid: "11111111-1111-1111-1111-111111111111")
        let b = person(localID: "2", given: "Amy", family: "Brown", uuid: "22222222-2222-2222-2222-222222222222")
        let c = person(localID: "3", given: "Bob", family: "Carter", uuid: "33333333-3333-3333-3333-333333333333")
        let store = InMemoryContactStore(contacts: [c, a, b])
        let repo = ContactsRepository(contacts: store)
        await repo.reload()
        repo.sortOrder = .firstLast

        #expect(repo.people.map(\.localID) == ["2", "3", "1"])  // Amy, Bob, Zoe
        // Sections by first-name leading letter.
        #expect(repo.peopleSections.map(\.0) == ["A", "B", "Z"])
    }

    // MARK: - Time orders

    @Test
    func lastViewed_sortsDescending_nilGoesLast() async throws {
        let recentUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let olderUUID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let neverUUID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let recent = person(localID: "recent", given: "R", family: "R", uuid: recentUUID)
        let older = person(localID: "older", given: "O", family: "O", uuid: olderUUID)
        let never = person(localID: "never", given: "N", family: "N", uuid: neverUUID)

        let sidecars = InMemorySidecarStore()
        let store = InMemoryContactStore(contacts: [recent, older, never])
        let sync = GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
        // Stamp 'recent' more recently than 'older'; 'never' is unstamped.
        try sync.stampContactTimestamp(.viewed, at: key(recentUUID), now: Date(timeIntervalSince1970: 2_000_000))
        try sync.stampContactTimestamp(.viewed, at: key(olderUUID), now: Date(timeIntervalSince1970: 1_000_000))

        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        repo.sortOrder = .lastViewed

        // DESC by viewed timestamp; the never-viewed contact sorts to the END.
        #expect(repo.people.map(\.localID) == ["recent", "older", "never"])
    }

    @Test
    func timeOrder_ignoresWrongTimestampKind() async throws {
        // A contact stamped only for `interacted` has a nil `viewed` and so
        // sorts to the end under .lastViewed.
        let viewedUUID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let interactedUUID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let viewedC = person(localID: "viewed", given: "V", family: "V", uuid: viewedUUID)
        let interactedC = person(localID: "interacted", given: "I", family: "I", uuid: interactedUUID)

        let sidecars = InMemorySidecarStore()
        let store = InMemoryContactStore(contacts: [viewedC, interactedC])
        let sync = GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
        try sync.stampContactTimestamp(.viewed, at: key(viewedUUID), now: Date(timeIntervalSince1970: 1_000_000))
        try sync.stampContactTimestamp(.interacted, at: key(interactedUUID), now: Date(timeIntervalSince1970: 9_000_000))

        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        repo.sortOrder = .lastViewed

        // Only `viewed` has a viewed-timestamp; the interacted-only one is nil → last.
        #expect(repo.people.map(\.localID) == ["viewed", "interacted"])
    }

    // MARK: - Time buckets

    @Test
    func timeBuckets_todayVsEarlier() async throws {
        // Fixed reference 'now' = 2026-06-28 12:00 UTC.
        let now = Date(timeIntervalSince1970: 1_782_648_000)
        let todayUUID = "f0000000-0000-0000-0000-000000000001"
        let earlierUUID = "f0000000-0000-0000-0000-000000000002"
        let todayC = person(localID: "today", given: "T", family: "T", uuid: todayUUID)
        let earlierC = person(localID: "earlier", given: "E", family: "E", uuid: earlierUUID)

        let sidecars = InMemorySidecarStore()
        let store = InMemoryContactStore(contacts: [todayC, earlierC])
        let sync = GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
        // 'today' stamped one hour before now; 'earlier' stamped a year before.
        try sync.stampContactTimestamp(.viewed, at: key(todayUUID), now: now.addingTimeInterval(-3_600))
        try sync.stampContactTimestamp(.viewed, at: key(earlierUUID), now: now.addingTimeInterval(-365 * 24 * 3_600))

        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        repo.sortOrder = .lastViewed

        let sections = repo.peopleSections(now: now)
        let titles = sections.map(\.0)
        #expect(titles == ["Today", "Earlier"])
        #expect(sections.first { $0.0 == "Today" }?.1.map(\.localID) == ["today"])
        #expect(sections.first { $0.0 == "Earlier" }?.1.map(\.localID) == ["earlier"])
        // Only non-empty buckets appear.
        #expect(!titles.contains("This Week"))
        #expect(!titles.contains("This Month"))
    }

    @Test
    func timeBuckets_neverStamped_isEarlier() async {
        // A reconciled but never-stamped contact buckets as "Earlier" under a
        // time order (nil timestamp → Earlier).
        let uuid = "f0000000-0000-0000-0000-000000000003"
        let c = person(localID: "x", given: "X", family: "X", uuid: uuid)
        let sidecars = InMemorySidecarStore()
        let store = InMemoryContactStore(contacts: [c])
        let sync = GuessWhoSync(contacts: store, events: InMemoryEventStore(), sidecars: sidecars, deviceID: "device-test")
        let repo = ContactsRepository(contacts: store, sync: sync)
        await repo.reload()
        repo.sortOrder = .lastModified

        let sections = repo.peopleSections(now: Date(timeIntervalSince1970: 1_782_648_000))
        #expect(sections.map(\.0) == ["Earlier"])
        #expect(sections.first?.1.map(\.localID) == ["x"])
    }
}
