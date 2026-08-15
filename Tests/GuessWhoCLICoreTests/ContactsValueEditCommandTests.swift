import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for the single-entry list value edits (`add-value`,
/// `delete-value`, `edit-value`) and the contact-card echo render.
final class ContactsValueEditCommandTests: CLICommandTestCase {

    // MARK: field positional validation

    func testFieldPositionalAcceptsEveryListFieldToken() throws {
        for token in ["phone", "email", "url", "related_name", "date"] {
            let command = try ContactsAddValue.parse(["c1", token, "v"])
            XCTAssertEqual(command.field.rawValue, token)
        }
    }

    func testFieldPositionalRejectsUnknownToken() {
        XCTAssertThrowsError(try ContactsAddValue.parse(["c1", "bogus", "v"]))
    }

    // MARK: add-value

    func testAddValueBuildsExpectedRequestWithLabel() throws {
        let command = try ContactsAddValue.parse([
            "c1", "phone", "+1 555 0100", "--label", "mobile", "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsAddValue.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsAddValue(
            helperId: "cli-test", messageId: "m1", contactId: "c1", field: "phone",
            value: "+1 555 0100", label: "mobile", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testAddValueBuildsExpectedRequestWithoutLabel() throws {
        let command = try ContactsAddValue.parse(["c1", "related_name", "Ada"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsAddValue.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsAddValue(
            helperId: "cli-test", messageId: "m1", contactId: "c1", field: "related_name",
            value: "Ada", label: nil, idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: delete-value

    func testDeleteValueBuildsExpectedRequest() throws {
        let command = try ContactsDeleteValue.parse(["c1", "email", "grace@navy.mil"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsDeleteValue.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsDeleteValue(
            helperId: "cli-test", messageId: "m1", contactId: "c1", field: "email",
            value: "grace@navy.mil", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: edit-value

    func testEditValueBuildsExpectedRequestWithNewLabel() throws {
        let command = try ContactsEditValue.parse([
            "c1", "url", "old.example.com", "new.example.com", "--new-label", "homepage",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsEditValue.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsEditValue(
            helperId: "cli-test", messageId: "m1", contactId: "c1", field: "url",
            currentValue: "old.example.com", newValue: "new.example.com",
            newLabel: "homepage", idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — contact-card echo

    func testAddValueRendersContactCardEcho() async throws {
        let contact = ContactsReadCommandTests.sampleContact
        let response = WireResponse.contact(helperId: "h", messageId: "m", contact: contact)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsAddValue.parse(["c1", "phone", "+1 555 0100"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(contact) + "\n")
    }
}
