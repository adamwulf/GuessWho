import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the organization reads, and render for the members
/// page (contact summaries) and the department-name page shapes.
final class OrganizationsCommandTests: CLICommandTestCase {

    // MARK: list-members — parse + request build

    func testListMembersParsesIdAndPaging() throws {
        let command = try OrganizationsListMembers.parse(["o1", "--limit", "10", "--cursor", "c"])
        XCTAssertEqual(command.organizationId, "o1")
        XCTAssertEqual(command.limit, 10)
        XCTAssertEqual(command.cursor, "c")
    }

    func testListMembersBuildsExpectedRequest() throws {
        let command = try OrganizationsListMembers.parse(["o1", "--limit", "10"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.organizationsListMembers.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.organizationsListMembers(
            helperId: "cli-test", messageId: "m1", organizationId: "o1", limit: 10, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: list-departments — parse + request build

    func testListDepartmentsParsesId() throws {
        XCTAssertEqual(try OrganizationsListDepartments.parse(["o1"]).organizationId, "o1")
    }

    func testListDepartmentsBuildsExpectedRequest() throws {
        let command = try OrganizationsListDepartments.parse(["o1", "--cursor", "d"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.organizationsListDepartments.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.organizationsListDepartments(
            helperId: "cli-test", messageId: "m1", organizationId: "o1", limit: nil, cursor: "d")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: list-department-members — parse + request build

    func testListDepartmentMembersParsesIdAndDepartment() throws {
        let command = try OrganizationsListDepartmentMembers.parse(["o1", "Engineering", "--limit", "5"])
        XCTAssertEqual(command.organizationId, "o1")
        XCTAssertEqual(command.department, "Engineering")
        XCTAssertEqual(command.limit, 5)
    }

    func testListDepartmentMembersMissingDepartmentIsAParseError() {
        XCTAssertThrowsError(try OrganizationsListDepartmentMembers.parse(["o1"]))
    }

    func testListDepartmentMembersBuildsExpectedRequest() throws {
        let command = try OrganizationsListDepartmentMembers.parse(["o1", "Engineering", "--limit", "5"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.organizationsListDepartmentMembers.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.organizationsListDepartmentMembers(
            helperId: "cli-test", messageId: "m1", organizationId: "o1",
            department: "Engineering", limit: 5, cursor: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — members page (contact summaries)

    func testListMembersRendersContactPageAsJSON() async throws {
        let page = WirePage(items: [
            WireContactSummary(id: "c1", kind: "person", name: "Ada Lovelace",
                               organization: "Analytical Engines", jobTitle: "Programmer"),
        ], nextCursor: "next")
        let response = WireResponse.contactPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try OrganizationsListMembers.parse(["o1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }

    // MARK: Render — department-name page

    func testListDepartmentsRendersDepartmentPageAsJSON() async throws {
        let page = WirePage(items: ["Engineering", "Sales"], nextCursor: nil)
        let response = WireResponse.departmentPage(helperId: "h", messageId: "m", page: page)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try OrganizationsListDepartments.parse(["o1"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(page) + "\n")
    }
}
