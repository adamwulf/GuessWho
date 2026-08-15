import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for `groups list-for-contact`, and its group-page
/// render (the same page shape contacts list-groups uses).
final class GroupsReadCommandTests: CLICommandTestCase {

    func testParsesContactIdAndPaging() throws {
        let command = try GroupsListForContact.parse(["c1", "--limit", "2", "--cursor", "g"])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.limit, 2)
        XCTAssertEqual(command.cursor, "g")
    }

    func testMissingContactIdIsAParseError() {
        XCTAssertThrowsError(try GroupsListForContact.parse([]))
    }

    func testBuildsExpectedRequest() throws {
        let command = try GroupsListForContact.parse(["c1", "--limit", "2"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsListForContact.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsListForContact(
            helperId: "cli-test", messageId: "m1", contactId: "c1", limit: 2, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testRendersGroupPageAsJSON() async throws {
        let page = WirePage(items: [
            WireGroup(id: "g1", name: "Book club", isFavorite: false),
        ], nextCursor: nil)
        let response = WireResponse.groupPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try GroupsListForContact.parse(["c1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }
}
