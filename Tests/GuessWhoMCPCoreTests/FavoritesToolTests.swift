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
    ) async throws -> MCPProductionFixture {
        let fixture = try await MCPProductionFixture.make(
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
    /// plus their event / guide / place referents as REAL records in the
    /// production `GuessWhoSync` engine. With `collision`, the place is minted at
    /// the guide's UUID key (by cloning its real envelope through the store's own
    /// write — the engine can't mint two records to the same UUID) so the reorder
    /// test can prove composite (kind,id) identity survives a cross-kind id clash.
    @MainActor
    @discardableResult
    private func installEveryKind(
        _ fixture: MCPProductionFixture, collision: Bool = false
    ) async throws -> EveryKindSeed {
        let eventUUID = try EngineSeed.manualEvent(
            fixture.sync, title: "Museum Gala",
            start: Date(timeIntervalSince1970: 1_760_000_000),
            end: Date(timeIntervalSince1970: 1_760_007_200))
        let event = try XCTUnwrap(
            fixture.sync.event(at: SidecarKey(kind: .event, id: eventUUID.uuidString)))

        let (guide, importedPlaces) = try EngineSeed.guide(
            fixture.sync, name: "Coffee Crawl",
            entries: [MapsGuideURL.Entry(
                address: "12 Main St", latitude: 30.27, longitude: -97.74)])
        // Resolve so the place displays "Bluebird Espresso".
        try fixture.sync.markPlaceResolved(
            at: SidecarKey(kind: .place, id: importedPlaces[0].id.uuidString),
            name: "Bluebird Espresso", address: "12 Main St",
            latitude: 30.27, longitude: -97.74)

        let placeID: UUID
        if collision {
            // Force the cross-kind UUID collision the engine's minting API can't
            // produce: clone the place's REAL envelope onto the guide's UUID key
            // through the store's public write, then drop the original. Reads
            // still ride the real engine decode (key.id becomes the place id).
            let originalKey = SidecarKey(kind: .place, id: importedPlaces[0].id.uuidString)
            let collidedKey = SidecarKey(kind: .place, id: guide.id.uuidString)
            if let envelope = try fixture.sidecars.read(originalKey) {
                try fixture.sidecars.write(envelope, at: collidedKey)
            }
            try fixture.sidecars.delete(originalKey)
            placeID = guide.id
        } else {
            placeID = importedPlaces[0].id
        }
        // Hoisted out of XCTUnwrap: in this async function `places(inGuide:)`
        // resolves to the async overload, which cannot be called inside the
        // non-async XCTUnwrap autoclosure.
        let guidePlaces = try await fixture.sync.places(inGuide: guide.id)
        let place = try XCTUnwrap(guidePlaces.first { $0.id == placeID })

        let groupLocalID = seededGroupLocalID(fixture) ?? ""
        await fixture.repository.loadGroups()
        let group = try XCTUnwrap(
            fixture.repository.groups.first { $0.localID == groupLocalID })
        _ = try await fixture.repository.setGroupFavorite(true, for: group)
        let groupIdentityID = try XCTUnwrap(
            fixture.favoritesStore.loadAll().first { $0.kind == .group }?.id)
        try fixture.favoritesStore.setAll([
            Favorite(kind: .contact, id: MCPProductionFixture.adaGuessWhoID, addedAt: Date(timeIntervalSince1970: 1)),
            Favorite(kind: .event, id: eventUUID.uuidString, addedAt: Date(timeIntervalSince1970: 2)),
            Favorite(kind: .group, id: groupIdentityID, addedAt: Date(timeIntervalSince1970: 3)),
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
    private func installEveryKind(_ fixture: Fixture) {
        guard let group = fixture.contacts.groups.first else {
            XCTFail("every-kind fixture is incomplete")
            return
        }
        // The event / guide / place referents are the fixture's REAL
        // engine-minted records; the fault-injecting favorites source only holds
        // the ordered list the favorites_* tools mutate. The group favorite
        // references a durable GroupIdentity UUID (like the real repository),
        // NOT the raw localID; register it so the group resolves to a live,
        // AVAILABLE row.
        let groupFavoriteID = "9a9a9a9a-0000-4000-8000-0000000c0de5"
        fixture.contacts.groupFavoriteResolutions[groupFavoriteID] = group
        fixture.favorites.items = [
            Favorite(kind: .contact, id: Sentinels.guessWhoUUID, addedAt: Date(timeIntervalSince1970: 1)),
            Favorite(kind: .event, id: fixture.galaEventUUID.uuidString, addedAt: Date(timeIntervalSince1970: 2)),
            Favorite(kind: .group, id: groupFavoriteID, addedAt: Date(timeIntervalSince1970: 3)),
            Favorite(kind: .guide, id: fixture.coffeeGuideID.uuidString, addedAt: Date(timeIntervalSince1970: 4)),
            Favorite(kind: .place, id: fixture.bluebirdPlaceID.uuidString, addedAt: Date(timeIntervalSince1970: 5)),
        ]
        fixture.contacts.favoriteEffectiveIDs = [Sentinels.guessWhoUUID]
    }

    // MARK: - List stream (production-backed)

    @MainActor
    func testListEveryKindPreservesStoredOrderNamesAddedAtAndOpaqueIDs() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let seed = try await installEveryKind(fixture)
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
        guard all.count == 5 else { return XCTFail("expected all five favorite kinds") }
        XCTAssertTrue(all[2].id.hasPrefix("g-"))
        XCTAssertFalse(all[2].id.contains(rawGroupID))
        XCTAssertFalse(all[1].id.hasPrefix("e-"), "stored events use ordinary record ids")
    }

    @MainActor
    func testStaleRowsStayInPlaceAndNeverLeakStoredIdentifier() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let raw = "EK-RAW-CALENDAR-SHOULD-NOT-CROSS"
        try fixture.favoritesStore.setAll([
            Favorite(kind: .event, id: raw, addedAt: Date(timeIntervalSince1970: 9)),
            Favorite(kind: .contact, id: MCPProductionFixture.adaGuessWhoID, addedAt: Date(timeIntervalSince1970: 10)),
        ])
        guard let page = await list(fixture) else { return XCTFail("no page") }
        guard page.items.count == 2 else { return XCTFail("expected stale and live favorites") }
        let staleItem = page.items[0]
        let liveItem = page.items[1]
        XCTAssertEqual(staleItem.displayName, "Unavailable")
        XCTAssertFalse(staleItem.isAvailable)
        XCTAssertEqual(liveItem.displayName, "Ada Lovelace")
        XCTAssertFalse(staleItem.id.contains(raw))

        let cleared = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "clear-stale", kind: .event,
            id: staleItem.id, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = cleared else { return XCTFail("stale clear failed") }
        let remaining = await list(fixture)
        XCTAssertEqual(remaining?.items.map(\.kind), [.contact])
        XCTAssertFalse(try fixture.favoritesStore.loadAll().contains { $0.kind == .event })
    }

    @MainActor
    func testGroupOpaqueIDStaysStableWhenReferentBecomesStale() async throws {
        let fixture = try await productionFixture()
        defer { fixture.cleanUp() }
        let groupLocalID = try XCTUnwrap(seededGroupLocalID(fixture))
        await fixture.repository.loadGroups()
        let group = try XCTUnwrap(
            fixture.repository.groups.first { $0.localID == groupLocalID })
        _ = try await fixture.repository.setGroupFavorite(true, for: group)
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
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        _ = try await installEveryKind(fixture)
        guard let entries = await list(fixture)?.items else { return XCTFail("no entries") }

        // Start from an empty favorites file; each kind is set from scratch.
        try fixture.favoritesStore.setAll([])
        for entry in entries {
            let token = "set-\(entry.kind.rawValue)"
            let first = await fixture.dispatcher.handle(.favoritesSet(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                kind: entry.kind, id: entry.id, favorite: true, idempotencyToken: token))
            guard case .acknowledged = first else { return XCTFail("set failed: \(String(describing: first))") }
            let originalStamp = try XCTUnwrap(
                fixture.favoritesStore.loadAll().first {
                    $0.kind.rawValue == entry.kind.rawValue
                }?.addedAt)
            let duplicate = await fixture.dispatcher.handle(.favoritesSet(
                helperId: MCPProductionFixture.helper, messageId: TestMessageID.next(),
                kind: entry.kind, id: entry.id, favorite: true, idempotencyToken: nil))
            guard case .acknowledged = duplicate else { return XCTFail("tokenless repeat failed") }
            XCTAssertEqual(
                try fixture.favoritesStore.loadAll().first {
                    $0.kind.rawValue == entry.kind.rawValue
                }?.addedAt,
                originalStamp, "desired-state repeat must preserve the original favorite")
        }
        let stored = try fixture.favoritesStore.loadAll()
        XCTAssertEqual(stored.map(\.kind), [.contact, .event, .group, .guide, .place])
        XCTAssertEqual(stored.count, 5)
    }

    @MainActor
    func testContactsCompatibilityUsesSameFavoriteState() async throws {
        let fixture = try await productionFixture(writable: true, seedContactFavorite: true)
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
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let (guide, _) = try EngineSeed.guide(
            fixture.sync, name: "Coffee Crawl",
            entries: [MapsGuideURL.Entry(address: "9 Kind St")])
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
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        _ = try await installEveryKind(fixture, collision: true)
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let collision = page.items.filter { $0.kind == .guide || $0.kind == .place }
        guard collision.count == 2 else { return XCTFail("expected guide/place collision") }
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
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        _ = try await installEveryKind(fixture)
        guard let page = await list(fixture) else { return XCTFail("no page") }
        let identities = page.items.map { WireFavoriteIdentity(kind: $0.kind, id: $0.id) }
        guard let firstIdentity = identities.first else { return XCTFail("no identities") }
        let original = try fixture.favoritesStore.loadAll()

        let duplicate = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "d",
            favorites: Array(identities.dropLast()) + [firstIdentity], idempotencyToken: nil))
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

        // A vanished referent makes the whole reorder stale, not partial:
        // soft-delete the guide (and its places) through the real engine.
        try EngineSeed.clearGuides(fixture.sync)
        let stale = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "s", favorites: identities,
            idempotencyToken: nil))
        error(stale, .notFound)
        XCTAssertEqual(try fixture.favoritesStore.loadAll(), original)
    }

    // MARK: - Entity-delete recovery + write pipeline (production-backed)

    @MainActor
    func testEntityDeleteLeavesStaleRowsThatGenericClearCanRecover() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let (guide, places) = try EngineSeed.guide(
            fixture.sync, name: "Coffee Crawl",
            entries: [MapsGuideURL.Entry(
                address: "12 Main St", latitude: 30.27, longitude: -97.74)])
        let place = places[0]
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
        let fixture = try await productionFixture(
            writable: true, writeLimit: 1, writeWindow: 60)
        defer { fixture.cleanUp() }
        let (guide, _) = try EngineSeed.guide(
            fixture.sync, name: "Coffee Crawl",
            entries: [MapsGuideURL.Entry(address: "5 Budget St")])
        let guideID = guide.id.uuidString

        let first = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "1", kind: .guide,
            id: guideID, favorite: true, idempotencyToken: "same"))
        guard case .acknowledged = first else { return XCTFail("first failed") }
        let auditAfterFirst = await fixture.storedAuditEntries()
        XCTAssertEqual(auditAfterFirst.count, 1)
        let replay = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "2", kind: .guide,
            id: guideID, favorite: false, idempotencyToken: "same"))
        guard case .acknowledged(_, let messageID, _) = replay else { return XCTFail("replay failed") }
        XCTAssertEqual(messageID, "2")
        // Same-token replay returns the original result even when the payload
        // conflicts; the cached true write must remain authoritative.
        XCTAssertEqual(try fixture.favoritesStore.loadAll().filter { $0.kind == .guide }.count, 1)
        let auditAfterReplay = await fixture.storedAuditEntries()
        XCTAssertEqual(
            auditAfterReplay, auditAfterFirst,
            "an idempotency replay must not append another audit entry")

        let blocked = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "3", kind: .guide,
            id: guideID, favorite: false, idempotencyToken: "different"))
        error(blocked, .busy)
        let entries = await fixture.storedAuditEntries()
        XCTAssertEqual(entries, auditAfterFirst, "a budget rejection must not be audited")
        XCTAssertEqual(entries.last?.action, .setFavorite)
        XCTAssertEqual(entries.last?.subjectKind, .guide)

        // A huge favorite page still rides the shared response cap: 200 REAL
        // guides with 5,000-char names project into an over-cap favorites list.
        fixture.gates.mcpAccess = .readOnly
        var bigGuideIDs: [UUID] = []
        for index in 0..<200 {
            bigGuideIDs.append(try fixture.sync.importGuide(
                from: MapsGuideURL.Snapshot(
                    name: String(repeating: "A", count: 5_000) + "\(index)", entries: []),
                sourceURL: nil))
        }
        try fixture.favoritesStore.setAll(bigGuideIDs.map {
            Favorite(kind: .guide, id: $0.uuidString, addedAt: Date())
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
        let guideID = fixture.coffeeGuideID
        let placeID = fixture.bluebirdPlaceID
        await MainActor.run {
            fixture.favorites.items = [
                Favorite(kind: .guide, id: guideID.uuidString, addedAt: Date()),
                Favorite(kind: .place, id: placeID.uuidString, addedAt: Date()),
            ]
            fixture.favorites.acceptNextReorder = true
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
        XCTAssertEqual(afterRejected.count, original.count + 1)
        XCTAssertEqual(afterRejected.prefix(original.count).map(\.kind), original.map(\.kind))
        XCTAssertEqual(afterRejected.last?.kind, .guide)
        XCTAssertFalse(original.contains { $0.id == afterRejected.last?.id })
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
        let guideID = fixture.coffeeGuideID.uuidString
        await MainActor.run { fixture.favorites.scriptedSetResults = [true] }
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
            fixture.favorites.scriptedSetResults = [true]
        }
        guard case .acknowledged = await fixture.dispatcher.handle(.favoritesSet(
            helperId: Fixture.helper, messageId: "budget-after-denial",
            kind: .guide, id: guideID, favorite: false, idempotencyToken: nil)) else {
            return XCTFail("permission denial must not consume the write budget")
        }
    }

    // MARK: - Department favorites (production-backed)

    @MainActor
    func testDepartmentFavoriteSetMintsOrgAndProjectsLiveDepartmentName() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        // Seed a person carrying a department under the seeded organization.
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace",
                givenName: "Grace", familyName: "Hopper",
                departmentName: "Research",
                organizationName: "Analytical Engines"),
        ])
        // The organization is unreconciled, so its wire id is the deterministic
        // preview UUID it will mint to on the first write.
        let liveOrg = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        XCTAssertNil(liveOrg.contactID.guessWhoID)
        let orgWireID = liveOrg.deterministicGuessWhoID
        let expectedWireID = DepartmentFavoriteKey(
            organizationGuessWhoID: orgWireID, department: "Research").favoriteID

        let set = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "dept-set",
            kind: .department, id: "\(orgWireID)/Research", favorite: true, idempotencyToken: nil))
        guard case .acknowledged = set else {
            return XCTFail("department set failed: \(String(describing: set))")
        }

        // The write minted the org identity and stored EXACTLY one department
        // favorite — never a second contact favorite for the organization.
        let stored = try fixture.favoritesStore.loadAll()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.kind, .department)
        let mintedOrg = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        XCTAssertEqual(mintedOrg.contactID.guessWhoID, orgWireID.lowercased())

        // favorites_list projects the row with the live department name and the
        // org's wire id, available.
        let listed = await list(fixture)
        let page = try XCTUnwrap(listed)
        XCTAssertEqual(page.items.count, 1)
        let row = try XCTUnwrap(page.items.first)
        XCTAssertEqual(row.kind, .department)
        XCTAssertEqual(row.id, expectedWireID)
        XCTAssertEqual(row.displayName, "Research")
        XCTAssertTrue(row.isAvailable)
    }

    @MainActor
    func testDepartmentFavoriteProjectsUnavailableWhenNoOneCarriesTheDepartment() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace",
                givenName: "Grace", familyName: "Hopper",
                departmentName: "Research",
                organizationName: "Analytical Engines"),
        ])
        let liveOrg = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        // Favorite a live department through the repository so the org mints and
        // its UUID becomes known.
        _ = try await fixture.repository.setDepartmentFavorite(
            true, department: "Research", in: liveOrg)
        let orgUUID = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID }?
                .contactID.guessWhoID)

        // Seed a second department favorite that no person carries; it must stay
        // in its stored position as Unavailable, never dropped.
        let researchKey = DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Research")
        let ghostKey = DepartmentFavoriteKey(organizationGuessWhoID: orgUUID, department: "Ghost")
        try fixture.favoritesStore.setAll([
            Favorite(kind: .department, id: researchKey.favoriteID, addedAt: Date(timeIntervalSince1970: 1)),
            Favorite(kind: .department, id: ghostKey.favoriteID, addedAt: Date(timeIntervalSince1970: 2)),
        ])

        let listed = await list(fixture)
        let page = try XCTUnwrap(listed)
        XCTAssertEqual(page.items.map(\.kind), [.department, .department])
        XCTAssertEqual(page.items[0].displayName, "Research")
        XCTAssertTrue(page.items[0].isAvailable)
        XCTAssertEqual(page.items[1].displayName, "Unavailable")
        XCTAssertFalse(page.items[1].isAvailable)
    }

    @MainActor
    func testDepartmentIdShapeIsValidatedAndNeverWrites() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        let before = try fixture.favoritesStore.loadAll()

        // A malformed department id (prefix is not a UUID) → notFound.
        let malformedPrefix = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "d1", kind: .department,
            id: "not-a-uuid/Lilie", favorite: true, idempotencyToken: nil))
        error(malformedPrefix, .notFound)

        // A department id with no "/" (a bare UUID) → notFound.
        let noSeparator = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "d2", kind: .department,
            id: UUID().uuidString, favorite: true, idempotencyToken: nil))
        error(noSeparator, .notFound)

        // A valid department composite supplied for a NON-department kind is a
        // typed kind mismatch, never a silent misfile.
        let mislabeled = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "d3", kind: .contact,
            id: "11111111-2222-4333-8444-555566667777/Lilie", favorite: true, idempotencyToken: nil))
        error(mislabeled, .invalidParams)

        // None of the rejected writes touched the store.
        XCTAssertEqual(try fixture.favoritesStore.loadAll(), before)
    }

    @MainActor
    func testReorderAcceptsDepartmentCompositeIdentity() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace", givenName: "Grace",
                departmentName: "Research", organizationName: "Analytical Engines"),
            Contact(
                localID: "harness-person-ida", givenName: "Ida",
                departmentName: "Sales", organizationName: "Analytical Engines"),
        ])
        let org = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        // The first favorite mints the org; the second favorites a sibling
        // department on the now-reconciled org.
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Research", in: org)
        let minted = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Sales", in: minted)

        let listed = await list(fixture)
        let page = try XCTUnwrap(listed)
        XCTAssertEqual(page.items.map(\.kind), [.department, .department])
        let originalOrder = page.items.map(\.id)
        let desired = page.items.reversed().map { WireFavoriteIdentity(kind: $0.kind, id: $0.id) }

        let response = await fixture.dispatcher.handle(.favoritesReorder(
            helperId: MCPProductionFixture.helper, messageId: "dept-reorder",
            favorites: desired, idempotencyToken: "dr-1"))
        guard case .acknowledged = response else {
            return XCTFail("department reorder failed: \(String(describing: response))")
        }

        let relisted = await list(fixture)
        let after = try XCTUnwrap(relisted)
        XCTAssertEqual(after.items.map(\.id), originalOrder.reversed())
    }

    // MARK: - Department favorite clear paths (production-backed)

    @MainActor
    func testDepartmentFavoriteStillClearsAfterItsLastMemberLeavesTheDepartment() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        // Seed a person carrying "Research" under the seeded org, favorite it,
        // then move that person out so no one carries "Research" any more.
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace", givenName: "Grace",
                departmentName: "Research", organizationName: "Analytical Engines"),
        ])
        let liveOrg = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Research", in: liveOrg)
        let orgUUID = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID }?
                .contactID.guessWhoID)

        // Re-seed the SAME person into a different department; "Research" now has
        // no members, so its favorite reads as Unavailable but keeps its row.
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace", givenName: "Grace",
                departmentName: "Analytics", organizationName: "Analytical Engines"),
        ])
        let emptiedList = await list(fixture)
        let emptied = try XCTUnwrap(emptiedList)
        XCTAssertEqual(emptied.items.count, 1)
        XCTAssertEqual(emptied.items[0].kind, .department)
        XCTAssertEqual(emptied.items[0].displayName, "Unavailable")
        XCTAssertFalse(emptied.items[0].isAvailable)

        // The org still exists, so clearing resolves it and removes the favorite
        // even though no live department matches — an emptied department stays
        // un-favoritable.
        let cleared = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "clear-emptied",
            kind: .department, id: "\(orgUUID)/Research", favorite: false, idempotencyToken: nil))
        guard case .acknowledged = cleared else {
            return XCTFail("emptied-department clear failed: \(String(describing: cleared))")
        }
        XCTAssertTrue(try fixture.favoritesStore.loadAll().isEmpty)
    }

    @MainActor
    func testDepartmentFavoriteClearsWhenTheOrganizationIsGoneButAddCannot() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        // A department favorite keyed on a UUID no contact carries — the org is
        // "gone" from this device's book. It projects as one Unavailable row.
        let ghostKey = DepartmentFavoriteKey(
            organizationGuessWhoID: "99999999-2222-4333-8444-555566667777",
            department: "Marketing")
        try fixture.favoritesStore.setAll([
            Favorite(kind: .department, id: ghostKey.favoriteID, addedAt: Date(timeIntervalSince1970: 1)),
        ])
        let listedPage = await list(fixture)
        let listed = try XCTUnwrap(listedPage)
        XCTAssertEqual(listed.items.count, 1)
        let row = listed.items[0]
        XCTAssertEqual(row.kind, .department)
        XCTAssertFalse(row.isAvailable)

        // Adding a favorite for a gone org is an error and writes nothing.
        let added = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "ghost-add",
            kind: .department, id: row.id, favorite: true, idempotencyToken: nil))
        error(added, .notFound)
        XCTAssertEqual(try fixture.favoritesStore.loadAll().count, 1)

        // Clearing the same id succeeds via the stored-row fallback.
        let cleared = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "ghost-clear",
            kind: .department, id: row.id, favorite: false, idempotencyToken: nil))
        guard case .acknowledged = cleared else {
            return XCTFail("org-gone clear failed: \(String(describing: cleared))")
        }
        XCTAssertTrue(try fixture.favoritesStore.loadAll().isEmpty)
    }

    @MainActor
    func testDepartmentFavoriteAddForAnUncarriedDepartmentFailsWithoutMintingTheOrg() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        // One live department ("Research") exists under the seeded org; "Ghost"
        // does not.
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace", givenName: "Grace",
                departmentName: "Research", organizationName: "Analytical Engines"),
        ])
        let liveOrg = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        XCTAssertNil(liveOrg.contactID.guessWhoID)
        let orgWireID = liveOrg.deterministicGuessWhoID
        let before = try fixture.favoritesStore.loadAll()

        let added = await fixture.dispatcher.handle(.favoritesSet(
            helperId: MCPProductionFixture.helper, messageId: "ghost-dept",
            kind: .department, id: "\(orgWireID)/Ghost", favorite: true, idempotencyToken: nil))
        error(added, .notFound)

        // The live-department check runs BEFORE any write, so nothing was stored
        // and the organization was NOT minted — its guessWhoID stays nil.
        XCTAssertEqual(try fixture.favoritesStore.loadAll(), before)
        XCTAssertNil(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID }?
                .contactID.guessWhoID)
    }

    // MARK: - Department rename re-keys the favorite (production-backed, end to end)

    @MainActor
    func testDepartmentRenameThroughTheToolReKeysTheFavoriteEndToEnd() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace", givenName: "Grace",
                departmentName: "Research", organizationName: "Analytical Engines"),
        ])
        let liveOrg = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        // Favorite the department; this mints the org identity.
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Research", in: liveOrg)
        let orgWireID = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID }?
                .contactID.guessWhoID)
        let originalAddedAt = try XCTUnwrap(fixture.favoritesStore.loadAll().first?.addedAt)

        let renamed = await fixture.dispatcher.handle(.organizationsRenameDepartment(
            helperId: MCPProductionFixture.helper, messageId: "rename",
            organizationId: orgWireID, oldName: "Research", newName: "Innovation",
            idempotencyToken: nil))
        guard case .departmentRename(_, _, let result) = renamed else {
            return XCTFail("rename failed: \(String(describing: renamed))")
        }
        XCTAssertEqual(result.affectedCount, 1)

        // favorites_list shows ONE department row, now "Innovation", available,
        // keyed on the org wire id + the new name.
        let listedAfterRename = await list(fixture)
        let page = try XCTUnwrap(listedAfterRename)
        XCTAssertEqual(page.items.count, 1)
        let listRow = page.items[0]
        XCTAssertEqual(listRow.kind, .department)
        XCTAssertEqual(listRow.displayName, "Innovation")
        XCTAssertTrue(listRow.isAvailable)
        XCTAssertEqual(listRow.id, DepartmentFavoriteKey(
            organizationGuessWhoID: orgWireID, department: "Innovation").favoriteID)

        // The stored favorite re-keyed to "Innovation" but kept its addedAt.
        let stored = try fixture.favoritesStore.loadAll()
        XCTAssertEqual(stored.count, 1)
        let storedKey = try XCTUnwrap(DepartmentFavoriteKey(favoriteID: stored[0].id))
        XCTAssertTrue(storedKey.matches(department: "Innovation"))
        XCTAssertFalse(storedKey.matches(department: "Research"))
        XCTAssertEqual(stored[0].addedAt, originalAddedAt)
    }

    // MARK: - Mixed-kind favorites list keeps the department row in place

    @MainActor
    func testMixedKindFavoritesKeepTheDepartmentRowInStoredOrderAndPageOnce() async throws {
        let fixture = try await productionFixture(writable: true)
        defer { fixture.cleanUp() }
        try await fixture.seedContacts([
            Contact(
                localID: "harness-person-grace", givenName: "Grace",
                departmentName: "Research", organizationName: "Analytical Engines"),
        ])
        // Written in this order → stored in this order: contact, department, group.
        let ada = try XCTUnwrap(
            fixture.repository.contact(localID: MCPProductionFixture.adaLocalID))
        _ = try await fixture.repository.toggleFavorite(ada.contactID)
        let org = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID })
        _ = try await fixture.repository.setDepartmentFavorite(true, department: "Research", in: org)
        let orgUUID = try XCTUnwrap(
            fixture.repository.allContacts.first { $0.localID == MCPProductionFixture.orgLocalID }?
                .contactID.guessWhoID)
        let group = try XCTUnwrap(
            fixture.repository.groups.first { $0.name == MCPProductionFixture.groupName })
        _ = try await fixture.repository.setGroupFavorite(true, for: group)

        XCTAssertEqual(try fixture.favoritesStore.loadAll().map(\.kind), [.contact, .department, .group])

        // The full page keeps the department row in the middle, correctly typed.
        let fullList = await list(fixture)
        let page = try XCTUnwrap(fullList)
        XCTAssertEqual(page.items.map(\.kind), [.contact, .department, .group])
        XCTAssertEqual(page.items[0].displayName, "Ada Lovelace")
        let deptRow = page.items[1]
        XCTAssertEqual(deptRow.kind, .department)
        XCTAssertEqual(deptRow.displayName, "Research")
        XCTAssertEqual(deptRow.id, DepartmentFavoriteKey(
            organizationGuessWhoID: orgUUID, department: "Research").favoriteID)
        XCTAssertEqual(page.items[2].displayName, "Pioneers")

        // Paging one at a time surfaces the department row exactly once, on page 2.
        let firstList = await list(fixture, limit: 1)
        let first = try XCTUnwrap(firstList)
        XCTAssertEqual(first.items.map(\.kind), [.contact])
        let secondList = await list(fixture, limit: 1, cursor: first.nextCursor)
        let second = try XCTUnwrap(secondList)
        XCTAssertEqual(second.items.map(\.kind), [.department])
        XCTAssertEqual(second.items[0].id, deptRow.id)
        let thirdList = await list(fixture, limit: 1, cursor: second.nextCursor)
        let third = try XCTUnwrap(thirdList)
        XCTAssertEqual(third.items.map(\.kind), [.group])
        XCTAssertNil(third.nextCursor)
    }
}
