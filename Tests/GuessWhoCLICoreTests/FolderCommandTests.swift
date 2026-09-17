import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

final class FolderCommandTests: CLICommandTestCase {
    func testEveryFolderCommandParsesAndBuildsExpectedRequest() throws {
        let commands: [(any CLIToolCommand, WireRequest)] = [
            (try FoldersList.parse(["--limit", "2", "--cursor", "o2"]),
             .foldersList(helperId: "h", messageId: "m", limit: 2, cursor: "o2")),
            (try FoldersMembers.parse(["f1", "--limit", "2", "--cursor", "cursor"]),
             .foldersListMembers(helperId: "h", messageId: "m", folderId: "f1", limit: 2, cursor: "cursor")),
            (try FoldersCreate.parse(["Family", "--in", "f1", "--idempotency-token", "token"]),
             .foldersCreate(helperId: "h", messageId: "m", name: "Family", parentFolderId: "f1", idempotencyToken: "token")),
            (try FoldersRename.parse(["f1", "Friends", "--idempotency-token", "token"]),
             .foldersRename(helperId: "h", messageId: "m", folderId: "f1", name: "Friends", idempotencyToken: "token")),
            (try FoldersMove.parse(["f1", "--to", "f2", "--idempotency-token", "token"]),
             .foldersMove(helperId: "h", messageId: "m", folderId: "f1", parentFolderId: "f2", idempotencyToken: "token")),
            (try FoldersDelete.parse(["f1", "--idempotency-token", "token"]),
             .foldersDelete(helperId: "h", messageId: "m", folderId: "f1", idempotencyToken: "token")),
            (try GroupsMove.parse(["g1", "--to", "f1", "--idempotency-token", "token"]),
             .groupsMove(helperId: "h", messageId: "m", groupId: "g1", parentFolderId: "f1", idempotencyToken: "token")),
        ]
        for (command, expected) in commands {
            let request = try WireRequest.create(
                helperId: "h", messageId: "m",
                parameters: MCP.CallTool.Parameters(name: type(of: command).tool.rawValue, arguments: command.argumentBag()))
            XCTAssertEqual(try canonicalEncoding(request), try canonicalEncoding(expected))
            let decoded = try JSONDecoder().decode(WireRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(try canonicalEncoding(decoded), try canonicalEncoding(expected))
            XCTAssertEqual(decoded.helperId, "h")
            XCTAssertEqual(decoded.messageId, "m")
            XCTAssertEqual(decoded.tool, type(of: command).tool)
            XCTAssertEqual(decoded.idempotencyToken, expected.idempotencyToken)
        }
    }

    func testTopLevelDestinationsAreOmittedOrNull() throws {
        let commands: [any CLIToolCommand] = [
            try FoldersCreate.parse(["Family"]), try FoldersMove.parse(["f1"]), try GroupsMove.parse(["g1"]),
        ]
        for command in commands {
            var args = try command.argumentBag()
            XCTAssertNil(args["parentFolderId"])
            let omitted = try WireRequest.create(helperId: "h", messageId: "m", parameters:
                MCP.CallTool.Parameters(name: type(of: command).tool.rawValue, arguments: args))
            args["parentFolderId"] = .null
            let null = try WireRequest.create(helperId: "h", messageId: "m", parameters:
                MCP.CallTool.Parameters(name: type(of: command).tool.rawValue, arguments: args))
            XCTAssertEqual(try canonicalEncoding(omitted), try canonicalEncoding(null))
            args["parentFolderId"] = .int(4)
            XCTAssertThrowsError(try WireRequest.create(helperId: "h", messageId: "m", parameters:
                MCP.CallTool.Parameters(name: type(of: command).tool.rawValue, arguments: args)))
        }
    }

    func testFolderResponsesRenderAndRoundTrip() throws {
        let folder = WireFolder(id: "f1", name: "Family", parentFolderId: nil)
        let responses: [WireResponse] = [
            .folder(helperId: "h", messageId: "m", folder: folder),
            .folderPage(helperId: "h", messageId: "m", page: WirePage(items: [folder], nextCursor: "o1")),
            .folderMemberPage(helperId: "h", messageId: "m", page:
                WireFolderMemberPage(items: [], nextCursor: nil, partial: true, unloadedGroupIds: ["g1"])),
        ]
        for response in responses {
            let decoded = try JSONDecoder().decode(WireResponse.self, from: JSONEncoder().encode(response))
            XCTAssertEqual(decoded.helperId, "h")
            XCTAssertEqual(decoded.messageId, "m")
            XCTAssertEqual(decoded.readdressed(helperId: "h2", messageId: "m2").messageId, "m2")
            let output = CapturingCLIOutput()
            XCTAssertEqual(CLIResponseRenderer.render(decoded, to: output), .success)
            XCTAssertEqual(output.stdoutString, CLIResponseRenderer.textContent(of: response.asCallToolResult()) + "\n")
        }
    }

    func testFolderMembersCommandIsReachableAtSpecifiedPath() throws {
        let parsed = try GuessWhoCLIRoot.parseAsRoot(["folders", "members", "f1"])
        XCTAssertTrue(parsed is FoldersMembers)
        XCTAssertEqual(CLICommandRegistry.derivedPath(for: .foldersListMembers), "folders members")
    }

    func testUnknownToolReportsUnavailableVersion() {
        XCTAssertThrowsError(try WireRequest.create(helperId: "h", messageId: "m", parameters:
            MCP.CallTool.Parameters(name: "folders_future_tool", arguments: [:]))) { error in
            guard case WireRequestError.unknownTool = error else {
                return XCTFail("Expected an unknown tool error")
            }
            XCTAssertTrue(String(describing: error).contains("unavailable in this version"))
            XCTAssertTrue(String(describing: error).contains("Update GuessWho"))
        }
    }
}
