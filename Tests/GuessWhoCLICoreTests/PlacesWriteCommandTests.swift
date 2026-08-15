import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for `places delete`, and render for its fixed ack.
final class PlacesWriteCommandTests: CLICommandTestCase {

    func testDeleteParsesPlaceId() throws {
        let command = try PlacesDelete.parse(["p1"])
        XCTAssertEqual(command.placeId, "p1")
        XCTAssertNil(command.idempotencyToken)
    }

    func testDeleteBuildsExpectedRequest() throws {
        let command = try PlacesDelete.parse(["p1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.placesDelete.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.placesDelete(
            helperId: "cli-test", messageId: "m1", placeId: "p1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testDeleteRendersAck() async throws {
        let response = WireResponse.acknowledged(helperId: "h", messageId: "m", message: WireAckMessage.placeDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try PlacesDelete.parse(["p1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.placeDeleted + "\n")
    }
}
