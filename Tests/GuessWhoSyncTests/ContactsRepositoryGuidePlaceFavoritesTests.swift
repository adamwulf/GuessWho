import Foundation
import Testing
@testable import GuessWhoSync
import GuessWhoSyncTesting

/// Guide and place favorites, unlike contacts and groups, have no cache inside
/// `ContactsRepository` — the guides live in the app's own repository — so the
/// projection hands their ids to caller-supplied resolvers, the same shape the
/// event resolver has. These tests pin what the projection promises those
/// callers: one row per favorite in order, the right payload slot filled, and a
/// resolver called with the canonical lowercased id.
@Suite("ContactsRepository — guide/place favorites projection")
struct ContactsRepositoryGuidePlaceFavoritesTests {

    private static let guideUUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!
    private static let placeUUID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000B2")!

    private func makeGuide(id: UUID = guideUUID, name: String = "Berlin") -> MapsGuide {
        MapsGuide(id: id, name: name, sourceURL: "https://maps.apple/ug/berlin")
    }

    private func makePlace(
        id: UUID = placeUUID,
        guideID: UUID = guideUUID,
        name: String = "Prater Garten"
    ) -> MapsPlace {
        MapsPlace(id: id, guideID: guideID, name: name, address: "Kastanienallee 7-9")
    }

    @Test @MainActor
    func favoriteListItemsResolveGuideWithSuppliedResolver() async {
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let guide = makeGuide()
        // The favorite is minted from an uppercase `uuidString`; the resolver is
        // handed the canonical lowercased form, so a caller comparing against a
        // lowercased `MapsGuide.id` matches regardless of the stored case.
        let favorite = Favorite(kind: .guide, id: Self.guideUUID.uuidString.uppercased(), addedAt: Date())
        let key = Self.guideUUID.uuidString.lowercased()

        let items = repository.favoriteListItems(
            from: [favorite],
            event: { _ in nil },
            guide: { id in id == key ? guide : nil }
        )

        #expect(items.count == 1)
        #expect(items[0].kind == .guide)
        #expect(items[0].id.rawValue == "guide:\(key)")
        #expect(items[0].guide?.id == Self.guideUUID)
        #expect(items[0].guide?.name == "Berlin")
        // No cross-talk into the other payload slots.
        #expect(items[0].place == nil)
        #expect(items[0].contact == nil)
        #expect(items[0].event == nil)
        #expect(items[0].group == nil)
    }

    @Test @MainActor
    func favoriteListItemsResolvePlaceWithSuppliedResolver() async {
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let place = makePlace()
        let favorite = Favorite(kind: .place, id: Self.placeUUID.uuidString, addedAt: Date())
        let key = Self.placeUUID.uuidString.lowercased()

        let items = repository.favoriteListItems(
            from: [favorite],
            event: { _ in nil },
            place: { id in id == key ? place : nil }
        )

        #expect(items.count == 1)
        #expect(items[0].kind == .place)
        #expect(items[0].id.rawValue == "place:\(key)")
        #expect(items[0].place?.id == Self.placeUUID)
        #expect(items[0].place?.name == "Prater Garten")
        // A favorited place does NOT drag its guide into the row.
        #expect(items[0].guide == nil)
        #expect(items[0].contact == nil)
        #expect(items[0].event == nil)
        #expect(items[0].group == nil)
    }

    @Test @MainActor
    func favoriteListItemsKeepUnresolvedGuideAndPlaceRows() async {
        // The guide/place is gone (deleted, or its sidecar hasn't synced yet).
        // The row must survive with a nil payload — the Favorites list renders
        // "Unavailable" and the user can still un-favorite it. Dropping the row
        // would strand the favorite in the file with no way to remove it.
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let favorites = [
            Favorite(kind: .guide, id: Self.guideUUID.uuidString, addedAt: Date()),
            Favorite(kind: .place, id: Self.placeUUID.uuidString, addedAt: Date())
        ]

        let items = repository.favoriteListItems(
            from: favorites,
            event: { _ in nil },
            guide: { _ in nil },
            place: { _ in nil }
        )

        #expect(items.count == 2)
        #expect(items.map(\.kind) == [.guide, .place])
        #expect(items[0].guide == nil)
        #expect(items[1].place == nil)
    }

    @Test @MainActor
    func favoriteListItemsLeaveGuideAndPlaceUnresolvedWhenNoResolverIsSupplied() async {
        // The guide/place resolvers are defaulted, so a caller that shows
        // neither kind still compiles — and its rows read as unavailable rather
        // than resolving to the wrong record.
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let favorites = [
            Favorite(kind: .guide, id: Self.guideUUID.uuidString, addedAt: Date()),
            Favorite(kind: .place, id: Self.placeUUID.uuidString, addedAt: Date())
        ]

        let items = repository.favoriteListItems(from: favorites, event: { _ in nil })

        #expect(items.map(\.kind) == [.guide, .place])
        #expect(items[0].guide == nil)
        #expect(items[1].place == nil)
    }

    @Test @MainActor
    func aTrailingClosureStillBindsToTheEventResolver() async throws {
        // Callers written before guide/place existed pass the event resolver as
        // an unlabelled trailing closure. Swift matches that closure forward to
        // the first parameter that can take it (SE-0286), so appending the
        // defaulted guide/place resolvers AFTER `event:` must not capture it —
        // if it ever did, those call sites would silently stop resolving events
        // rather than fail to build.
        let repository = ContactsRepository(contacts: InMemoryContactStore())
        let eventID = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let event = Event(
            id: eventID,
            title: "Favorite Event",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600)
        )
        let favorite = Favorite(kind: .event, id: eventID.uuidString, addedAt: Date())

        let items = repository.favoriteListItems(from: [favorite]) { id in
            id == eventID.uuidString.lowercased() ? event : nil
        }

        #expect(items.count == 1)
        #expect(items[0].event?.title == "Favorite Event")
    }

    @Test @MainActor
    func favoriteListItemsProjectAllFiveKindsInOrder() async throws {
        let contactUUID = "55555555-5555-5555-5555-555555555555"
        let contact = Contact(
            localID: "r",
            givenName: "Favorite",
            urlAddresses: [LabeledValue(label: "GuessWho", value: "guesswho://contact/\(contactUUID)")]
        )
        let store = InMemoryContactStore(contacts: [contact])
        let family = try await store.createGroup(name: "Family")
        let sync = GuessWhoSync(
            contacts: store,
            events: InMemoryEventStore(),
            sidecars: InMemorySidecarStore(),
            deviceID: "device-test")
        let repository = ContactsRepository(contacts: store, sync: sync)
        await repository.reload()
        await repository.loadGroups()
        let emptyFingerprint = GroupIdentity.fingerprint(forGuessWhoIDs: [])
        let groupIdentity = try sync.mintGroupIdentity(
            name: family.name,
            account: nil,
            memberCount: 0,
            memberHash: emptyFingerprint.memberHash,
            hashedMemberCount: emptyFingerprint.hashedMemberCount,
            localID: family.localID)
        _ = try await repository.resolveGroupIdentity(id: groupIdentity.id)

        let eventID = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let event = Event(
            id: eventID,
            title: "Favorite Event",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let favorites = [
            Favorite(kind: .contact, id: contactUUID, addedAt: now),
            Favorite(kind: .event, id: eventID.uuidString, addedAt: now.addingTimeInterval(1)),
            Favorite(kind: .group, id: groupIdentity.id, addedAt: now.addingTimeInterval(2)),
            Favorite(kind: .guide, id: Self.guideUUID.uuidString, addedAt: now.addingTimeInterval(3)),
            Favorite(kind: .place, id: Self.placeUUID.uuidString, addedAt: now.addingTimeInterval(4))
        ]
        let guideKey = Self.guideUUID.uuidString.lowercased()
        let placeKey = Self.placeUUID.uuidString.lowercased()

        let items = repository.favoriteListItems(
            from: favorites,
            event: { id in id == eventID.uuidString.lowercased() ? event : nil },
            guide: { id in id == guideKey ? self.makeGuide() : nil },
            place: { id in id == placeKey ? self.makePlace() : nil }
        )

        // Order is the persisted order, unchanged by kind.
        #expect(items.map(\.kind) == [.contact, .event, .group, .guide, .place])
        #expect(items.map(\.id) == favorites.map { FavoriteListItem.ID($0.stableID) })

        // Each row carries exactly one payload — the one its kind names.
        #expect(items[0].contact?.localID == "r")
        #expect(items[1].event?.title == "Favorite Event")
        #expect(items[2].group?.name == "Family")
        #expect(items[3].guide?.name == "Berlin")
        #expect(items[4].place?.name == "Prater Garten")

        func payloadCount(_ item: FavoriteListItem) -> Int {
            [item.contact != nil, item.event != nil, item.group != nil, item.guide != nil, item.place != nil]
                .filter { $0 }.count
        }
        #expect(items.allSatisfy { payloadCount($0) == 1 })
    }
}
