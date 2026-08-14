import XCTest
import GuessWhoSync
import GuessWhoMCPCore
import GuessWhoMCPWire

final class GuidePlaceReadToolTests: XCTestCase {
    private func expectError(
        _ response: WireResponse?, code: WireErrorCode,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(response?.errorPayload?.code, code, file: file, line: line)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func testGuideListAndGetExposeEveryVisibleFieldAndFavoriteState() async throws {
        let fixture = await Fixture.make()
        let engine = fixture.linkEngine
        try EngineSeed.clearGuides(engine)
        let viewed = Date(timeIntervalSince1970: 1_750_000_000)
        let (guide, _) = try EngineSeed.guide(
            engine, name: "Coffee Crawl", sourceURL: "https://guides.apple/example",
            entries: [
                MapsGuideURL.Entry(address: "12 Main St", latitude: 30.27, longitude: -97.74),
                MapsGuideURL.Entry(address: "2 Main St"),
            ])
        try engine.stampGuideViewed(
            at: SidecarKey(kind: .guide, id: guide.id.uuidString), now: viewed)
        _ = try fixture.guidesFavoritesStore.set(
            kind: .guide, id: guide.id.uuidString, favorite: true, now: Date())
        // Assert the wire mapping against the SAME engine projection the
        // dispatcher reads: createdAt is the engine's mint time (not a fixed
        // value), lastViewed is exactly the timestamp we stamped.
        let projected = try XCTUnwrap(EngineSeed.guide(engine, id: guide.id))

        let list = await fixture.dispatcher.handle(.guidesList(
            helperId: Fixture.helper, messageId: "list", limit: nil, cursor: nil))
        guard case .guidePage(_, _, let page) = list, let wire = page.items.first else {
            return XCTFail("expected guide page")
        }
        XCTAssertEqual(wire.id, guide.id.uuidString.lowercased())
        XCTAssertEqual(wire.name, "Coffee Crawl")
        XCTAssertEqual(wire.sourceURL, "https://guides.apple/example")
        XCTAssertEqual(wire.createdAt, projected.createdAt.map(timestamp))
        XCTAssertEqual(wire.lastViewedAt, timestamp(viewed))
        XCTAssertEqual(wire.placeCount, 2)
        XCTAssertTrue(wire.isFavorite)

        let get = await fixture.dispatcher.handle(.guidesGet(
            helperId: Fixture.helper, messageId: "get", guideId: wire.id))
        guard case .guide(_, _, let fetched) = get else {
            return XCTFail("expected guide")
        }
        XCTAssertEqual(fetched.id, wire.id)
        XCTAssertEqual(fetched.lastViewedAt, wire.lastViewedAt)
        XCTAssertEqual(fetched.placeCount, 2)
        XCTAssertTrue(fetched.isFavorite)
    }

    func testPlacesGetExposesAllFieldsAndNeverMapsIdentifier() async throws {
        let fixture = await Fixture.make()
        let engine = fixture.linkEngine
        try EngineSeed.clearGuides(engine)
        let viewed = Date(timeIntervalSince1970: 1_720_000_000)
        let resolved = Date(timeIntervalSince1970: 1_730_000_000)
        // A place-ID entry carrying the private MapKit id, then RESOLVED through
        // the engine's own resolution path (fills name/address/coordinate and
        // stamps resolvedAt), then view-stamped and favorited.
        let (guide, places) = try EngineSeed.guide(
            engine, name: "Coffee Crawl",
            entries: [MapsGuideURL.Entry(mapsPlaceID: "IAPPLE-PRIVATE-SENTINEL")])
        let placeID = places[0].id
        let placeKey = SidecarKey(kind: .place, id: placeID.uuidString)
        try engine.markPlaceResolved(
            at: placeKey, name: "Visible Cafe",
            address: "12 Main Street, Austin, TX", latitude: 30.2, longitude: -97.7,
            now: resolved)
        try engine.stampPlaceViewed(at: placeKey, now: viewed)
        _ = try fixture.guidesFavoritesStore.set(
            kind: .place, id: placeID.uuidString, favorite: true, now: Date())
        let projected = try XCTUnwrap(EngineSeed.place(engine, id: placeID, inGuide: guide.id))

        let response = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "get",
            placeId: placeID.uuidString.lowercased()))
        guard case .place(_, _, let wire) = response else {
            return XCTFail("expected place")
        }
        XCTAssertEqual(wire.id, placeID.uuidString.lowercased())
        XCTAssertEqual(wire.guideId, guide.id.uuidString.lowercased())
        XCTAssertEqual(wire.name, "Visible Cafe")
        XCTAssertEqual(wire.address, "12 Main Street, Austin, TX")
        XCTAssertEqual(wire.latitude, 30.2)
        XCTAssertEqual(wire.longitude, -97.7)
        // sortOrder + createdAt are engine-owned (import order + mint time);
        // assert the wire matches the engine's own projection.
        XCTAssertEqual(wire.sortOrder, projected.sortOrder)
        XCTAssertEqual(wire.createdAt, projected.createdAt.map(timestamp))
        XCTAssertEqual(wire.lastViewedAt, timestamp(viewed))
        XCTAssertEqual(wire.resolvedAt, timestamp(resolved))
        XCTAssertFalse(wire.needsResolution)
        XCTAssertTrue(wire.isFavorite)
        XCTAssertFalse(response?.agentVisibleText.contains("IAPPLE-PRIVATE-SENTINEL") == true)
        XCTAssertFalse(response?.wireJSON.contains("IAPPLE-PRIVATE-SENTINEL") == true)
    }

    func testUnresolvedPlaceHasVisibleNilState() async throws {
        let fixture = await Fixture.make()
        let engine = fixture.linkEngine
        try EngineSeed.clearGuides(engine)
        // A place-ID entry (never resolved) followed by an inline address entry.
        let (_, places) = try EngineSeed.guide(
            engine, name: "Coffee Crawl",
            entries: [
                MapsGuideURL.Entry(mapsPlaceID: "IUNRESOLVED-PRIVATE"),
                MapsGuideURL.Entry(address: "1 Inline Address", latitude: 1, longitude: 2),
            ])
        let place = places[0]
        let addressEntry = places[1]

        let response = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "get",
            placeId: place.id.uuidString.lowercased()))
        guard case .place(_, _, let wire) = response else {
            return XCTFail("expected place")
        }
        XCTAssertEqual(wire.name, "")
        XCTAssertNil(wire.address)
        XCTAssertNil(wire.latitude)
        XCTAssertNil(wire.longitude)
        XCTAssertNil(wire.resolvedAt)
        // Unlike the retired fake (which left createdAt unset), the engine
        // always stamps a mint time on every imported place.
        XCTAssertNotNil(wire.createdAt)
        XCTAssertNil(wire.lastViewedAt)
        XCTAssertTrue(wire.needsResolution)
        XCTAssertFalse(wire.isFavorite)
        XCTAssertFalse(response?.wireJSON.contains("IUNRESOLVED-PRIVATE") == true)

        let addressResponse = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "address",
            placeId: addressEntry.id.uuidString))
        guard case .place(_, _, let addressWire) = addressResponse else {
            return XCTFail("expected address place")
        }
        XCTAssertNil(addressWire.resolvedAt)
        XCTAssertFalse(addressWire.needsResolution)
    }

    func testPlacesSearchMatchesVisibleFieldsAndGuideNameOnly() async throws {
        let fixture = await Fixture.make()
        let engine = fixture.linkEngine
        try EngineSeed.clearGuides(engine)
        // Coffee Crawl holds a named place, an address-only place, and a
        // private place-ID entry; Museum Weekend holds one place matched only
        // by its guide name.
        let (_, coffeePlaces) = try EngineSeed.guide(
            engine, name: "Coffee Crawl",
            entries: [
                MapsGuideURL.Entry(address: "12 Main Street"),
                MapsGuideURL.Entry(address: "500 Gallery Avenue"),
                MapsGuideURL.Entry(mapsPlaceID: "IHIDDENNEEDLE"),
            ])
        let byName = coffeePlaces[0]
        let byAddress = coffeePlaces[1]
        let privateOnly = coffeePlaces[2]
        // Give byName a searchable display name.
        try engine.markPlaceResolved(
            at: SidecarKey(kind: .place, id: byName.id.uuidString),
            name: "Bluebird Espresso", address: "12 Main Street",
            latitude: nil, longitude: nil)
        let (_, museumPlaces) = try EngineSeed.guide(
            engine, name: "Museum Weekend",
            entries: [MapsGuideURL.Entry(address: "9 Oak Road")])
        let byGuide = museumPlaces[0]
        let records = [byName, byAddress, byGuide, privateOnly]

        func search(_ query: String) async -> [WirePlace] {
            let response = await fixture.dispatcher.handle(.placesSearch(
                helperId: Fixture.helper, messageId: query, query: query,
                limit: nil, cursor: nil))
            guard case .placePage(_, _, let page) = response else { return [] }
            return page.items
        }

        let nameMatches = await search("blueBIRD")
        let addressMatches = await search("gallery avenue")
        let guideMatches = await search("museum weekend")
        let privateMatches = await search("hiddenneedle")
        let absentMatches = await search("not present")
        XCTAssertEqual(nameMatches.map(\.id), [records[0].id.uuidString.lowercased()])
        XCTAssertEqual(addressMatches.map(\.id), [records[1].id.uuidString.lowercased()])
        XCTAssertEqual(guideMatches.map(\.id), [records[2].id.uuidString.lowercased()])
        XCTAssertTrue(privateMatches.isEmpty)
        XCTAssertTrue(absentMatches.isEmpty)
    }

    func testPlacesSearchRejectsWhitespaceOnlyQuery() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.placesSearch(
            helperId: Fixture.helper, messageId: "blank", query: "  \n ",
            limit: nil, cursor: nil))
        expectError(response, code: .invalidParams)
    }

    func testPlacesSearchUsesGlobalSearchBudgetAcrossHelpers() async {
        let fixture = await Fixture.make()
        let dispatcher = ToolDispatcher(
            contacts: fixture.contacts, events: fixture.events,
            guides: fixture.guides, favorites: fixture.favorites,
            links: fixture.links, gates: fixture.gates,
            searchLimitPerWindow: 1, searchWindowSeconds: 60)
        let first = await dispatcher.handle(.placesSearch(
            helperId: Fixture.helper, messageId: "first", query: "coffee",
            limit: nil, cursor: nil))
        guard case .placePage = first else {
            return XCTFail("first search should pass")
        }
        let second = await dispatcher.handle(.placesSearch(
            helperId: RequestOrigin.mcp.makeHelperId(), messageId: "second",
            query: "coffee", limit: nil, cursor: nil))
        expectError(second, code: .busy)
    }

    func testPlaceSearchAndListsHaveDeterministicPaging() async throws {
        let fixture = await Fixture.make()
        let engine = fixture.linkEngine
        try EngineSeed.clearGuides(engine)
        // Two places with identical name + address: search paging tie-breaks by
        // UUID, list paging tie-breaks by the guide's sort order.
        let (guide, places) = try EngineSeed.guide(
            engine, name: "Coffee Crawl",
            entries: [MapsGuideURL.Entry(address: "A"), MapsGuideURL.Entry(address: "A")])
        for place in places {
            try engine.markPlaceResolved(
                at: SidecarKey(kind: .place, id: place.id.uuidString),
                name: "Same", address: "A", latitude: nil, longitude: nil)
        }
        // Search paging tie-breaks by UUID; list paging tie-breaks by the guide's
        // sort order. Force the guide's sort order to the REVERSE of UUID order so
        // the two orderings are guaranteed to differ — otherwise two random v4
        // UUIDs might already sit in import order, and the run would never
        // actually exercise the search-vs-list tie-break distinction.
        let placesByUUID = places.sorted {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        try engine.reorderPlaces(
            inGuide: guide.id, orderedIDs: placesByUUID.reversed().map { $0.id })
        let byUUID = placesByUUID.map { $0.id.uuidString.lowercased() }
        let bySortOrder = Array(byUUID.reversed())

        let first = await fixture.dispatcher.handle(.placesSearch(
            helperId: Fixture.helper, messageId: "first", query: "same",
            limit: 1, cursor: nil))
        guard case .placePage(_, _, let firstPage) = first else {
            return XCTFail("expected first page")
        }
        XCTAssertEqual(firstPage.items.map(\.id), [byUUID[0]])
        XCTAssertEqual(firstPage.nextCursor, "o1")

        let second = await fixture.dispatcher.handle(.placesSearch(
            helperId: Fixture.helper, messageId: "second", query: "same",
            limit: 1, cursor: firstPage.nextCursor))
        guard case .placePage(_, _, let secondPage) = second else {
            return XCTFail("expected second page")
        }
        XCTAssertEqual(secondPage.items.map(\.id), [byUUID[1]])
        XCTAssertNil(secondPage.nextCursor)

        let listed = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: "list",
            guideId: guide.id.uuidString, limit: nil, cursor: nil))
        guard case .placePage(_, _, let listPage) = listed else {
            return XCTFail("expected list page")
        }
        XCTAssertEqual(listPage.items.map(\.id), bySortOrder)
    }

    func testPlacesListRejectsSyntacticallyValidMissingGuide() async {
        let fixture = await Fixture.make()
        let response = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: "missing",
            guideId: UUID().uuidString, limit: nil, cursor: nil))
        expectError(response, code: .notFound)
    }

    func testPlacesGetUnknownOrWrongKindIsNotFound() async {
        let fixture = await Fixture.make()
        expectError(await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "bad", placeId: "not-an-id")), code: .notFound)
        let guideID = fixture.coffeeGuideID.uuidString
        expectError(await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "wrong", placeId: guideID)), code: .notFound)
        expectError(await fixture.dispatcher.handle(.guidesListForPlace(
            helperId: Fixture.helper, messageId: "containing-missing",
            placeId: UUID().uuidString, limit: nil, cursor: nil)), code: .notFound)
    }

    func testGuidesListForPlaceUsesAddressMatchingPagingAndFavoriteFields() async throws {
        let fixture = await Fixture.make()
        let engine = fixture.linkEngine
        try EngineSeed.clearGuides(engine)
        // Alpha and Beta each hold a place at the same street; the Unresolved
        // guide holds a place-ID entry with no address (matches nothing).
        let (alpha, _) = try EngineSeed.guide(
            engine, name: "Alpha Guide",
            entries: [MapsGuideURL.Entry(address: "12 Main Street, Austin, Texas")])
        let (beta, betaPlaces) = try EngineSeed.guide(
            engine, name: "Beta Guide",
            entries: [MapsGuideURL.Entry(address: "12 Main Street, Austin, TX")])
        let (_, unresolvedPlaces) = try EngineSeed.guide(
            engine, name: "Unresolved Guide",
            entries: [MapsGuideURL.Entry(mapsPlaceID: "IPRIVATE")])
        _ = try fixture.guidesFavoritesStore.set(
            kind: .guide, id: beta.id.uuidString, favorite: true, now: Date())
        let setup = (
            betaPlaces[0], unresolvedPlaces[0],
            [alpha.id, beta.id].map { $0.uuidString.lowercased() })

        let first = await fixture.dispatcher.handle(.guidesListForPlace(
            helperId: Fixture.helper, messageId: "first",
            placeId: setup.0.id.uuidString, limit: 1, cursor: nil))
        guard case .guidePage(_, _, let firstPage) = first else {
            return XCTFail("expected guide page")
        }
        XCTAssertEqual(firstPage.items.map(\.id), [setup.2[0]])
        XCTAssertEqual(firstPage.items[0].placeCount, 1)
        XCTAssertFalse(firstPage.items[0].isFavorite)
        XCTAssertEqual(firstPage.nextCursor, "o1")

        let second = await fixture.dispatcher.handle(.guidesListForPlace(
            helperId: Fixture.helper, messageId: "second",
            placeId: setup.0.id.uuidString, limit: 1, cursor: firstPage.nextCursor))
        guard case .guidePage(_, _, let secondPage) = second else {
            return XCTFail("expected second guide page")
        }
        XCTAssertEqual(secondPage.items.map(\.id), [setup.2[1]])
        XCTAssertTrue(secondPage.items[0].isFavorite)
        XCTAssertNil(secondPage.nextCursor)

        let unresolved = await fixture.dispatcher.handle(.guidesListForPlace(
            helperId: Fixture.helper, messageId: "unresolved",
            placeId: setup.1.id.uuidString, limit: nil, cursor: nil))
        guard case .guidePage(_, _, let unresolvedPage) = unresolved else {
            return XCTFail("expected unresolved guide page")
        }
        XCTAssertTrue(unresolvedPage.items.isEmpty)
    }

    func testGuidePlaceReadsAreAvailableInReadOnlyAndHiddenWhenOff() async {
        let fixture = await Fixture.make()
        let list = await fixture.dispatcher.handle(.listTools(
            helperId: Fixture.helper, messageId: "list"))
        guard case .toolList(_, _, let tools, _) = list else {
            return XCTFail("expected tools")
        }
        let names = Set(tools.map(\.name))
        XCTAssertTrue(names.contains(MCPTool.placesGet.rawValue))
        XCTAssertTrue(names.contains(MCPTool.placesSearch.rawValue))
        XCTAssertTrue(names.contains(MCPTool.guidesListForPlace.rawValue))

        let placeID = fixture.bluebirdPlaceID.uuidString
        let read = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "read", placeId: placeID))
        guard case .place = read else { return XCTFail("read-only must allow reads") }

        await MainActor.run { fixture.gates.mcpAccess = .off }
        expectError(await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "off", placeId: placeID)), code: .disabled)
    }

    func testPlaceReadResponseCapReturnsTypedTooLarge() async throws {
        let fixture = await Fixture.make()
        // The lone place is a REAL one whose address alone exceeds the response
        // cap (clear the seeded guide so `guideId: nil` returns only this one).
        try EngineSeed.clearGuides(fixture.linkEngine)
        _ = try EngineSeed.guide(
            fixture.linkEngine, name: "Huge Guide",
            entries: [MapsGuideURL.Entry(
                address: String(
                    repeating: "x", count: WireEnvironment.maxResponsePayloadBytes + 1_024))])
        let response = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: "huge",
            guideId: nil, limit: 1, cursor: nil))
        expectError(response, code: .tooLarge)
    }
}
