import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

final class FavoritesToolTests: XCTestCase {
    private func fixture(writable: Bool = false) async -> Fixture {
        let fixture = await Fixture.make()
        if writable {
            await MainActor.run {
                fixture.gates.mcpAccess = .readWrite
                fixture.gates.cliAccess = .readWrite
            }
        }
        return fixture
    }

    private func list(_ fixture: Fixture, limit: Int? = nil, cursor: String? = nil) async -> WirePage<WireFavorite>? {
        let response = await fixture.dispatcher.handle(.favoritesList(
            helperId: Fixture.helper, messageId: TestMessageID.next(),
            limit: limit, cursor: cursor))
        guard case .favoritePage(_, _, let page) = response else { return nil }
        return page
    }

    private func error(
        _ response: WireResponse?, _ code: WireErrorCode,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(response?.errorPayload?.code, code, file: file, line: line)
    }

    @MainActor
    private func installEveryKind(_ fixture: Fixture, collision: Bool = false) -> [WireFavoriteIdentity] {
        let jane = fixture.contacts.contacts[0]
        let event = fixture.events.events[0]
        let group = fixture.contacts.groups[0]
        let guide = fixture.guides.guides[0]
        let place = fixture.guides.places[0]
        let shared = collision ? guide.id : place.id
        if collision {
            fixture.guides.places[0] = MapsPlace(
                id: shared, guideID: guide.id, name: place.name,
                address: place.address, latitude: place.latitude, longitude: place.longitude)
        }
        fixture.favorites.items = [
            Favorite(kind: .contact, id: Sentinels.guessWhoUUID, addedAt: Date(timeIntervalSince1970: 1)),
            Favorite(kind: .event, id: event.id.uuidString, addedAt: Date(timeIntervalSince1970: 2)),
            Favorite(kind: .group, id: group.localID, addedAt: Date(timeIntervalSince1970: 3)),
            Favorite(kind: .guide, id: guide.id.uuidString, addedAt: Date(timeIntervalSince1970: 4)),
            Favorite(kind: .place, id: shared.uuidString, addedAt: Date(timeIntervalSince1970: 5)),
        ]
        fixture.contacts.favoriteEffectiveIDs = [Sentinels.guessWhoUUID]
        return [
            WireFavoriteIdentity(kind: .contact, id: WireRecordIDForTests.contact(jane)),
            WireFavoriteIdentity(kind: .event, id: event.id.uuidString.lowercased()),
            WireFavoriteIdentity(kind: .group, id: ""), // filled from list
            WireFavoriteIdentity(kind: .guide, id: guide.id.uuidString.lowercased()),
            WireFavoriteIdentity(kind: .place, id: shared.uuidString.lowercased()),
        ]
    }

    func testListEveryKindPreservesStoredOrderNamesAddedAtAndOpaqueIDs() async throws {
        let fixture = await fixture()
        let rawGroupID = await MainActor.run { fixture.contacts.groups[0].localID }
        _ = await MainActor.run { installEveryKind(fixture) }

        guard let first = await list(fixture, limit: 2) else { return XCTFail("no first page") }
        XCTAssertEqual(first.items.map(\.kind), [.contact, .event])
        XCTAssertEqual(first.nextCursor, "o2")
        guard let second = await list(fixture, limit: 3, cursor: first.nextCursor) else {
            return XCTFail("no second page")
        }
        XCTAssertEqual(second.items.map(\.kind), [.group, .guide, .place])
        XCTAssertNil(second.nextCursor)
        let all = first.items + second.items
        XCTAssertEqual(all.map(\.displayName), [
            "Jane Doe", "Museum Gala", "Museum Friends", "Coffee Crawl", "Bluebird Espresso",
        ])
        XCTAssertTrue(all.allSatisfy(\.isAvailable))
        XCTAssertEqual(all.first?.addedAt, "1970-01-01T00:00:01Z")
        XCTAssertTrue(all[2].id.hasPrefix("g-"))
        XCTAssertFalse(all[2].id.contains(rawGroupID))
        XCTAssertFalse(all[1].id.hasPrefix("e-"), "stored events use ordinary record ids")
        let contactReads = await MainActor.run { fixture.contacts.allContactsReadCount }
        XCTAssertEqual(contactReads, 1, "a page without contact favorites must not fetch contacts")
    }

    func testStaleRowsStayInPlaceAndNeverLeakStoredIdentifier() async {
        let fixture = await fixture(writable: true)
        let raw = "EK-RAW-CALENDAR-SHOULD-NOT-CROSS"
        await MainActor.run {
            fixture.favorites.items = [
                Favorite(kind: .event, id: raw, addedAt: Date(timeIntervalSince1970: 9)),
                Favorite(kind: .contact, id: Sentinels.guessWhoUUID, addedAt: Date(timeIntervalSince1970: 10)),
            ]
        }
        guard let page = await list(fixture) else { return XCTFail("no page") }
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].displayName, "Unavailable")
        XCTAssertFalse(page.items[0].isAvailable)
        XCTAssertEqual(page.items[1].displayName, "Jane Doe")
        XCTAssertFalse(page.items[0].id.contains(raw))

        let cleared = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "clear-stale", kind: .event,
            id: page.items[0].id, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = cleared else { return XCTFail("stale clear failed") }
        let remaining = await list(fixture)
        XCTAssertEqual(remaining?.items.map(\.kind), [.contact])
    }

    func testReadFailureIsExplicitInsteadOfAnEmptyPage() async {
        let fixture = await fixture()
        await MainActor.run { fixture.favorites.failReads = true }
        let response = await fixture.dispatcher.handle(.favoritesList(
            helperId: Fixture.helper, messageId: "read-failure", limit: nil, cursor: nil))
        error(response, .busy)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.favoritesReadFailed)
    }

    func testGroupOpaqueIDStaysStableWhenReferentBecomesStale() async {
        let fixture = await fixture()
        let group = await MainActor.run { fixture.contacts.groups[0] }
        await MainActor.run {
            fixture.favorites.items = [Favorite(kind: .group, id: group.localID, addedAt: Date())]
        }
        guard let liveID = await list(fixture)?.items.first?.id else { return XCTFail("no live row") }
        await MainActor.run { fixture.contacts.groups = [] }
        guard let stale = await list(fixture)?.items.first else { return XCTFail("no stale row") }
        XCTAssertEqual(stale.id, liveID)
        XCTAssertFalse(stale.isAvailable)
    }

    func testCalendarOnlyEventOpaqueIDResolvesButCannotBeFavoritedBeforeAppSetup() async {
        let fixture = await fixture(writable: true)
        let response = await fixture.dispatcher.handle(.eventsList(
            helperId: Fixture.helper, messageId: "events",
            startDate: "2025-10-01T00:00:00Z", endDate: "2025-12-31T00:00:00Z",
            limit: nil, cursor: nil))
        guard case .eventPage(_, _, let page) = response,
              let dentist = page.items.first(where: { $0.title == "Dentist" })
        else { return XCTFail("missing calendar-only event") }
        XCTAssertTrue(dentist.id.hasPrefix("e-"))
        XCTAssertFalse(dentist.id.contains("EK-SENTINEL-42"))
        let set = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "set", kind: .event,
            id: dentist.id, favorite: true, idempotencyToken: nil))
        error(set, .requiresAppAction)
        XCTAssertFalse(set?.agentVisibleText.contains("EK-SENTINEL-42") ?? true)
    }

    func testSetSupportsEveryKindAndIsDesiredStateIdempotent() async {
        let fixture = await fixture(writable: true)
        _ = await MainActor.run { installEveryKind(fixture) }
        let current = await list(fixture)
        guard let entries = current?.items else { return XCTFail("no entries") }

        await MainActor.run {
            fixture.favorites.items = []
            fixture.contacts.favoriteEffectiveIDs = []
        }
        for entry in entries {
            let token = "set-\(entry.kind.rawValue)"
            let first = await fixture.dispatcher.handle(.favoritesSet(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                kind: entry.kind, id: entry.id, favorite: true, idempotencyToken: token))
            guard case .acknowledged = first else { return XCTFail("set failed: \(String(describing: first))") }
            let duplicate = await fixture.dispatcher.handle(.favoritesSet(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                kind: entry.kind, id: entry.id, favorite: true, idempotencyToken: token))
            guard case .acknowledged = duplicate else { return XCTFail("retry failed") }
        }
        let stored = await MainActor.run { fixture.favorites.items }
        XCTAssertEqual(stored.map(\.kind), [.contact, .event, .group, .guide, .place])
        XCTAssertEqual(stored.count, 5)
    }

    func testContactsCompatibilityUsesSameFavoriteState() async {
        let fixture = await fixture(writable: true)
        let contactID = Sentinels.guessWhoUUID
        let genericClear = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "g1", kind: .contact,
            id: contactID, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = genericClear else { return XCTFail("generic clear failed") }
        let isEmpty = await MainActor.run { fixture.favorites.items.isEmpty }
        XCTAssertTrue(isEmpty)

        let compatibilitySet = await fixture.dispatcher.handle(.contactsSetFavorite(
            helperId: Fixture.helper, messageId: "c1", contactId: contactID,
            favorite: true, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = compatibilitySet else {
            return XCTFail("compat set failed")
        }
        XCTAssertEqual(message, WireAckMessage.favoriteSet)
        let stored = await MainActor.run { fixture.favorites.items }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.kind, .contact)
    }

    func testKindMismatchAndUnknownReferentsNeverWrite() async {
        let fixture = await fixture(writable: true)
        let mismatched = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "m1", kind: .contact,
            id: "g-not-a-contact", favorite: true, idempotencyToken: nil))
        error(mismatched, .invalidParams)
        let guideID = await MainActor.run { fixture.guides.guides[0].id.uuidString }
        let resolvableWrongKind = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "m1b", kind: .contact,
            id: guideID, favorite: true, idempotencyToken: nil))
        error(resolvableWrongKind, .invalidParams)
        let unknown = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "m2", kind: .guide,
            id: UUID().uuidString, favorite: true, idempotencyToken: nil))
        error(unknown, .notFound)
        let setCalls = await MainActor.run { fixture.favorites.setCallCount }
        XCTAssertEqual(setCalls, 0)
    }

    func testReorderUsesCompositeIdentityAndAllowsCrossKindIDCollision() async {
        let fixture = await fixture(writable: true)
        _ = await MainActor.run { installEveryKind(fixture, collision: true) }
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let collision = page.items.filter { $0.kind == .guide || $0.kind == .place }
        XCTAssertEqual(collision[0].id, collision[1].id)
        XCTAssertNotEqual(collision[0].kind, collision[1].kind)
        let desired = page.items.reversed().map {
            WireFavoriteIdentity(kind: $0.kind, id: $0.id)
        }
        let readsBefore = await MainActor.run {
            (
                fixture.contacts.fetchGroupsCallCount,
                fixture.guides.allGuidesCallCount,
                fixture.guides.allPlacesCallCount
            )
        }
        let response = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "r", favorites: desired,
            idempotencyToken: "reorder-1"))
        guard case .acknowledged = response else { return XCTFail("reorder failed: \(String(describing: response))") }
        let replay = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "r-retry", favorites: desired,
            idempotencyToken: "reorder-1"))
        guard case .acknowledged(_, let replayMessageID, _) = replay else {
            return XCTFail("reorder replay failed")
        }
        XCTAssertEqual(replayMessageID, "r-retry")
        let order = await MainActor.run { fixture.favorites.items.map(\.kind) }
        XCTAssertEqual(order, [.place, .guide, .group, .event, .contact])
        let reorderCalls = await MainActor.run { fixture.favorites.reorderCallCount }
        XCTAssertEqual(reorderCalls, 1)
        let readsAfter = await MainActor.run {
            (
                fixture.contacts.fetchGroupsCallCount,
                fixture.guides.allGuidesCallCount,
                fixture.guides.allPlacesCallCount
            )
        }
        XCTAssertEqual(readsAfter.0 - readsBefore.0, 1)
        XCTAssertEqual(readsAfter.1 - readsBefore.1, 1)
        XCTAssertEqual(readsAfter.2 - readsBefore.2, 1)
        let favoriteReads = await MainActor.run { fixture.favorites.loadCallCount }
        XCTAssertEqual(
            favoriteReads, 3,
            "one list read and one permission snapshot for each reorder call")
    }

    func testReorderWithoutContactsSkipsContactSnapshot() async {
        let fixture = await fixture(writable: true)
        await MainActor.run {
            fixture.favorites.items = [
                Favorite(kind: .guide, id: fixture.guides.guides[0].id.uuidString, addedAt: Date()),
                Favorite(kind: .place, id: fixture.guides.places[0].id.uuidString, addedAt: Date()),
            ]
        }
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let desired = page.items.reversed().map {
            WireFavoriteIdentity(kind: $0.kind, id: $0.id)
        }
        let response = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "non-contact-reorder",
            favorites: desired, idempotencyToken: nil))
        guard case .acknowledged = response else {
            return XCTFail("reorder failed: \(String(describing: response))")
        }
        let contactReads = await MainActor.run { fixture.contacts.allContactsReadCount }
        XCTAssertEqual(contactReads, 0)
    }

    func testReorderRejectsDuplicateMissingExtraStaleAndConcurrentChange() async {
        let fixture = await fixture(writable: true)
        _ = await MainActor.run { installEveryKind(fixture) }
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let identities = page.items.map { WireFavoriteIdentity(kind: $0.kind, id: $0.id) }
        let original = await MainActor.run { fixture.favorites.items }

        let duplicate = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "d",
            favorites: Array(identities.dropLast()) + [identities[0]], idempotencyToken: nil))
        error(duplicate, .invalidParams)
        let missing = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "m",
            favorites: Array(identities.dropLast()), idempotencyToken: nil))
        error(missing, .invalidParams)
        let extra = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "e",
            favorites: identities + [WireFavoriteIdentity(kind: .guide, id: UUID().uuidString)],
            idempotencyToken: nil))
        error(extra, .invalidParams)
        let afterRejected = await MainActor.run { fixture.favorites.items }
        XCTAssertEqual(afterRejected, original)

        await MainActor.run { fixture.guides.guides = [] }
        let stale = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "s", favorites: identities,
            idempotencyToken: nil))
        error(stale, .notFound)
        await MainActor.run {
            fixture.guides.guides = [MapsGuide(
                id: UUID(uuidString: identities[3].id)!, name: "Coffee Crawl",
                sourceURL: nil, createdAt: Date())]
            fixture.favorites.mutateBeforeNextReorder = true
        }
        let changed = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "c", favorites: Array(identities.reversed()),
            idempotencyToken: nil))
        error(changed, .busy)
    }

    func testDynamicPermissionsAndAccessGatesApplyPerReferent() async {
        let fixture = await fixture(writable: true)
        _ = await MainActor.run { installEveryKind(fixture) }
        await MainActor.run { fixture.gates.contactsAuthorized = false }
        error(await fixture.dispatcher.handle(.favoritesList(
            helperId: Fixture.helper, messageId: "l", limit: nil, cursor: nil)), .permissionDenied)
        error(await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "g", kind: .group,
            id: "g-x", favorite: true, idempotencyToken: nil)), .permissionDenied)
        error(await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "gr",
            favorites: [WireFavoriteIdentity(kind: .contact, id: Sentinels.guessWhoUUID)],
            idempotencyToken: nil)), .permissionDenied)

        await MainActor.run {
            fixture.gates.contactsAuthorized = true
            fixture.gates.eventsAuthorized = false
        }
        error(await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "ev", kind: .event,
            id: UUID().uuidString, favorite: true, idempotencyToken: nil)), .permissionDenied)
        let guideID = await MainActor.run { fixture.guides.guides[0].id.uuidString }
        guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "gu", kind: .guide,
            id: guideID, favorite: false, idempotencyToken: nil)) else {
            return XCTFail("guide should need no system permission")
        }

        await MainActor.run { fixture.gates.mcpAccess = .readOnly }
        error(await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "ro", kind: .guide,
            id: guideID, favorite: true, idempotencyToken: nil)), .readOnly)
        await MainActor.run { fixture.gates.mcpAccess = .off }
        error(await fixture.dispatcher.handle(.favoritesList(
            helperId: Fixture.helper, messageId: "off", limit: nil, cursor: nil)), .disabled)
    }

    func testReorderRechecksPermissionsAgainstItsCurrentSnapshot() async {
        let fixture = await Fixture.make(writeLimitPerWindow: 1, writeWindowSeconds: 60)
        await MainActor.run { fixture.gates.mcpAccess = .readWrite }
        _ = await MainActor.run { installEveryKind(fixture) }
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let identities = page.items.map { WireFavoriteIdentity(kind: $0.kind, id: $0.id) }
        await MainActor.run {
            let nextBodyLoad = fixture.favorites.loadCallCount + 1
            fixture.favorites.onLoadFavorites = {
                if fixture.favorites.loadCallCount == nextBodyLoad {
                    fixture.gates.contactsAuthorized = false
                }
            }
        }

        let response = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "permission-race",
            favorites: Array(identities.reversed()), idempotencyToken: nil))

        error(response, .permissionDenied)
        let reorderCalls = await MainActor.run { fixture.favorites.reorderCallCount }
        XCTAssertEqual(reorderCalls, 0)

        guard let guideID = identities.first(where: { $0.kind == .guide })?.id else {
            return XCTFail("missing guide identity")
        }
        await MainActor.run {
            fixture.gates.contactsAuthorized = true
            fixture.favorites.onLoadFavorites = nil
        }
        guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "budget-after-denial",
            kind: .guide, id: guideID, favorite: false, idempotencyToken: nil)) else {
            return XCTFail("permission denial must not consume the write budget")
        }
    }

    func testEntityDeleteLeavesStaleRowsThatGenericClearCanRecover() async {
        let fixture = await fixture(writable: true)
        let (guide, place) = await MainActor.run {
            (fixture.guides.guides[0], fixture.guides.places[0])
        }
        await MainActor.run {
            fixture.favorites.items = [
                Favorite(kind: .guide, id: guide.id.uuidString, addedAt: Date()),
                Favorite(kind: .place, id: place.id.uuidString, addedAt: Date()),
            ]
        }

        guard case .acknowledged = await fixture.dispatcher.handle(.guidesDelete(
            helperId: Fixture.helper, messageId: "delete-guide",
            guideId: guide.id.uuidString, idempotencyToken: nil)) else {
            return XCTFail("guide delete failed")
        }
        guard let stale = await list(fixture) else { return XCTFail("no stale projection") }
        XCTAssertEqual(stale.items.map(\.isAvailable), [false, false])
        for item in stale.items {
            guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
                helperId: Fixture.helper, messageId: TestMessageID.next(),
                kind: item.kind, id: item.id, favorite: false, idempotencyToken: nil)) else {
                return XCTFail("could not clear stale \(item.kind)")
            }
        }
        let empty = await list(fixture)
        XCTAssertEqual(empty?.items.count, 0)
    }

    func testWriteBudgetIdempotencyAuditAndResponseCapPipeline() async {
        let fixture = await Fixture.make(writeLimitPerWindow: 1, writeWindowSeconds: 60)
        await MainActor.run { fixture.gates.mcpAccess = .readWrite }
        let guideID = await MainActor.run { fixture.guides.guides[0].id.uuidString }
        let first = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "1", kind: .guide,
            id: guideID, favorite: true, idempotencyToken: "same"))
        guard case .acknowledged = first else { return XCTFail("first failed") }
        let replay = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "2", kind: .guide,
            id: guideID, favorite: true, idempotencyToken: "same"))
        guard case .acknowledged(_, let messageID, _) = replay else { return XCTFail("replay failed") }
        XCTAssertEqual(messageID, "2")
        let setCalls = await MainActor.run { fixture.favorites.setCallCount }
        XCTAssertEqual(setCalls, 1)
        let blocked = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "3", kind: .guide,
            id: guideID, favorite: false, idempotencyToken: "different"))
        error(blocked, .busy)
        let entries = await fixture.audit.entries()
        XCTAssertEqual(entries.last?.action, .setFavorite)
        XCTAssertEqual(entries.last?.subjectKind, .guide)

        // A huge stale favorite page still rides the shared response cap.
        await MainActor.run {
            fixture.gates.mcpAccess = .readOnly
            fixture.contacts.groups = (0..<200).map { index in
                ContactGroup(
                    localID: "group-\(index)",
                    name: String(repeating: "A", count: 5_000) + "\(index)")
            }
            fixture.favorites.items = fixture.contacts.groups.map { group in
                Favorite(kind: .group, id: group.localID, addedAt: Date())
            }
        }
        let capped = await fixture.dispatcher.handle(.favoritesList(
            helperId: Fixture.helper, messageId: "cap", limit: 200, cursor: nil))
        error(capped, .tooLarge)
    }
}

/// The production contact id derivation is intentionally internal. Tests only
/// need the known reconciled fixture's ordinary id, so keep the helper tiny and
/// avoid making production identity APIs public for test convenience.
private enum WireRecordIDForTests {
    static func contact(_ contact: Contact) -> String {
        contact.contactID.restorationToken.guessWhoID ?? contact.deterministicGuessWhoID
    }
}
