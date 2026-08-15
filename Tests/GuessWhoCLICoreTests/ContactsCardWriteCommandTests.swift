import ArgumentParser
import Foundation
import GuessWhoMCPWire
import MCP
import XCTest
@testable import GuessWhoCLICore

/// Parse + request-build for `contacts create`, `contacts update`, and
/// `contacts delete-photo`, plus the contact-card echo render. The scalar flags
/// funnel through `ContactScalarOptions`; create additionally merges the list
/// fields from `--json`.
final class ContactsCardWriteCommandTests: CLICommandTestCase {

    // MARK: contacts update — scalars, omitted = absent from the bag

    func testUpdateParsesScalarFlags() throws {
        let command = try ContactsUpdate.parse([
            "c1", "--given-name", "Ada", "--family-name", "Lovelace",
        ])
        XCTAssertEqual(command.contactId, "c1")
        XCTAssertEqual(command.scalars.givenName, "Ada")
        XCTAssertEqual(command.scalars.familyName, "Lovelace")
        XCTAssertNil(command.scalars.middleName)
    }

    func testUpdateBagOmitsUnsetFlagsAndKeepsExplicitEmptyString() throws {
        let command = try ContactsUpdate.parse([
            "c1", "--given-name", "Ada", "--organization", "",
        ])
        let bag = try command.argumentBag()
        // Set flags are present…
        XCTAssertEqual(bag["givenName"], .string("Ada"))
        // …an explicit empty string is sent verbatim (clears the field)…
        XCTAssertEqual(bag["organization"], .string(""))
        // …and an unset flag is absent entirely (the wire PATCH rule).
        XCTAssertNil(bag["middleName"])
        XCTAssertNil(bag["jobTitle"])
        XCTAssertNil(bag["kind"])
    }

    func testUpdateBuildsExpectedRequest() throws {
        let command = try ContactsUpdate.parse([
            "c1", "--kind", "person", "--given-name", "Ada",
            "--organization", "", "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsUpdate.rawValue, arguments: command.argumentBag()))
        var fields = WireContactScalarFields()
        fields.kind = "person"
        fields.givenName = "Ada"
        fields.organization = ""
        let expected = WireRequest.contactsUpdate(
            helperId: "cli-test", messageId: "m1", contactId: "c1",
            fields: fields, idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: contacts create — scalars + --json list fields

    func testCreateBuildsExpectedRequestWithScalarsOnly() throws {
        let command = try ContactsCreate.parse([
            "--kind", "person", "--given-name", "Grace", "--family-name", "Hopper",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsCreate.rawValue, arguments: command.argumentBag()))
        var fields = WireContactFields()
        fields.givenName = "Grace"
        fields.familyName = "Hopper"
        let expected = WireRequest.contactsCreate(
            helperId: "cli-test", messageId: "m1", kind: "person",
            fields: fields, idempotencyToken: nil)
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testCreateMergesJSONListFields() throws {
        let json = "{\"emailAddresses\":[{\"label\":\"work\",\"value\":\"grace@navy.mil\"}]}"
        let command = try ContactsCreate.parse([
            "--given-name", "Grace", "--json", json, "--idempotency-token", "tok",
        ])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsCreate.rawValue, arguments: command.argumentBag()))
        var fields = WireContactFields()
        fields.givenName = "Grace"
        fields.emailAddresses = [WireLabeledValue(label: "work", value: "grace@navy.mil")]
        let expected = WireRequest.contactsCreate(
            helperId: "cli-test", messageId: "m1", kind: nil,
            fields: fields, idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    func testCreateRejectsNonObjectJSON() throws {
        let command = try ContactsCreate.parse(["--json", "[1,2,3]"])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testCreateFlagAndJSONForSameKeyIsUsageError() throws {
        // givenName supplied by both a flag and the --json object.
        let command = try ContactsCreate.parse([
            "--given-name", "Grace", "--json", "{\"givenName\":\"Grace\"}",
        ])
        XCTAssertThrowsError(try command.argumentBag()) { error in
            XCTAssertTrue(error is CLIUsageError)
        }
    }

    func testCreateRejectsNoteShapedJSON() throws {
        // The Apple note is the hard exclusion line. A note-shaped key smuggled
        // through --json reaches the bag, but the production wire builder
        // rejects it — the CLI adds no bypass, so no note is ever written.
        let command = try ContactsCreate.parse(["--json", "{\"note\":\"do not persist\"}"])
        XCTAssertThrowsError(
            try WireRequest.create(
                helperId: "cli-test", messageId: "m1",
                parameters: MCP.CallTool.Parameters(
                    name: MCPTool.contactsCreate.rawValue, arguments: command.argumentBag()))
        ) { error in
            XCTAssertTrue(error is WireRequestError)
        }
    }

    // MARK: contacts delete-photo

    func testDeletePhotoBuildsExpectedRequest() throws {
        let command = try ContactsDeletePhoto.parse(["c1", "--idempotency-token", "tok"])
        let built = try WireRequest.create(
            helperId: "cli-test", messageId: "m1",
            parameters: MCP.CallTool.Parameters(
                name: MCPTool.contactsDeletePhoto.rawValue, arguments: command.argumentBag()))
        let expected = WireRequest.contactsDeletePhoto(
            helperId: "cli-test", messageId: "m1", contactId: "c1", idempotencyToken: "tok")
        XCTAssertEqual(try canonicalEncoding(built), try canonicalEncoding(expected))
    }

    // MARK: Render — contact-card echo + ack

    func testUpdateRendersContactCardEcho() async throws {
        let contact = ContactsReadCommandTests.sampleContact
        let response = WireResponse.contact(helperId: "h", messageId: "m", contact: contact)
        let output = installRuntime(transport: StubCLITransport(response: response))

        let command = try ContactsUpdate.parse(["c1", "--given-name", "Ada"])
        let code = await exitCode { try await command.run() }

        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, try expectedJSONText(contact) + "\n")
        XCTAssertTrue(output.stderr.isEmpty)
    }

    func testDeletePhotoRendersAck() async throws {
        let response = WireResponse.acknowledged(
            helperId: "h", messageId: "m", message: WireAckMessage.photoDeleted)
        let output = installRuntime(transport: StubCLITransport(response: response))
        let command = try ContactsDeletePhoto.parse(["c1"])
        let code = await exitCode { try await command.run() }
        XCTAssertNil(code)
        XCTAssertEqual(output.stdoutString, WireAckMessage.photoDeleted + "\n")
    }
}
