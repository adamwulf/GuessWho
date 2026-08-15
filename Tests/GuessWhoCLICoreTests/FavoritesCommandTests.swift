import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for `favorites list`, and its favorites-page render.
final class FavoritesCommandTests: CLICommandTestCase {

    func testParsesPagingOnly() throws {
        let command = try FavoritesList.parse(["--limit", "12", "--cursor", "f"])
        XCTAssertEqual(command.limit, 12)
        XCTAssertEqual(command.cursor, "f")
    }

    func testBuildsExpectedRequest() throws {
        let command = try FavoritesList.parse(["--limit", "12"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.favoritesList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.favoritesList(
            helperId: "cli-test", messageId: "m1", limit: 12, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testRendersFavoritePageAsJSON() async throws {
        let page = WirePage(items: [
            WireFavorite(kind: .contact, id: "c1", displayName: "Ada Lovelace",
                         addedAt: "2026-01-02T00:00:00Z", isAvailable: true),
        ], nextCursor: nil)
        let response = WireResponse.favoritePage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try FavoritesList.parse([])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }
}
