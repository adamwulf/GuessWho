import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse → request-build → render for `contacts search`, the read command.
final class ContactsSearchTests: XCTestCase {

    // MARK: Parse

    func testParsesQueryOnly() throws {
        let command = try ContactsSearch.parse(["Ada"])
        XCTAssertEqual(command.query, "Ada")
        XCTAssertNil(command.limit)
        XCTAssertNil(command.cursor)
    }

    func testParsesLimitAndCursor() throws {
        let command = try ContactsSearch.parse(["Ada", "--limit", "5", "--cursor", "abc"])
        XCTAssertEqual(command.query, "Ada")
        XCTAssertEqual(command.limit, 5)
        XCTAssertEqual(command.cursor, "abc")
    }

    func testMissingQueryIsAParseError() {
        XCTAssertThrowsError(try ContactsSearch.parse([]))
    }

    func testNonIntegerLimitIsAParseError() {
        XCTAssertThrowsError(try ContactsSearch.parse(["Ada", "--limit", "lots"]))
    }

    // MARK: Request build (argumentBag → WireRequest.create, byte-compared)

    func testBuildsExpectedRequestWithAllArguments() throws {
        let command = try ContactsSearch.parse(["Ada", "--limit", "5", "--cursor", "abc"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSearch.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSearch(
            helperId: "cli-test", messageId: "m1", query: "Ada", limit: 5, cursor: "abc")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testBuildsExpectedRequestWithOnlyQuery() throws {
        let command = try ContactsSearch.parse(["Ada"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsSearch.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsSearch(
            helperId: "cli-test", messageId: "m1", query: "Ada", limit: nil, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testEmptyQueryIsRejectedByTheSharedBuilder() throws {
        let command = try ContactsSearch.parse([""])
        XCTAssertThrowsError(
            try WireRequest.create(
                helperId: "cli-test", messageId: "m1",
                parameters: MCP.CallTool.Parameters(
                    name: MCPTool.contactsSearch.rawValue, arguments: command.argumentBag()))
        ) { error in
            XCTAssertTrue(error is WireRequestError)
        }
    }

    // MARK: Funnel plumbing

    /// The funnel sends the built request through the transport with the tool's
    /// own timeout (contacts_search = 10 s), and the request names the right
    /// tool with the right query.
    func testFunnelSendsRequestThroughTransportWithToolTimeout() async throws {
        let page = WirePage<WireContactSummary>(items: [], nextCursor: nil)
        let transport = RecordingCLITransport(
            response: .contactPage(helperId: "h", messageId: "m", page: page))
        installRuntime(transport: transport)

        let command = try ContactsSearch.parse(["Ada", "--limit", "7"])
        _ = await exitCode { try await command.run() }

        XCTAssertEqual(transport.timeout, MCPTool.contactsSearch.timeout)
        guard case .contactsSearch(_, _, let query, let limit, _)? = transport.recorded else {
            return XCTFail("expected a contactsSearch request")
        }
        XCTAssertEqual(query, "Ada")
        XCTAssertEqual(limit, 7)
    }

    // MARK: Render (full funnel through a stub transport)

    func testRendersContactPageAsJSONToStdout() async throws {
        let page = WirePage(items: [
            WireContactSummary(
                id: "c1", kind: "person", name: "Ada Lovelace",
                organization: "Analytical Engines", jobTitle: "Programmer"),
        ], nextCursor: "next")
        let response = WireResponse.contactPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsSearch.parse(["Ada"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code, "success returns normally")
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testRendersTypedErrorToStderrWithExitOne() async throws {
        let response = WireResponse.error(
            helperId: "h", messageId: "m", code: .notFound,
            message: WireErrorMessage.notFoundContact)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsSearch.parse(["Ada"])
        let code = await exitCode { try await command.run() }

        XCTAssertEqual(code, CLIExitCode.appError.rawValue)
        XCTAssertTrue(output.stdoutString.isEmpty)
        XCTAssertEqual(output.stderr, WireErrorMessage.notFoundContact + "\n")
    }
}
