import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the place reads, and render for the place page and
/// full place shapes.
final class PlacesCommandTests: CLICommandTestCase {

    // MARK: places list — parse + request build

    func testListParsesGuideFilterAndPaging() throws {
        let command = try PlacesList.parse(["--guide-id", "g1", "--limit", "7", "--cursor", "p"])
        XCTAssertEqual(command.guideId, "g1")
        XCTAssertEqual(command.limit, 7)
        XCTAssertEqual(command.cursor, "p")
    }

    func testListParsesNoArguments() throws {
        let command = try PlacesList.parse([])
        XCTAssertNil(command.guideId)
        XCTAssertNil(command.limit)
        XCTAssertNil(command.cursor)
    }

    func testListBuildsExpectedRequest() throws {
        let command = try PlacesList.parse(["--guide-id", "g1", "--limit", "7"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.placesList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.placesList(
            helperId: "cli-test", messageId: "m1", guideId: "g1", limit: 7, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: places search — parse + request build

    func testSearchParsesQueryAndPaging() throws {
        let command = try PlacesSearch.parse(["cafe", "--limit", "5"])
        XCTAssertEqual(command.query, "cafe")
        XCTAssertEqual(command.limit, 5)
    }

    func testSearchMissingQueryIsAParseError() {
        XCTAssertThrowsError(try PlacesSearch.parse([]))
    }

    func testSearchBuildsExpectedRequest() throws {
        let command = try PlacesSearch.parse(["cafe", "--limit", "5"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.placesSearch.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.placesSearch(
            helperId: "cli-test", messageId: "m1", query: "cafe", limit: 5, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: places get — parse + request build

    func testGetParsesPlaceId() throws {
        XCTAssertEqual(try PlacesGet.parse(["p1"]).placeId, "p1")
    }

    func testGetBuildsExpectedRequest() throws {
        let command = try PlacesGet.parse(["p1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.placesGet.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.placesGet(helperId: "cli-test", messageId: "m1", placeId: "p1")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — place page

    func testListRendersPlacePageAsJSON() async throws {
        let page = WirePage(items: [Self.samplePlace], nextCursor: "next")
        let response = WireResponse.placePage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try PlacesList.parse([])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Render — full place

    func testGetRendersPlaceAsJSON() async throws {
        let response = WireResponse.place(helperId: "h", messageId: "m", place: Self.samplePlace)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try PlacesGet.parse(["p1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(Self.samplePlace) + "\n")
    }

    static let samplePlace = WirePlace(
        id: "p1", guideId: "g1", name: "Blue Bottle", address: "300 Webster St",
        latitude: 37.8, longitude: -122.2, sortOrder: 0,
        createdAt: "2026-01-02T00:00:00Z", lastViewedAt: nil, resolvedAt: nil,
        needsResolution: false, isFavorite: false)
}
