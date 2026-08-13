import XCTest
import GuessWhoSync
import GuessWhoSyncTesting
import GuessWhoMCPCore
import GuessWhoMCPWire

final class FavoritesToolTests: XCTestCase {
    // MARK: - Production-backed helpers (real on-disk FavoritesStore)
    //
    // The favorite storage-semantics streams below dispatch against
    // `MCPProductionFixture`, so every canonicalization / idempotency / CAS /
    // ordering assertion reaches the REAL `FavoritesStore` through
    // `MCPFavoriteStoreAdapter` and the REAL `ContactsRepository`. Seeding and
    // inspection go through `FavoritesStore.setAll` / `loadAll`; the store's
    // rules are never re-implemented here. Event / guide / place referents stay
    // the OS-independent fakes — only their storage identity is exercised.

    @MainActor
    private func productionFixture(
        writable: Bool = false,
        seedContactFavorite: Bool = false,
        writeLimit: Int = 30,
        writeWindow: TimeInterval = 60
    ) async -> MCPProductionFixture {
        let fixture = await MCPProductionFixture.make(
            writeLimitPerWindow: writeLimit,
            writeWindowSeconds: writeWindow,
            seedContactFavorite: seedContactFavorite)
        if writable {
            fixture.gates.mcpAccess = .readWrite
            fixture.gates.cliAccess = .readWrite
        }
        return fixture
    }

    @MainActor
    private func list(
        _ fixture: MCPProductionFixture, limit: Int? = nil, cursor: String? = nil
    ) async -> WirePage<WireFavorite>? {
        let response = await fixture.dispatcher.handle(.favoritesList(
            helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
            limit: limit, cursor: cursor))
        guard case .favoritePage(_, _, let page) = response else { return nil }
        return page
    }

    @MainActor
    private func seededGroupLocalID(_ fixture: MCPProductionFixture) -> String? {
        fixture.repository.groups.first { $0.name == MCPProductionFixture.groupName }?.localID
    }

    /// The records a production `installEveryKind` seeded, so a test can
    /// reference specific referent ids without re-reading the fakes.
    @MainActor
    private struct EveryKindSeed {
        let event: Event
        let guide: MapsGuide
        let place: MapsPlace
        let groupLocalID: String
    }

    /// Seed one favorite of every kind on disk (through `FavoritesStore.setAll`)
    /// plus their event / guide / place referents on the OS-independent fakes.
    /// With `collision`, the place reuses the guide's UUID so the reorder test
    /// can prove composite (kind,id) identity survives a cross-kind id clash.
    @MainActor
    @discardableResult
    private func installEveryKind(
        _ fixture: MCPProductionFixture, collision: Bool = false
    ) throws -> EveryKindSeed {
        let event = Event(
            id: UUID(), eventKitID: nil, title: "Museum Gala",
            startDate: Date(timeIntervalSince1970: 1_760_000_000),
            endDate: Date(timeIntervalSince1970: 1_760_007_200))
        fixture.events.events = [event]

        let guide = MapsGuide(
            id: UUID(), name: "Coffee Crawl", sourceURL: nil,
            createdAt: Date(timeIntervalSince1970: 1_740_000_000))
        let placeID = collision ? guide.id : UUID()
        let place = MapsPlace(
            id: placeID, guideID: guide.id, name: "Bluebird Espresso",
            address: "12 Main St", latitude: 30.27, longitude: -97.74)
        fixture.guides.guides = [guide]
        fixture.guides.places = [place]

        let groupLocalID = seededGroupLocalID(fixture) ?? ""
        try fixture.favoritesStore.setAll([
            Favorite(kind: .contact, id: MCPProductionFixture.adaGuessWhoID, addedAt: Date(timeIntervalSince1970: 1)),
            Favorite(kind: .event, id: event.id.uuidString, addedAt: Date(timeIntervalSince1970: 2)),
            Favorite(kind: .group, id: groupLocalID, addedAt: Date(timeIntervalSince1970: 3)),
            Favorite(kind: .guide, id: guide.id.uuidString, addedAt: Date(timeIntervalSince1970: 4)),
            Favorite(kind: .place, id: placeID.uuidString, addedAt: Date(timeIntervalSince1970: 5)),
        ])
        return EveryKindSeed(
            event: event, guide: guide, place: place, groupLocalID: groupLocalID)
    }

    // MARK: - Fake-backed helpers (injected-fault / read-observation streams)

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

    // MARK: - List stream (production-backed)

    @MainActor
    func testListEveryKindPreservesStoredOrderNamesAddedAtAndOpaqueIDs() async throws {
        let fixture = await productionFixture()
        defer { fixture.cleanUp() }
        let seed = try installEveryKind(fixture)
        let rawGroupID = seed.groupLocalID

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
            "Ada Lovelace", "Museum Gala", "Pioneers", "Coffee Crawl", "Bluebird Espresso",
        ])
        XCTAssertTrue(all.allSatisfy(\.isAvailable))
        XCTAssertEqual(all.first?.addedAt, "1970-01-01T00:00:01Z")
        XCTAssertTrue(all[2].id.hasPrefix("g-"))
        XCTAssertFalse(all[2].id.contains(rawGroupID))
        XCTAssertFalse(all[1].id.hasPrefix("e-"), "stored events use ordinary record ids")
    }

    @MainActor
    func testStaleRowsStayInPlaceAndNeverLeakStoredIdentifier() async throws {
        let fixture = await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let raw = "EK-RAW-CALENDAR-SHOULD-NOT-CROSS"
        try fixture.favoritesStore.setAll([
            Favorite(kind: .event, id: raw, addedAt: Date(timeIntervalSince1970: 9)),
            Favorite(kind: .contact, id: MCPProductionFixture.adaGuessWhoID, addedAt: Date(timeIntervalSince1970: 10)),
        ])
        guard let page = await list(fixture) else { return XCTFail("no page") }
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.items[0].displayName, "Unavailable")
        XCTAssertFalse(page.items[0].isAvailable)
        XCTAssertEqual(page.items[1].displayName, "Ada Lovelace")
        XCTAssertFalse(page.items[0].id.contains(raw))

        let cleared = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "clear-stale", kind: .event,
            id: page.items[0].id, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = cleared else { return XCTFail("stale clear failed") }
        let remaining = await list(fixture)
        XCTAssertEqual(remaining?.items.map(\.kind), [.contact])
        XCTAssertFalse(try fixture.favoritesStore.loadAll().contains { $0.kind == .event })
    }

    @MainActor
    func testGroupOpaqueIDStaysStableWhenReferentBecomesStale() async throws {
        let fixture = await productionFixture()
        defer { fixture.cleanUp() }
        let groupLocalID = try XCTUnwrap(seededGroupLocalID(fixture))
        try fixture.favoritesStore.setAll([Favorite(kind: .group, id: groupLocalID, addedAt: Date())])
        guard let liveID = await list(fixture)?.items.first?.id else { return XCTFail("no live row") }
        XCTAssertTrue(liveID.hasPrefix("g-"))
        // Make the group referent stale by deleting it from the store, then
        // refreshing the repository's group cache.
        try await fixture.store.deleteGroup(localID: groupLocalID)
        await fixture.repository.loadGroups()
        guard let stale = await list(fixture)?.items.first else { return XCTFail("no stale row") }
        XCTAssertEqual(stale.id, liveID)
        XCTAssertFalse(stale.isAvailable)
    }

    // MARK: - Set stream (production-backed)

    @MainActor
    func testSetSupportsEveryKindAndIsDesiredStateIdempotent() async throws {
        let fixture = await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        _ = try installEveryKind(fixture)
        guard let entries = await list(fixture)?.items else { return XCTFail("no entries") }

        // Start from an empty favorites file; each kind is set from scratch.
        try fixture.favoritesStore.setAll([])
        for entry in entries {
            let token = "set-\(entry.kind.rawValue)"
            let first = await fixture.dispatcher.handle(.favoritesSet(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                kind: entry.kind, id: entry.id, favorite: true, idempotencyToken: token))
            guard case .acknowledged = first else { return XCTFail("set failed: \(String(describing: first))") }
            let duplicate = await fixture.dispatcher.handle(.favoritesSet(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                kind: entry.kind, id: entry.id, favorite: true, idempotencyToken: token))
            guard case .acknowledged = duplicate else { return XCTFail("retry failed") }
        }
        let stored = try fixture.favoritesStore.loadAll()
        XCTAssertEqual(stored.map(\.kind), [.contact, .event, .group, .guide, .place])
        XCTAssertEqual(stored.count, 5)
    }

    @MainActor
    func testContactsCompatibilityUsesSameFavoriteState() async throws {
        let fixture = await productionFixture(writable: true, seedContactFavorite: true)
        defer { fixture.cleanUp() }
        let contactID = MCPProductionFixture.adaGuessWhoID
        let genericClear = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "g1", kind: .contact,
            id: contactID, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = genericClear else { return XCTFail("generic clear failed") }
        XCTAssertTrue(try fixture.favoritesStore.loadAll().isEmpty)

        let compatibilitySet = await fixture.dispatcher.handle(.contactsSetFavorite(
            helperId: MCPProductionFixture.helper, messageId: "c1", contactId: contactID,
            favorite: true, idempotencyToken: nil))
        guard case .acknowledged(_, _, let message) = compatibilitySet else {
            return XCTFail("compat set failed")
        }
        XCTAssertEqual(message, WireAckMessage.favoriteSet)
        let stored = try fixture.favoritesStore.loadAll()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.kind, .contact)
        XCTAssertEqual(stored.first?.id, contactID)
    }

    @MainActor
    func testKindMismatchAndUnknownReferentsNeverWrite() async throws {
        let fixture = await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let guide = MapsGuide(id: UUID(), name: "Coffee Crawl", sourceURL: nil, createdAt: Date())
        fixture.guides.guides = [guide]
        let before = try fixture.favoritesStore.loadAll()

        let mismatched = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "m1", kind: .contact,
            id: "g-not-a-contact", favorite: true, idempotencyToken: nil))
        error(mismatched, .invalidParams)
        let resolvableWrongKind = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "m1b", kind: .contact,
            id: guide.id.uuidString, favorite: true, idempotencyToken: nil))
        error(resolvableWrongKind, .invalidParams)
        let unknown = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "m2", kind: .guide,
            id: UUID().uuidString, favorite: true, idempotencyToken: nil))
        error(unknown, .notFound)
        // None of the rejected writes touched the store.
        XCTAssertEqual(try fixture.favoritesStore.loadAll(), before)
    }

    // MARK: - Reorder stream (production-backed)

    @MainActor
    func testReorderUsesCompositeIdentityAndAllowsCrossKindIDCollision() async throws {
        let fixture = await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        _ = try installEveryKind(fixture, collision: true)
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let collision = page.items.filter { $0.kind == .guide || $0.kind == .place }
        XCTAssertEqual(collision[0].id, collision[1].id)
        XCTAssertNotEqual(collision[0].kind, collision[1].kind)
        let desired = page.items.reversed().map {
            WireFavoriteIdentity(kind: $0.kind, id: $0.id)
        }
        let guideReadsBefore = fixture.guides.allGuidesCallCount
        let placeReadsBefore = fixture.guides.allPlacesCallCount
        let response = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "r", favorites: desired,
            idempotencyToken: "reorder-1"))
        guard case .acknowledged = response else { return XCTFail("reorder failed: \(String(describing: response))") }
        let orderAfterReorder = try fixture.favoritesStore.loadAll().map(\.kind)
        XCTAssertEqual(orderAfterReorder, [.place, .guide, .group, .event, .contact])

        let replay = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "r-retry", favorites: desired,
            idempotencyToken: "reorder-1"))
        guard case .acknowledged(_, let replayMessageID, _) = replay else {
            return XCTFail("reorder replay failed")
        }
        XCTAssertEqual(replayMessageID, "r-retry")
        // The idempotent replay changed nothing on disk.
        XCTAssertEqual(try fixture.favoritesStore.loadAll().map(\.kind), orderAfterReorder)
        // A reorder reads the guide and place collections exactly once; the
        // replay short-circuits on the idempotency cache and reads neither.
        XCTAssertEqual(fixture.guides.allGuidesCallCount - guideReadsBefore, 1)
        XCTAssertEqual(fixture.guides.allPlacesCallCount - placeReadsBefore, 1)
    }

    @MainActor
    func testReorderRejectsDuplicateMissingExtraAndStaleFavorites() async throws {
        let fixture = await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        _ = try installEveryKind(fixture)
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let identities = page.items.map { WireFavoriteIdentity(kind: $0.kind, id: $0.id) }
        let original = try fixture.favoritesStore.loadAll()

        let duplicate = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "d",
            favorites: Array(identities.dropLast()) + [identities[0]], idempotencyToken: nil))
        error(duplicate, .invalidParams)
        let missing = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "m",
            favorites: Array(identities.dropLast()), idempotencyToken: nil))
        error(missing, .invalidParams)
        let extra = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "e",
            favorites: identities + [WireFavoriteIdentity(kind: .guide, id: UUID().uuidString)],
            idempotencyToken: nil))
        error(extra, .invalidParams)
        // Every rejected order left the stored favorites byte-for-byte untouched.
        XCTAssertEqual(try fixture.favoritesStore.loadAll(), original)

        // A vanished referent makes the whole reorder stale, not partial.
        fixture.guides.guides = []
        let stale = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "s", favorites: identities,
            idempotencyToken: nil))
        error(stale, .notFound)
        XCTAssertEqual(try fixture.favoritesStore.loadAll(), original)
    }

    // MARK: - Entity-delete recovery + write pipeline (production-backed)

    @MainActor
    func testEntityDeleteLeavesStaleRowsThatGenericClearCanRecover() async throws {
        let fixture = await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let guide = MapsGuide(id: UUID(), name: "Coffee Crawl", sourceURL: nil, createdAt: Date())
        let place = MapsPlace(
            id: UUID(), guideID: guide.id, name: "Bluebird Espresso",
            address: "12 Main St", latitude: 30.27, longitude: -97.74)
        fixture.guides.guides = [guide]
        fixture.guides.places = [place]
        try fixture.favoritesStore.setAll([
            Favorite(kind: .guide, id: guide.id.uuidString, addedAt: Date()),
            Favorite(kind: .place, id: place.id.uuidString, addedAt: Date()),
        ])

        guard case .acknowledged = await fixture.dispatcher.handle(.guidesDelete(
            helperId: MCPProductionFixture.helper, messageId: "delete-guide",
            guideId: guide.id.uuidString, idempotencyToken: nil)) else {
            return XCTFail("guide delete failed")
        }
        guard let stale = await list(fixture) else { return XCTFail("no stale projection") }
        XCTAssertEqual(stale.items.map(\.isAvailable), [false, false])
        for item in stale.items {
            guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                kind: item.kind, id: item.id, favorite: false, idempotencyToken: nil)) else {
                return XCTFail("could not clear stale \(item.kind)")
            }
        }
        let empty = await list(fixture)
        XCTAssertEqual(empty?.items.count, 0)
        XCTAssertTrue(try fixture.favoritesStore.loadAll().isEmpty)
    }

    @MainActor
    func testWriteBudgetIdempotencyAuditAndResponseCapPipeline() async throws {
        let fixture = await productionFixture(writable: true, writeLimit: 1, writeWindow: 60)
        defer { fixture.cleanUp() }
        let guide = MapsGuide(id: UUID(), name: "Coffee Crawl", sourceURL: nil, createdAt: Date())
        fixture.guides.guides = [guide]
        let guideID = guide.id.uuidString

        let first = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "1", kind: .guide,
            id: guideID, favorite: true, idempotencyToken: "same"))
        guard case .acknowledged = first else { return XCTFail("first failed") }
        let replay = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "2", kind: .guide,
            id: guideID, favorite: true, idempotencyToken: "same"))
        guard case .acknowledged(_, let messageID, _) = replay else { return XCTFail("replay failed") }
        XCTAssertEqual(messageID, "2")
        // The replay did not write a second time.
        XCTAssertEqual(try fixture.favoritesStore.loadAll().filter { $0.kind == .guide }.count, 1)

        let blocked = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "3", kind: .guide,
            id: guideID, favorite: false, idempotencyToken: "different"))
        error(blocked, .busy)
        let entries = await fixture.audit.entries()
        XCTAssertEqual(entries.last?.action, .setFavorite)
        XCTAssertEqual(entries.last?.subjectKind, .guide)

        // A huge stale favorite page still rides the shared response cap.
        fixture.gates.mcpAccess = .readOnly
        let bigGuides = (0..<200).map { index in
            MapsGuide(
                id: UUID(), name: String(repeating: "A", count: 5_000) + "\(index)",
                sourceURL: nil, createdAt: Date())
        }
        fixture.guides.guides = bigGuides
        try fixture.favoritesStore.setAll(bigGuides.map {
            Favorite(kind: .guide, id: $0.id.uuidString, addedAt: Date())
        })
        let capped = await fixture.dispatcher.handle(.favoritesList(
            helperId: MCPProductionFixture.helper, messageId: "cap", limit: 200, cursor: nil))
        error(capped, .tooLarge)
    }

    // MARK: - Injected-fault / read-observation streams (fake-backed)
    //
    // These stay on `Fixture`: each needs a fault or read observation the real
    // `FavoritesStore` cannot expose — a thrown read, a compare-and-swap race
    // injected between the snapshot and the write, a permission flip mid-load,
    // or a contact-fetch-avoidance counter. The event Option-B test writes
    // nothing to storage, so it stays with the seeded calendar-only event.

    func testReadFailureIsExplicitInsteadOfAnEmptyPage() async {
        let fixture = await fixture()
        await MainActor.run { fixture.favorites.failReads = true }
        let response = await fixture.dispatcher.handle(.favoritesList(
            helperId: Fixture.helper, messageId: "read-failure", limit: nil, cursor: nil))
        error(response, .busy)
        XCTAssertEqual(response?.errorPayload?.message, WireErrorMessage.favoritesReadFailed)
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

    func testReorderRejectsConcurrentChange() async {
        let fixture = await fixture(writable: true)
        _ = await MainActor.run { installEveryKind(fixture) }
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let identities = page.items.map { WireFavoriteIdentity(kind: $0.kind, id: $0.id) }
        let original = await MainActor.run { fixture.favorites.items }

        // Arm a concurrent device edit that lands between the dispatcher's
        // snapshot read and the store's compare-and-swap: the CAS sees a changed
        // list and rejects the write instead of clobbering it.
        await MainActor.run { fixture.favorites.mutateBeforeNextReorder = true }
        let changed = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: Fixture.helper, messageId: "c", favorites: Array(identities.reversed()),
            idempotencyToken: nil))
        error(changed, .busy)
        // The rejected reorder did not reorder the caller's requested order; the
        // injected edit is the only mutation the fake performed.
        let afterRejected = await MainActor.run { fixture.favorites.items }
        XCTAssertEqual(afterRejected.prefix(original.count).map(\.kind), original.map(\.kind))
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
}

/// The production contact id derivation is intentionally internal. Tests only
/// need the known reconciled fixture's ordinary id, so keep the helper tiny and
/// avoid making production identity APIs public for test convenience.
private enum WireRecordIDForTests {
    static func contact(_ contact: Contact) -> String {
        contact.contactID.restorationToken.guessWhoID ?? contact.deterministicGuessWhoID
    }
}
