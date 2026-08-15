import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the guide reads, and render for the guide page and
/// full guide shapes.
final class GuidesCommandTests: CLICommandTestCase {

    // MARK: guides list — parse + request build

    func testListParsesPagingOnly() throws {
        let command = try GuidesList.parse(["--limit", "6", "--cursor", "g"])
        XCTAssertEqual(command.limit, 6)
        XCTAssertEqual(command.cursor, "g")
    }

    func testListBuildsExpectedRequest() throws {
        let command = try GuidesList.parse(["--limit", "6"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesList(helperId: "cli-test", messageId: "m1", limit: 6, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: guides get — parse + request build

    func testGetParsesGuideId() throws {
        XCTAssertEqual(try GuidesGet.parse(["g1"]).guideId, "g1")
    }

    func testGetBuildsExpectedRequest() throws {
        let command = try GuidesGet.parse(["g1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesGet.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesGet(helperId: "cli-test", messageId: "m1", guideId: "g1")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: guides list-for-place — parse + request build

    func testListForPlaceParsesIdAndPaging() throws {
        let command = try GuidesListForPlace.parse(["p1", "--limit", "3"])
        XCTAssertEqual(command.placeId, "p1")
        XCTAssertEqual(command.limit, 3)
    }

    func testListForPlaceBuildsExpectedRequest() throws {
        let command = try GuidesListForPlace.parse(["p1", "--limit", "3"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesListForPlace.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesListForPlace(
            helperId: "cli-test", messageId: "m1", placeId: "p1", limit: 3, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — guide page

    func testListRendersGuidePageAsJSON() async throws {
        let page = WirePage(items: [Self.sampleGuide], nextCursor: "next")
        let response = WireResponse.guidePage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try GuidesList.parse([])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Render — full guide

    func testGetRendersGuideAsJSON() async throws {
        let response = WireResponse.guide(helperId: "h", messageId: "m", guide: Self.sampleGuide)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try GuidesGet.parse(["g1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(Self.sampleGuide) + "\n")
    }

    static let sampleGuide = WireGuide(
        id: "g1", name: "Coffee Crawl", sourceURL: nil,
        createdAt: "2026-01-02T00:00:00Z", lastViewedAt: nil,
        placeCount: 3, isFavorite: false)
}
