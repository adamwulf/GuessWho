import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the Phase 3 event-tag writes, and render for the
/// tag echo and the fixed delete ack.
final class EventsWriteCommandTests: CLICommandTestCase {

    // MARK: events add-tag — parse + request build

    func testAddTagParsesIdAndText() throws {
        let command = try EventsAddTag.parse(["e1", "fundraiser"])
        XCTAssertEqual(command.eventId, "e1")
        XCTAssertEqual(command.text, "fundraiser")
    }

    func testAddTagBuildsExpectedRequest() throws {
        let command = try EventsAddTag.parse(["e1", "fundraiser", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.eventsAddTag.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.eventsAddTag(
            helperId: "cli-test", messageId: "m1", eventId: "e1", text: "fundraiser", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: events edit-tag — parse + request build

    func testEditTagParsesIdsAndText() throws {
        let command = try EventsEditTag.parse(["e1", "t1", "gala"])
        XCTAssertEqual(command.eventId, "e1")
        XCTAssertEqual(command.tagId, "t1")
        XCTAssertEqual(command.text, "gala")
    }

    func testEditTagBuildsExpectedRequest() throws {
        let command = try EventsEditTag.parse(["e1", "t1", "gala"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.eventsEditTag.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.eventsEditTag(
            helperId: "cli-test", messageId: "m1", eventId: "e1", tagId: "t1",
            text: "gala", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: events delete-tag — parse + request build

    func testDeleteTagParsesIds() throws {
        let command = try EventsDeleteTag.parse(["e1", "t1"])
        XCTAssertEqual(command.eventId, "e1")
        XCTAssertEqual(command.tagId, "t1")
    }

    func testDeleteTagBuildsExpectedRequest() throws {
        let command = try EventsDeleteTag.parse(["e1", "t1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.eventsDeleteTag.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.eventsDeleteTag(
            helperId: "cli-test", messageId: "m1", eventId: "e1", tagId: "t1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — tag echo

    func testAddTagRendersTagEchoAsJSON() async throws {
        let tag = WireTag(id: "t1", text: "fundraiser", createdAt: "2026-07-01T00:00:00Z")
        let response = WireResponse.tag(helperId: "h", messageId: "m", tag: tag)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try EventsAddTag.parse(["e1", "fundraiser"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(tag) + "\n")
    }

    // MARK: Render — delete ack

    func testDeleteTagRendersAck() async throws {
        let response = WireResponse.acknowledged(helperId: "h", messageId: "m", message: WireAckMessage.tagDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try EventsDeleteTag.parse(["e1", "t1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.tagDeleted + "\n")
    }
}
