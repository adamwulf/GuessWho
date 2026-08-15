import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the six group writes, plus render for the group
/// echo, the membership result, and the fixed delete ack.
final class GroupsWriteCommandTests: CLICommandTestCase {

    // MARK: create / rename / delete

    func testCreateBuildsExpectedRequest() throws {
        let command = try GroupsCreate.parse(["Book club", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsCreate.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsCreate(
            helperId: "cli-test", messageId: "m1", name: "Book club", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testRenameBuildsExpectedRequest() throws {
        let command = try GroupsRename.parse(["g1", "Reading circle"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsRename.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsRename(
            helperId: "cli-test", messageId: "m1", groupId: "g1", name: "Reading circle",
            idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testDeleteBuildsExpectedRequest() throws {
        let command = try GroupsDelete.parse(["g1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsDelete.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsDelete(
            helperId: "cli-test", messageId: "m1", groupId: "g1", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: add-members / remove-members (variadic)

    func testAddMembersParsesVariadicIds() throws {
        let command = try GroupsAddMembers.parse(["g1", "c1", "c2", "c3"])
        XCTAssertEqual(command.groupId, "g1")
        XCTAssertEqual(command.contactIds, ["c1", "c2", "c3"])
    }

    func testAddMembersBuildsExpectedRequest() throws {
        let command = try GroupsAddMembers.parse(["g1", "c1", "c2", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsAddMembers.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsAddMembers(
            helperId: "cli-test", messageId: "m1", groupId: "g1",
            contactIds: ["c1", "c2"], idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testRemoveMembersBuildsExpectedRequest() throws {
        let command = try GroupsRemoveMembers.parse(["g1", "c1"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsRemoveMembers.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsRemoveMembers(
            helperId: "cli-test", messageId: "m1", groupId: "g1",
            contactIds: ["c1"], idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: set-favorite (required flag)

    func testSetFavoriteParsesFlagBothWays() throws {
        XCTAssertEqual(try GroupsSetFavorite.parse(["g1", "--favorite"]).favorite, true)
        XCTAssertEqual(try GroupsSetFavorite.parse(["g1", "--no-favorite"]).favorite, false)
        XCTAssertNil(try GroupsSetFavorite.parse(["g1"]).favorite)
    }

    func testSetFavoriteMissingFlagIsUsageError() throws {
        let command = try GroupsSetFavorite.parse(["g1"])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testSetFavoriteBuildsExpectedRequest() throws {
        let command = try GroupsSetFavorite.parse(["g1", "--no-favorite"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.groupsSetFavorite.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.groupsSetFavorite(
            helperId: "cli-test", messageId: "m1", groupId: "g1", favorite: false, idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render

    func testCreateRendersGroupEcho() async throws {
        let group = WireGroup(id: "g1", name: "Book club", isFavorite: false)
        let response = WireResponse.group(helperId: "h", messageId: "m", group: group)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try GroupsCreate.parse(["Book club"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(group) + "\n")
    }

    func testAddMembersRendersMembershipResult() async throws {
        let result = WireGroupMembershipResult(
            groupId: "g1", appliedContactIds: ["c1", "c2"], failures: [])
        let response = WireResponse.groupMembership(helperId: "h", messageId: "m", result: result)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try GroupsAddMembers.parse(["g1", "c1", "c2"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        // The wire projects the membership result through its own agent-facing
        // wrapper; compare against exactly what asCallToolResult would print.
        let expected = CLIResponseRenderer.textContent(of: response.asCallToolResult()) + "\n"
        XCTAssertEqual(output.stdoutString, expected)
    }

    func testDeleteRendersAck() async throws {
        let response = WireResponse.acknowledged(
            helperId: "h", messageId: "m", message: WireAckMessage.groupDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try GroupsDelete.parse(["g1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.groupDeleted + "\n")
    }
}
