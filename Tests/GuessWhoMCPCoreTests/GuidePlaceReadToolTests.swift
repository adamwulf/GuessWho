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

    func testGuideListAndGetExposeEveryVisibleFieldAndFavoriteState() async {
        let fixture = await Fixture.make()
        let created = Date(timeIntervalSince1970: 1_740_000_000)
        let viewed = Date(timeIntervalSince1970: 1_750_000_000)
        let guide = await MainActor.run { () -> MapsGuide in
            var guide = fixture.guides.guides[0]
            guide.createdAt = created
            guide.lastViewedAt = viewed
            fixture.guides.guides = [guide]
            fixture.guides.places.append(MapsPlace(
                guideID: guide.id, name: "Second", address: "2 Main St", sortOrder: 1))
            fixture.guides.favoriteGuideIDs = [guide.id.uuidString.lowercased()]
            return guide
        }

        let list = await fixture.dispatcher.handle(.guidesList(
            helperId: Fixture.helper, messageId: "list", limit: nil, cursor: nil))
        guard case .guidePage(_, _, let page) = list, let wire = page.items.first else {
            return XCTFail("expected guide page")
        }
        XCTAssertEqual(wire.id, guide.id.uuidString.lowercased())
        XCTAssertEqual(wire.name, "Coffee Crawl")
        XCTAssertEqual(wire.sourceURL, "https://guides.apple/example")
        XCTAssertEqual(wire.createdAt, timestamp(created))
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

    func testPlacesGetExposesAllFieldsAndNeverMapsIdentifier() async {
        let fixture = await Fixture.make()
        let created = Date(timeIntervalSince1970: 1_710_000_000)
        let viewed = Date(timeIntervalSince1970: 1_720_000_000)
        let resolved = Date(timeIntervalSince1970: 1_730_000_000)
        let place = await MainActor.run { () -> MapsPlace in
            let guideID = fixture.guides.guides[0].id
            let place = MapsPlace(
                id: UUID(), guideID: guideID, name: "Visible Cafe",
                address: "12 Main Street, Austin, TX", latitude: 30.2,
                longitude: -97.7, mapsPlaceID: "IAPPLE-PRIVATE-SENTINEL",
                resolvedAt: resolved, sortOrder: 7, createdAt: created,
                lastViewedAt: viewed)
            fixture.guides.places = [place]
            fixture.guides.favoritePlaceIDs = [place.id.uuidString.lowercased()]
            return place
        }

        let response = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "get",
            placeId: place.id.uuidString.lowercased()))
        guard case .place(_, _, let wire) = response else {
            return XCTFail("expected place")
        }
        XCTAssertEqual(wire.id, place.id.uuidString.lowercased())
        XCTAssertEqual(wire.guideId, place.guideID.uuidString.lowercased())
        XCTAssertEqual(wire.name, "Visible Cafe")
        XCTAssertEqual(wire.address, "12 Main Street, Austin, TX")
        XCTAssertEqual(wire.latitude, 30.2)
        XCTAssertEqual(wire.longitude, -97.7)
        XCTAssertEqual(wire.sortOrder, 7)
        XCTAssertEqual(wire.createdAt, timestamp(created))
        XCTAssertEqual(wire.lastViewedAt, timestamp(viewed))
        XCTAssertEqual(wire.resolvedAt, timestamp(resolved))
        XCTAssertFalse(wire.needsResolution)
        XCTAssertTrue(wire.isFavorite)
        XCTAssertFalse(response?.agentVisibleText.contains("IAPPLE-PRIVATE-SENTINEL") == true)
        XCTAssertFalse(response?.wireJSON.contains("IAPPLE-PRIVATE-SENTINEL") == true)
    }

    func testUnresolvedPlaceHasVisibleNilState() async {
        let fixture = await Fixture.make()
        let place = await MainActor.run { () -> MapsPlace in
            let place = MapsPlace(
                id: UUID(), guideID: fixture.guides.guides[0].id,
                mapsPlaceID: "IUNRESOLVED-PRIVATE", sortOrder: 3)
            fixture.guides.places = [place]
            return place
        }
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
        XCTAssertNil(wire.createdAt)
        XCTAssertNil(wire.lastViewedAt)
        XCTAssertTrue(wire.needsResolution)
        XCTAssertFalse(wire.isFavorite)
        XCTAssertFalse(response?.wireJSON.contains("IUNRESOLVED-PRIVATE") == true)

        let addressEntry = await MainActor.run { () -> MapsPlace in
            let entry = MapsPlace(
                id: UUID(), guideID: fixture.guides.guides[0].id,
                address: "1 Inline Address", latitude: 1, longitude: 2)
            fixture.guides.places.append(entry)
            return entry
        }
        let addressResponse = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "address",
            placeId: addressEntry.id.uuidString))
        guard case .place(_, _, let addressWire) = addressResponse else {
            return XCTFail("expected address place")
        }
        XCTAssertNil(addressWire.resolvedAt)
        XCTAssertFalse(addressWire.needsResolution)
    }

    func testPlacesSearchMatchesVisibleFieldsAndGuideNameOnly() async {
        let fixture = await Fixture.make()
        let records = await MainActor.run { () -> [MapsPlace] in
            let coffee = fixture.guides.guides[0]
            let museums = MapsGuide(id: UUID(), name: "Museum Weekend")
            fixture.guides.guides = [museums, coffee]
            let byName = MapsPlace(
                id: UUID(), guideID: coffee.id, name: "Bluebird Espresso",
                address: "12 Main Street", sortOrder: 2)
            let byAddress = MapsPlace(
                id: UUID(), guideID: coffee.id, name: "Roaster",
                address: "500 Gallery Avenue", sortOrder: 1)
            let byGuide = MapsPlace(
                id: UUID(), guideID: museums.id, name: "Quiet Cafe",
                address: "9 Oak Road", sortOrder: 0)
            let privateOnly = MapsPlace(
                id: UUID(), guideID: coffee.id, name: "Ordinary",
                address: "1 Plain Road", mapsPlaceID: "IHIDDENNEEDLE",
                resolvedAt: Date(), sortOrder: 0)
            fixture.guides.places = [byName, byAddress, byGuide, privateOnly]
            return [byName, byAddress, byGuide, privateOnly]
        }

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

    func testPlaceSearchAndListsHaveDeterministicPaging() async {
        let fixture = await Fixture.make()
        let expected = await MainActor.run { () -> [String] in
            let guide = fixture.guides.guides[0]
            let high = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
            let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            fixture.guides.places = [
                MapsPlace(id: high, guideID: guide.id, name: "Same", address: "A", sortOrder: 1),
                MapsPlace(id: low, guideID: guide.id, name: "Same", address: "A", sortOrder: 0),
            ]
            return [low, high].map { $0.uuidString.lowercased() }
        }

        let first = await fixture.dispatcher.handle(.placesSearch(
            helperId: Fixture.helper, messageId: "first", query: "same",
            limit: 1, cursor: nil))
        guard case .placePage(_, _, let firstPage) = first else {
            return XCTFail("expected first page")
        }
        XCTAssertEqual(firstPage.items.map(\.id), [expected[0]])
        XCTAssertEqual(firstPage.nextCursor, "o1")

        let second = await fixture.dispatcher.handle(.placesSearch(
            helperId: Fixture.helper, messageId: "second", query: "same",
            limit: 1, cursor: firstPage.nextCursor))
        guard case .placePage(_, _, let secondPage) = second else {
            return XCTFail("expected second page")
        }
        XCTAssertEqual(secondPage.items.map(\.id), [expected[1]])
        XCTAssertNil(secondPage.nextCursor)

        let listed = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: "list",
            guideId: await MainActor.run { fixture.guides.guides[0].id.uuidString },
            limit: nil, cursor: nil))
        guard case .placePage(_, _, let listPage) = listed else {
            return XCTFail("expected list page")
        }
        XCTAssertEqual(listPage.items.map(\.id), expected)
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
        let guideID = await MainActor.run { fixture.guides.guides[0].id.uuidString }
        expectError(await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "wrong", placeId: guideID)), code: .notFound)
        expectError(await fixture.dispatcher.handle(.guidesListForPlace(
            helperId: Fixture.helper, messageId: "containing-missing",
            placeId: UUID().uuidString, limit: nil, cursor: nil)), code: .notFound)
    }

    func testGuidesListForPlaceUsesAddressMatchingPagingAndFavoriteFields() async {
        let fixture = await Fixture.make()
        let setup = await MainActor.run { () -> (MapsPlace, MapsPlace, [String]) in
            let alpha = MapsGuide(id: UUID(), name: "Alpha Guide")
            let beta = MapsGuide(id: UUID(), name: "Beta Guide")
            let unresolvedGuide = MapsGuide(id: UUID(), name: "Unresolved Guide")
            let target = MapsPlace(
                id: UUID(), guideID: beta.id, name: "Target",
                address: "12 Main Street, Austin, TX", sortOrder: 0)
            let sameAddress = MapsPlace(
                id: UUID(), guideID: alpha.id, name: "Also Here",
                address: "12 Main Street, Austin, Texas", sortOrder: 0)
            let unresolved = MapsPlace(
                id: UUID(), guideID: unresolvedGuide.id,
                mapsPlaceID: "IPRIVATE", sortOrder: 0)
            fixture.guides.guides = [beta, unresolvedGuide, alpha]
            fixture.guides.places = [target, sameAddress, unresolved]
            fixture.guides.favoriteGuideIDs = [beta.id.uuidString.lowercased()]
            return (
                target, unresolved,
                [alpha.id, beta.id].map { $0.uuidString.lowercased() })
        }

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

        let placeID = await MainActor.run { fixture.guides.places[0].id.uuidString }
        let read = await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "read", placeId: placeID))
        guard case .place = read else { return XCTFail("read-only must allow reads") }

        await MainActor.run { fixture.gates.mcpAccess = .off }
        expectError(await fixture.dispatcher.handle(.placesGet(
            helperId: Fixture.helper, messageId: "off", placeId: placeID)), code: .disabled)
    }

    func testPlaceReadResponseCapReturnsTypedTooLarge() async {
        let fixture = await Fixture.make()
        await MainActor.run {
            let guide = fixture.guides.guides[0]
            fixture.guides.places = [MapsPlace(
                id: UUID(), guideID: guide.id, name: "Huge",
                address: String(
                    repeating: "x", count: WireEnvironment.maxResponsePayloadBytes + 1_024))]
        }
        let response = await fixture.dispatcher.handle(.placesList(
            helperId: Fixture.helper, messageId: "huge",
            guideId: nil, limit: 1, cursor: nil))
        expectError(response, code: .tooLarge)
    }
}
