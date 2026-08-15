import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for `organizations rename-department` and the
/// `{affectedCount}` result render.
final class OrganizationsWriteCommandTests: CLICommandTestCase {

    func testRenameDepartmentParsesPositionals() throws {
        let command = try OrganizationsRenameDepartment.parse(["o1", "Sales", "Revenue"])
        XCTAssertEqual(command.organizationId, "o1")
        XCTAssertEqual(command.oldName, "Sales")
        XCTAssertEqual(command.newName, "Revenue")
    }

    func testRenameDepartmentBuildsExpectedRequest() throws {
        let command = try OrganizationsRenameDepartment.parse([
            "o1", "Sales", "Revenue", "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.organizationsRenameDepartment.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.organizationsRenameDepartment(
            helperId: "cli-test", messageId: "m1", organizationId: "o1",
            oldName: "Sales", newName: "Revenue", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testRenameDepartmentRendersAffectedCount() async throws {
        let result = WireDepartmentRenameResult(affectedCount: 3)
        let response = WireResponse.departmentRename(helperId: "h", messageId: "m", result: result)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try OrganizationsRenameDepartment.parse(["o1", "Sales", "Revenue"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(result) + "\n")
    }
}
