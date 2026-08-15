import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the Phase 3 connection writes (create, delete), and
/// render for the connection echo and the fixed removal ack.
final class LinksWriteCommandTests: CLICommandTestCase {

    // MARK: links create — parse + request build

    func testCreateParsesEndpointsAndNote() throws {
        let command = try LinksCreate.parse(["c1", "person", "e1", "event", "--note", "Met here"])
        XCTAssertEqual(command.fromId, "c1")
        XCTAssertEqual(command.fromKind, "person")
        XCTAssertEqual(command.toId, "e1")
        XCTAssertEqual(command.toKind, "event")
        XCTAssertEqual(command.note, "Met here")
    }

    func testCreateBuildsExpectedRequestWithNote() throws {
        let command = try LinksCreate.parse([
            "c1", "person", "e1", "event", "--note", "Met here", "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.linksCreate.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.linksCreate(
            helperId: "cli-test", messageId: "m1", fromId: "c1", fromKind: "person",
            toId: "e1", toKind: "event", note: "Met here", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testCreateBuildsExpectedRequestWithoutNote() throws {
        let command = try LinksCreate.parse(["c1", "person", "p1", "place"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.linksCreate.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.linksCreate(
            helperId: "cli-test", messageId: "m1", fromId: "c1", fromKind: "person",
            toId: "p1", toKind: "place", note: nil, idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: links delete — parse + request build

    func testDeleteParsesLinkId() throws {
        XCTAssertEqual(try LinksDelete.parse(["l1"]).linkId, "l1")
    }

    func testDeleteBuildsExpectedRequest() throws {
        let command = try LinksDelete.parse(["l1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.linksDelete.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.linksDelete(
            helperId: "cli-test", messageId: "m1", linkId: "l1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — connection echo

    func testCreateRendersLinkEchoAsJSON() async throws {
        let link = WireLink(id: "l1", kind: "event", otherId: "e1", note: "Met here",
                            createdAt: "2026-01-02T00:00:00Z")
        let response = WireResponse.link(helperId: "h", messageId: "m", link: link)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try LinksCreate.parse(["c1", "person", "e1", "event", "--note", "Met here"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(link) + "\n")
    }

    // MARK: Render — removal ack

    func testDeleteRendersAck() async throws {
        let response = WireResponse.acknowledged(helperId: "h", messageId: "m", message: WireAckMessage.linkRemoved)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try LinksDelete.parse(["l1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.linkRemoved + "\n")
    }
}
