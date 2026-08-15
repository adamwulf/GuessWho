import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the Phase 3 favorites writes (set, reorder), the
/// first use of `--json`, and render for their fixed acks.
final class FavoritesWriteCommandTests: CLICommandTestCase {

    // MARK: favorites set — parse + request build (flag required)

    func testSetParsesKindIdAndFlag() throws {
        let command = try FavoritesSet.parse(["event", "e1", "--favorite"])
        XCTAssertEqual(command.kind, "event")
        XCTAssertEqual(command.id, "e1")
        XCTAssertEqual(command.favorite, true)
    }

    func testSetMissingFlagIsUsageError() throws {
        let command = try FavoritesSet.parse(["event", "e1"])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testSetBuildsExpectedRequestWhenTrue() throws {
        let command = try FavoritesSet.parse(["event", "e1", "--favorite", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.favoritesSet.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.favoritesSet(
            helperId: "cli-test", messageId: "m1", kind: .event, id: "e1",
            favorite: true, idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testSetBuildsExpectedRequestWhenFalse() throws {
        let command = try FavoritesSet.parse(["place", "p1", "--no-favorite"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.favoritesSet.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.favoritesSet(
            helperId: "cli-test", messageId: "m1", kind: .place, id: "p1",
            favorite: false, idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: favorites reorder — parse + request build (--json)

    func testReorderParsesJSONFlags() throws {
        XCTAssertEqual(try FavoritesReorder.parse(["--json", "[]"]).json, "[]")
        XCTAssertEqual(try FavoritesReorder.parse(["--json-file", "/tmp/f.json"]).jsonFile, "/tmp/f.json")
        XCTAssertEqual(try FavoritesReorder.parse(["--json", "-"]).json, "-")
    }

    func testReorderBuildsExpectedRequestFromInlineJSON() throws {
        let command = try FavoritesReorder.parse([
            "--json", "[{\"kind\":\"contact\",\"id\":\"c1\"},{\"kind\":\"event\",\"id\":\"e1\"}]",
            "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.favoritesReorder.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.favoritesReorder(
            helperId: "cli-test", messageId: "m1",
            favorites: [
                WireFavoriteIdentity(kind: .contact, id: "c1"),
                WireFavoriteIdentity(kind: .event, id: "e1"),
            ],
            idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testReorderMissingJSONIsUsageErrorThroughFunnel() async throws {
        // No --json: the `favorites` key is absent from the bag, so the wire
        // builder answers missingArgument, mapped to usage exit 64.
        let output = installRuntime(transport: StubCLITransport(response: ack("unused")))
        let command = try FavoritesReorder.parse([])
        let code = await exitCode { try await command.run() }
        XCTAssertEqual(code, CLIExitCode.usage.rawValue)
        XCTAssertFalse(output.stderr.isEmpty)
        XCTAssertTrue(output.stdoutString.isEmpty)
    }

    func testReorderMalformedJSONIsUsageError() async throws {
        let output = installRuntime(transport: StubCLITransport(response: ack("unused")))
        let command = try FavoritesReorder.parse(["--json", "[{not json"])
        let code = await exitCode { try await command.run() }
        XCTAssertEqual(code, CLIExitCode.usage.rawValue)
        XCTAssertTrue(output.stdoutString.isEmpty)
    }

    // MARK: Render — fixed acks

    func testSetRendersAck() async throws {
        let output = installRuntime(transport: StubCLITransport(response: ack(WireAckMessage.genericFavoriteSet)))
        let command = try FavoritesSet.parse(["event", "e1", "--favorite"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.genericFavoriteSet + "\n")
    }

    func testReorderRendersAck() async throws {
        let output = installRuntime(transport: StubCLITransport(response: ack(WireAckMessage.favoritesReordered)))
        let command = try FavoritesReorder.parse(["--json", "[{\"kind\":\"contact\",\"id\":\"c1\"}]"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.favoritesReordered + "\n")
    }

    // MARK: helpers

    private func ack(_ message: String) -> WireResponse {
        .acknowledged(helperId: "h", messageId: "m", message: message)
    }
}
