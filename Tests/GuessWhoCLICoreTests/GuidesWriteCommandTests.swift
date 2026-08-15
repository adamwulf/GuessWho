import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the Phase 3 guide writes (create with `--json`
/// places, delete, reorder-places), and render for the guide echo and acks.
final class GuidesWriteCommandTests: CLICommandTestCase {

    // MARK: guides create — parse + request build (--json places)

    func testCreateParsesNameAndJSONFlags() throws {
        let command = try GuidesCreate.parse(["Coffee Crawl", "--json", "[]"])
        XCTAssertEqual(command.name, "Coffee Crawl")
        XCTAssertEqual(command.json, "[]")
        XCTAssertNil(command.jsonFile)
    }

    func testCreateBuildsExpectedRequestWithPlaces() throws {
        let command = try GuidesCreate.parse([
            "Coffee Crawl",
            "--json", "[{\"address\":\"1 Main St\"},{\"address\":\"2 Oak Ave\",\"latitude\":1.5,\"longitude\":2.5}]",
            "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesCreate.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesCreate(
            helperId: "cli-test", messageId: "m1", name: "Coffee Crawl",
            places: [
                WireNewPlace(address: "1 Main St", latitude: nil, longitude: nil),
                WireNewPlace(address: "2 Oak Ave", latitude: 1.5, longitude: 2.5),
            ],
            idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testCreateBuildsExpectedRequestWithoutPlaces() throws {
        let command = try GuidesCreate.parse(["Coffee Crawl"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesCreate.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesCreate(
            helperId: "cli-test", messageId: "m1", name: "Coffee Crawl",
            places: [], idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testCreateMalformedJSONIsUsageError() async throws {
        let output = installRuntime(transport: StubCLITransport(response: ack("unused")))
        let command = try GuidesCreate.parse(["Coffee Crawl", "--json", "[{bad"])
        let code = await exitCode { try await command.run() }
        XCTAssertEqual(code, CLIExitCode.usage.rawValue)
        XCTAssertTrue(output.stdoutString.isEmpty)
    }

    // MARK: guides delete — parse + request build

    func testDeleteBuildsExpectedRequest() throws {
        let command = try GuidesDelete.parse(["g1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesDelete.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesDelete(
            helperId: "cli-test", messageId: "m1", guideId: "g1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: guides reorder-places — parse + request build (variadic)

    func testReorderPlacesParsesGuideIdAndVariadicPlaceIds() throws {
        let command = try GuidesReorderPlaces.parse(["g1", "p1", "p2", "p3"])
        XCTAssertEqual(command.guideId, "g1")
        XCTAssertEqual(command.placeIds, ["p1", "p2", "p3"])
    }

    func testReorderPlacesBuildsExpectedRequest() throws {
        let command = try GuidesReorderPlaces.parse(["g1", "p1", "p2", "p3", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.guidesReorderPlaces.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.guidesReorderPlaces(
            helperId: "cli-test", messageId: "m1", guideId: "g1",
            placeIds: ["p1", "p2", "p3"], idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — guide echo

    func testCreateRendersGuideEchoAsJSON() async throws {
        let guide = WireGuide(
            id: "g1", name: "Coffee Crawl", sourceURL: nil,
            createdAt: "2026-01-02T00:00:00Z", lastViewedAt: nil,
            placeCount: 2, isFavorite: false)
        let response = WireResponse.guide(helperId: "h", messageId: "m", guide: guide)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try GuidesCreate.parse(["Coffee Crawl"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(guide) + "\n")
    }

    // MARK: Render — acks

    func testDeleteRendersAck() async throws {
        let output = installRuntime(transport: StubCLITransport(response: ack(WireAckMessage.guideDeleted)))
        let command = try GuidesDelete.parse(["g1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.guideDeleted + "\n")
    }

    func testReorderPlacesRendersAck() async throws {
        let output = installRuntime(transport: StubCLITransport(response: ack(WireAckMessage.placesReordered)))
        let command = try GuidesReorderPlaces.parse(["g1", "p1", "p2"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.placesReordered + "\n")
    }

    // MARK: helpers

    private func ack(_ message: String) -> WireResponse {
        .acknowledged(helperId: "h", messageId: "m", message: message)
    }
}
