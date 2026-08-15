import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for `links list` (id-first, §6 #5), and its
/// connections-page render.
final class LinksCommandTests: CLICommandTestCase {

    func testParsesIdKindAndPaging() throws {
        let command = try LinksList.parse(["c1", "person", "--limit", "8", "--cursor", "l"])
        XCTAssertEqual(command.id, "c1")
        XCTAssertEqual(command.kind, "person")
        XCTAssertEqual(command.limit, 8)
        XCTAssertEqual(command.cursor, "l")
    }

    /// Id-first: the FIRST positional is the id, the SECOND is the kind.
    func testPositionalOrderIsIdThenKind() throws {
        let command = try LinksList.parse(["e1", "event"])
        XCTAssertEqual(command.id, "e1")
        XCTAssertEqual(command.kind, "event")
    }

    func testMissingKindIsAParseError() {
        XCTAssertThrowsError(try LinksList.parse(["c1"]))
    }

    func testBuildsExpectedRequest() throws {
        let command = try LinksList.parse(["c1", "person", "--limit", "8"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.linksList.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.linksList(
            helperId: "cli-test", messageId: "m1", id: "c1", kind: "person", limit: 8, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testRendersLinkPageAsJSON() async throws {
        let page = WirePage(items: [
            WireLink(id: "l1", kind: "event", otherId: "e1",
                     note: "Met here.", createdAt: "2026-01-02T00:00:00Z"),
        ], nextCursor: nil)
        let response = WireResponse.linkPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try LinksList.parse(["c1", "person"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }
}
